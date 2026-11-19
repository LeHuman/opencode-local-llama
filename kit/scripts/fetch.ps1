# scripts/fetch.ps1 - fetch the framework binaries (llama.cpp CUDA build).
# No model is hardcoded: pass -Gguf to download any GGUF by URL.
#   (no args)                      install/upgrade llama.cpp to the newest build
#   -Gguf <url> [-FileName name] [-MinGb n]   also download that GGUF into $MODELS_DIR
#   -CheckOnly                     validate prerequisites and exit
# Re-runnable: an installed build that is already current is left alone; pass
# -Update to force a re-download. Interrupted downloads resume via curl -C -.
# Windows only.
param(
    [string]$Gguf,
    [string]$FileName,
    [double]$MinGb = 0,
    [switch]$Update,
    [switch]$CheckOnly
)
. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = "Stop"
Assert-KitRoot

# ---- Prerequisites ------------------------------------------------------------
if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    throw "nvidia-smi not found - an NVIDIA GPU + driver is required."
}
$gpuName = (& nvidia-smi --query-gpu=name --format=csv,noheader | Select-Object -First 1)
$freeVram = Get-FreeVramGb
Write-Host ("GPU : {0}   free VRAM: {1} GB" -f $gpuName, $freeVram)
if ($freeVram -ge 0 -and $freeVram -lt 7.5) {
    Write-Warning "Less than 7.5 GB VRAM free. Close GPU-heavy apps, or lower `$NUM_CTX in scripts/env.ps1 (e.g. 16384)."
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe not found - Windows 10 1803+ ships it in System32; check PATH."
}

$drive = Get-PSDrive ($MODELS_DIR.Substring(0, 1))
$freeDiskGb = [math]::Round($drive.Free / 1GB, 1)
Write-Host ("Disk: {0} GB free on {1}: (models folder)" -f $freeDiskGb, $drive.Name)

# Optional: opencode status (informational, never fails the fetch)
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    Write-Host "opencode: installed (add the plugin or point a provider at $BASE_URL/v1)"
} else {
    Write-Host "opencode: not installed (optional - llama-server exposes the OpenAI API regardless)"
}

if ($CheckOnly) {
    Write-Host "Check-only mode: prerequisites look usable." -ForegroundColor Green
    exit 0
}

# ---- Binaries -----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $MODELS_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $TOOLS_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
Initialize-ModelsConfig

function Get-InstalledBuild($server) {
    # llama-server --version prints "version: 1.0.0-dev (build 12466, commit ...)"
    # and exits non-zero, so keep stderr out of the terminating-error path.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = (& $server.FullName --version 2>&1 | Out-String)
        if ($out -match 'build\s+(\d+)') { return [int]$Matches[1] }
    } catch { }
    finally { $ErrorActionPreference = $prev }
    return 0
}

$headers = @{ "User-Agent" = "local-llm" }
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15" -Headers $headers -TimeoutSec 60

# releases/latest can be a pointer-only v1.0.0 release (nightly-tag.txt only),
# so scan for the newest tagged build with both CUDA zips we need.
$release = $null; $mainAsset = $null; $rtAsset = $null
foreach ($rel in $releases) {
    if ($rel.tag_name -match '^b(\d+)$' -and [int]$Matches[1] -ge $MIN_BUILD) {
        $m = $rel.assets | Where-Object { $_.name -match '^llama-b\d+-bin-win-cuda-12\.\d+-x64\.zip$' } | Select-Object -First 1
        $r = $rel.assets | Where-Object { $_.name -match '^cudart-llama-bin-win-cuda-12\.\d+-x64\.zip$' } | Select-Object -First 1
        if ($m -and $r) { $release = $rel; $mainAsset = $m; $rtAsset = $r; break }
    }
}
if (-not $release) { throw "No llama.cpp release >= b$MIN_BUILD with CUDA 12.x zips found in the last 15 releases." }
$latestBuild = [int]($release.tag_name -replace '^b', '')

$installed = Find-LlamaExe "llama-server.exe"
$installedBuild = if ($installed) { Get-InstalledBuild $installed } else { 0 }
Write-Host ("llama.cpp : installed b{0}, latest available b{1}" -f $installedBuild, $latestBuild)

if ($installed -and $installedBuild -ge $latestBuild -and -not $Update) {
    Write-Host ("llama.cpp already current: {0}" -f $installed.FullName) -ForegroundColor Green
} else {
    if ($installed -and $installedBuild -gt 0 -and $installedBuild -lt $latestBuild) {
        Write-Host ("Upgrading llama.cpp b{0} -> b{1}" -f $installedBuild, $latestBuild) -ForegroundColor Cyan
    } elseif ($Update -and $installed) {
        Write-Host "Re-downloading llama.cpp (-Update)" -ForegroundColor Cyan
    } else {
        Write-Host "Fetching llama.cpp..." -ForegroundColor Cyan
    }

    $mainZip = Join-Path $CACHE_DIR $mainAsset.name
    $rtZip   = Join-Path $CACHE_DIR $rtAsset.name
    foreach ($pair in @(@($mainAsset.browser_download_url, $mainZip), @($rtAsset.browser_download_url, $rtZip))) {
        $url, $zip = $pair
        if (Test-Path $zip) { Write-Host "zip already present: $zip" }
        else {
            # Resume into "<zip>.part" so an interrupted download doesn't leave a
            # truncated zip that Expand-Archive would choke on.
            Write-Host "Downloading $url"
            & curl.exe -L --fail -C - -o "$zip.part" $url
            if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
            Move-Item -Force "$zip.part" $zip
        }
    }

    # A running server holds ggml-cuda.dll / llama.dll, which blocks extraction.
    $running = @(Get-Process -Name "llama-server" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$TOOLS_DIR*" })
    if ($running.Count -gt 0) {
        Write-Host ("Stopping {0} llama-server process(es) to replace binaries..." -f $running.Count) -ForegroundColor Yellow
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Host "Extracting llama.cpp..."
    Expand-Archive -Path $mainZip -DestinationPath $TOOLS_DIR -Force
    $server = Find-LlamaExe "llama-server.exe"
    if (-not $server) { throw "llama-server.exe not found after extracting $($mainAsset.name)." }

    $rtTmp = Join-Path $TOOLS_DIR "_cudart"
    Expand-Archive -Path $rtZip -DestinationPath $rtTmp -Force
    Get-ChildItem $rtTmp -Recurse -Filter *.dll | ForEach-Object {
        Copy-Item $_.FullName -Destination $server.DirectoryName -Force
    }
    Remove-Item $rtTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $mainZip, $rtZip -Force -ErrorAction SilentlyContinue
    $finalBuild = Get-InstalledBuild $server
    Write-Host ("llama.cpp installed: {0} (b{1})" -f $server.FullName, $finalBuild) -ForegroundColor Green
}

# ---- Optional model download ---------------------------------------------------
if ($Gguf) {
    if (-not $FileName) {
        $FileName = [IO.Path]::GetFileName(([Uri]$Gguf).AbsolutePath)
        if (-not $FileName -or $FileName -notmatch '\.gguf$') {
            throw "Cannot infer a GGUF filename from that URL - pass -FileName <name>.gguf"
        }
    }
    $min = if ($MinGb -gt 0) { $MinGb } else { $GGUF_MIN_GB }
    Get-Gguf $Gguf (Join-Path $MODELS_DIR $FileName) $min
}

Write-Host ""
Write-Host "Fetch complete (framework binaries)." -ForegroundColor Green
if (-not (Get-GgufFiles)) {
    Write-Host ("No models yet. Download one: powershell -File scripts\fetch.ps1 -Gguf <url> -FileName <name>.gguf") -ForegroundColor Yellow
    Write-Host ("Or drop .gguf files into: {0}" -f $MODELS_DIR) -ForegroundColor Yellow
}

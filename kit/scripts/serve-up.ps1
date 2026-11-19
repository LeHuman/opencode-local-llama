# scripts/serve-up.ps1 - start llama-server, wait for /health, verify VRAM.
# Idempotent: safe to run repeatedly. Windows only (PowerShell + CUDA).
# Models are whatever GGUFs live in $MODELS_DIR; nothing is hardcoded. Ids and
# per-model serving knobs come from config.json at the kit root.
#   -Model <stem>   primary model in single-model mode (default: first GGUF)
#   -Gguf <path>    serve a specific GGUF file directly (single-model mode)
param(
    [string]$Model,
    [string]$Gguf
)
. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = "Stop"
Assert-KitRoot
Initialize-KitConfig
Initialize-ModelsConfig
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

function Resolve-Gguf {
    if ($Gguf) {
        if (-not (Test-Path $Gguf)) { throw "-Gguf path not found: $Gguf" }
        return (Resolve-Path $Gguf).Path
    }
    $files = Get-GgufFiles
    if ($files.Count -eq 0) {
        throw "No GGUF found in $MODELS_DIR. Download one (scripts\fetch.ps1 -Gguf <url>) or set modelsDir in config.json."
    }
    if ($Model) {
        $hit = $files | Where-Object { $_.BaseName -eq $Model -or $_.Name -eq $Model } | Select-Object -First 1
        if (-not $hit) {
            $names = ($files | ForEach-Object { $_.BaseName }) -join ", "
            throw "Model '$Model' not found in $MODELS_DIR. Available: $names"
        }
        return $hit.FullName
    }
    return $files[0].FullName
}

# config key -> llama.cpp INI/CLI args
function New-IniBody($settings) {
    $lines = @()
    # INI values are line-based: strip control characters so a models.json value
    # cannot inject extra keys.
    $clean = { param($v) ([string]$v) -replace "[\r\n\t]", " " }
    if ($settings.ContainsKey("alias"))       { $lines += "alias = $(& $clean $settings['alias'])" }
    if ($settings.ContainsKey("context"))     { $lines += "c = $($settings['context'])" }
    if ($settings.ContainsKey("gpuLayers"))   { $lines += "n-gpu-layers = $($settings['gpuLayers'])" }
    if ($settings.ContainsKey("kvQuant"))     {
        $lines += "cache-type-k = $($settings['kvQuant'])"
        $lines += "cache-type-v = $($settings['kvQuant'])"
    }
    if ($settings.ContainsKey("temperature")) { $lines += "temp = $($settings['temperature'])" }
    if ($settings.ContainsKey("topP"))        { $lines += "top-p = $($settings['topP'])" }
    if ($settings.ContainsKey("parallel"))    { $lines += "parallel = $($settings['parallel'])" }
    if ($settings.ContainsKey("jinja"))       { $lines += "jinja = $(([string]$settings['jinja']).ToLower())" }
    if ($settings.ContainsKey("chatTemplate") -and $settings['chatTemplate']) {
        $lines += "chat-template-file = $(Resolve-ModelPath $settings['chatTemplate'])"
    }
    return $lines
}

$ggufPath = Resolve-Gguf
$ggufName = Split-Path -Leaf $ggufPath
$ggufStem = [IO.Path]::GetFileNameWithoutExtension($ggufPath)
$primary = Get-ModelSettings $ggufStem
$primaryAlias = Get-ModelAlias $ggufStem
if (-not $primaryAlias) { $primaryAlias = $ggufStem }

if (Test-ServerHealthy) {
    Write-Host "Server already up at $BASE_URL." -ForegroundColor Green
    if ($ROUTER_MODE -eq "1") {
        Write-Host "Router mode: models load on first request; switch models by name (no restart needed)."
    } else {
        Write-Host "To switch models: run serve-down first, then serve-up -Model <stem>."
    }
    exit 0
}

$server = Find-LlamaExe "llama-server.exe"
if (-not $server) { throw "llama-server.exe not found in $TOOLS_DIR - run scripts\fetch.ps1, or set toolsDir in config.json." }

$useRouter = ($ROUTER_MODE -eq "1")
$resolved = (Resolve-Path $ggufPath).Path
if ($useRouter -and -not $resolved.StartsWith((Resolve-Path $MODELS_DIR).Path, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "-Gguf is outside $MODELS_DIR; router mode cannot serve it. Using single-model mode."
    $useRouter = $false
}

$free = Get-FreeVramGb
if ($free -ge 0 -and $free -lt 7.5) {
    Write-Warning ("Only {0} GB VRAM free. Close GPU-heavy apps, or lower context in config.json." -f $free)
}

if ($useRouter) {
    # One process serves every GGUF in $MODELS_DIR, loading on first request and
    # evicting when modelsMax is exceeded. Every model entry must be complete:
    # nothing is inherited from a defaults block.
    New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
    $iniPath = Join-Path $CACHE_DIR "models.ini"
    $models = @(Get-GgufFiles)

    $unconfigured = @($models | Where-Object { -not (Get-ModelEntry $_.BaseName) })
    if ($unconfigured.Count -gt 0) {
        $names = ($unconfigured | ForEach-Object { $_.BaseName }) -join ", "
        throw "Missing model entries in ${MODELS_CONFIG}: $names. Add each one with context, kvQuant, gpuLayers, parallel, temperature, topP (and optionally alias, chatTemplate)."
    }

    $sections = @(foreach ($f in $models) {
        $settings = Assert-ModelSettings $f.BaseName
        if ($settings.ContainsKey("chatTemplate") -and $settings["chatTemplate"]) {
            $tpl = Resolve-ModelPath $settings["chatTemplate"]
            if (-not (Test-Path $tpl)) { throw "chatTemplate not found for '$($f.BaseName)': $tpl" }
        }
        "[$($f.BaseName)]`r`n$((New-IniBody $settings) -join "`r`n")"
    }) -join "`r`n`r`n"

    $display = ($models | ForEach-Object {
        $a = Get-ModelAlias $_.BaseName
        if ($a) { $a } else { $_.BaseName }
    }) -join ", "

    # [*] only carries the global Jinja switch; every serving knob is per model.
    $ini = @"
version = 1

[*]
jinja = true

$sections
"@
    [IO.File]::WriteAllText($iniPath, $ini, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "Starting llama-server in router mode: $MODELS_DIR" -ForegroundColor Cyan
    Write-Host ("  models: {0}" -f $display) -ForegroundColor DarkGray
    Write-Host "  load on first request; sleep after $SLEEP_IDLE_SECONDS s idle; max $MODELS_MAX resident" -ForegroundColor DarkGray

    $argList = @(
        "--models-dir", "`"$MODELS_DIR`"",
        "--models-preset", "`"$iniPath`"",
        "--models-max", $MODELS_MAX,
        "-fa", "on",
        "--host", $BIND_ADDR,
        "--port", $PORT,
        "--no-webui",
        "--no-slots"
    ) -join " "
} else {
    # Single-model mode: all knobs come from the merged settings for this model.
    $ctx      = if ($primary.ContainsKey("context")) { $primary["context"] } else { $NUM_CTX }
    $kv       = if ($primary.ContainsKey("kvQuant")) { $primary["kvQuant"] } else { $KV_QUANT }
    $ngl      = if ($primary.ContainsKey("gpuLayers")) { $primary["gpuLayers"] } else { $NUM_GPU_LAYERS }
    $np       = if ($primary.ContainsKey("parallel")) { $primary["parallel"] } else { $NUM_PARALLEL }
    $temp     = if ($primary.ContainsKey("temperature")) { $primary["temperature"] } else { $SAMPLE_TEMP }
    $topP     = if ($primary.ContainsKey("topP")) { $primary["topP"] } else { $SAMPLE_TOP_P }
    $template = if ($primary.ContainsKey("chatTemplate") -and $primary["chatTemplate"]) {
        Resolve-ModelPath $primary["chatTemplate"]
    } else { $null }
    if ($template -and -not (Test-Path $template)) {
        throw "chatTemplate not found for '$ggufStem': $template"
    }

    Write-Host "Starting llama-server: $ggufName  (ctx $ctx, KV $kv, temp $temp, top_p $topP)" -ForegroundColor Cyan
    $argList = @(
        "-m", "`"$resolved`"",
        "--alias", $primaryAlias,
        "-c", $ctx,
        "-ngl", $ngl,
        "-np", $np,
        "-fa", "on",
        "--cache-type-k", $kv,
        "--cache-type-v", $kv,
        "--temp", $temp,
        "--top-p", $topP,
        "--host", $BIND_ADDR,
        "--port", $PORT,
        "--no-webui",
        "--no-slots"
    ) -join " "
    if ($template) {
        $argList += " --jinja --chat-template-file `"$template`""
    }
}
if ([int]$SLEEP_IDLE_SECONDS -gt 0) { $argList += " --sleep-idle-seconds $SLEEP_IDLE_SECONDS" }

$outLog = Join-Path $LOG_DIR "server.out.log"
$errLog = Join-Path $LOG_DIR "server.err.log"
# Refuse to race another serve-up: two spawns would fight over the port and the
# loser would clobber the PID file.
$live = @(Get-Process -Name "llama-server" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($server.DirectoryName, [StringComparison]::OrdinalIgnoreCase) })
if ($live.Count -gt 0) {
    throw ("llama-server is already running (pid {0}) from this kit. Run serve-down.ps1 first." -f ($live.Id -join ", "))
}

$proc = Start-Process -FilePath $server.FullName -ArgumentList $argList `
    -WorkingDirectory $server.DirectoryName -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog

$deadline = (Get-Date).AddSeconds(180)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        Write-Host "llama-server exited early (code $($proc.ExitCode)). Last log lines:" -ForegroundColor Red
        Get-Content $errLog -Tail 25 -ErrorAction SilentlyContinue
        throw "Server failed to start. 'unknown model architecture' => run fetch.ps1 to update llama.cpp. 'out of memory' => lower context in models.json for this model."
    }
    if (Test-ServerHealthy) { $ready = $true; break }
}
if (-not $ready) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Server did not become healthy within 180s; process stopped. See $errLog"
}
# Only record the PID once the server is actually serving, so a failed spawn
# cannot overwrite a healthy instance's PID.
$proc.Id | Set-Content -Path $PID_FILE

Start-Sleep -Seconds 1
$freeAfter = Get-FreeVramGb
Write-Host ""
Write-Host "Server is UP (pid $($proc.Id))" -ForegroundColor Green
if ($useRouter) {
    Write-Host "  mode      : router - models load on first request (max $MODELS_MAX resident)"
    Write-Host "  models    : $MODELS_DIR"
    Write-Host "  primary   : $primaryAlias (first request pays the model load)"
} else {
    Write-Host "  serving   : $ggufName"
}
Write-Host "  OpenAI API: $BASE_URL/v1   (model id: $primaryAlias)"
Write-Host "  Free VRAM : $freeAfter GB"
if (-not $useRouter -and $freeAfter -ge 0 -and $freeAfter -lt 0.5) {
    Write-Warning "Under 0.5GB VRAM headroom; lower context in config.json and restart."
}
Write-Host "Next: task '3. Tool-call test'." -ForegroundColor Green

# scripts/status.ps1 — one-glance health of the whole kit.
. "$PSScriptRoot\env.ps1"
Write-Host "=== local-llm status ===" -ForegroundColor Cyan

# GPU
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $name = (& nvidia-smi --query-gpu=name --format=csv,noheader) | Select-Object -First 1
    $used = (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) | Select-Object -First 1
    Write-Host ("GPU        : {0}   VRAM in use: {1} MB   free: {2} GB" -f $name, $used, (Get-FreeVramGb))
    $proc = (& nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader) 2>$null
    if ($proc) { $proc | ForEach-Object { Write-Host ("  resident: {0}" -f $_) } }
} else { Write-Host "GPU        : nvidia-smi not found" -ForegroundColor Yellow }

# llama-server
if (Test-ServerHealthy) {
    Write-Host "llama-server: UP at $BASE_URL" -ForegroundColor Green
    try {
        $m = Invoke-RestMethod -Uri "$BASE_URL/v1/models" -TimeoutSec 3
        $labels = $m.data | ForEach-Object {
            $name = if ($_.aliases -and $_.aliases.Count -gt 0) { "{0} ({1})" -f $_.aliases[0], $_.id } else { $_.id }
            $state = if ($_.status -and $_.status.value) { $_.status.value } else { "loaded" }
            "$name [$state]"
        }
        Write-Host ("  models : {0}" -f ($labels -join ", "))
    } catch {}
    try {
        $props = Invoke-RestMethod -Uri "$BASE_URL/props" -TimeoutSec 3
        $n = $props.default_generation_settings.n_ctx
        if ($n) { Write-Host "  context: $n tokens" }
    } catch {}
} else {
    Write-Host "llama-server: down (task '2. Serve: UP')"
}

# llama.cpp presence
$exe = Find-LlamaExe "llama-server.exe"
Write-Host ("llama.cpp  : {0}" -f $(if ($exe) { $exe.FullName } else { "not installed (run scripts\fetch.ps1, or set toolsDir in config.json)" }))

# Models on disk (whatever is in $MODELS_DIR)
$ggufs = @(Get-GgufFiles)
if ($ggufs.Count -eq 0) {
    Write-Host ("models     : none in {0} (download one with scripts\fetch.ps1 -Gguf <url>)" -f $MODELS_DIR) -ForegroundColor Yellow
} else {
    foreach ($g in $ggufs) {
        $alias = Get-ModelAlias $g.BaseName
        $label = if ($alias) { "$alias ($($g.BaseName))" } else { $g.BaseName }
        Write-Host ("models     : {0,-44} {1,7:N2} GB" -f $label, ($g.Length / 1GB))
    }
}

# Repo-local opencode config + CLI
$wired = (Test-Path (Join-Path $KIT_ROOT "opencode.json"))
if ($wired) { Write-Host ("opencode.json: present (provider -> {0})" -f $BASE_URL) -ForegroundColor Green }
else { Write-Host "opencode.json: missing" -ForegroundColor Yellow }
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    Write-Host "opencode   : installed"
} else { Write-Host "opencode   : not installed (optional)" -ForegroundColor Yellow }

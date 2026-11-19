# scripts/env.ps1 - loads config.json and exposes the variables the scripts use.
# Windows only: lifecycle is PowerShell + CUDA binaries.
#
# Configuration precedence (highest first):
#   1. environment variables set by the plugin for one session
#      (LOCAL_LLM_MODELS_DIR, LOCAL_LLM_TOOLS_DIR, LOCAL_LLM_PORT)
#   2. config.json at the kit root
#   3. defaults below
#
# config.json holds machine-level settings only: paths, endpoint, router
# behaviour, and "defaults" used by any model that does not override them.
# Per-model data (alias, context, kvQuant, ...) lives next to the weights in
# <modelsDir>\models.json so it travels with them.

$KIT_ROOT      = Split-Path -Parent $PSScriptRoot
$BUILD_DIR     = Join-Path $KIT_ROOT "build"
$CACHE_DIR     = Join-Path $BUILD_DIR "cache"
$LOG_DIR       = Join-Path $KIT_ROOT "logs"
$PID_FILE      = Join-Path $LOG_DIR "server.pid"
$CONFIG_FILE   = Join-Path $KIT_ROOT "config.json"

function Get-KitConfig {
    if ($null -ne $script:KitConfig) { return $script:KitConfig }
    $script:KitConfig = [pscustomobject]@{}
    if (Test-Path $CONFIG_FILE) {
        try { $script:KitConfig = Get-Content $CONFIG_FILE -Raw | ConvertFrom-Json }
        catch { throw "Could not parse ${CONFIG_FILE}: $($_.Exception.Message)" }
    }
    return $script:KitConfig
}

function Get-CfgValue($object, $name) {
    if ($null -eq $object) { return $null }
    $prop = $object.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

$cfg = Get-KitConfig

# ---- Paths and endpoint --------------------------------------------------------
function Resolve-KitPath($value, $fallback) {
    if (-not $value) { return $fallback }
    if ([IO.Path]::IsPathRooted($value)) { return $value }
    return (Join-Path $KIT_ROOT $value)   # relative paths in config are kit-relative
}

$MODELS_DIR = Resolve-KitPath $env:LOCAL_LLM_MODELS_DIR $null
if (-not $MODELS_DIR) { $MODELS_DIR = Resolve-KitPath (Get-CfgValue $cfg "modelsDir") (Join-Path $KIT_ROOT "models") }

$TOOLS_DIR = Resolve-KitPath $env:LOCAL_LLM_TOOLS_DIR $null
if (-not $TOOLS_DIR) { $TOOLS_DIR = Resolve-KitPath (Get-CfgValue $cfg "toolsDir") (Join-Path $BUILD_DIR "tools") }

$BIND_ADDR = Get-CfgValue $cfg "host"
if (-not $BIND_ADDR) { $BIND_ADDR = "127.0.0.1" }

$PORT = $env:LOCAL_LLM_PORT
if (-not $PORT) { $PORT = Get-CfgValue $cfg "port" }
if (-not $PORT) { $PORT = "5514" }
$BASE_URL = "http://${BIND_ADDR}:${PORT}"

$tplRel = Get-CfgValue $cfg "chatTemplate"
if ($tplRel) {
    $CHAT_TEMPLATE = Resolve-KitPath $tplRel $null
} else {
    # No framework-wide template: chat templates are per model in models.json.
    $CHAT_TEMPLATE = $null
}

$MIN_BUILD = Get-CfgValue $cfg "minBuild"
if ($null -eq $MIN_BUILD) { $MIN_BUILD = 0 }   # 0 = accept whatever llama.cpp ships
$GGUF_MIN_GB = 0.5

# ---- Server-wide behaviour -----------------------------------------------------
$SLEEP_IDLE_SECONDS = Get-CfgValue $cfg "sleepIdleSeconds"
if ($null -eq $SLEEP_IDLE_SECONDS) { $SLEEP_IDLE_SECONDS = 900 }
$ROUTER_MODE = if ((Get-CfgValue $cfg "routerMode") -eq $false) { "0" } else { "1" }
$MODELS_MAX = Get-CfgValue $cfg "modelsMax"
if (-not $MODELS_MAX) { $MODELS_MAX = 1 }

# Per-model structural knobs are NOT defaulted on purpose: every entry in
# <modelsDir>\models.json must define them. Sampling (temperature/topP) is the
# exception — "defaults" here covers knobs that are common across models.
$MODEL_REQUIRED = @("context", "kvQuant", "gpuLayers", "parallel")

# Process-scoped isolation: keep HF/pip caches inside build\cache instead of
# leaking gigabytes into the user profile.
$env:HF_HOME             = Join-Path $CACHE_DIR "hf"
$env:HUGGINGFACE_HUB_CACHE = Join-Path $CACHE_DIR "hf\hub"
$env:PIP_CACHE_DIR       = Join-Path $CACHE_DIR "pip"

# ---- Model helpers -------------------------------------------------------------
# Per-model data lives with the weights:
#   <modelsDir>\models.json
#   { "models": { "<gguf file stem>": { "alias": "...", "context": 8192 } } }
$MODELS_CONFIG = Join-Path $MODELS_DIR "models.json"

function Get-ModelsConfig {
    if ($null -ne $script:ModelsConfig) { return $script:ModelsConfig }
    $script:ModelsConfig = [pscustomobject]@{}
    if (Test-Path $MODELS_CONFIG) {
        try { $script:ModelsConfig = Get-Content $MODELS_CONFIG -Raw | ConvertFrom-Json }
        catch { Write-Warning "Could not parse ${MODELS_CONFIG}: $($_.Exception.Message)" }
    }
    return $script:ModelsConfig
}

function Get-ModelEntry($stem) {
    return Get-CfgValue (Get-CfgValue (Get-ModelsConfig) "models") $stem
}

function Get-ModelSettings($stem) {
    # config.json "defaults" carries only knobs that are truly common (sampling);
    # structural settings come from the model entry in <modelsDir>\models.json.
    $merged = @{}
    $D = Get-CfgValue (Get-KitConfig) "defaults"
    if ($D) { $D.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value } }
    $entry = Get-ModelEntry $stem
    if ($entry) { $entry.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value } }
    if (-not $merged.ContainsKey("temperature")) { $merged["temperature"] = 1.0 }
    if (-not $merged.ContainsKey("topP")) { $merged["topP"] = 0.95 }
    return $merged
}

function Assert-ModelSettings($stem) {
    $settings = Get-ModelSettings $stem
    $missing = @($MODEL_REQUIRED | Where-Object { -not $settings.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw ("Model '{0}' is missing {1} in {2}. Every model entry must define: {3}." -f
            $stem, ($missing -join ", "), $MODELS_CONFIG, ($MODEL_REQUIRED -join ", "))
    }
    return $settings
}

function Get-ModelOverrides($stem) {
    # only what the model entry itself sets (used to write INI overrides)
    $entry = Get-ModelEntry $stem
    $out = @{}
    if ($entry) { $entry.PSObject.Properties | ForEach-Object { $out[$_.Name] = $_.Value } }
    return $out
}

function Get-ModelAlias($stem) {
    $entry = Get-ModelEntry $stem
    $alias = Get-CfgValue $entry "alias"
    if ($alias) { return $alias }
    return $null
}

function Resolve-ModelPath($value) {
    # Absolute, else relative to the models folder (model data), else kit-relative.
    if (-not $value) { return $null }
    if ([IO.Path]::IsPathRooted($value)) { return $value }
    $inModels = Join-Path $MODELS_DIR $value
    if (Test-Path $inModels) { return $inModels }
    return (Resolve-KitPath $value $null)
}

function Get-GgufFiles {
    if (-not (Test-Path $MODELS_DIR)) { return @() }
    return @(Get-ChildItem $MODELS_DIR -Filter *.gguf -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Initialize-ModelsConfig {
    New-Item -ItemType Directory -Force -Path $MODELS_DIR | Out-Null
    if (Test-Path $MODELS_CONFIG) { return }
    $template = @'
{
  "models": {
  }
}
'@
    [IO.File]::WriteAllText($MODELS_CONFIG, $template, (New-Object System.Text.UTF8Encoding($false)))
}

function Initialize-KitConfig {
    if (Test-Path $CONFIG_FILE) { return }
    $template = @'
{
  "modelsDir": "models",
  "host": "127.0.0.1",
  "port": 5514,
  "sleepIdleSeconds": 900,
  "routerMode": true,
  "modelsMax": 1,
  "minBuild": 0,
  "defaults": {
    "temperature": 1.0,
    "topP": 0.95
  }
}
'@
    [IO.File]::WriteAllText($CONFIG_FILE, $template, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- Helpers ------------------------------------------------------------------
function Assert-KitRoot {
    if (-not (Test-Path (Join-Path $PSScriptRoot "serve-up.ps1"))) {
        throw "env.ps1: kit root looks wrong: $KIT_ROOT"
    }
}

function Get-FreeVramGb {
    try {
        $line = (& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1)
        return [math]::Round([double]$line / 1024.0, 2)
    } catch { return -1 }
}

function Find-LlamaExe($name) {
    if (-not (Test-Path $TOOLS_DIR)) { return $null }
    return (Get-ChildItem $TOOLS_DIR -Recurse -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-ServerHealthy {
    try {
        $r = Invoke-WebRequest -Uri "$BASE_URL/health" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# Resumable GGUF download via curl.exe, with size floor + GGUF header check.
# Writes to "<out>.part", validates, then moves into place atomically.
function Get-Gguf($url, $out, $minGb) {
    if (Test-Path $out) {
        $sizeGb = [math]::Round((Get-Item $out).Length / 1GB, 2)
        $magic = ""
        try {
            $fs = [System.IO.File]::OpenRead($out)
            try { $buf = New-Object byte[] 4; [void]$fs.Read($buf, 0, 4); $magic = [System.Text.Encoding]::ASCII.GetString($buf) }
            finally { $fs.Dispose() }
        } catch {}
        if ($sizeGb -ge $minGb -and $magic -eq "GGUF") {
            Write-Host "already present: $out"
            return
        }
    }
    Write-Host "Downloading $url"
    Write-Host "  -> $out  (resumable: re-run this script if interrupted)"
    $part = "$out.part"
    & curl.exe -L --fail -C - -o $part $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    $gb = [math]::Round((Get-Item $part).Length / 1GB, 2)
    if ($gb -lt $minGb) { throw "Downloaded file is only $gb GB (expected >= $minGb GB): $part" }
    $fs = [System.IO.File]::OpenRead($part)
    try { $buf = New-Object byte[] 4; [void]$fs.Read($buf, 0, 4) } finally { $fs.Dispose() }
    if ([System.Text.Encoding]::ASCII.GetString($buf) -ne "GGUF") { throw "Not a GGUF file (bad header): $part" }
    Move-Item -Force $part $out
    Write-Host ("OK: {0} ({1} GB)" -f $out, $gb) -ForegroundColor Green
}

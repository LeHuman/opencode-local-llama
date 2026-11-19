# scripts/test-tools.ps1 — the single most important smoke test in the kit.
# Tool-call support depends on the model's chat template.
# (set per model as chatTemplate in models.json). If this passes, opencode's agent
# loop will work; if it fails, nothing downstream will. Prints speed too.
# max_tokens 8192: reasoning models think before acting; 2048 can truncate it and
# the tool call never gets emitted (truncated reasoning = FAILED response).
#   -Model <id>   force a model id (default: first model the server lists)
param([string]$Model)
. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = "Stop"

if (-not (Test-ServerHealthy)) { throw "Server is not up. Run '2. Serve: UP' first." }

# Target the model passed with -Model, else whatever the server lists first.
$modelID = $Model
try {
    $ids = @((Invoke-RestMethod -Uri "$BASE_URL/v1/models" -TimeoutSec 5).data |
        ForEach-Object { @($_.aliases) + $_.id } | Where-Object { $_ })
    if (-not $modelID) { $modelID = $ids[0] }
    elseif ($ids.Count -gt 0 -and $ids -notcontains $modelID) {
        Write-Warning "Model '$modelID' is not served. Available: $($ids -join ', ')"
    }
} catch {}
if (-not $modelID) { throw "Could not determine a model id from $BASE_URL/v1/models." }
Write-Host "Using model id: $modelID" -ForegroundColor DarkGray

$body = @{
    model      = $modelID
    max_tokens = 8192
    messages   = @(
        @{ role = "user"; content = "Use the read_file tool to read README.md. Do not answer from memory." }
    )
    tools      = @(
        @{
            type     = "function"
            function = @{
                name        = "read_file"
                description = "Read a text file from the project"
                parameters  = @{
                    type       = "object"
                    properties = @{ path = @{ type = "string"; description = "relative file path" } }
                    required   = @("path")
                }
            }
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

Write-Host "Sending a tool-call request (this is a reasoning model - may think for a while)..." -ForegroundColor Cyan
$r = Invoke-RestMethod -Uri "$BASE_URL/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 300
$msg = $r.choices[0].message
$calls = @($msg.tool_calls)

$ok = $false
if ($calls.Count -gt 0 -and $calls[0].function.name -eq "read_file") {
    try {
        $a = $calls[0].function.arguments
        if ($a -is [string]) { $a = $a | ConvertFrom-Json }
        if ($a.path) { $ok = $true; Write-Host ("Tool call OK: read_file(path = {0})" -f $a.path) -ForegroundColor Green }
    } catch {}
}
if (-not $ok) {
    Write-Host "FAIL: no valid read_file tool call came back. Raw message:" -ForegroundColor Red
    $msg | ConvertTo-Json -Depth 6
    Write-Host ""
    Write-Host "Check logs\server.err.log. Ensure the model entry in models.json sets a working chatTemplate, and llama.cpp is a recent build." -ForegroundColor Yellow
}

if ($r.timings) {
    Write-Host ("Speed: prompt {0:N0} t/s, generation {1:N1} t/s" -f $r.timings.prompt_per_second, $r.timings.predicted_per_second)
}
Write-Host ("Free VRAM with model loaded: {0} GB" -f (Get-FreeVramGb))
if (-not $ok) { exit 1 }
Write-Host "Agent-loop compatibility: VERIFIED." -ForegroundColor Green

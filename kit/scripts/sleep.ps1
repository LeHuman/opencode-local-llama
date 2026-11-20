# scripts/sleep.ps1 - unload loaded models now, ahead of the idle timer.
# The router stays up (health stays green) and the next request reloads the
# model automatically. Windows only (PowerShell).
. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = "Stop"

try {
    $models = (Invoke-RestMethod -Uri "$BASE_URL/v1/models" -TimeoutSec 10).data
} catch {
    Write-Host "No llama-server is answering at $BASE_URL; nothing to unload."
    exit 0
}

$loaded = @($models | Where-Object { $_.status -and $_.status.value -eq "loaded" })
if ($loaded.Count -eq 0) {
    Write-Host "No models are loaded; nothing to unload."
    exit 0
}

foreach ($m in $loaded) {
    $body = @{ model = $m.id } | ConvertTo-Json -Compress
    try {
        $res = Invoke-RestMethod -Uri "$BASE_URL/models/unload" -Method Post `
            -Body $body -ContentType "application/json" -TimeoutSec 30
        if ($res.success) {
            Write-Host "Unloaded $($m.id)."
        } else {
            Write-Host "Router refused to unload $($m.id)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Unload failed for $($m.id): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "VRAM freed. The next request reloads the model automatically."

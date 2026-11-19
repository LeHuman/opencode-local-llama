# scripts/serve-down.ps1 — tear the service down deterministically: stop
# llama-server (PID file first, then strays from this kit's tools folder),
# verify VRAM came back. Nothing on disk is deleted.
. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = "Continue"
Assert-KitRoot
Write-Host "=== serve-down ===" -ForegroundColor Cyan

$stopped = 0
if (Test-Path $PID_FILE) {
    $savedId = [int](Get-Content $PID_FILE | Select-Object -First 1)
    $p = Get-Process -Id $savedId -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like "llama-server*") {
        Stop-Process -Id $savedId -Force
        $stopped++
    }
    Remove-Item $PID_FILE -ErrorAction SilentlyContinue
}

# Catch strays started by hand from this kit's tools folder only - never kill
# some other llama-server the user runs elsewhere.
Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($TOOLS_DIR, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    $stopped++
}

if ($stopped -eq 0) { Write-Host "No llama-server from this kit was running." }
else { Write-Host "Stopped $stopped process(es)." -ForegroundColor Green }

Start-Sleep -Seconds 2
Write-Host ("Free VRAM now: {0} GB" -f (Get-FreeVramGb))
Write-Host "Model files stay on disk. 'Serve: UP' brings it back in under a minute." -ForegroundColor Green

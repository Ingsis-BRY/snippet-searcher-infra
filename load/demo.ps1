# Runs the 4-minute demo load test against dev and opens Locust's live charts.
#   powershell -ExecutionPolicy Bypass -File load\demo.ps1            (dev)
#   powershell -ExecutionPolicy Bypass -File load\demo.ps1 -Env prod
param([ValidateSet('dev', 'prod')][string]$Env = 'dev')

$hosts = @{ dev = 'https://snippet-searcher-bry.duckdns.org'; prod = 'https://snippet-searcher-bry-prod.duckdns.org' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$locust = Join-Path $here '.venv\Scripts\locust.exe'

if (-not (Test-Path $locust)) {
    Write-Host "Locust no está instalado. Correr una vez:"
    Write-Host "  python -m venv load\.venv; load\.venv\Scripts\pip install -r load\requirements.txt"
    exit 1
}
if (-not $env:SYNTHETIC_CLIENT_SECRET -and -not (Test-Path (Join-Path $here 'client_secret'))) {
    Write-Host "Falta el secret de la app M2M: crear load\client_secret (una línea, ignorado por git)."
    exit 1
}

Start-Job { Start-Sleep -Seconds 4; Start-Process 'http://localhost:8089/?tab=charts' } | Out-Null
Write-Host "Prueba de demo contra $($hosts[$Env]) (4 minutos). Ctrl+C para cortar."
& $locust -f (Join-Path $here 'demo.py') --host $hosts[$Env] --autostart --autoquit 120

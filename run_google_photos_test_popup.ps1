$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonExe = Join-Path $repoRoot ".venv\Scripts\python.exe"
$scriptPath = Join-Path $repoRoot "test_google_photos_api.py"
$clientSecrets = Join-Path $repoRoot "client_secret.json"

if (-not (Test-Path -LiteralPath $pythonExe)) {
    Write-Host "Missing virtual environment Python: $pythonExe" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

if (-not (Test-Path -LiteralPath $clientSecrets)) {
    Write-Host "Missing OAuth client secrets file: $clientSecrets" -ForegroundColor Yellow
    Write-Host "Download the Desktop app OAuth client JSON from Google Cloud and save it as client_secret.json in this folder."
    Read-Host "Press Enter to close"
    exit 1
}

$command = @"
Set-Location -LiteralPath '$repoRoot'
& '$pythonExe' '$scriptPath' --client-secrets '$clientSecrets'
`$exitCode = `$LASTEXITCODE
Write-Host ''
Read-Host 'Press Enter to close'
exit `$exitCode
"@

Start-Process powershell.exe -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command", $command
)

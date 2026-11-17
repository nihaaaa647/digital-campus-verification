# Keeps the phone's USB tunnel to the laptop server (adb reverse) alive during a demo.
# adb drops the tunnel silently when the cable, the USB mode or the phone's screen state changes, and the apps
# then say "Can't reach the college server". This puts it back within two seconds.
#
#   powershell -ExecutionPolicy Bypass -File tools\demo-tunnel.ps1          (leave the window open)
#   powershell -ExecutionPolicy Bypass -File tools\demo-tunnel.ps1 -Port 8790

param([int]$Port = 8787)

$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { Write-Error "adb not found at $adb"; exit 1 }

Write-Host "Keeping tcp:$Port tunnelled to the phone. Ctrl+C to stop."
while ($true) {
    $listed = & $adb reverse --list 2>$null | Select-String "tcp:$Port"
    if (-not $listed) {
        & $adb reverse "tcp:$Port" "tcp:$Port" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host ("{0}  tunnel restored" -f (Get-Date -Format 'HH:mm:ss')) }
    }
    Start-Sleep -Seconds 2
}

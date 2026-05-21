Write-Host "=== LOGCAT DEBUG STARTED ==="
Write-Host "Filtering: Flutter + Choreographer"

cd C:\Users\jaxba\AppData\Local\Android\sdk\platform-tools

.\adb logcat -c

.\adb logcat Choreographer:I flutter:I *:S
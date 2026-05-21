# Clean project
flutter clean
flutter pub get

# Read pubspec.yaml as raw text
$content = Get-Content pubspec.yaml -Raw

# Extract version using regex
if ($content -match 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {

    $appVersion = $matches[1]
    $buildNumber = [int]$matches[2]

    $newBuild = $buildNumber + 1
    $newVersion = "$appVersion+$newBuild"

    Write-Host "Bumping version $appVersion+$buildNumber -> $newVersion"

    # Replace version
    $content = $content -replace "version:\s*$appVersion\+$buildNumber", "version: $newVersion"

    # Save with UTF8 encoding
    Set-Content pubspec.yaml $content -Encoding utf8
}
flutter pub get

# Get app name from pubspec.yaml
$nameLine = Select-String -Path pubspec.yaml -Pattern "^name:"
$appName = $nameLine.ToString().Split(" ")[1]
$appName = $appName -replace "_","-"

Write-Host "Building app: $appName"
Write-Host "Version: $newVersion"

# Build AAB with obfuscation
flutter build appbundle --release --obfuscate --split-debug-info=debug-symbols

# Paths
$aabSource = "build/app/outputs/bundle/release/app-release.aab"
$aabFolder = "release-builds"
$symbolFolder = "release-symbols/$newVersion"

# Create folders
New-Item -ItemType Directory -Force -Path $aabFolder | Out-Null
New-Item -ItemType Directory -Force -Path $symbolFolder | Out-Null

# Target AAB name
$aabTarget = "$aabFolder/${appName}_$newVersion.aab"

# Copy build
Copy-Item $aabSource $aabTarget

# Copy debug symbols
Copy-Item -Recurse debug-symbols/* $symbolFolder

Write-Host ""
Write-Host "Release build complete"
Write-Host "App: $appName"
Write-Host "Version: $newVersion"
Write-Host "AAB: $aabTarget"
Write-Host "Symbols: $symbolFolder"
Write-Host "===== CLEANING ====="
flutter clean

Write-Host "===== FETCHING DEPS ====="
flutter pub get

Write-Host "===== RUNNING RELEASE BUILD ====="
flutter run --release
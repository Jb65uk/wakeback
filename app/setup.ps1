# WakeBack app — Android setup / test / run / build (Windows PowerShell)
#
#   .\setup.ps1            one-time: make the android\ project, permissions, packages
#   .\setup.ps1 -Test      run the tests (the phone dock vs app.py behaviour, sync)
#   .\setup.ps1 -Run       run on the phone or emulator (debug, hot reload with r)
#   .\setup.ps1 -Build     release APK -> .\WakeBack.apk (send it to a mate)
#
# Every run copies the latest viewer (..\viewer\*.html) into the app, so the viewer
# stays one file that the dock Pi and the app both use.
#
# If Windows blocks the script:  powershell -ExecutionPolicy Bypass -File .\setup.ps1
param([switch]$Build, [switch]$Run, [switch]$Test)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host 'Flutter is not on your PATH yet - see app\README.md, step 1.' -ForegroundColor Red
    exit 1
}

# ---- 1. latest viewer into the app
foreach ($p in 'index.html', 'dock.html', 'upload.html') {
    $src = Join-Path $PSScriptRoot "..\viewer\$p"
    if (Test-Path $src) { Copy-Item $src (Join-Path $PSScriptRoot "assets\web\$p") -Force }
}
Write-Host 'Viewer copied into the app.' -ForegroundColor DarkGray

# ---- 2. Android project (only creates missing files; lib\ and pubspec are left alone)
if (-not (Test-Path 'android')) {
    Write-Host 'Creating Android project...' -ForegroundColor Cyan
    flutter create --platforms=android --org uk.bridgesolutions --project-name wakeback .
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
    Remove-Item 'test\widget_test.dart' -ErrorAction SilentlyContinue   # its sample test refers to a MyApp we don't have
}

# ---- 3. permissions: internet (server sync, map tiles) and plain http (the viewer talks to the phone's own dock)
$manifest = Join-Path $PSScriptRoot 'android\app\src\main\AndroidManifest.xml'
$m = [IO.File]::ReadAllText($manifest)
$changed = $false
if ($m -notmatch 'android.permission.INTERNET') {
    $perms = @'

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
'@
    $m = ([regex]'<manifest[^>]*>').Replace($m, { param($x) $x.Value + $perms }, 1)
    $changed = $true
}
if ($m -notmatch 'usesCleartextTraffic') {
    $m = ([regex]'<application').Replace($m, '<application android:usesCleartextTraffic="true"', 1)
    $changed = $true
}
if ($m -match 'android:label="wakeback"') {
    $m = $m.Replace('android:label="wakeback"', 'android:label="WakeBack"')
    $changed = $true
}
if ($changed) {
    [IO.File]::WriteAllText($manifest, $m)   # UTF-8, no BOM
    Write-Host 'AndroidManifest.xml updated' -ForegroundColor Green
}

# ---- 4. packages
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

if ($Test) { flutter test; exit $LASTEXITCODE }
if ($Run) { flutter run; exit $LASTEXITCODE }
if ($Build) {
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
    Copy-Item 'build\app\outputs\flutter-apk\app-release.apk' 'WakeBack.apk' -Force
    Write-Host "`nBuilt $(Join-Path $PSScriptRoot 'WakeBack.apk')" -ForegroundColor Green
    Write-Host 'Send it to a phone and open it - allow "install unknown apps" when asked.'
    exit 0
}

Write-Host "`nSet up. Next:" -ForegroundColor Green
Write-Host '  .\setup.ps1 -Test    check it all works'
Write-Host '  .\setup.ps1 -Run     run on your phone / emulator'
Write-Host '  .\setup.ps1 -Build   make WakeBack.apk'

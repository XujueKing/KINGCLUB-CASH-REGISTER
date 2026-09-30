param(
    [string]$FlutterSdk = '',
    [string]$AndroidSdk = '',
    [ValidateSet('release', 'profile', 'debug')]
    [string]$Mode = 'release',
    [switch]$Install,
    [string]$DeviceSerial = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (!$FlutterSdk) { $FlutterSdk = Join-Path (Split-Path -Parent $projectRoot) 'tools\flutter-3.47.1' }
if (!$AndroidSdk) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
if (!$AndroidSdk) { throw 'Set ANDROID_SDK_ROOT or provide -AndroidSdk.' }
if ($Install -and !$DeviceSerial) { throw 'Installation requires an explicitly verified -DeviceSerial.' }
$flutterExe = Join-Path $FlutterSdk 'bin\flutter.bat'
$adbExe = Join-Path $AndroidSdk 'platform-tools\adb.exe'
Push-Location $projectRoot
try {
    $version = (& $flutterExe --version --machine | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $version.frameworkVersion -ne '3.47.1') { throw 'Flutter 3.47.1 is required.' }
    & $flutterExe pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    # Release optimizes runtime performance; CASHIER_PREVIEW still disables real business actions.
    # This preview package retains its existing development signing identity for in-place upgrades.
    # Split filters dependency JNI libraries as well as the Flutter engine.
    # Without this, an ARM32 engine can be packaged alongside incomplete ARM64 JNI libraries.
    & $flutterExe build apk "--$Mode" --target-platform android-arm --split-per-abi --dart-define=CASHIER_PREVIEW=true --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
    $apk = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-armeabi-v7a-$Mode.apk"
    Get-FileHash -Algorithm SHA256 -LiteralPath $apk
    if ($Install) {
        $model = (& $adbExe -s $DeviceSerial shell getprop ro.product.model).Trim()
        if ($LASTEXITCODE -ne 0 -or $model -ne 'D2_2nd-SQB') { throw 'The selected device is not the expected cashier model.' }
        & $adbExe -s $DeviceSerial install -r $apk
        if ($LASTEXITCODE -ne 0) { throw 'Installation failed.' }
        & $adbExe -s $DeviceSerial shell am start -n cn.kingclub.cashregister.preview/cn.kingclub.kingclub_cash_register.MainActivity
        if ($LASTEXITCODE -ne 0) { throw 'Launch failed.' }
    }
} finally { Pop-Location }

param(
    [Parameter(Mandatory=$true)][string]$ServiceUrl,
    [Parameter(Mandatory=$true)][string]$FlutterSdk
)
$ErrorActionPreference = 'Stop'
$uri = [Uri]$ServiceUrl
if (!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or !$uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'A valid HTTPS service URL must be supplied by the release operator.'
}
if ($uri.AbsolutePath.TrimEnd('/') -ne '/kingclub-v2') {
    throw 'Cashier service URL must include the /kingclub-v2 application prefix.'
}
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & (Join-Path $FlutterSdk 'bin\flutter.bat') build apk --release --target-platform android-arm --split-per-abi "--dart-define=CASHIER_SERVICE_URL=$ServiceUrl" --dart-define=CASHIER_REALTIME=true --dart-define=CASHIER_USB_RASTER_OUTPUT=true --dart-define=CASHIER_TABLE_RECEIPT_OUTPUT=true --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Cashier build failed.' }
} finally { Pop-Location }

param(
    [Parameter(Mandatory=$true)][string]$ServiceUrl,
    [Parameter(Mandatory=$true)][string]$FlutterSdk
)
$ErrorActionPreference = 'Stop'
$uri = [Uri]$ServiceUrl
if (!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or !$uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'A valid HTTPS service URL must be supplied by the release operator.'
}
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & (Join-Path $FlutterSdk 'bin\flutter.bat') build apk --release --target-platform android-arm --split-per-abi "--dart-define=CASHIER_SERVICE_URL=$ServiceUrl" --dart-define=CASHIER_REALTIME=true --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Cashier build failed.' }
} finally { Pop-Location }

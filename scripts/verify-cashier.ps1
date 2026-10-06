param([string]$FlutterSdk = 'D:/SDK/flutter')
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
  # Receipt tests exercise the same USB output switch used by build-cashier.ps1.
  & "$FlutterSdk/bin/flutter.bat" test --dart-define=CASHIER_USB_RASTER_OUTPUT=true
  if ($LASTEXITCODE -ne 0) { throw 'Cashier tests failed' }
} finally { Pop-Location }

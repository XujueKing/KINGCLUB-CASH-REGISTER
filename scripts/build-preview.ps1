param(
    [Parameter(Mandatory=$true)][string]$ServiceUrl,
    [Parameter(Mandatory=$true)][string]$FlutterSdk
)
# Compatibility command name only: always builds the same authenticated product.
& (Join-Path $PSScriptRoot 'build-cashier.ps1') -ServiceUrl $ServiceUrl -FlutterSdk $FlutterSdk

# Packages a Windows release: PnRGUI.exe + tools/ + docs, zipped into dist/.
#
#   pwsh packaging/package-win.ps1 -Version 1.0.0 [-Configuration Release]
#
# Build Win64/Release in the IDE first (see docs/BUILDING.md).

param(
  [string]$Version = "dev",
  [string]$Configuration = "Release",
  [string]$Platform = "Win64"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root "$Platform\$Configuration\PnRGUI.exe"
if (-not (Test-Path -LiteralPath $exe)) {
  throw "not found: $exe`nBuild the $Platform $Configuration target in RAD Studio first."
}

$name = "FluxRoute-$Version-win64"
$dist = Join-Path $root "dist"
$stage = Join-Path $dist $name
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item -LiteralPath $exe -Destination $stage
foreach ($item in @("tools", "README.md", "LICENSE")) {
  $src = Join-Path $root $item
  if (-not (Test-Path -LiteralPath $src)) { throw "missing: $src" }
  Copy-Item -LiteralPath $src -Destination $stage -Recurse
}
# Never ship a machine's real config or Python caches.
$realCfg = Join-Path $stage "tools\config.json"
if (Test-Path -LiteralPath $realCfg) { Remove-Item -LiteralPath $realCfg -Force }
Get-ChildItem -LiteralPath (Join-Path $stage "tools") -Directory -Filter "__pycache__" -Recurse -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force

$zip = Join-Path $dist "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Remove-Item -LiteralPath $stage -Recurse -Force

Write-Host "wrote $zip"
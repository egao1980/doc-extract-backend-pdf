# Download a pinned bblanchon/pdfium-binaries shared lib and stage it for
# :cl-repo overlays + publish-native-package (flat native-bundle/ dest names).
# Do not vendor Chromium source. Do not commit the binaries.
#
# Usage: .\scripts\stage-pdfium.ps1 [-Os windows] [-Arch amd64]
# Env:   PDFIUM_BINARIES_TAG (default chromium/8035)
[CmdletBinding()]
param(
  [string]$Os = "",
  [string]$Arch = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tag = if ($env:PDFIUM_BINARIES_TAG) { $env:PDFIUM_BINARIES_TAG } else { "chromium/8035" }
$Supported = "linux/amd64 linux/arm64 darwin/arm64 windows/amd64"

function Get-DetectedOs {
  if ($env:OS -eq "Windows_NT" -or [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
      [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    return "windows"
  }
  throw "error: unknown OS (supported: $Supported). Pass -Os / -Arch."
}

function Get-DetectedArch {
  $m = $env:PROCESSOR_ARCHITECTURE
  switch -Regex ($m) {
    "^(AMD64|X64)$" { return "amd64" }
    "^(ARM64)$" { return "arm64" }
  }
  throw "error: unknown arch from PROCESSOR_ARCHITECTURE=$m (supported: $Supported)"
}

if (-not $Os -and -not $Arch) {
  $Os = Get-DetectedOs
  $Arch = Get-DetectedArch
} elseif (-not $Os -or -not $Arch) {
  throw "error: pass both -Os and -Arch, or neither (to detect). supported: $Supported"
}

$Asset = switch ("$Os/$Arch") {
  "linux/amd64" { "pdfium-linux-x64.tgz" }
  "linux/arm64" { "pdfium-linux-arm64.tgz" }
  "darwin/arm64" { "pdfium-mac-arm64.tgz" }
  "windows/amd64" { "pdfium-win-x64.tgz" }
  default { throw "error: unknown platform ${Os}/${Arch} (supported: $Supported)" }
}

$DestNames = switch ($Os) {
  "linux" { @("libpdfium.so", "libpdfium.so.1") }
  "darwin" { @("libpdfium.dylib", "libpdfium.1.dylib") }
  "windows" { @("pdfium.dll", "libpdfium.dll") }
  default { throw "error: unknown OS $Os" }
}

$TagEnc = $Tag.Replace("/", "%2F")
$Url = "https://github.com/bblanchon/pdfium-binaries/releases/download/${TagEnc}/${Asset}"
$SafeTag = $Tag.Replace("/", "-")
$Build = Join-Path $Root "build"
$Tgz = Join-Path $Build "pdfium-${SafeTag}-${Asset}"
$Extract = Join-Path $Build "pdfium-${SafeTag}-${Os}-${Arch}"
$LibDir = Join-Path $Root (Join-Path "lib" "${Os}-${Arch}")
$Bundle = Join-Path $Root "native-bundle"

New-Item -ItemType Directory -Force -Path $Build | Out-Null
if (-not (Test-Path $Tgz) -or ((Get-Item $Tgz).Length -eq 0)) {
  Write-Host "==> download $Url"
  Invoke-WebRequest -Uri $Url -OutFile $Tgz
} else {
  Write-Host "==> reuse $Tgz"
}

if (Test-Path $Extract) { Remove-Item -Recurse -Force $Extract }
New-Item -ItemType Directory -Force -Path $Extract | Out-Null
tar -xzf $Tgz -C $Extract
if ($LASTEXITCODE -ne 0) { throw "tar extract failed for $Tgz" }

function Find-PdfiumSrc([string]$ExtractDir) {
  $candidates = switch ($Os) {
    "linux" {
      @(
        (Join-Path $ExtractDir "lib/libpdfium.so"),
        (Join-Path $ExtractDir "lib/libpdfium.so.1"),
        (Join-Path $ExtractDir "lib64/libpdfium.so")
      )
    }
    "darwin" {
      @(
        (Join-Path $ExtractDir "lib/libpdfium.dylib"),
        (Join-Path $ExtractDir "lib/libpdfium.1.dylib")
      )
    }
    "windows" {
      @(
        (Join-Path $ExtractDir "bin/pdfium.dll"),
        (Join-Path $ExtractDir "lib/pdfium.dll"),
        (Join-Path $ExtractDir "pdfium.dll")
      )
    }
  }
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  $hit = Get-ChildItem -Path $ExtractDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -eq "libpdfium.so" -or $_.Name -like "libpdfium.so.*" -or
      $_.Name -eq "libpdfium.dylib" -or $_.Name -like "libpdfium.*.dylib" -or
      $_.Name -eq "pdfium.dll"
    } |
    Select-Object -First 1
  if ($hit) { return $hit.FullName }
  throw "error: libpdfium not found in $ExtractDir ($Asset / $Tag)"
}

$Src = Find-PdfiumSrc $Extract
Write-Host "==> source $Src"

if (Test-Path $LibDir) { Remove-Item -Recurse -Force $LibDir }
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
New-Item -ItemType Directory -Force -Path $Bundle | Out-Null

foreach ($name in $DestNames) {
  Copy-Item -Path $Src -Destination (Join-Path $LibDir $name) -Force
  Copy-Item -Path $Src -Destination (Join-Path $Bundle $name) -Force
}

Write-Host "==> verify overlay inventory"
foreach ($name in $DestNames) {
  $libFile = Join-Path $LibDir $name
  $bundleFile = Join-Path $Bundle $name
  if (-not (Test-Path $libFile)) { throw "missing $libFile" }
  if (-not (Test-Path $bundleFile)) { throw "missing $bundleFile" }
}

Write-Host "staged ${Os}/${Arch} from ${Tag} (${Asset}):"
Get-ChildItem $LibDir | Format-Table Name, Length
Get-ChildItem $Bundle | Format-Table Name, Length

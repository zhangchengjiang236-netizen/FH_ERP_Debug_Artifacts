[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$AdbPath,
  [Parameter(Mandatory=$true)][string]$AaptPath,
  [Parameter(Mandatory=$true)][string]$ApkSignerPath,
  [Parameter(Mandatory=$true)][string]$PackageId
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments)
  $result = & $File @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Command failed: $File $($Arguments -join ' ')`n$result" }
  return ($result -join "`n")
}

foreach ($path in @($AdbPath, $AaptPath, $ApkSignerPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required tool was not found: $path" }
}

$devices = Invoke-Checked $AdbPath @('devices')
$ready = @($devices -split "`r?`n" | Where-Object { $_ -match '^[^\s]+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if ($ready.Count -ne 1) { throw "Exactly one authorized Android device is required; found $($ready.Count)." }
$serial = $ready[0]

$paths = Invoke-Checked $AdbPath @('-s', $serial, 'shell', 'pm', 'path', $PackageId)
$base = @($paths -split "`r?`n" | Where-Object { $_ -match '^package:.*/base\.apk$' } | Select-Object -First 1)
if ($base.Count -ne 1) { throw "The installed base APK for $PackageId was not found." }
$remoteApk = $base[0].Substring('package:'.Length)
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("$($PackageId.Replace('.', '_'))-$serial-base.apk")

try {
  Invoke-Checked $AdbPath @('-s', $serial, 'pull', $remoteApk, $temporary) | Out-Null
  $badging = Invoke-Checked $AaptPath @('dump', 'badging', $temporary)
  $package = [regex]::Match($badging, "package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'")
  if (-not $package.Success) { throw 'aapt did not return package metadata.' }
  $signing = Invoke-Checked $ApkSignerPath @('verify', '--verbose', '--print-certs', $temporary)
  $fingerprint = [regex]::Match($signing, 'Signer #1 certificate SHA-256 digest:\s*([a-f0-9:]+)', 'IgnoreCase')
  if (-not $fingerprint.Success) { throw 'apksigner did not return a signer SHA-256 fingerprint.' }
  [pscustomobject]@{
    serial = $serial
    packageId = $package.Groups[1].Value
    versionCode = [Int64]$package.Groups[2].Value
    versionName = $package.Groups[3].Value
    signerSha256 = ($fingerprint.Groups[1].Value -replace ':', '').ToLowerInvariant()
  } | ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

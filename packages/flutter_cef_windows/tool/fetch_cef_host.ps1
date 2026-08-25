# fetch_cef_host.ps1 - consumer fetch of a prebuilt cef_host.exe + cef_host.dll
# keyed by a CONTENT HASH of the build inputs, from public GCS. Runs at CMake
# configure time (windows/CMakeLists.txt), which then bundles
# native/cef_host/prebuilt/ beside the app instead of building the host from
# source. Self-locating (CWD-independent). Mirrors the macOS
# packages/flutter_cef_macos/tool/fetch_cef_host.sh.
#
# The hash (cef_host_hash.ps1) is derived from the checked-out cef_host sources +
# fetch_cef.ps1, so it is identical to what the publisher computed -- no committed
# manifest, release-model-agnostic. Fail-OPEN on network/missing (co-dev + offline
# builds fall back to build-from-source); fail-CLOSED on checksum mismatch and on
# a bad / foreign / absent code signature.
#
# ---------------------------------------------------------------------------
# SIGNING TRANSITION (STUBBED-BUT-REAL) -- READ BEFORE THE CERT SHIPS
# ---------------------------------------------------------------------------
# The Authenticode gate below is REAL: it requires Get-AuthenticodeSignature
# Status 'Valid' AND the signer certificate pinned to FLUTTER_CEF_CERT_THUMBPRINT
# (exact thumbprint) or FLUTTER_CEF_CERT_SUBJECT (subject substring). BECAUSE the
# signing certificate is not procured yet, published artifacts are UNSIGNED today.
# To accept an unsigned host you MUST opt in with FLUTTER_CEF_ALLOW_UNSIGNED_HOST=1
# (a LOUD warning is printed). Anything else -- unsigned WITHOUT the opt-in, a
# validly-signed host with NO pin configured, or any invalid/foreign signature --
# fails CLOSED (exit 1).
#   FLIP WHEN SIGNING SHIPS: set FLUTTER_CEF_CERT_THUMBPRINT in CI + consumers and
#   DELETE the FLUTTER_CEF_ALLOW_UNSIGNED_HOST opt-in branch (and this paragraph).
# ---------------------------------------------------------------------------
#
# STDERR-only: this script has NO intended stdout value; every message goes to
# STDERR (Info) so a caller capturing stdout sees nothing from here. Exit codes:
#   0 = proceed (prebuilt placed, already-current, or fail-OPEN to source)
#   1 = fail-CLOSED (checksum / signature) -- the caller MUST refuse to build.
#
# ASCII-ONLY (PS 5.1 mis-parses multibyte in a UTF-8-no-BOM file).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Progress -> STDERR. Write-Host / Write-Output would land on STDOUT under
# `powershell -File` and pollute anything a caller captures.
function Info($m) { [Console]::Error.WriteLine($m) }

# fail-CLOSED authenticity gate for one binary. Returns $true if acceptable.
function Test-CefHostSignature {
  param([Parameter(Mandatory = $true)][string]$Path)
  $name = Split-Path -Leaf $Path
  $sig = Get-AuthenticodeSignature -LiteralPath $Path

  if ($sig.Status -eq 'Valid') {
    $cert = $sig.SignerCertificate
    if ($env:FLUTTER_CEF_CERT_THUMBPRINT) {
      $want = ($env:FLUTTER_CEF_CERT_THUMBPRINT -replace '\s', '').ToUpperInvariant()
      $got = ($cert.Thumbprint -replace '\s', '').ToUpperInvariant()
      if ($got -eq $want) {
        Info "[flutter_cef] signature OK for $name (thumbprint $got)."
        return $true
      }
      Info "[flutter_cef] $name signed by UNEXPECTED cert (thumbprint $got, wanted $want) - refusing."
      return $false
    }
    elseif ($env:FLUTTER_CEF_CERT_SUBJECT) {
      if ($cert.Subject -like "*$($env:FLUTTER_CEF_CERT_SUBJECT)*") {
        Info "[flutter_cef] signature OK for $name (subject matches '$($env:FLUTTER_CEF_CERT_SUBJECT)')."
        return $true
      }
      Info "[flutter_cef] $name signed by UNEXPECTED subject ('$($cert.Subject)') - refusing."
      return $false
    }
    else {
      Info "[flutter_cef] $name is validly signed but no FLUTTER_CEF_CERT_THUMBPRINT / FLUTTER_CEF_CERT_SUBJECT is set to pin it - refusing (cannot verify provenance)."
      return $false
    }
  }
  elseif ($sig.Status -eq 'NotSigned') {
    if ($env:FLUTTER_CEF_ALLOW_UNSIGNED_HOST -eq '1') {
      Info "==================================================================="
      Info "[flutter_cef] WARNING: accepting UNSIGNED cef_host ($name) because"
      Info "[flutter_cef]          FLUTTER_CEF_ALLOW_UNSIGNED_HOST=1 is set. This"
      Info "[flutter_cef]          is a TEMPORARY pre-certificate posture. Remove"
      Info "[flutter_cef]          the opt-in once code signing ships; do NOT rely"
      Info "[flutter_cef]          on it in a trusted / production pipeline."
      Info "==================================================================="
      return $true
    }
    Info "[flutter_cef] $name is UNSIGNED and FLUTTER_CEF_ALLOW_UNSIGNED_HOST is not set - refusing (fail-closed)."
    return $false
  }
  else {
    Info "[flutter_cef] $name has an INVALID signature (Status=$($sig.Status)) - refusing (fail-closed)."
    return $false
  }
}

# --- Escape hatch: co-dev / build-from-source. Any non-empty value skips. ---
if ($env:FLUTTER_CEF_FROM_SOURCE) {
  Info "[flutter_cef] FLUTTER_CEF_FROM_SOURCE set - skipping prebuilt fetch (build from source)."
  exit 0
}

# --- Self-locate. ---
$here = $PSScriptRoot
$pkg = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
$cefHost = Join-Path $pkg 'native\cef_host'
$dest = Join-Path $cefHost 'prebuilt'
$stamp = Join-Path $dest 'cef_host_input_hash.txt'

# --- Compute the input hash (shared with the publisher). ---
. (Join-Path $here 'cef_host_hash.ps1')
$hash = Get-CefHostInputHash -CefHostDir $cefHost

$base = if ($env:FLUTTER_CEF_GCS_BASE) { $env:FLUTTER_CEF_GCS_BASE }
        else { 'https://storage.googleapis.com/flutterflow-downloads/campus_prebuilt_cef_host' }
$file = 'cef_host-windows-x64.zip'
$url = "$base/$hash/$file"
$shaUrl = "$url.sha256"

# --- Already current? the placed prebuilt carries the hash it was built from. ---
if ((Test-Path -LiteralPath (Join-Path $dest 'cef_host.exe')) -and
    (Test-Path -LiteralPath (Join-Path $dest 'cef_host.dll')) -and
    (Test-Path -LiteralPath $stamp) -and
    ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $hash)) {
  Info "[flutter_cef] prebuilt cef_host already current ($hash) - skipping fetch."
  exit 0
}

# --- Transport-integrity sidecar. Fail-OPEN if unreachable (nothing published
#     for this hash yet -- a fresh native change before CI publishes, or offline
#     -> build from source). ---
Info "[flutter_cef] resolving prebuilt cef_host for input hash $hash"
$shaLine = & curl.exe -fsSL --retry 3 --retry-delay 1 $shaUrl
if ($LASTEXITCODE -ne 0 -or -not $shaLine) {
  Info "[flutter_cef] no published cef_host for hash $hash ($shaUrl unreachable)."
  Info "[flutter_cef] building from source (dev), or CI will publish it shortly."
  exit 0
}
$expected = (([string]$shaLine).Trim() -split '\s+')[0].ToLowerInvariant()

# --- Download to a per-hash cache (re-use a good cached zip). ---
$cacheRoot = if ($env:FLUTTER_CEF_CACHE) { $env:FLUTTER_CEF_CACHE }
             else { Join-Path $env:LOCALAPPDATA 'flutter_cef' }
$cacheDir = Join-Path $cacheRoot "prebuilt\$hash\x64"
New-Item -ItemType Directory -Force $cacheDir | Out-Null
$zip = Join-Path $cacheDir $file

$needDownload = $true
if (Test-Path -LiteralPath $zip) {
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -eq $expected) {
    $needDownload = $false
  }
}
if ($needDownload) {
  Info "[flutter_cef] downloading prebuilt cef_host: $url"
  $part = "$zip.part"
  & curl.exe -fL --retry 3 --retry-delay 1 -o $part $url
  if ($LASTEXITCODE -ne 0) {
    Info "[flutter_cef] download failed - building from source."
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    exit 0
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    Info "[flutter_cef] SHA256 MISMATCH for $file (expected $expected, got $actual) - refusing."
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    exit 1                              # fail-CLOSED: never place an unverified host
  }
  Move-Item -LiteralPath $part -Destination $zip -Force
}

# --- Extract to a PRIVATE staging dir, verify there, then move into place. A
#     consumer can never observe a half-extracted or unverified host. ---
$stage = Join-Path $cacheRoot (".fetch-$PID-" + [System.Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force $stage | Out-Null
  Info "[flutter_cef] extracting prebuilt cef_host..."
  Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force

  $exe = Join-Path $stage 'cef_host.exe'
  $dll = Join-Path $stage 'cef_host.dll'
  if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $dll)) {
    Info "[flutter_cef] archive did not contain cef_host.exe + cef_host.dll - refusing."
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    exit 1
  }

  # fail-CLOSED authenticity gate on BOTH binaries (see the header).
  if (-not (Test-CefHostSignature -Path $exe) -or -not (Test-CefHostSignature -Path $dll)) {
    Info "[flutter_cef] SIGNATURE VERIFICATION FAILED for the fetched cef_host - refusing."
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue   # poisoned; don't trust the cache
    exit 1
  }

  # Verified: move into place. cef_host.exe + cef_host.dll + provenance stamps.
  New-Item -ItemType Directory -Force $dest | Out-Null
  foreach ($n in @('cef_host.exe', 'cef_host.dll',
                   'cef_host_input_hash.txt', 'cef_version.txt', 'cef_host_source_sha.txt')) {
    $src = Join-Path $stage $n
    if (Test-Path -LiteralPath $src) {
      Move-Item -LiteralPath $src -Destination (Join-Path $dest $n) -Force
    }
  }
  # Stamp even if the archive predated the field.
  Set-Content -LiteralPath $stamp -Value $hash -Encoding ascii
  Info "[flutter_cef] prebuilt cef_host ready ($hash)."
  exit 0
}
finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

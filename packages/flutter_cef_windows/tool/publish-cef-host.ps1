# publish-cef-host.ps1 - CI / maintainer publish of a prebuilt Windows cef_host
# to public GCS, keyed by a content hash of the build inputs. Mirrors the macOS
# packages/flutter_cef_macos/tool/publish-cef-host.sh (+ the Makefile
# publish-cef-host target). Run when native/cef_host or the CEF pin changes so
# consumers FETCH a matching host (fetch_cef_host.ps1) instead of compiling it.
# Idempotent: re-running with an unchanged tree is a no-op.
#
# ---------------------------------------------------------------------------
# SIGNING (three modes, priority order)
# ---------------------------------------------------------------------------
# 1. GOOGLECLOUD (jsign) -- the FlutterFlow production identity. Set
#    FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE (the KMS keyring path) +
#    FLUTTER_CEF_SIGN_CERTFILE (the public cert chain .crt). Reuses the SAME
#    EV cert + Google Cloud KMS key the FlutterFlow desktop app signs with
#    (flutterflow/windows/Makefile) -- so cef_host is signed by "FlutterFlow,
#    Inc." No key material on this machine: the private key stays in KMS, auth
#    is `gcloud auth print-access-token`. Needs `jsign` + `gcloud` (authed with
#    roles/cloudkms.signerVerifier on the key).
#      FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE  e.g. projects/flutterflow-cicd/locations/
#                                        us-central1/keyRings/windows-code-sign
#      FLUTTER_CEF_SIGN_GCLOUD_ALIAS     default windows-code-sign-key/cryptoKeyVersions/1
#      FLUTTER_CEF_SIGN_CERTFILE         path to the public cert chain (.crt)
# 2. signtool -- set FLUTTER_CEF_SIGN_THUMBPRINT for a cert in the machine store.
# 3. unsigned -- neither set (pre-cert dev posture); the consumer then requires
#    FLUTTER_CEF_ALLOW_UNSIGNED_HOST=1.
#   FLIP WHEN SIGNING IS WIRED IN CI: make signing mandatory (fail if no mode is
#   set) and drop the consumer's unsigned opt-in.
# Common: FLUTTER_CEF_SIGN_TIMESTAMP_URL (default http://timestamp.digicert.com).
# ---------------------------------------------------------------------------
#
# Requires: gsutil (Google Cloud SDK) authed with object-create on the bucket.
# Env: GCS_BUCKET (default flutterflow-downloads), GCS_PREFIX (default
#   campus_prebuilt_cef_host), FLUTTER_CEF_SIGN_THUMBPRINT, FLUTTER_CEF_SIGN_TIMESTAMP_URL.
#
# STDERR-only progress (Info); no intended stdout value. ASCII-ONLY (PS 5.1).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Info($m) { [Console]::Error.WriteLine($m) }
function Fail($m) { Info $m; exit 1 }

# Locate signtool.exe: PATH first, else the newest x64 copy under the Windows SDK.
function Resolve-Signtool {
  $c = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
  foreach ($r in $roots) {
    if (Test-Path -LiteralPath $r) {
      $hit = Get-ChildItem -LiteralPath $r -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\x64\\' } |
             Sort-Object FullName -Descending | Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
  }
  return $null
}

# Read the CEF version pin ($CefVersion) out of fetch_cef.ps1 for provenance.
function Get-CefVersionPin {
  param([Parameter(Mandatory = $true)][string]$CefHostDir)
  foreach ($ln in (Get-Content -LiteralPath (Join-Path $CefHostDir 'fetch_cef.ps1'))) {
    if ($ln -match "CefVersion\s*=\s*'([^']+)'") { return $Matches[1] }
  }
  return 'unknown'
}

# --- Self-locate. ---
$here = $PSScriptRoot
$pkg = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
$cefHost = Join-Path $pkg 'native\cef_host'

# --- Guard: gsutil present. ---
if (-not (Get-Command gsutil -ErrorAction SilentlyContinue)) {
  Info "[publish] gsutil not found. Install the Google Cloud SDK, then authenticate:"
  Info "[publish]   https://cloud.google.com/sdk/docs/install"
  Info "[publish]   gcloud auth login   (needs object-create on the target bucket)"
  exit 2
}

# --- Content hash / object key (shared with the consumer). ---
. (Join-Path $here 'cef_host_hash.ps1')
$hash = Get-CefHostInputHash -CefHostDir $cefHost
Info "[publish] cef_host input hash: $hash"

$bucket = if ($env:GCS_BUCKET) { $env:GCS_BUCKET } else { 'flutterflow-downloads' }
$prefix = if ($env:GCS_PREFIX) { $env:GCS_PREFIX } else { 'campus_prebuilt_cef_host' }
$file = 'cef_host-windows-x64.zip'
$dst = "gs://$bucket/$prefix/$hash/$file"

# --- Idempotency: this exact tree is already published -> nothing to do. ---
# NOTE (flip when signing ships): mirror macOS and download + verify the remote
# artifact's Authenticode signature here before trusting the skip, to defeat a
# planted object pre-staged at a future content hash. Stubbed while unsigned.
& gsutil -q stat $dst
if ($LASTEXITCODE -eq 0) {
  Info "[publish] $dst already exists - nothing to do (idempotent skip)."
  exit 0
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cef_host_publish_" + [System.Guid]::NewGuid().ToString('N'))
$buildDir = Join-Path $work 'build'
$out = Join-Path $work 'out'
try {
  New-Item -ItemType Directory -Force $out | Out-Null

  # --- Build cef_host.dll + stage cef_host.exe via the existing build script. ---
  Info "[publish] building cef_host via build_cef_host.bat ..."
  & (Join-Path $cefHost 'build_cef_host.bat') $buildDir $out
  if ($LASTEXITCODE -ne 0) { Fail "[publish] build_cef_host.bat failed (exit $LASTEXITCODE)." }
  $exe = Join-Path $out 'cef_host.exe'
  $dll = Join-Path $out 'cef_host.dll'
  if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $dll)) {
    Fail "[publish] build did not produce cef_host.exe + cef_host.dll."
  }

  # --- Sign. Three modes, in priority order:
  #   1. GOOGLECLOUD (jsign, the FlutterFlow production identity): set
  #      FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE. Reuses the SAME EV cert + Google
  #      Cloud KMS key the FlutterFlow desktop app signs with (see
  #      flutterflow/windows/Makefile), so cef_host is signed by "FlutterFlow,
  #      Inc." No key material touches this machine or repo -- the private key
  #      stays in KMS; auth is `gcloud auth print-access-token`. Needs `jsign`
  #      (choco install jsign), `gcloud` authed with roles/cloudkms.signerVerifier
  #      on the key, and the public cert chain (FLUTTER_CEF_SIGN_CERTFILE).
  #   2. signtool + a local cert (FLUTTER_CEF_SIGN_THUMBPRINT) -- for a cert
  #      installed in the machine store.
  #   3. unsigned (neither set) -- the pre-cert dev posture; the consumer then
  #      requires FLUTTER_CEF_ALLOW_UNSIGNED_HOST=1.
  $tsUrl = if ($env:FLUTTER_CEF_SIGN_TIMESTAMP_URL) { $env:FLUTTER_CEF_SIGN_TIMESTAMP_URL }
           else { 'http://timestamp.digicert.com' }
  if ($env:FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE) {
    if (-not (Get-Command jsign -ErrorAction SilentlyContinue)) {
      Fail "[publish] FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE set but 'jsign' not found (choco install jsign)."
    }
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
      Fail "[publish] jsign GOOGLECLOUD signing needs 'gcloud' on PATH (authed with KMS sign access)."
    }
    $certfile = $env:FLUTTER_CEF_SIGN_CERTFILE
    if (-not $certfile -or -not (Test-Path -LiteralPath $certfile)) {
      Fail "[publish] set FLUTTER_CEF_SIGN_CERTFILE to the public cert chain (.crt) for the KMS key."
    }
    $alias = if ($env:FLUTTER_CEF_SIGN_GCLOUD_ALIAS) { $env:FLUTTER_CEF_SIGN_GCLOUD_ALIAS }
             else { 'windows-code-sign-key/cryptoKeyVersions/1' }
    $token = (& gcloud auth print-access-token).Trim()
    if (-not $token) { Fail "[publish] 'gcloud auth print-access-token' returned nothing (run gcloud auth login)." }
    foreach ($f in @($exe, $dll)) {
      Info "[publish] jsign GOOGLECLOUD signing $([IO.Path]::GetFileName($f)) ..."
      & jsign --storetype GOOGLECLOUD --keystore $env:FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE `
              --alias $alias --certfile $certfile --tsaurl $tsUrl --storepass $token $f
      if ($LASTEXITCODE -ne 0) { Fail "[publish] jsign failed on $f (exit $LASTEXITCODE)." }
      $sig = Get-AuthenticodeSignature -LiteralPath $f
      if ($sig.Status -ne 'Valid') { Fail "[publish] signature not Valid after jsign on $f ($($sig.Status))." }
    }
    Info "[publish] signed + verified (GOOGLECLOUD KMS, cert $([IO.Path]::GetFileName($certfile)))."
  }
  elseif ($env:FLUTTER_CEF_SIGN_THUMBPRINT) {
    $signtool = Resolve-Signtool
    if (-not $signtool) {
      Fail "[publish] FLUTTER_CEF_SIGN_THUMBPRINT set but signtool.exe not found (install the Windows SDK)."
    }
    Info "[publish] signtool signing cef_host.exe + cef_host.dll (thumbprint $($env:FLUTTER_CEF_SIGN_THUMBPRINT)) ..."
    & $signtool sign /sha1 $env:FLUTTER_CEF_SIGN_THUMBPRINT /fd SHA256 /tr $tsUrl /td SHA256 $exe $dll
    if ($LASTEXITCODE -ne 0) { Fail "[publish] signtool sign failed (exit $LASTEXITCODE)." }
    & $signtool verify /pa $exe $dll
    if ($LASTEXITCODE -ne 0) { Fail "[publish] signtool verify failed after signing." }
  }
  else {
    Info "[publish] signing skipped (no cert; unsigned artifact). Set FLUTTER_CEF_SIGN_GCLOUD_KEYSTORE (jsign+KMS) or FLUTTER_CEF_SIGN_THUMBPRINT (signtool) to sign."
  }

  # --- Provenance stamps beside the binaries (informational; the URL is the hash). ---
  $srcSha = 'unknown'
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $rev = & git -C $pkg rev-parse HEAD
    if ($LASTEXITCODE -eq 0 -and $rev) { $srcSha = ([string]$rev).Trim() }
  }
  Set-Content -LiteralPath (Join-Path $out 'cef_host_input_hash.txt') -Value $hash -Encoding ascii
  Set-Content -LiteralPath (Join-Path $out 'cef_version.txt') -Value (Get-CefVersionPin -CefHostDir $cefHost) -Encoding ascii
  Set-Content -LiteralPath (Join-Path $out 'cef_host_source_sha.txt') -Value $srcSha -Encoding ascii

  # --- Package + sha256 sidecar. The zip's own bytes need not be deterministic:
  #     the URL is keyed by the INPUT hash, and the consumer verifies the download
  #     against this sidecar. ---
  $stage = Join-Path $work 'stage'
  New-Item -ItemType Directory -Force $stage | Out-Null
  $zip = Join-Path $stage $file
  Info "[publish] packaging $file ..."
  Compress-Archive -Force -DestinationPath $zip -Path @(
    (Join-Path $out 'cef_host.exe'),
    (Join-Path $out 'cef_host.dll'),
    (Join-Path $out 'cef_host_input_hash.txt'),
    (Join-Path $out 'cef_version.txt'),
    (Join-Path $out 'cef_host_source_sha.txt')
  )
  $zipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  $shaSidecar = "$zip.sha256"
  Set-Content -LiteralPath $shaSidecar -Value ("{0}  {1}" -f $zipSha, $file) -Encoding ascii

  # --- Upload (re-check to close a publish race; objects are immutable). ---
  & gsutil -q stat $dst
  if ($LASTEXITCODE -eq 0) {
    Info "[publish] $dst appeared during build - skipping upload."
    exit 0
  }
  $cacheHdr = 'Cache-Control:public,max-age=31536000,immutable'
  & gsutil -h $cacheHdr cp $zip $dst
  if ($LASTEXITCODE -ne 0) { Fail "[publish] upload of $dst failed (exit $LASTEXITCODE)." }
  & gsutil -h $cacheHdr cp $shaSidecar "$dst.sha256"
  if ($LASTEXITCODE -ne 0) { Fail "[publish] upload of $dst.sha256 failed (exit $LASTEXITCODE)." }
  Info "[publish] uploaded $dst (zip sha256 $zipSha)."
  exit 0
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

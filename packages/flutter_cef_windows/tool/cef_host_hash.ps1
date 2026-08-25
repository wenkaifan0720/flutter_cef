# cef_host_hash.ps1 - deterministic content hash of the Windows cef_host build
# inputs. Prints a 64-hex digest to STDOUT (Write-Output).
#
# Dot-sourced by BOTH fetch_cef_host.ps1 (consumer, at CMake configure) and
# publish-cef-host.ps1 (CI) so they ALWAYS compute the same digest from the same
# source tree -- that digest IS the GCS object key, so any drift here is a silent
# cache miss. Mirrors packages/flutter_cef_macos/tool/cef_host_hash.sh.
#
# Inputs (the ONLY files that determine the shipped cef_host.dll/.exe bytes):
#   build_cef_host.bat, CMakeLists.txt, cef_host_protocol.h, cef_host_win.cc,
#   fetch_cef.ps1.  fetch_cef.ps1 carries the CEF version pin ($CefVersion) -- the
#   Windows analogue of the macOS build_cef_host.sh carrying CEF_VERSION -- so a
#   CEF bump moves the digest without hashing the multi-hundred-MB CEF dist.
# Docs (PROTOCOL.md) and the standalone IPC test (test/) are NOT build inputs and
# are excluded; the build/ and prebuilt/ OUTPUT dirs are never inputs.
#
# Determinism across machines: the input list is byte-stable (ordinal) sorted,
# each file's CR (0x0D) is stripped before hashing so a git core.autocrlf checkout
# does NOT perturb the digest, and we emit "<relpath>\n<filesha256>\n" per file
# (LF, lowercase hex) then SHA-256 the whole UTF-8 stream. Same tree -> same
# digest on every machine.
#
# ASCII-ONLY (no em-dashes / smart quotes): PowerShell 5.1 reads a UTF-8-no-BOM
# file as ANSI and mis-parses multibyte characters. Keep this file 7-bit.
#
# Usage:
#   Dot-source:  . .\cef_host_hash.ps1 ; Get-CefHostInputHash -CefHostDir <dir>
#   Standalone:  powershell -File .\cef_host_hash.ps1   (prints this pkg's hash)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# SHA-256 of a byte array, returned as lowercase 64-hex.
function ConvertTo-Sha256Hex {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $digest = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
  return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
}

# SHA-256 of a file with CR bytes stripped (CRLF and LF checkouts hash equal).
# All inputs are text, so a 0x0D only ever appears as part of a CRLF here.
function Get-NormalizedFileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $out = New-Object System.Collections.Generic.List[byte]
  foreach ($b in $bytes) { if ($b -ne 13) { [void]$out.Add($b) } }
  return (ConvertTo-Sha256Hex -Bytes $out.ToArray())
}

function Get-CefHostInputHash {
  [CmdletBinding()]
  param(
    # .../packages/flutter_cef_windows/native/cef_host . Defaults to the copy
    # beside this script so dot-source and standalone use both work arg-free.
    [string]$CefHostDir = (Join-Path $PSScriptRoot '..\native\cef_host')
  )

  $root = (Resolve-Path -LiteralPath $CefHostDir).Path

  # Explicit, ordered build-input list (relative to $CefHostDir). Extend this if
  # a new file starts to affect the shipped host bytes.
  $inputs = [string[]]@(
    'build_cef_host.bat',
    'CMakeLists.txt',
    'cef_host_protocol.h',
    'cef_host_win.cc',
    'fetch_cef.ps1'
  )
  # Byte-stable (ordinal) sort: identical order on every machine and culture.
  [Array]::Sort($inputs, [System.StringComparer]::Ordinal)

  $sb = New-Object System.Text.StringBuilder
  foreach ($rel in $inputs) {
    $path = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "cef_host_hash: missing build input '$rel' under '$root'"
    }
    $fileSha = Get-NormalizedFileSha256 -Path $path
    # relpath (forward slashes; inputs are flat, this only future-proofs nested
    # entries) then its sha, each LF-terminated.
    $relKey = $rel -replace '\\', '/'
    [void]$sb.Append($relKey);  [void]$sb.Append("`n")
    [void]$sb.Append($fileSha); [void]$sb.Append("`n")
  }

  $streamBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
  return (ConvertTo-Sha256Hex -Bytes $streamBytes)
}

# Standalone: print the digest for this package's native/cef_host. Dot-sourcing
# ('. .\cef_host_hash.ps1') sets InvocationName to '.', which skips this block.
if ($MyInvocation.InvocationName -ne '.') {
  Write-Output (Get-CefHostInputHash)
}

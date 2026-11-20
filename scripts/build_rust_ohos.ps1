<#
Cross-compiles the Rust backend for the OpenHarmony arm64 target and copies
libfqapi_napi.so into entry/libs/arm64-v8a, where hvigor packages it into
the HAP.

The workspace (root Cargo.toml) holds two members:
  - rust/            vendored fqapi_core (do not edit, keep diff-minimal vs fqapp)
  - crates/fqapi_napi  Node-API adapter that exposes the core to ArkTS

The DevEco OpenHarmony toolchain only ships /bin/sh clang wrappers, which do
not run on Windows, so this script generates equivalent .cmd wrappers (same
flags: --target=aarch64-linux-ohos, sysroot, -D__MUSL__) next to the Rust
target dir and points cargo's CC/linker env at them.

Usage:
  .\scripts\build_rust_ohos.ps1
  .\scripts\build_rust_ohos.ps1 -DevEcoHome "E:\Huawei\DevEco Studio7"
  .\scripts\build_rust_ohos.ps1 -Profile debug

Unknown parameters are a hard error. -Profile only accepts release|debug.
$DevEcoHome falls back to $env:DEVECO_HOME when omitted.

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [string]$DevEcoHome,
    [ValidateSet('release', 'debug')][string]$Profile = 'release'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceManifest = Join-Path $RepoRoot 'Cargo.toml'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo not found in PATH. Install the Rust toolchain first (rustup target add aarch64-unknown-linux-ohos).'
    exit 1
}
if (-not (Test-Path -LiteralPath $WorkspaceManifest)) {
    Write-Error "workspace manifest not found at $WorkspaceManifest"
    exit 1
}

if (-not $DevEcoHome) { $DevEcoHome = $env:DEVECO_HOME }
if (-not $DevEcoHome) {
    Write-Error 'DevEco Studio install dir not set. Pass -DevEcoHome or set DEVECO_HOME.'
    exit 1
}
if (-not (Test-Path -LiteralPath $DevEcoHome)) {
    Write-Error "DevEco home not found at $DevEcoHome"
    exit 1
}

# Native commands (cargo) write progress to stderr, and PowerShell turns any
# stderr line into a NativeCommandError. With $ErrorActionPreference = 'Stop'
# that aborts the script *before* the copy step. Downgrade the preference for
# the duration of the native call and let $LASTEXITCODE decide.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)" }
}

$NativeRoot = Join-Path $DevEcoHome 'sdk\default\openharmony\native'
if (-not (Test-Path -LiteralPath $NativeRoot)) {
    Write-Error "OpenHarmony native toolchain not found at $NativeRoot. Check the DevEco Studio layout (sdk\default\openharmony\native)."
    exit 1
}

$LlvmBin = Join-Path $NativeRoot 'llvm\bin'
$Clang = Join-Path $LlvmBin 'clang.exe'
$Clangxx = Join-Path $LlvmBin 'clang++.exe'
$Ar = Join-Path $LlvmBin 'llvm-ar.exe'
$Sysroot = Join-Path $NativeRoot 'sysroot'
foreach ($p in @($Clang, $Clangxx, $Ar)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error "toolchain component not found: $p"
        exit 1
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Sysroot 'usr\lib\aarch64-linux-ohos'))) {
    Write-Error "arm64 sysroot not found under $Sysroot"
    exit 1
}

# .cmd wrappers carrying exactly the flags of the shipped sh wrappers.
$ToolDir = Join-Path $RepoRoot 'target\ohos-cc'
New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
$CcCmd = Join-Path $ToolDir 'aarch64-unknown-linux-ohos-clang.cmd'
$CxxCmd = Join-Path $ToolDir 'aarch64-unknown-linux-ohos-clang++.cmd'
$wrapper = @'
@echo off
"{0}" --target=aarch64-linux-ohos "--sysroot={1}" -D__MUSL__ %*
'@ -f $Clang.Replace('\', '/'), $Sysroot.Replace('\', '/')
Set-Content -LiteralPath $CcCmd -Value $wrapper -Encoding Ascii
Set-Content -LiteralPath $CxxCmd -Value ($wrapper -replace [regex]::Escape($Clang.Replace('\', '/')), $Clangxx.Replace('\', '/')) -Encoding Ascii

$env:CC_aarch64_unknown_linux_ohos = $CcCmd
$env:CXX_aarch64_unknown_linux_ohos = $CxxCmd
$env:AR_aarch64_unknown_linux_ohos = $Ar
$env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER = $CcCmd

# --- btls-sys (wreq / BoringSSL) cross-build environment ---
# btls-sys builds vendored BoringSSL with cmake and runs bindgen against the
# patched headers, so the OHOS build additionally needs:
#   - cmake + ninja on PATH (DevEco ships both under build-tools\cmake\bin)
#   - CMAKE_TOOLCHAIN_FILE pointing at ohos.toolchain.cmake; cmake-rs picks the
#     env var up and btls-sys's build script early-returns its own cross logic
#     when it is set (see btls-sys build/main.rs get_boringssl_cmake_config)
#   - LIBCLANG_PATH so bindgen finds DevEco's libclang.dll
#   - BORING_BSSL_RUST_CPPLIB=c++_static: btls-sys would otherwise default to
#     -lstdc++ on linux targets (OHOS has none). The static libc++ is only a
#     linker placeholder (BoringSSL references no C++ runtime symbols), so the
#     final .so gains no DT_NEEDED and the HAP does not need libc++_shared.so.
#   - BINDGEN_EXTRA_CLANG_ARGS with the sysroot and clang's own resource
#     include dir: DevEco's libclang does not search its resource dir and has
#     no MSVC integration, so freestanding headers (stddef.h etc.) must be
#     passed explicitly. bindgen inserts --target=aarch64-unknown-linux-ohos by
#     itself for cross builds. Paths are double-quoted because the variable is
#     shlex-parsed and unquoted backslashes get eaten.
$CmakeBin = Join-Path $NativeRoot 'build-tools\cmake\bin'
$OhosToolchain = Join-Path $NativeRoot 'build\cmake\ohos.toolchain.cmake'
$ClangResourceInclude = $null
$ClangResourceRoot = Join-Path $NativeRoot 'llvm\lib\clang'
if (Test-Path -LiteralPath $ClangResourceRoot) {
    $ClangResourceInclude = Get-ChildItem -LiteralPath $ClangResourceRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'include\stddef.h') } |
        Select-Object -First 1
}
if ($ClangResourceInclude) {
    $ClangResourceInclude = Join-Path $ClangResourceInclude.FullName 'include'
} else {
    Write-Error "clang resource include dir (with stddef.h) not found under $ClangResourceRoot"
    exit 1
}
foreach ($p in @(
        (Join-Path $CmakeBin 'cmake.exe'),
        (Join-Path $CmakeBin 'ninja.exe'),
        (Join-Path $LlvmBin 'libclang.dll'),
        $OhosToolchain,
        (Join-Path $ClangResourceInclude 'stddef.h')
    )) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error "btls-sys cross-build component not found: $p"
        exit 1
    }
}

$env:PATH = "$CmakeBin;$env:PATH"
$env:CMAKE_GENERATOR = 'Ninja'
$env:CMAKE_TOOLCHAIN_FILE = $OhosToolchain
$env:LIBCLANG_PATH = $LlvmBin
$env:BORING_BSSL_RUST_CPPLIB = 'c++_static'
$env:BINDGEN_EXTRA_CLANG_ARGS = "--sysroot=`"$Sysroot`" -isystem `"$ClangResourceInclude`""

Write-Host "==> CC: $CcCmd"
Write-Host "==> sysroot: $Sysroot"
Write-Host "==> cmake toolchain: $OhosToolchain"
Write-Host "==> clang resource include: $ClangResourceInclude"

$Target = 'aarch64-unknown-linux-ohos'
$LibsDir = Join-Path $RepoRoot 'entry\libs\arm64-v8a'
New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null

$ProfileArgs = @()
if ($Profile -eq 'release') { $ProfileArgs = @('--release') }

Write-Host "==> cargo build -p fqapi_napi --target $Target ($Profile)..."
Push-Location -LiteralPath $RepoRoot
try {
    Invoke-NativeCommand -Exe 'cargo' `
        -Arguments (@('build', '-p', 'fqapi_napi', '--manifest-path', $WorkspaceManifest, '--target', $Target) + $ProfileArgs) `
        -FailureMessage 'rust ohos cross build failed'
}
finally { Pop-Location }

$ProfileDir = if ($Profile -eq 'release') { 'release' } else { 'debug' }
$BuiltSo = Join-Path $RepoRoot "target\$Target\$ProfileDir\libfqapi_napi.so"
if (-not (Test-Path -LiteralPath $BuiltSo)) {
    Write-Error "rust build produced no $BuiltSo"
    exit 1
}

$DestSo = Join-Path $LibsDir 'libfqapi_napi.so'
Copy-Item -LiteralPath $BuiltSo -Destination $DestSo -Force
Write-Host "==> ohos libs: $DestSo"
Get-FileHash -Algorithm SHA256 -LiteralPath $DestSo | Format-List

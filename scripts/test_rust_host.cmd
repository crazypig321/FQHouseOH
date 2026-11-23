@echo off
REM Host-side cargo test helper for fqapi_core (btls-sys / BoringSSL host build).
REM
REM Why this wrapper exists (all discovered the hard way on this machine):
REM  * btls-sys builds vendored BoringSSL with cmake+ninja and needs MSVC (vcvars64).
REM  * Host has no NASM, so scripts/host-noasm-toolchain.cmake injects OPENSSL_NO_ASM=1
REM    via CMAKE_TOOLCHAIN_FILE (btls-sys early-returns when a toolchain file is set).
REM  * DevEco's libclang does not search its own resource dir and has no MSVC
REM    integration, so bindgen needs explicit clang args: msvc target + the
REM    clang resource include + MSVC/ucrt/um/shared includes.
REM  * Paths inside BINDGEN_EXTRA_CLANG_ARGS MUST be double-quoted: bindgen parses
REM    the value with shlex, which eats unquoted backslashes and splits on spaces.
REM
REM Usage: scripts\test_rust_host.cmd [extra cargo test args]

setlocal
call "E:\VisualStudio\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1

set "CMAKE_GENERATOR=Ninja"
set "LIBCLANG_PATH=E:\Huawei\DevEco Studio7\sdk\default\openharmony\native\llvm\bin"
set "CMAKE_TOOLCHAIN_FILE=%~dp0host-noasm-toolchain.cmake"
set "BINDGEN_EXTRA_CLANG_ARGS=--target=x86_64-pc-windows-msvc -isystem "E:\Huawei\DevEco Studio7\sdk\default\openharmony\native\llvm\lib\clang\15.0.4\include" -isystem "E:\VisualStudio\VC\Tools\MSVC\14.44.35207\include" -isystem "C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\ucrt" -isystem "C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\um" -isystem "C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\shared""

cargo test -p fqapi_core --manifest-path "%~dp0..\rust\Cargo.toml" %*
exit /b %errorlevel%

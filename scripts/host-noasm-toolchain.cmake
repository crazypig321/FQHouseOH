# Windows 宿主 cargo test 专用：本机无 NASM，而 btls-sys 在 host==target
# 时提前返回，不会给 BoringSSL 传 OPENSSL_NO_ASM（build/main.rs:231 早退
# 于 windows 分支的 OPENSSL_NO_ASM 定义），导致 enable_language(ASM_NASM)
# 失败。通过 CMAKE_TOOLCHAIN_FILE 注入（cmake-rs 自动携带该变量）：
# - OPENSSL_NO_ASM：跳过汇编，用 C 实现（宿主测试只验证逻辑，指纹在
#   OHOS 交叉构建仍用预生成汇编）。
# - CMAKE_MSVC_RUNTIME_LIBRARY：btls-sys 早退分支跳过 CRT 定义，这里
#   对齐 rustc 的 /MD。
set(OPENSSL_NO_ASM "1")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")

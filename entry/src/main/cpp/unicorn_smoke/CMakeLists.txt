cmake_minimum_required(VERSION 3.5.0)
project(unicorn_smoke)

add_library(unicorn_smoke SHARED
    unicorn_smoke.cpp
    smoke_core.c
)

# Unicorn prebuilt 已按计划迁至 rust/vendor/unicorn（P1），此处复用同一份。
set(UNICORN_VENDOR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../rust/vendor/unicorn)

target_include_directories(unicorn_smoke PRIVATE
    ${UNICORN_VENDOR}/include
)

target_link_libraries(unicorn_smoke PUBLIC
    ${UNICORN_VENDOR}/lib/libunicorn.a
    libace_napi.z.so
    libhilog_ndk.z.so
)

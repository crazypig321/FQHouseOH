#include <limits.h>
#include <pthread.h>
#include <string.h>

#include <hilog/log.h>

#include "napi/native_api.h"

extern "C" {
int smoke_state_get(void);
int smoke_state_try_begin(void);
const char *smoke_result_get(void);
void smoke_start(const char *path);
}

static char g_path[PATH_MAX];

static void *smoke_thread(void *arg)
{
    (void)arg;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "UnicornSmoke", "%{public}s", "thread enter");
    smoke_start(g_path);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "UnicornSmoke", "%{public}s", "thread done");
    return nullptr;
}

static napi_value StartSmoke(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, argv[0], g_path, sizeof(g_path), &len) != napi_ok) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "UnicornSmoke", "startSmoke path=%{public}s", g_path);
    if (!smoke_state_try_begin()) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    pthread_t tid;
    pthread_create(&tid, nullptr, smoke_thread, nullptr);
    pthread_detach(tid);
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value GetSmokeResult(napi_env env, napi_callback_info info)
{
    (void)info;
    const char *text = "";
    if (smoke_state_get() == 2) {
        text = smoke_result_get();
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, text, strlen(text), &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startSmoke", nullptr, StartSmoke, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSmokeResult", nullptr, GetSmokeResult, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "unicorn_smoke",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterUnicornSmokeModule(void)
{
    napi_module_register(&g_module);
}

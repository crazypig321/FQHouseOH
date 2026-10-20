/**
 * fqapi_napi 原生模块类型声明。
 * 实现见 crates/fqapi_napi/src/lib.rs（Node-API 手写绑定，nm_modname = "fqapi_napi"）。
 */

export interface FqBridgeResponse {
  status: number;
  contentType: string;
  body: ArrayBuffer;
}

export const version: () => string;
export const cancel: (requestId: string) => boolean;
export const setDevicePoolKey: (key: Uint8Array) => boolean;
export const init: (
  configPath: string,
  poolPath: string,
  filterPath: string,
  runtimeDir: string,
  port: number,
  mockUpstreamOrigin: string
) => Promise<string>;
export const request: (
  requestId: string,
  method: string,
  path: string,
  query: string,
  body: Uint8Array,
  timeoutMs: number
) => Promise<FqBridgeResponse>;
export const status: () => Promise<string>;
export const baseUrl: () => Promise<string>;
export const sessionCapability: () => Promise<string>;
export const shutdown: () => Promise<void>;

// 红果新签名 golden 向量生成器（x-gorgon 8404 / x-helios / x-medusa / branchOf）。
//
// 参照源：hongguoTV `server/vendor/hongguo.cjs`（drpys「红果果[短]」，GPL-3.0，
// 本项目同为 GPL-3.0）。在 Node vm 中加载该 cjs，固定 `Date.now` / `Math.random`
// 后调用其签名内部函数，把确定性的期望值写入 `hongguo_vsign_golden.json`，
// 供 `rust/tests/hongguo_vsign_vectors.rs` 逐字节对拍 Rust 移植版
// （`rust/src/endpoints/hongguo/vsign.rs`）。
//
// 用法：node rust/testdata/gen_hongguo_vsign_golden.mjs [hongguo.cjs 路径]
// 默认 cjs 路径：E:\next\crazypig\Gitea\hongguoTV\server\vendor\hongguo.cjs

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cjsPath =
  process.argv[2] || "E:/next/crazypig/Gitea/hongguoTV/server/vendor/hongguo.cjs";
const source = fs.readFileSync(cjsPath, "utf8");

// 固定时间与随机源：所有签名函数内部经 Date.now()/Math.random() 取值，
// 钉死后整条链路完全确定。
const FIXED_MS = 1763382000000; // 2026-11-17 19:00:00 UTC
const FIXED_RAND = 0.42;
const khronos = Math.floor(FIXED_MS / 1000);

// 与 cjs 内 `Math.floor(Math.random() * N)` 完全同式的派生值（供 Rust 侧显式传参对拍）。
const randU32 = Math.floor(FIXED_RAND * 0x100000000);
const randU16 = Math.floor(FIXED_RAND * 65536);
const envLaunch = Math.floor(FIXED_RAND * 21) + 100;
const envPid = Math.floor(FIXED_RAND * 2000) + 10001;

// axios 捕获桩：signedAppGet 走 axios 发请求，这里截下 (url, headers) 即返回成功。
const axiosCalls = [];
const axiosStub = async (url, config) => {
  axiosCalls.push({ url: String(url), headers: { ...(config?.headers || {}) } });
  return { status: 200, data: JSON.stringify({ code: 0 }) };
};

const context = vm.createContext({
  require: (name) => {
    if (name === "node:crypto") return crypto;
    throw new Error(`Unsupported module: ${name}`);
  },
  Buffer,
  URL,
  URLSearchParams,
  axios: axiosStub,
  console,
});
vm.runInContext(
  `Date.now = () => ${FIXED_MS}; Math.random = () => ${FIXED_RAND};`,
  context
);
// 与 server/provider.mjs 相同的加载方式，另导出签名内部函数。
vm.runInContext(
  source +
    "\nthis.__api = { sm3, md5, pythonUrlEncode, proto, deviceProto, getIv, sumMd5, md5SumV3, BRANCH2_ORDERS, hashF13, branchOf, rc4Gorgon, xGorgon, helios, AesV3, xmxor, keyHash, buildMedusa, signedVideoRequest, signedAppGet, appSearchParams, DEVICE, APP_DEVICE, VIDEO_API, APP_SEARCH_API, VIDEO_UA, APP_UA };",
  context,
  { timeout: 10000 }
);
const api = context.__api;

const hex = (buf) => Buffer.from(buf).toString("hex");

// ---------- 单元级向量 ----------
// 注意：AesV3.encrypt / xmxor 在真实链路里输入 >=248 字节（buildMedusa 的 message），
// 单元向量须覆盖该量级；短输入会被 JS 侧静默截断，Rust 对拍无意义。
const big = Buffer.alloc(256);
for (let i = 0; i < big.length; i += 1) big[i] = (i * 41 + 7) & 255;
const unitInput = {
  text: "hello 红果短剧",
  data: Buffer.from("0123456789abcdef0123456789abcdef0123456789abcdef", "hex"),
  body: Buffer.from('{"biz_param":{"device_level":3},"mixed_video_id_map":{"1004":["7123456789012345678"]}}', "utf8"),
  signKey: Buffer.from("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5", "hex"),
  aesKey: Buffer.from("f1593376766ea98d34f31b057a9d5be4", "hex"),
  aesIv: Buffer.from("1fe109a4125283f418de9e051a969e12", "hex"),
};
const querySm3 = api.sm3(Buffer.from("aid=8662&device_id=1905892595378490&ts=" + khronos, "utf8"));
const bodyMd5Full = crypto.createHash("md5").update(unitInput.body).digest();
const tsBytes = Buffer.alloc(4);
tsBytes.writeUInt32LE(khronos >>> 0);

// pythonUrlEncode 的输出依赖键的迭代顺序：golden 里记录有序键值对数组，
// Rust 测试按数组顺序重建，避免 serde_json Map 排序差异。
const urlEncodePairs = [
  ["aid", "8662"],
  ["ts", String(khronos)],
  ["device_id", api.DEVICE.device_id],
  ["query", "测试 keyword!"],
];
const urlEncodeInput = Object.fromEntries(urlEncodePairs);

const unit = {
  sm3: { input_text: unitInput.text, out_hex: hex(api.sm3(Buffer.from(unitInput.text, "utf8"))) },
  md5_upper: { input_text: unitInput.text, out: api.md5(Buffer.from(unitInput.text, "utf8")) },
  python_url_encode: {
    input_pairs: urlEncodePairs,
    output: api.pythonUrlEncode(urlEncodeInput),
  },
  proto_nested_hex: hex(
    api.proto([[1, 111, "sint"], [2, 10, "sint"], [3, 694367, "sint"], [5, 586952199, "sint"]])
  ),
  device_proto_hex: hex(api.deviceProto(api.DEVICE.device_id, api.DEVICE.version_name)),
  get_iv: {
    iv: 0x20230928,
    data_hex: hex(unitInput.data.subarray(0, 16)),
    out: api.getIv(0x20230928, unitInput.data.subarray(0, 16)),
  },
  sum_md5: {
    data_hex: hex(unitInput.data.subarray(0, 12)),
    out: api.sumMd5(unitInput.data.subarray(0, 12)),
  },
  md5_sum_v3: {
    message_hex: hex(big.subarray(0, 64)),
    count_v2: 12345,
    orders_hex: hex(api.BRANCH2_ORDERS.subarray(0, 64)),
    count_v1: 201,
    out_hex: hex(api.md5SumV3(big.subarray(0, 64), 12345, api.BRANCH2_ORDERS.subarray(0, 64), 201)),
  },
  hash_f13: {
    query_sm3_hex: hex(querySm3),
    body_md5_hex: hex(bodyMd5Full),
    ts_hex: hex(tsBytes),
    khronos,
    out_hex: hex(api.hashF13(querySm3, bodyMd5Full, tsBytes, khronos)),
  },
  rc4_gorgon: {
    data_hex: hex(unitInput.data.subarray(0, 20)),
    key_hex: hex(Buffer.from([0x4a, 0x40, 0x16, 0x0a, 0x47, 0x6c, 0x01, 0xb9])),
    out_hex: hex(api.rc4Gorgon(Array.from(unitInput.data.subarray(0, 20)), Buffer.from([0x4a, 0x40, 0x16, 0x0a, 0x47, 0x6c, 0x01, 0xb9]))),
  },
  x_gorgon: {
    query: "aid=8662&device_id=1905892595378490&ts=" + khronos,
    body_hex: hex(unitInput.body),
    ts: khronos,
    random: randU16,
    out: api.xGorgon("aid=8662&device_id=1905892595378490&ts=" + khronos, unitInput.body, khronos, randU16),
  },
  helios: {
    khronos,
    random: randU32,
    out: api.helios(khronos),
  },
  aes_v3: {
    key_hex: hex(unitInput.aesKey),
    khronos,
    data_hex: hex(big),
    iv_hex: hex(unitInput.aesIv),
    out_hex: hex(new api.AesV3(unitInput.aesKey, khronos).encrypt(big, unitInput.aesIv)),
  },
  xmxor: {
    data_hex: hex(big),
    key_hex: hex(querySm3),
    out_hex: hex(api.xmxor(big, querySm3)),
  },
  key_hash: {
    sign_key_hex: hex(unitInput.signKey),
    random: randU32,
    hash_hex: "",
    seed_hex: "",
  },
  build_medusa: null, // 下方填充
  branch_of: null,
};

{
  const [hash, seed] = api.keyHash(unitInput.signKey, randU32);
  unit.key_hash.hash_hex = hex(hash);
  unit.key_hash.seed_hex = hex(seed);
}

// buildMedusa：内部取 5 次 Math.random（均 = FIXED_RAND 派生值），Rust 侧显式传参。
const medusaUrl =
  "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?aid=8662&device_id=1905892595378490&ts=" +
  khronos +
  "&_rticket=" +
  FIXED_MS;
unit.build_medusa = {
  url: medusaUrl,
  body_hex: hex(unitInput.body),
  khronos,
  rand: {
    message_rand: randU32,
    env_launch: envLaunch,
    env_pid: envPid,
    key_random: randU32,
    xm_rand: randU32,
  },
  out: api.buildMedusa(medusaUrl, unitInput.body, khronos),
};
unit.branch_of = {
  url: medusaUrl,
  body_hex: hex(unitInput.body),
  khronos,
  out: api.branchOf(medusaUrl, unitInput.body, khronos),
};

// ---------- 请求级向量 ----------
const videoPayload = JSON.stringify({
  biz_param: {
    detail_page_version: 0,
    device_level: 3,
    disable_digg_stat: false,
    need_all_video_definition: true,
    need_mp4_align: false,
    use_os_player: false,
    use_server_dns: false,
    video_platform: 1024,
  },
  mixed_video_id_map: { "1004": ["7123456789012345678"] },
});
const videoReq = api.signedVideoRequest(videoPayload);

// appSearchParams(keyword, tabType, limit, cursor, page)：map 搜索沿用 tab_type 29。
const appValues = api.appSearchParams("替身新娘", 29, 20, {}, 1);
await api.signedAppGet(appValues);
const appCall = axiosCalls[axiosCalls.length - 1];

const golden = {
  meta: {
    now_ms: FIXED_MS,
    random_seed: FIXED_RAND,
    khronos,
    derived_random: { u32: randU32, u16: randU16, env_launch: envLaunch, env_pid: envPid },
    source: "hongguoTV server/vendor/hongguo.cjs (drpys 红果果[短], GPL-3.0)",
    generator: "rust/testdata/gen_hongguo_vsign_golden.mjs",
  },
  device: { DEVICE: api.DEVICE, APP_DEVICE: api.APP_DEVICE },
  apis: { VIDEO_API: api.VIDEO_API, APP_SEARCH_API: api.APP_SEARCH_API, VIDEO_UA: api.VIDEO_UA, APP_UA: api.APP_UA },
  unit,
  video_request: {
    payload: videoPayload,
    url: videoReq.url,
    headers: videoReq.headers,
    body: videoReq.body.toString("utf8"),
  },
  app_get: {
    values: appValues,
    url: appCall.url,
    headers: appCall.headers,
  },
};

const outPath = path.join(here, "hongguo_vsign_golden.json");
fs.writeFileSync(outPath, JSON.stringify(golden, null, 2) + "\n", "utf8");
console.log(`golden written: ${outPath}`);
console.log(`branch_of(video) = ${unit.branch_of.out}`);
console.log(`x-gorgon(video)  = ${videoReq.headers["x-gorgon"].slice(0, 24)}...`);
console.log(`x-helios         = ${videoReq.headers["x-helios"].slice(0, 24)}...`);
console.log(`x-medusa         = ${videoReq.headers["x-medusa"].slice(0, 24)}...`);

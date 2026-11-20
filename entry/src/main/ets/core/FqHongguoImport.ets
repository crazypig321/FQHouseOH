/**
 * 红果云端收藏导入（只读）：
 * - 登录：扫码（POST /api/v1/account/hongguo/login/{qr|poll}，本地 Rust 端走红果官网
 *   Web passport 协议）/ 手机验证码（FqHongguoSmsWebLogin，平台 HTTP 栈
 *   @ohos.net.http 直接请求官网 send_code/sms_login——系统 TLS 指纹规避
 *   rustls 指纹触发的 1105 滑块风控；cookie 只留内存）；
 * - 采集：POST /api/v1/account/hongguo/favorites 读取云端收藏短剧/漫剧
 *   （本地 Rust 端用生产验证的签名套件请求并解析，返回归一化列表）；
 * - 合并：书架只补缺失（已有条目回填空封面），重复导入不产生重复条目；
 * - 文件：收藏列表可导出 JSON（encodeFavoritesFile）/ 从历史文件导入
 *   （parseFavoritesFileText），导出不含登录凭证，可跨设备传输；
 * - 持久化：登录 cookie + 最近一次收藏预览存 filesDir（FqHongguoSessionStore），
 *   重进页面不丢登录态；cookie 是凭据，只存应用私有目录，不进备份链路；
 * - kind 启发式：标签含「漫剧/漫画」归为漫剧（manju），其余为短剧（video）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import fq from 'libfqapi_napi.so';
import { FqBackend } from './FqBackend';
import { FqShelfItem, FqShelfStore } from './FqShelfStore';
import { fqAsArray, fqAsInt, fqAsRecord } from './FqJson';

const FQ_HONGGUO_FAVORITES_PATH: string = '/api/v1/account/hongguo/favorites';
const FQ_HONGGUO_LOGIN_QR_PATH: string = '/api/v1/account/hongguo/login/qr';
const FQ_HONGGUO_LOGIN_POLL_PATH: string = '/api/v1/account/hongguo/login/poll';
/** 归一化收藏条数上限（响应解析与持久化复用）。 */
const FQ_HONGGUO_FAVORITES_MAX: number = 1000;

// ===== 红果官网 Web 登录参数（hongguoTV WebLogin 同款，验证码登录直连用） =====
/** 官网登录基址。 */
const FQ_HONGGUO_WEB_BASE: string = 'https://hongguoduanju.com';
/** 官网登录 UA（Mac Chrome 141，hongguoTV 同款）。 */
const FQ_HONGGUO_WEB_UA: string = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
/** 官网登录公共 query（aid/…/language）。 */
const FQ_HONGGUO_WEB_QUERY: string = 'aid=513755&passport_jssdk_version=3.4.10' +
  '&passport_jssdk_type=normal&account_sdk_source=web&is_from_ttaccountsdk=1&language=zh';
/** csrf 引导取码的 next 参数（okhttp percent-encode 同款）。 */
const FQ_HONGGUO_WEB_NEXT_ENCODED: string = 'https%3A%2F%2Fhongguoduanju.com%2F';

/** 文本字段收窄（超长/非串返回空；二维码/cookie 等大字段由调用方放宽 maxLen）。 */
function fqHongguoText(value: Object | undefined, maxLen: number): string {
  if (typeof value !== 'string' || value.length > maxLen) {
    return '';
  }
  return value;
}

/** hongguoTV WebLogin.mix：UTF-8 字节逐个 XOR 5 → 小写 hex（不补零）。 */
function fqHongguoMix(value: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(value);
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] ^ 5).toString(16);
  }
  return out;
}

/** 拆分逗号合并的 Set-Cookie 串：仅当逗号后紧跟「名称=」形态时切分，
 * 避开 Expires 属性里的逗号（如 `Expires=Wed, 21 Oct 2026…`）。 */
function fqHongguoSplitSetCookie(joined: string): string[] {
  const out: string[] = [];
  let start: number = 0;
  for (let i: number = 0; i < joined.length; i++) {
    if (joined.charAt(i) !== ',') {
      continue;
    }
    let j: number = i + 1;
    while (j < joined.length && joined.charAt(j) === ' ') {
      j++;
    }
    if (j >= joined.length || !/[A-Za-z_]/.test(joined.charAt(j))) {
      continue;
    }
    let k: number = j;
    while (k < joined.length && /[A-Za-z0-9_-]/.test(joined.charAt(k))) {
      k++;
    }
    if (k > j && joined.charAt(k) === '=') {
      out.push(joined.substring(start, i));
      start = j;
      i = k;
    }
  }
  out.push(joined.substring(start));
  return out;
}

/** 红果官网登录 cookie 罐（内存持有；cookie 是凭据，不落盘不进日志）。 */
class FqHongguoCookieJar {
  private names: string[] = [];
  private values: string[] = [];

  /** 是否已持有指定 cookie。 */
  public has(name: string): boolean {
    return this.names.indexOf(name) >= 0;
  }

  /** 取指定 cookie 值（无则空串）。 */
  public valueOf(name: string): string {
    const index: number = this.names.indexOf(name);
    return index >= 0 ? this.values[index] : '';
  }

  /** 全部 cookie 拼 `name=value; …` 请求头。 */
  public header(): string {
    let out: string = '';
    for (let i: number = 0; i < this.names.length; i++) {
      out += `${i > 0 ? '; ' : ''}${this.names[i]}=${this.values[i]}`;
    }
    return out;
  }

  /** 并入响应 Set-Cookie（同名覆盖；兼容数组与逗号合并串两种返回形态）。 */
  public merge(header: Object): void {
    const record: Record<string, Object> | null = fqAsRecord(header);
    if (record === null) {
      return;
    }
    const raw: Object | undefined = record['set-cookie'];
    if (raw === undefined) {
      return;
    }
    let lines: string[] = [];
    if (typeof raw === 'string') {
      lines = fqHongguoSplitSetCookie(raw);
    } else {
      const items: Object[] | null = fqAsArray(raw);
      if (items !== null) {
        for (const item of items) {
          if (typeof item === 'string') {
            lines.push(item);
          }
        }
      }
    }
    for (const line of lines) {
      const pair: string = line.split(';')[0];
      const eq: number = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = pair.substring(0, eq).trim();
      const value: string = pair.substring(eq + 1).trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      const index: number = this.names.indexOf(name);
      if (index >= 0) {
        this.values[index] = value;
      } else {
        this.names.push(name);
        this.values.push(value);
      }
    }
  }
}

/** 云端收藏条目（后端归一化）。 */
export class FqHongguoFavorite {
  readonly id: string;
  title: string = '';
  cover: string = '';
  intro: string = '';
  episodes: number = 0;
  tags: string = '';
  collectedAt: number = 0;

  constructor(id: string) {
    this.id = id;
  }
}

/** 合并结果统计。 */
export class FqHongguoMergeResult {
  readonly added: number;
  readonly coverFilled: number;

  constructor(added: number, coverFilled: number) {
    this.added = added;
    this.coverFilled = coverFilled;
  }
}

/** 扫码登录二维码（image 为 data URL）。 */
export class FqHongguoQr {
  readonly image: string;
  readonly expiresIn: number;

  constructor(image: string, expiresIn: number) {
    this.image = image;
    this.expiresIn = expiresIn;
  }
}

/** 短信验证码发送结果。 */
export class FqHongguoSmsSent {
  readonly maskedMobile: string;
  readonly retrySeconds: number;

  constructor(maskedMobile: string, retrySeconds: number) {
    this.maskedMobile = maskedMobile;
    this.retrySeconds = retrySeconds;
  }
}

/**
 * 红果官网手机验证码登录（平台 HTTP 栈）：
 * hongguoTV WebLogin 协议移植，走 @ohos.net.http（系统 TLS 指纹，
 * 规避 rustls 指纹触发的 1105 滑块风控）；cookie 罐只在内存，
 * 验证码会话随本实例存续（发送与校验须同一实例）；取消销毁在途请求。
 */
export class FqHongguoSmsWebLogin {
  private readonly jar: FqHongguoCookieJar = new FqHongguoCookieJar();
  private request: http.HttpRequest | null = null;
  private cancelled: boolean = false;
  /** 平台手机号（如 '+86 13800138000'，mix 前形态）。 */
  private mobile: string = '';
  private sent: boolean = false;

  /** 取消在途请求（销毁 http 请求，进行中的 await 以「请求已取消」拒绝）。 */
  public cancel(): void {
    this.cancelled = true;
    const request: http.HttpRequest | null = this.request;
    if (request !== null) {
      try {
        request.destroy();
      } catch (error) {
        // 请求可能已完成
      }
    }
  }

  /**
   * 发送短信验证码（hongguoTV WebLogin.send）：
   * 无 csrf cookie 时先取二维码补 cookie；大陆号码拼 '+86 ' 前缀，
   * 境外号码去一个开头 0（PhoneLogin.format 同款）。
   */
  public async send(mobile: string): Promise<FqHongguoSmsSent> {
    if (!this.jar.has('passport_csrf_token')) {
      await this.call('/passport/web/get_qrcode/', `&next=${FQ_HONGGUO_WEB_NEXT_ENCODED}`, null);
    }
    this.mobile = mobile.startsWith('+') ? this.normalizeForeign(mobile) : `+86 ${mobile}`;
    const form: string = `mobile=${fqHongguoMix(this.mobile)}` +
      `&type=${fqHongguoMix('24')}&mix_mode=1&fixed_mix_mode=1`;
    const data: Record<string, Object> = await this.call('/passport/web/send_code/', '', form);
    this.sent = true;
    const masked: string = fqHongguoText(data['mobile'], 64);
    const retrySeconds: number = Math.min(Math.max(fqAsInt(data['retry_time'], 60), 1), 600);
    return new FqHongguoSmsSent(masked.length > 0 ? masked : '你的手机', retrySeconds);
  }

  /** 校验短信验证码（hongguoTV WebLogin.verify + credentials）：
   * 成功后取账号信息，返回全部会话 cookie 串。 */
  public async verify(code: string): Promise<string> {
    if (!this.sent) {
      throw new Error('请先发送验证码');
    }
    const form: string = `mobile=${fqHongguoMix(this.mobile)}&code=${fqHongguoMix(code)}` +
      '&login_only=true&mix_mode=1&fixed_mix_mode=1';
    await this.call('/passport/web/sms_login/', '', form);
    await this.call('/passport/account/info/v2/', '', null);
    return this.jar.header();
  }

  /** 境外号码归一化：`+区号 号码` 去一个开头 0。 */
  private normalizeForeign(mobile: string): string {
    const spaceIndex: number = mobile.indexOf(' ');
    if (spaceIndex <= 0) {
      return mobile;
    }
    const cc: string = mobile.substring(0, spaceIndex);
    let digits: string = mobile.substring(spaceIndex + 1);
    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return `${cc} ${digits}`;
  }

  /**
   * 官网登录公共通道（hongguoTV WebLogin.call）：
   * 公共 query + csrf 头 + cookie 罐 + 表单 POST / GET，
   * Set-Cookie 并回罐，message 非 success 抛业务错误。
   */
  private async call(path: string, extraQuery: string,
    form: string | null): Promise<Record<string, Object>> {
    const url: string = `${FQ_HONGGUO_WEB_BASE}${path}?${FQ_HONGGUO_WEB_QUERY}${extraQuery}`;
    const header: Record<string, string> = {
      'User-Agent': FQ_HONGGUO_WEB_UA,
      'Referer': `${FQ_HONGGUO_WEB_BASE}/`,
      'Origin': FQ_HONGGUO_WEB_BASE,
      'Accept': 'application/json, text/javascript',
    };
    const csrf: string = this.jar.valueOf('passport_csrf_token');
    if (csrf.length > 0) {
      header['x-tt-passport-csrf-token'] = csrf;
    }
    const cookie: string = this.jar.header();
    if (cookie.length > 0) {
      header['Cookie'] = cookie;
    }
    if (form !== null) {
      header['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    const options: http.HttpRequestOptions = {
      method: form === null ? http.RequestMethod.GET : http.RequestMethod.POST,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 20000,
      usingCache: false,
    };
    if (form !== null) {
      options.extraData = form;
    }
    const request: http.HttpRequest = http.createHttp();
    this.request = request;
    this.cancelled = false;
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, options);
      } catch (error) {
        if (this.cancelled) {
          throw new Error('请求已取消');
        }
        throw new Error('红果登录服务暂不可用，请检查网络后重试');
      }
      this.jar.merge(response.header);
      const status: number = response.responseCode;
      if (status < 200 || status >= 300) {
        throw new Error(`红果登录请求失败（HTTP ${status}）`);
      }
      const text: string = typeof response.result === 'string' ? response.result : '';
      if (text.length === 0) {
        throw new Error('红果登录接口返回空响应，请稍后重试');
      }
      let root: Record<string, Object> | null = null;
      try {
        root = fqAsRecord(JSON.parse(text));
      } catch (error) {
        root = null;
      }
      if (root === null) {
        throw new Error('红果登录响应不是有效的 JSON 数据');
      }
      return FqHongguoSmsWebLogin.checked(root);
    } finally {
      if (this.request === request) {
        this.request = null;
      }
      request.destroy();
    }
  }

  /** hongguoTV WebLogin.checked：message 非 success 抛业务错误（滑块风控给扫码指引）。 */
  private static checked(root: Record<string, Object>): Record<string, Object> {
    const data: Record<string, Object> | null = fqAsRecord(root['data']);
    if (data === null) {
      throw new Error('官网登录返回格式异常');
    }
    const message: string = fqHongguoText(root['message'], 64);
    if (message === 'success') {
      return data;
    }
    const code: number = fqAsInt(data['error_code'], -1);
    if (data['verify_center_decision_conf'] !== undefined) {
      throw new Error('红果要求滑块验证（可能因近期尝试过多），请稍后再试或更换网络，' +
        `也可改用扫码登录（错误码 ${code}）`);
    }
    const description: string = fqHongguoText(data['description'], 256);
    throw new Error(description.length > 0
      ? `${description}（错误码 ${code}）`
      : `官网登录失败（错误码 ${code}）`);
  }
}

/** 导入服务：官网登录（扫码/验证码）→ 拉取云端收藏 → 合并到本机书架。 */
export class FqHongguoImportService {
  private static currentRequestId: string = '';
  private readonly smsWebLogin: FqHongguoSmsWebLogin = new FqHongguoSmsWebLogin();

  /** 取消在途请求（fq.cancel → 499；验证码登录销毁平台 http 请求）。 */
  public cancel(): void {
    this.smsWebLogin.cancel();
    if (FqHongguoImportService.currentRequestId.length > 0) {
      fq.cancel(FqHongguoImportService.currentRequestId);
    }
  }

  /** 登录端点公共通道（共用 requestId 便于取消）。 */
  private async postLogin(requestId: string, path: string,
    body: Record<string, Object>): Promise<Record<string, Object>> {
    FqHongguoImportService.currentRequestId = requestId;
    try {
      return await FqBackend.get().postJson(requestId, path, JSON.stringify(body));
    } finally {
      FqHongguoImportService.currentRequestId = '';
    }
  }

  /** 获取登录二维码（data URL + 剩余秒数）。 */
  public async requestQr(): Promise<FqHongguoQr> {
    const result: Record<string, Object> =
      await this.postLogin('hongguo-login-qr', FQ_HONGGUO_LOGIN_QR_PATH, {});
    const image: string = fqHongguoText(result['image'], 200 * 1024);
    if (!image.startsWith('data:image/')) {
      throw new Error('红果登录响应无效');
    }
    return new FqHongguoQr(image, fqAsInt(result['expiresIn'], 180));
  }

  /** 轮询扫码状态：未确认返回空串，确认后返回登录 cookie。 */
  public async pollQr(): Promise<string> {
    const result: Record<string, Object> =
      await this.postLogin('hongguo-login-poll', FQ_HONGGUO_LOGIN_POLL_PATH, {});
    const status: string = fqHongguoText(result['status'], 64);
    if (status === 'waiting') {
      return '';
    }
    if (status === 'confirmed') {
      const cookie: string = fqHongguoText(result['cookie'], 16 * 1024);
      if (cookie.length === 0) {
        throw new Error('红果登录响应无效');
      }
      return cookie;
    }
    throw new Error('红果登录响应无效');
  }

  /** 发送短信验证码（平台 HTTP 栈直连官网，规避 rustls 指纹风控）。 */
  public async sendSms(mobile: string): Promise<FqHongguoSmsSent> {
    return await this.smsWebLogin.send(mobile);
  }

  /** 校验短信验证码，成功返回登录 cookie。 */
  public async verifySms(code: string): Promise<string> {
    return await this.smsWebLogin.verify(code);
  }

  /** 拉取云端收藏（归一化列表；畸形条目跳过，响应格式无效报错）。 */
  public async fetch(cookie: string): Promise<FqHongguoFavorite[]> {
    const requestId: string = 'hongguo-favorites';
    FqHongguoImportService.currentRequestId = requestId;
    try {
      const body: Record<string, Object> = {};
      body['cookie'] = cookie;
      const result: Record<string, Object> =
        await FqBackend.get().postJson(requestId, FQ_HONGGUO_FAVORITES_PATH, JSON.stringify(body));
      const rawFavorites: Object[] | null = fqAsArray(result['favorites']);
      if (rawFavorites === null) {
        throw new Error('红果收藏响应格式无效');
      }
      return FqHongguoImportService.decodeFavorites(rawFavorites);
    } finally {
      FqHongguoImportService.currentRequestId = '';
    }
  }

  /** 归一化收藏列表（后端响应与本地持久化复用；畸形条目跳过，按 id 去重）。 */
  public static decodeFavorites(rawFavorites: Object[]): FqHongguoFavorite[] {
    const favorites: FqHongguoFavorite[] = [];
    const seen: Set<string> = new Set<string>();
    for (const raw of rawFavorites) {
      if (favorites.length >= FQ_HONGGUO_FAVORITES_MAX) {
        break;
      }
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null) {
        continue;
      }
      const id: string = fqHongguoText(rec['id'], 64);
      if (!/^[0-9]{1,30}$/.test(id) || seen.has(id)) {
        continue;
      }
      const favorite: FqHongguoFavorite = new FqHongguoFavorite(id);
      favorite.title = fqHongguoText(rec['title'], 512);
      if (favorite.title.length === 0) {
        continue;
      }
      favorite.cover = fqHongguoText(rec['cover'], 8192);
      favorite.intro = fqHongguoText(rec['intro'], 8192);
      favorite.episodes = fqAsInt(rec['episodes'], 0);
      favorite.tags = fqHongguoText(rec['tags'], 512);
      favorite.collectedAt = fqAsInt(rec['collectedAt'], 0);
      seen.add(id);
      favorites.push(favorite);
    }
    return favorites;
  }

  /** 收藏导出文件编码（type/version 元信息 + 收藏列表，不含登录凭证，可跨设备导入）。 */
  public static encodeFavoritesFile(favorites: FqHongguoFavorite[]): string {
    const encoded: Object[] = [];
    for (const favorite of favorites) {
      const record: Record<string, Object> = {};
      record['id'] = favorite.id;
      record['title'] = favorite.title;
      record['cover'] = favorite.cover;
      record['intro'] = favorite.intro;
      record['episodes'] = favorite.episodes;
      record['tags'] = favorite.tags;
      record['collectedAt'] = favorite.collectedAt;
      encoded.push(record);
    }
    const root: Record<string, Object> = {};
    root['type'] = 'hongguo-favorites';
    root['version'] = 1;
    root['exportedAt'] = new Date().toISOString();
    root['favorites'] = encoded;
    return JSON.stringify(root);
  }

  /** 解析收藏导出文件文本（「从历史文件导入」；类型不符/无有效条目报错）。 */
  public static parseFavoritesFileText(text: string): FqHongguoFavorite[] {
    let root: Record<string, Object> | null = null;
    try {
      root = fqAsRecord(JSON.parse(text));
    } catch (error) {
      root = null;
    }
    if (root === null || fqHongguoText(root['type'], 64) !== 'hongguo-favorites') {
      throw new Error('不是红果收藏导出文件');
    }
    const rawFavorites: Object[] | null = fqAsArray(root['favorites']);
    if (rawFavorites === null) {
      throw new Error('不是红果收藏导出文件');
    }
    const favorites: FqHongguoFavorite[] = FqHongguoImportService.decodeFavorites(rawFavorites);
    if (favorites.length === 0) {
      throw new Error('文件中没有可导入的收藏');
    }
    return favorites;
  }

  /** 合并到本机书架：只补缺失（已有条目回填空封面），kind 按标签启发式。 */
  public merge(favorites: FqHongguoFavorite[]): FqHongguoMergeResult {
    let added: number = 0;
    let coverFilled: number = 0;
    for (const favorite of favorites) {
      const kind: string = /漫剧|漫画/.test(favorite.tags) ? 'manju' : 'video';
      const item: FqShelfItem =
        new FqShelfItem(favorite.id, kind, favorite.title, favorite.cover);
      if (FqShelfStore.addIfAbsent(item)) {
        added++;
      } else if (favorite.cover.length > 0
        && FqShelfStore.updateCover(favorite.id, favorite.cover)) {
        coverFilled++;
      }
    }
    return new FqHongguoMergeResult(added, coverFilled);
  }
}

/** 持久化恢复的登录态（cookie + 最近一次收藏预览）。 */
export class FqHongguoSavedSession {
  readonly cookie: string;
  readonly favorites: FqHongguoFavorite[];

  constructor(cookie: string, favorites: FqHongguoFavorite[]) {
    this.cookie = cookie;
    this.favorites = favorites;
  }
}

/** 红果登录态持久化（filesDir 单文件：登录 cookie + 最近一次收藏预览）。
 * cookie 是凭据：只存应用私有目录，不进日志、不进备份链路。 */
export class FqHongguoSessionStore {
  private static readonly FILE_NAME: string = 'hongguo_import_session.json';
  private static readonly MAX_FILE_BYTES: number = 4 * 1024 * 1024;

  public static save(context: common.Context, cookie: string,
    favorites: FqHongguoFavorite[]): void {
    let text: string = FqHongguoSessionStore.encode(cookie, favorites);
    if (text.length > FqHongguoSessionStore.MAX_FILE_BYTES) {
      // 收藏预览过大时只留 cookie，登录态不因预览超限而丢。
      text = FqHongguoSessionStore.encode(cookie, []);
    }
    const path: string = `${context.filesDir}/${FqHongguoSessionStore.FILE_NAME}`;
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        // 关闭失败忽略
      }
    }
  }

  public static load(context: common.Context): FqHongguoSavedSession | null {
    const path: string = `${context.filesDir}/${FqHongguoSessionStore.FILE_NAME}`;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        if (stat.size <= 0 || stat.size > FqHongguoSessionStore.MAX_FILE_BYTES) {
          return null;
        }
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
        const text: string = decoder.decodeWithStream(new Uint8Array(buffer), { stream: false });
        const root: Record<string, Object> | null = fqAsRecord(JSON.parse(text));
        if (root === null) {
          return null;
        }
        const cookie: string = fqHongguoText(root['cookie'], 16 * 1024);
        if (cookie.length === 0) {
          return null;
        }
        const rawFavorites: Object[] | null = fqAsArray(root['favorites']);
        return new FqHongguoSavedSession(cookie,
          rawFavorites === null ? [] : FqHongguoImportService.decodeFavorites(rawFavorites));
      } finally {
        try {
          fileIo.closeSync(file);
        } catch (error) {
          // 关闭失败忽略
        }
      }
    } catch (error) {
      return null;
    }
  }

  /** 退出登录时清除本机留存的登录态与收藏预览。 */
  public static clear(context: common.Context): void {
    try {
      const path: string = `${context.filesDir}/${FqHongguoSessionStore.FILE_NAME}`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      // 清理失败忽略（文件残留不影响下次覆盖写）
    }
  }

  private static encode(cookie: string, favorites: FqHongguoFavorite[]): string {
    const encoded: Object[] = [];
    for (const favorite of favorites) {
      const record: Record<string, Object> = {};
      record['id'] = favorite.id;
      record['title'] = favorite.title;
      record['cover'] = favorite.cover;
      record['intro'] = favorite.intro;
      record['episodes'] = favorite.episodes;
      record['tags'] = favorite.tags;
      record['collectedAt'] = favorite.collectedAt;
      encoded.push(record);
    }
    const root: Record<string, Object> = {};
    root['cookie'] = cookie;
    root['favorites'] = encoded;
    return JSON.stringify(root);
  }
}

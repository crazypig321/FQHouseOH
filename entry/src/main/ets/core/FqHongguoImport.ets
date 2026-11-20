/**
 * 红果云端收藏导入（只读）：
 * - 登录：扫码 / 手机验证码（POST /api/v1/account/hongguo/login/{qr|poll|send|verify}，
 *   本地 Rust 端走红果官网 Web passport 协议，cookie 只留内存）；
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
import { util } from '@kit.ArkTS';
import fq from 'libfqapi_napi.so';
import { FqBackend } from './FqBackend';
import { FqShelfItem, FqShelfStore } from './FqShelfStore';
import { fqAsArray, fqAsInt, fqAsRecord } from './FqJson';

const FQ_HONGGUO_FAVORITES_PATH: string = '/api/v1/account/hongguo/favorites';
const FQ_HONGGUO_LOGIN_QR_PATH: string = '/api/v1/account/hongguo/login/qr';
const FQ_HONGGUO_LOGIN_POLL_PATH: string = '/api/v1/account/hongguo/login/poll';
const FQ_HONGGUO_LOGIN_SEND_PATH: string = '/api/v1/account/hongguo/login/send';
const FQ_HONGGUO_LOGIN_VERIFY_PATH: string = '/api/v1/account/hongguo/login/verify';
/** 归一化收藏条数上限（响应解析与持久化复用）。 */
const FQ_HONGGUO_FAVORITES_MAX: number = 1000;

/** 文本字段收窄（超长/非串返回空；二维码/cookie 等大字段由调用方放宽 maxLen）。 */
function fqHongguoText(value: Object | undefined, maxLen: number): string {
  if (typeof value !== 'string' || value.length > maxLen) {
    return '';
  }
  return value;
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

/** 导入服务：官网登录（扫码/验证码）→ 拉取云端收藏 → 合并到本机书架。 */
export class FqHongguoImportService {
  private static currentRequestId: string = '';

  /** 取消在途请求（fq.cancel → 499）。 */
  public cancel(): void {
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

  /** 发送短信验证码（后端归一化并校验手机号）。 */
  public async sendSms(mobile: string): Promise<FqHongguoSmsSent> {
    const body: Record<string, Object> = {};
    body['mobile'] = mobile;
    const result: Record<string, Object> =
      await this.postLogin('hongguo-login-send', FQ_HONGGUO_LOGIN_SEND_PATH, body);
    const maskedMobile: string = fqHongguoText(result['maskedMobile'], 64);
    if (maskedMobile.length === 0) {
      throw new Error('红果登录响应无效');
    }
    return new FqHongguoSmsSent(maskedMobile, fqAsInt(result['retrySeconds'], 60));
  }

  /** 校验短信验证码，成功返回登录 cookie。 */
  public async verifySms(code: string): Promise<string> {
    const body: Record<string, Object> = {};
    body['code'] = code;
    const result: Record<string, Object> =
      await this.postLogin('hongguo-login-verify', FQ_HONGGUO_LOGIN_VERIFY_PATH, body);
    const cookie: string = fqHongguoText(result['cookie'], 16 * 1024);
    if (cookie.length === 0) {
      throw new Error('红果登录响应无效');
    }
    return cookie;
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

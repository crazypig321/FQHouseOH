/**
 * WebDAV 备份与恢复（对齐 musicfreeOH WebDav 写法，适配本项目）：
 * - 服务器地址（如 https://dav.example.com/dav/）+ 备份路径（可选）+ 自动追加的 FQHouseOH 目录，
 *   每次备份生成独立文件 fqhouse-backup_yyyyMMdd_HHmmss_设备名.json（互不覆盖，恢复时选择）；
 * - 备份内容复用 FqLibraryBackup（capture/encode 白名单校验），恢复走 decode/restore 合并语义；
 * - 认证方式为 Basic Auth（用户名/密码可留空）；
 * - 备份完成后按保留数量清理最老备份；开启「退出时自动备份」时彻底退出前静默备份一次；
 * - HTTP 经 rcp（Remote Communication Kit）共享会话，支持 PROPFIND/MKCOL/PUT/DELETE 等 WebDAV 方法。
 */

import { rcp } from '@kit.RemoteCommunicationKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { FqWebDavConfigStore } from './FqWebDavConfigStore';
import { FqLibraryBackup, FqLibraryBackupData } from './FqLibraryBackup';

/** WebDAV 远端备份条目（列表弹窗展示用）。 */
export class FqWebDavBackupEntry {
  /** 备份文件名。 */
  public readonly fileName: string;
  /** 文件大小（字节，未知 -1）。 */
  public readonly size: number;

  constructor(fileName: string, size: number) {
    this.fileName = fileName;
    this.size = size;
  }
}

/** WebDAV 拉取结果。 */
export class FqWebDavRestoreResult {
  /** 请求成功且拿到备份内容。 */
  public readonly ok: boolean;
  /** 远端不存在备份文件。 */
  public readonly notFound: boolean;
  /** 备份 JSON 文本。 */
  public readonly data: string;

  constructor(ok: boolean, notFound: boolean, data: string) {
    this.ok = ok;
    this.notFound = notFound;
    this.data = data;
  }
}

/** rcp 响应轻量包装（状态码 + 解码后文本）。 */
class FqWebDavResponse {
  public readonly statusCode: number;
  public readonly body: string;

  constructor(statusCode: number, body: string) {
    this.statusCode = statusCode;
    this.body = body;
  }
}

export class FqWebDav {
  static readonly BACKUP_PREFIX: string = 'fqhouse-backup_';
  static readonly BACKUP_DIRNAME: string = 'FQHouseOH';
  /** 退出自动备份进行中标记（防重复触发）。 */
  private static exitBackupRunning: boolean = false;
  /** rcp 全局共享会话（会话数量有限制，禁止按请求新建）。 */
  private static session: rcp.Session | null = null;

  /** 是否已配置服务器地址。 */
  static isConfigured(): boolean {
    return FqWebDavConfigStore.getUrl().trim().length > 0;
  }

  /** 备份文件名中的设备名：外部产品系列名（marketName），空时回退产品型号；剔除文件名非法字符。 */
  private static deviceName(): string {
    let name: string = deviceInfo.marketName.trim();
    if (name.length === 0) {
      name = deviceInfo.productModel.trim();
    }
    return name.replace(/[\\/:*?"<>|\s]+/g, '_');
  }

  /** 生成备份文件名：fqhouse-backup_yyyyMMdd_HHmmss_设备名.json。 */
  static backupFileName(): string {
    const date: Date = new Date();
    const stamp: string = `${date.getFullYear()}${FqWebDav.pad(date.getMonth() + 1)}` +
      `${FqWebDav.pad(date.getDate())}_${FqWebDav.pad(date.getHours())}` +
      `${FqWebDav.pad(date.getMinutes())}${FqWebDav.pad(date.getSeconds())}`;
    return `${FqWebDav.BACKUP_PREFIX}${stamp}_${FqWebDav.deviceName()}.json`;
  }

  /** 两位补零。 */
  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 备份文件条目显示文本：时间戳+设备名文件转为「yyyy-MM-dd HH:mm:ss · 设备名」，其余原样展示。 */
  static displayTitle(fileName: string): string {
    if (!fileName.startsWith(FqWebDav.BACKUP_PREFIX) || !fileName.endsWith('.json')) {
      return fileName;
    }
    const stem: string =
      fileName.substring(FqWebDav.BACKUP_PREFIX.length, fileName.length - '.json'.length);
    // stem 结构：yyyyMMdd_HHmmss_设备名
    if (stem.length <= 16 || stem.charAt(8) !== '_' || stem.charAt(15) !== '_') {
      return fileName;
    }
    const dateStr: string = stem.substring(0, 8);
    const timeStr: string = stem.substring(9, 15);
    if (!/^\d{8}$/.test(dateStr) || !/^\d{6}$/.test(timeStr)) {
      return fileName;
    }
    return `${dateStr.substring(0, 4)}-${dateStr.substring(4, 6)}-${dateStr.substring(6, 8)}` +
      ` ${timeStr.substring(0, 2)}:${timeStr.substring(2, 4)}:${timeStr.substring(4, 6)}` +
      ` · ${stem.substring(16)}`;
  }

  /** 字节数格式化（备份列表展示用；未知大小返回空串）。 */
  static formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB'];
    const index: number = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return `${(bytes / Math.pow(1024, index)).toFixed(1)}${units[index]}`;
  }

  /**
   * 采集本机数据生成备份并 PUT 到 WebDAV（每次生成新文件，不覆盖历史备份；
   * 完成后按保留数量清理最老备份）。
   */
  static async backup(): Promise<boolean> {
    const headers: Record<string, string> = FqWebDav.authHeaders();
    headers['Content-Type'] = 'application/json';
    // 逐级创建远端目录（已存在时返回 405，忽略即可）
    await FqWebDav.ensureRemoteFolders();
    const data: FqLibraryBackupData = await FqLibraryBackup.capture();
    const text: string = FqLibraryBackup.encode(data);
    const resp: FqWebDavResponse | null = await FqWebDav.request(
      `${FqWebDav.folderUrl()}${encodeURIComponent(FqWebDav.backupFileName())}`,
      'PUT', headers, text, 30000);
    const ok: boolean = resp !== null && resp.statusCode >= 200 && resp.statusCode < 300;
    if (ok) {
      await FqWebDav.pruneBackups();
    }
    return ok;
  }

  /** 备份完成后清理超限旧备份：仅保留最新 maxBackupCount 个，其余按从旧到新删除；失败静默。 */
  private static async pruneBackups(): Promise<void> {
    const limit: number = FqWebDavConfigStore.getMaxBackupCount();
    const entries: FqWebDavBackupEntry[] | null = await FqWebDav.listBackups();
    if (entries === null) {
      return;
    }
    // 列表按文件名倒序（新→旧），仅收集带时间戳前缀的备份
    const timestamped: string[] = [];
    for (const entry of entries) {
      if (entry.fileName.startsWith(FqWebDav.BACKUP_PREFIX)) {
        timestamped.push(entry.fileName);
      }
    }
    for (let index: number = limit; index < timestamped.length; index++) {
      await FqWebDav.request(`${FqWebDav.folderUrl()}${encodeURIComponent(timestamped[index])}`,
        'DELETE', FqWebDav.authHeaders(), null, 15000);
    }
  }

  /**
   * 列出远端备份条目（PROPFIND Depth:1，含文件大小）；
   * 按文件名倒序（时间戳前缀字典序即时间序，新备份在前）；请求失败返回 null。
   */
  static async listBackups(): Promise<FqWebDavBackupEntry[] | null> {
    const headers: Record<string, string> = FqWebDav.authHeaders();
    headers['Depth'] = '1';
    headers['Content-Type'] = 'application/xml';
    const body: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/></D:prop></D:propfind>';
    const resp: FqWebDavResponse | null =
      await FqWebDav.request(FqWebDav.folderUrl(), 'PROPFIND', headers, body, 15000);
    if (resp === null || resp.statusCode < 200 || resp.statusCode >= 300) {
      return null;
    }
    const entries: FqWebDavBackupEntry[] = [];
    // 按 response 块解析（href 与文件大小配对；命名空间前缀因服务器而异，按通配处理）
    const blocks: string[] = resp.body.split(/<(?:[A-Za-z0-9_.-]+:)?response>/);
    for (const block of blocks) {
      const hrefMatch: RegExpMatchArray | null =
        block.match(/<(?:[A-Za-z0-9_.-]+:)?href>([^<]+)<\/(?:[A-Za-z0-9_.-]+:)?href>/);
      if (hrefMatch === null) {
        continue;
      }
      const href: string = hrefMatch[1];
      const raw: string = href.substring(href.lastIndexOf('/') + 1);
      if (raw.length === 0 || !raw.endsWith('.json')) {
        continue;
      }
      let name: string = raw;
      try {
        name = decodeURIComponent(raw);
      } catch (error) {
        name = raw;
      }
      const isBackup: boolean = name.startsWith(FqWebDav.BACKUP_PREFIX);
      let duplicate: boolean = false;
      for (const entry of entries) {
        if (entry.fileName === name) {
          duplicate = true;
          break;
        }
      }
      if (!isBackup || duplicate) {
        continue;
      }
      let size: number = -1;
      const sizeMatch: RegExpMatchArray | null =
        block.match(/<(?:[A-Za-z0-9_.-]+:)?getcontentlength>(\d+)<\/(?:[A-Za-z0-9_.-]+:)?getcontentlength>/);
      if (sizeMatch !== null) {
        size = parseInt(sizeMatch[1], 10);
      }
      entries.push(new FqWebDavBackupEntry(name, size));
    }
    entries.sort((a: FqWebDavBackupEntry, b: FqWebDavBackupEntry): number =>
      b.fileName.localeCompare(a.fileName));
    return entries;
  }

  /** 从 WebDAV 拉取指定备份文件（404 标记 notFound）。 */
  static async fetchBackup(fileName: string): Promise<FqWebDavRestoreResult> {
    const resp: FqWebDavResponse | null = await FqWebDav.request(
      `${FqWebDav.folderUrl()}${encodeURIComponent(fileName)}`,
      'GET', FqWebDav.authHeaders(), null, 30000);
    if (resp === null) {
      return new FqWebDavRestoreResult(false, false, '');
    }
    if (resp.statusCode === 404) {
      return new FqWebDavRestoreResult(false, true, '');
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300 && resp.body.length > 0) {
      return new FqWebDavRestoreResult(true, false, resp.body);
    }
    return new FqWebDavRestoreResult(false, false, '');
  }

  /** 服务器地址（补齐结尾斜杠，不含备份路径）。 */
  static serverUrl(): string {
    const base: string = FqWebDavConfigStore.getUrl().trim();
    return base.endsWith('/') ? base : `${base}/`;
  }

  /** 备份路径段（去首尾斜杠，空配置为空数组）。 */
  private static pathSegments(): string[] {
    const path: string = FqWebDavConfigStore.getPath().trim();
    if (path.length === 0) {
      return [];
    }
    const parts: string[] = [];
    for (const seg of path.split('/')) {
      if (seg.length > 0) {
        parts.push(seg);
      }
    }
    return parts;
  }

  /** 备份目录完整地址：服务器地址 + 备份路径 + FQHouseOH/（路径末尾已是 FQHouseOH 时不重复拼接）。 */
  static folderUrl(): string {
    const segs: string[] = FqWebDav.pathSegments();
    let url: string = FqWebDav.serverUrl();
    for (const seg of segs) {
      url = `${url}${seg}/`;
    }
    if (segs.length === 0 || segs[segs.length - 1] !== FqWebDav.BACKUP_DIRNAME) {
      url = `${url}${FqWebDav.BACKUP_DIRNAME}/`;
    }
    return url;
  }

  /** 逐级 MKCOL 创建备份路径与 FQHouseOH 目录（每级失败不中断，由 PUT 兜底报错）。 */
  private static async ensureRemoteFolders(): Promise<void> {
    const segs: string[] = FqWebDav.pathSegments();
    if (segs.length === 0 || segs[segs.length - 1] !== FqWebDav.BACKUP_DIRNAME) {
      segs.push(FqWebDav.BACKUP_DIRNAME);
    }
    let current: string = FqWebDav.serverUrl();
    for (const seg of segs) {
      current = `${current}${seg}/`;
      await FqWebDav.request(current, 'MKCOL', FqWebDav.authHeaders(), null, 15000);
    }
  }

  /** 服务器连通性探测（OPTIONS）：拿到 HTTP 响应且认证通过（非 401/403）视为可达。 */
  private static async isReachable(): Promise<boolean> {
    const resp: FqWebDavResponse | null =
      await FqWebDav.request(FqWebDav.serverUrl(), 'OPTIONS', FqWebDav.authHeaders(), null, 8000);
    if (resp === null) {
      return false;
    }
    return resp.statusCode !== 401 && resp.statusCode !== 403;
  }

  /** 彻底退出应用前自动备份（Ability onDestroy 触发）：开关开启 + 已配置服务器 + 可达时执行，全程静默失败。 */
  static async backupOnExit(): Promise<void> {
    if (FqWebDav.exitBackupRunning) {
      return;
    }
    if (!FqWebDavConfigStore.isAutoBackupOnExit() || !FqWebDav.isConfigured()) {
      return;
    }
    FqWebDav.exitBackupRunning = true;
    try {
      if (await FqWebDav.isReachable()) {
        await FqWebDav.backup();
      }
    } catch (error) {
      // 退出路径不弹提示，静默失败
    } finally {
      FqWebDav.exitBackupRunning = false;
    }
  }

  /** Basic Auth 请求头。 */
  private static authHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    const user: string = FqWebDavConfigStore.getUsername();
    const pass: string = FqWebDavConfigStore.getPassword();
    if (user.length > 0 || pass.length > 0) {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const encoded: Uint8Array = encoder.encodeInto(`${user}:${pass}`);
      const helper: util.Base64Helper = new util.Base64Helper();
      headers['Authorization'] = `Basic ${helper.encodeToStringSync(encoded)}`;
    }
    return headers;
  }

  /** rcp 共享会话。 */
  private static getSession(): rcp.Session {
    if (FqWebDav.session === null) {
      FqWebDav.session = rcp.createSession();
    }
    return FqWebDav.session;
  }

  /** 任意 method 请求（body 为 null 时无请求体）；异常返回 null。 */
  private static async request(url: string, method: string, headers: Record<string, string>,
    body: string | null, timeoutMs: number): Promise<FqWebDavResponse | null> {
    try {
      const reqHeaders: rcp.RequestHeaders = {};
      for (const key of Object.keys(headers)) {
        reqHeaders[key] = headers[key];
      }
      const config: rcp.Configuration = {
        transfer: { timeout: { connectMs: timeoutMs, transferMs: timeoutMs } }
      };
      const req: rcp.Request = body === null
        ? new rcp.Request(url, method, reqHeaders, undefined, undefined, undefined, config)
        : new rcp.Request(url, method, reqHeaders, body, undefined, undefined, config);
      const resp = await FqWebDav.getSession().fetch(req);
      return new FqWebDavResponse(resp.statusCode, FqWebDav.decodeBody(resp.body));
    } catch (error) {
      return null;
    }
  }

  /** 响应体 UTF-8 解码。 */
  private static decodeBody(body: ArrayBuffer | undefined): string {
    if (body === undefined) {
      return '';
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(body));
  }
}

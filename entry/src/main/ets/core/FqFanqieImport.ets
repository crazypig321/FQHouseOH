/**
 * 番茄书架导入（对齐 fqapp fanqie_library_capture_service / fanqie_library_import_service）：
 * - 采集：Web 登录官方页面取 cookie → POST /api/v1/account/fanqie/library 按白名单只读接口
 *   分页采集（书架/置顶/标签/进度/历史/文件夹），响应原样留存（凭证字段清洗），
 *   文档为 fqapp.fanqie-library-capture v2 兼容格式（≤16MB，本机 filesDir 持久化）；
 * - 解析：只导入小说（book_type=0）；书架/文件夹递归识别、历史/进度逐条收敛，
 *   阅读位置保留官方章节 ID 原样证据（不换算官方段落偏移）；
 * - 章节定位：官方章节 ID 对本应用目录匹配 → 阅读进度从对应章节开头续读；
 * - 合并：书架只补缺失（已有条目回填空封面），进度仅本机无记录时写入；
 *   重复导入不产生重复书籍；
 * - 文件导入兼容：fqapp 采集 JSON（单文件）或官方 read_history 单页响应（须 has_more=false）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import fq from 'libfqapi_napi.so';
import { FqBackend, FqRequestError } from './FqBackend';
import { FqChapter } from '../model/FqModels';
import { FqShelfItem, FqShelfStore } from './FqShelfStore';
import { FqReaderStore } from './FqReaderStore';
import { fqAsArray, fqAsInt, fqAsRecord } from './FqJson';

const FQ_FANQIE_LIBRARY_PATH: string = '/api/v1/account/fanqie/library';
const FQ_FANQIE_CAPTURE_FORMAT: string = 'fqapp.fanqie-library-capture';
const FQ_FANQIE_CAPTURE_MAX_BYTES: number = 16 * 1024 * 1024;
const FQ_FANQIE_MAX_SOURCES: number = 2000;
const FQ_FANQIE_MAX_PAGES: number = 200;
const FQ_FANQIE_MAX_BOOKS: number = 10000;
const FQ_FANQIE_MAX_TIME: number = 8640000000000000;
/** 凭证字段清洗（对齐 fqapp _credentialKey）。 */
const FQ_FANQIE_CREDENTIAL_KEY: RegExp =
  /cookie|token|^session(?:id)?(?:_ss)?$|^sid_tt$|^sid_guard$|authorization|password|secret|device.?id|install.?id|^iid$|^headers$/;
/** 凭证值清洗（对齐 fqapp 字符串回溯替换）。 */
const FQ_FANQIE_SESSION_VALUE: RegExp = /(sessionid(?:_ss)?|sid_tt|sid_guard|passport_csrf_token)=[^;\s&]+/g;
/** 资源中文名（采集进度文案用）。 */
const FQ_FANQIE_RESOURCE_LABELS: Record<string, string> = {
  'shelf_list': '书架列表',
  'shelf_info': '书架完整信息',
  'history': '阅读历史',
  'progress_list': '进度列表',
  'progress_batch': '按作品查询进度',
  'folder_list': '文件夹列表',
  'folder_detail': '文件夹内容',
  'topping': '置顶信息',
  'tabs': '书架标签',
  'book_detail': '书籍详情',
};

function fqFanqieResourceLabel(resource: string): string {
  const label: string | undefined = FQ_FANQIE_RESOURCE_LABELS[resource];
  return label !== undefined ? label : resource;
}

/** UTF-8 字节数（体积校验用，不额外分配大缓冲）。 */
function fqFanqieUtf8Length(text: string): number {
  let total: number = 0;
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code < 0x80) {
      total += 1;
    } else if (code < 0x800) {
      total += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF) {
      total += 4;
      index++;
    } else {
      total += 3;
    }
  }
  return total;
}

/** 官方数字 ID 收窄：1-20 位纯数字且非全零。 */
function fqFanqieId(value: Object | undefined): string | null {
  let text: string = '';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      return null;
    }
    text = `${Math.trunc(value)}`;
  } else if (typeof value === 'string') {
    text = value;
  } else {
    return null;
  }
  if (!/^[0-9]{1,20}$/.test(text) || /^0+$/.test(text)) {
    return null;
  }
  return text;
}

/** 阅读时间收敛：优先毫秒时间戳，回退秒级 ×1000。 */
function fqFanqieTime(rec: Record<string, Object>): number {
  const ms: number = fqAsInt(rec['read_timestamp_ms'], 0);
  const seconds: number = fqAsInt(rec['read_timestamp'], 0);
  const time: number = ms > 0 ? ms : seconds * 1000;
  return time >= 0 && time <= FQ_FANQIE_MAX_TIME ? time : 0;
}

/** 封面可移植化：仅保留 http(s) 且主机名无 userInfo 的网络地址。 */
function fqFanqieCoverOk(cover: string): boolean {
  const match: RegExpExecArray | null = /^https?:\/\/([^/?#]+)/.exec(cover);
  if (match === null) {
    return false;
  }
  const host: string = match[1];
  return host.length > 0 && host.indexOf('@') < 0;
}

/** 采集文档（fqapp.fanqie-library-capture v2 兼容；sources 内联载荷）。 */
export class FqFanqieCapture {
  readonly document: Record<string, Object>;

  constructor(document: Record<string, Object>) {
    this.document = document;
  }

  public sources(): Object[] {
    const arr: Object[] | null = fqAsArray(this.document['sources']);
    return arr !== null ? arr : [];
  }

  public receivedCount(): number {
    let count: number = 0;
    for (const raw of this.sources()) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec !== null && rec['status'] === 'received') {
        count++;
      }
    }
    return count;
  }

  public failedCount(): number {
    let count: number = 0;
    for (const raw of this.sources()) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec !== null && rec['status'] !== 'received') {
        count++;
      }
    }
    return count;
  }

  public stopReason(): string {
    const value: Object | undefined = this.document['stopReason'];
    return typeof value === 'string' ? value : '';
  }

  /** 序列化为采集 JSON 文本（体积超限抛错）。 */
  public encode(): string {
    const text: string = JSON.stringify(this.document);
    if (fqFanqieUtf8Length(text) > FQ_FANQIE_CAPTURE_MAX_BYTES) {
      throw new Error('采集结果超过 16 MB，未能保存');
    }
    return text;
  }

  /** 解析并校验采集文本（v1/v2；分卷格式不支持）。 */
  public static decode(text: string): FqFanqieCapture {
    let clean: string = text;
    if (clean.startsWith('\uFEFF')) {
      clean = clean.substring(1);
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(clean);
    } catch (error) {
      throw new Error('文件不是有效的 JSON');
    }
    const root: Record<string, Object> | null = fqAsRecord(parsed);
    if (root === null || root['format'] !== FQ_FANQIE_CAPTURE_FORMAT) {
      throw new Error('不是支持的番茄书架采集文件');
    }
    const version: Object | undefined = root['version'];
    if (version !== 1 && version !== 2) {
      throw new Error('番茄书架采集文件版本不受支持');
    }
    const parts: Object[] | null = fqAsArray(root['parts']);
    if (parts !== null && parts.length > 0) {
      throw new Error('该采集文件为分卷格式，暂不支持导入');
    }
    const sources: Object[] | null = fqAsArray(root['sources']);
    if (sources === null) {
      throw new Error('番茄书架采集文件缺少响应列表');
    }
    for (const raw of sources) {
      if (fqAsRecord(raw) === null) {
        throw new Error('番茄书架采集文件响应列表格式无效');
      }
    }
    return new FqFanqieCapture(root);
  }
}

/**
 * 书架采集器：cookie 登录态 + 白名单只读接口分页采集。
 * 取消语义：cancel() 中断在途请求（fq.cancel → 499），已收到数据保留进 stopReason 部分采集。
 */
export class FqFanqieCollector {
  private readonly cookie: string;
  private readonly startedAt: string = new Date().toISOString();
  private readonly sources: Record<string, Object>[] = [];
  private readonly novelIds: Set<string> = new Set<string>();
  private readonly folders: Set<string> = new Set<string>();
  private deviceId: string = '';
  private requestSeq: number = 0;
  private currentRequestId: string = '';
  private usedBytes: number = 0;
  private redactedFields: number = 0;
  private stopReasonValue: string = '';
  private stopped: boolean = false;
  private cancelled: boolean = false;

  constructor(cookie: string) {
    this.cookie = cookie;
  }

  /** 取消采集：中断在途请求，已收到的数据保留。 */
  public cancel(): void {
    this.cancelled = true;
    if (this.currentRequestId.length > 0) {
      fq.cancel(this.currentRequestId);
    }
  }

  public async collect(onProgress: (message: string) => void): Promise<FqFanqieCapture> {
    const singles: string[] = ['shelf_list', 'shelf_info', 'topping', 'tabs', 'progress_list'];
    for (const resource of singles) {
      if (this.stopped) {
        break;
      }
      await this.fetch(resource, 0, 0, [], '', onProgress);
    }
    if (!this.stopped) {
      await this.paged('history', 0, '', onProgress);
    }
    if (!this.stopped) {
      await this.paged('folder_list', 0, '', onProgress);
    }
    const folderList: string[] = [];
    this.folders.forEach((folder: string): void => {
      folderList.push(folder);
    });
    for (const folder of folderList) {
      if (this.stopped) {
        break;
      }
      await this.paged('folder_detail', 0, folder, onProgress);
    }
    const ids: string[] = [];
    this.novelIds.forEach((id: string): void => {
      ids.push(id);
    });
    for (let offset: number = 0; offset < ids.length; offset += 50) {
      if (this.stopped) {
        break;
      }
      const chunk: string[] = ids.slice(offset, offset + 50);
      await this.fetch('progress_batch', 0, 0, chunk, '', onProgress);
    }
    const document: Record<string, Object> = {};
    document['format'] = FQ_FANQIE_CAPTURE_FORMAT;
    document['version'] = 2;
    document['createdAt'] = this.startedAt;
    document['finishedAt'] = new Date().toISOString();
    document['stopReason'] = this.stopReasonValue;
    document['totalResponseBytes'] = this.usedBytes;
    document['credentialFieldsRemoved'] = this.redactedFields;
    document['sources'] = this.sources;
    return new FqFanqieCapture(document);
  }

  private checkStop(): void {
    if (this.cancelled) {
      this.stopReasonValue = '用户取消；已收到的数据保留，尚未请求的部分没有采集';
      this.stopped = true;
    }
    if (!this.stopped && this.sources.length >= FQ_FANQIE_MAX_SOURCES) {
      this.stopReasonValue = '达到 2000 个响应上限；保留已采集的部分数据';
      this.stopped = true;
    }
  }

  /** 单资源采集；返回清洗后的上游 payload（失败返回 null）。 */
  private async fetch(resource: string, bookType: number, offset: number,
    bookIds: string[], folderId: string,
    onProgress: (message: string) => void): Promise<Record<string, Object> | null> {
    this.checkStop();
    if (this.stopped) {
      return null;
    }
    this.requestSeq += 1;
    this.currentRequestId = `fanqie-${this.requestSeq}`;
    onProgress(`正在采集${fqFanqieResourceLabel(resource)}，已保存 ${this.sources.length} 个响应`);
    const body: Record<string, Object> = {};
    body['cookie'] = this.cookie;
    body['resource'] = resource;
    body['offset'] = offset;
    body['book_type'] = bookType;
    if (this.deviceId.length > 0) {
      body['device_id'] = this.deviceId;
    }
    if (bookIds.length > 0) {
      body['book_ids'] = bookIds;
    }
    if (folderId.length > 0) {
      body['folder_id'] = folderId;
    }
    let result: Record<string, Object>;
    try {
      result = await FqBackend.get().postJson(this.currentRequestId,
        FQ_FANQIE_LIBRARY_PATH, JSON.stringify(body));
    } catch (error) {
      if (this.cancelled) {
        this.checkStop();
        return null;
      }
      if (error instanceof FqRequestError && (error.statusCode === 400 || error.statusCode === 503)) {
        // 后端 authored 的拒绝（登录态无效/设备不可用）：终止采集并透出消息
        this.stopReasonValue = error.message;
        this.stopped = true;
        return null;
      }
      this.addSource(this.buildSource(resource, bookType, offset, folderId,
        'failed', null, '读取失败或响应无效，未保存异常详情和请求凭证'));
      return null;
    }
    const selectedRaw: Object | undefined = result['device_id'];
    if (typeof selectedRaw !== 'string' || selectedRaw.length === 0) {
      this.addSource(this.buildSource(resource, bookType, offset, folderId,
        'failed', null, '采集响应缺少设备标识，未保存该响应'));
      return null;
    }
    if (this.deviceId.length > 0 && selectedRaw !== this.deviceId) {
      this.stopReasonValue = '采集设备不一致，已停止；此文件是部分采集';
      this.stopped = true;
      return null;
    }
    this.deviceId = selectedRaw;
    const payload: Record<string, Object> | null = fqAsRecord(result['payload']);
    const code: Object | undefined = payload !== null ? payload['code'] : undefined;
    const success: boolean =
      result['upstream_status'] === 200 && payload !== null && (code === 0 || code === '0');
    const payloadClean: Record<string, Object> =
      payload !== null ? this.cleanRecord(payload, 0) : {};
    this.addSource(this.buildSource(resource, bookType, offset, folderId,
      success ? 'received' : 'failed', payloadClean,
      success ? '' : '接口未成功；保留响应供后续分析，未当成空书架'));
    if (!success) {
      return null;
    }
    this.identities(payloadClean, bookType, 0);
    return payloadClean;
  }

  /** 分页资源采集（has_more/next_offset 明确推进才继续，最多 200 页）。 */
  private async paged(resource: string, bookType: number, folderId: string,
    onProgress: (message: string) => void): Promise<void> {
    let offset: number = 0;
    for (let page: number = 0; page < FQ_FANQIE_MAX_PAGES; page++) {
      if (this.stopped) {
        return;
      }
      const payload: Record<string, Object> | null =
        await this.fetch(resource, bookType, offset, [], folderId, onProgress);
      if (payload === null) {
        return;
      }
      const data: Record<string, Object> | null = fqAsRecord(payload['data']);
      if (data === null || typeof data['has_more'] !== 'boolean') {
        this.addSource(this.buildSource(resource, bookType, offset, folderId,
          'incomplete', null, '缺少明确分页字段，未假定已采集完毕'));
        return;
      }
      if (data['has_more'] === false) {
        return;
      }
      const nextOffset: number = fqAsInt(data['next_offset'], -1);
      if (nextOffset <= offset || nextOffset > 100000) {
        this.addSource(this.buildSource(resource, bookType, offset, folderId,
          'incomplete', null, '分页未前进或超过游标范围'));
        return;
      }
      offset = nextOffset;
    }
    this.addSource(this.buildSource(resource, bookType, offset, folderId,
      'incomplete', null, '达到 200 页上限'));
  }

  private buildSource(resource: string, bookType: number, offset: number,
    folderId: string, status: string, payload: Record<string, Object> | null,
    note: string): Record<string, Object> {
    const source: Record<string, Object> = {};
    source['resource'] = resource;
    source['bookType'] = bookType;
    source['offset'] = offset;
    if (folderId.length > 0) {
      source['folderId'] = folderId;
    }
    source['status'] = status;
    if (payload !== null) {
      source['payload'] = payload;
    }
    if (note.length > 0) {
      source['note'] = note;
    }
    return source;
  }

  /** 计入响应（单个响应超限则记摘要并停止采集）。 */
  private addSource(source: Record<string, Object>): void {
    const size: number = fqFanqieUtf8Length(JSON.stringify(source));
    if (size > FQ_FANQIE_CAPTURE_MAX_BYTES - 128 * 1024) {
      const summary: Record<string, Object> = {};
      for (const key of Object.keys(source)) {
        if (key !== 'payload') {
          summary[key] = source[key];
        }
      }
      summary['status'] = 'failed';
      summary['note'] = '单个响应超过大小上限，未保存原始载荷';
      this.sources.push(summary);
      this.stopReasonValue = '单个响应超过大小上限；其他已保存的响应保留';
      this.stopped = true;
      return;
    }
    this.usedBytes += size;
    this.sources.push(source);
  }

  /** 凭证字段清洗（对齐 fqapp _clean：键名剔除 + 字符串值回溯替换）。 */
  private cleanValue(value: Object, depth: number): Object {
    if (depth > 48) {
      throw new Error('响应嵌套过深');
    }
    const arr: Object[] | null = fqAsArray(value);
    if (arr !== null) {
      const cleaned: Object[] = [];
      for (const item of arr) {
        cleaned.push(this.cleanValue(item, depth + 1));
      }
      return cleaned;
    }
    const rec: Record<string, Object> | null = fqAsRecord(value);
    if (rec !== null) {
      const result: Record<string, Object> = {};
      for (const key of Object.keys(rec)) {
        if (FQ_FANQIE_CREDENTIAL_KEY.test(key)) {
          this.redactedFields++;
          continue;
        }
        result[key] = this.cleanValue(rec[key], depth + 1);
      }
      return result;
    }
    if (typeof value === 'string') {
      return this.cleanString(value);
    }
    return value;
  }

  private cleanRecord(payload: Record<string, Object>, depth: number): Record<string, Object> {
    const cleaned: Object = this.cleanValue(payload, depth);
    const rec: Record<string, Object> | null = fqAsRecord(cleaned);
    return rec !== null ? rec : {};
  }

  private cleanString(text: string): string {
    let value: string = text;
    if (this.cookie.length > 0 && value.indexOf(this.cookie) >= 0) {
      value = value.split(this.cookie).join('[removed]');
    }
    return value.replace(FQ_FANQIE_SESSION_VALUE, '[removed]');
  }

  /** 递归收集小说 ID 与文件夹 ID（深度上限 32）。 */
  private identities(node: Object | undefined, type: number, depth: number): void {
    if (depth > 32 || node === undefined || node === null) {
      return;
    }
    const arr: Object[] | null = fqAsArray(node);
    if (arr !== null) {
      for (const item of arr) {
        this.identities(item, type, depth + 1);
      }
      return;
    }
    const rec: Record<string, Object> | null = fqAsRecord(node);
    if (rec === null) {
      return;
    }
    const currentType: number = fqAsInt(rec['book_type'], type);
    const id: string | null = fqFanqieId(rec['book_id_str']) ?? fqFanqieId(rec['book_id']);
    if (id !== null && currentType === 0) {
      this.novelIds.add(id);
    }
    const folder: string | null = fqFanqieId(rec['folder_id']);
    if (folder !== null && folder !== '0') {
      this.folders.add(folder);
    }
    for (const key of Object.keys(rec)) {
      const child: Object | undefined = rec[key];
      if (child !== null && typeof child === 'object') {
        this.identities(child, currentType, depth + 1);
      }
    }
  }
}

/** 解析出的单本小说（fqapp FanqieLibraryImport record 对应物）。 */
export class FqFanqieBook {
  readonly id: string;
  title: string = '';
  cover: string = '';
  author: string = '';
  time: number = 0;
  /** 官方章节 ID（'' = 无阅读进度记录）。 */
  chapterId: string = '';
  /** 已匹配的本应用目录章节下标（-1 未定位/未匹配）。 */
  episode: number = -1;
  /** 预览文案（'第 N 章'；空 = 未定位）。 */
  epText: string = '';

  constructor(id: string) {
    this.id = id;
  }
}

/** 单书阅读位置证据（官方章节 ID + 收敛时间）。 */
class FqFanqiePosition {
  readonly time: number;
  readonly chapterId: string;

  constructor(time: number, chapterId: string) {
    this.time = time;
    this.chapterId = chapterId;
  }
}

/** 采集响应解析器：只收敛小说（book_type=0）记录与最新阅读位置。 */
export class FqFanqieImportParser {
  private readonly books: Map<string, FqFanqieBook> = new Map();
  private readonly positions: Map<string, FqFanqiePosition> = new Map();
  private skippedCount: number = 0;

  public get skipped(): number {
    return this.skippedCount;
  }

  public addSource(source: Record<string, Object>): void {
    if (source['status'] !== 'received') {
      return;
    }
    const payload: Record<string, Object> | null = fqAsRecord(source['payload']);
    if (payload === null) {
      return;
    }
    const code: Object | undefined = payload['code'];
    if (code !== 0 && code !== '0') {
      return;
    }
    const resource: Object | undefined = source['resource'];
    if (resource === 'history') {
      this.addHistorySource(payload);
    } else if (resource === 'shelf_list' || resource === 'shelf_info' || resource === 'folder_detail') {
      this.visit(payload['data'], 0);
    } else if (resource === 'progress_list' || resource === 'progress_batch') {
      this.addProgressSource(payload);
    }
  }

  /** 历史来源：跳过已删除与非小说，收敛最新阅读时间。 */
  private addHistorySource(payload: Record<string, Object>): void {
    const data: Record<string, Object> | null = fqAsRecord(payload['data']);
    if (data === null) {
      return;
    }
    const list: Object[] | null = fqAsArray(data['data_list']);
    if (list === null) {
      return;
    }
    for (const raw of list) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null) {
        continue;
      }
      if (!this.isNovel(rec) || rec['is_delete'] === true || rec['is_delete'] === 1) {
        this.skippedCount++;
        continue;
      }
      const book: FqFanqieBook | null = this.include(rec);
      if (book === null) {
        continue;
      }
      const time: number = fqFanqieTime(rec);
      if (time > book.time) {
        book.time = time;
      }
    }
  }

  /** 进度来源：官方章节 ID 原样保留，同一本书取时间最新的一条。 */
  private addProgressSource(payload: Record<string, Object>): void {
    const list: Object[] | null = fqAsArray(payload['data']);
    if (list === null) {
      return;
    }
    for (const raw of list) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null || !this.isNovel(rec)) {
        continue;
      }
      const book: FqFanqieBook | null = this.include(rec);
      const chapterId: string | null = fqFanqieId(rec['item_id']);
      if (book === null || chapterId === null) {
        continue;
      }
      const time: number = fqFanqieTime(rec);
      const previous: FqFanqiePosition | undefined = this.positions.get(book.id);
      if (previous !== undefined && time < previous.time) {
        continue;
      }
      this.positions.set(book.id, new FqFanqiePosition(time, chapterId));
    }
  }

  /** 书架/文件夹来源：递归遍历；命中小说记录即停（其嵌套是自身字段，不再下钻）。 */
  private visit(value: Object | undefined, depth: number): void {
    if (depth > 24 || value === undefined || value === null) {
      return;
    }
    const arr: Object[] | null = fqAsArray(value);
    if (arr !== null) {
      for (const item of arr) {
        this.visit(item, depth + 1);
      }
      return;
    }
    const rec: Record<string, Object> | null = fqAsRecord(value);
    if (rec === null) {
      return;
    }
    if (this.isNovel(rec)) {
      this.include(rec);
      return;
    }
    for (const key of Object.keys(rec)) {
      const child: Object | undefined = rec[key];
      if (child !== null && typeof child === 'object') {
        this.visit(child, depth + 1);
      }
    }
  }

  private isNovel(rec: Record<string, Object>): boolean {
    const bookType: Object | undefined = rec['book_type'];
    return bookType === 0 || bookType === '0';
  }

  private include(rec: Record<string, Object>): FqFanqieBook | null {
    const id: string | null = fqFanqieId(rec['book_id_str']) ?? fqFanqieId(rec['book_id']);
    if (id === null) {
      return null;
    }
    let book: FqFanqieBook | undefined = this.books.get(id);
    if (book === undefined) {
      book = new FqFanqieBook(id);
      this.books.set(id, book);
    }
    this.fill(book, rec);
    return book;
  }

  private fill(book: FqFanqieBook, rec: Record<string, Object>): void {
    const title: Object | undefined = rec['book_name'];
    if (typeof title === 'string' && title.length > 0 && title.length <= 8192) {
      book.title = title;
    }
    const cover: Object | undefined = rec['thumb_url'];
    if (typeof cover === 'string' && cover.length > 0 && cover.length <= 8192
      && fqFanqieCoverOk(cover)) {
      book.cover = cover;
    }
    const author: Object | undefined = rec['author'];
    if (typeof author === 'string' && author.length > 0 && author.length <= 8192) {
      book.author = author;
    }
  }

  /** 全部小说记录（含官方阅读位置证据），按最近阅读时间降序。 */
  public records(): FqFanqieBook[] {
    const list: FqFanqieBook[] = [];
    this.books.forEach((book: FqFanqieBook): void => {
      const position: FqFanqiePosition | undefined = this.positions.get(book.id);
      if (position !== undefined) {
        book.chapterId = position.chapterId;
        if (position.time > book.time) {
          book.time = position.time;
        }
      }
      list.push(book);
    });
    list.sort((a: FqFanqieBook, b: FqFanqieBook): number => b.time - a.time);
    return list;
  }
}

/** 导入预览（统计 + 已定位记录）。 */
export class FqFanqieImportPreview {
  readonly records: FqFanqieBook[];
  readonly matched: number;
  readonly unresolved: number;
  readonly skipped: number;
  readonly sourceLabel: string;

  constructor(records: FqFanqieBook[], matched: number, unresolved: number,
    skipped: number, sourceLabel: string) {
    this.records = records;
    this.matched = matched;
    this.unresolved = unresolved;
    this.skipped = skipped;
    this.sourceLabel = sourceLabel;
  }
}

/** 合并结果统计。 */
export class FqFanqieMergeResult {
  readonly shelfAdded: number;
  readonly coverFilled: number;
  readonly progressAdded: number;

  constructor(shelfAdded: number, coverFilled: number, progressAdded: number) {
    this.shelfAdded = shelfAdded;
    this.coverFilled = coverFilled;
    this.progressAdded = progressAdded;
  }
}

/** 导入服务：解析 → 章节定位 → 合并（对齐 fqapp FanqieLibraryImportService 流程）。 */
export class FqFanqieImportService {
  /** 解析采集文档并逐书定位章节（官方章节 ID → 本应用目录下标）。 */
  public async prepare(capture: FqFanqieCapture, sourceLabel: string,
    onProgress: (message: string) => void,
    isCancelled: () => boolean): Promise<FqFanqieImportPreview> {
    const parser: FqFanqieImportParser = new FqFanqieImportParser();
    for (const raw of capture.sources()) {
      const source: Record<string, Object> | null = fqAsRecord(raw);
      if (source !== null) {
        parser.addSource(source);
      }
    }
    const records: FqFanqieBook[] = parser.records();
    if (records.length > FQ_FANQIE_MAX_BOOKS) {
      throw new Error('小说超过 10000 本，未导入');
    }
    let matched: number = 0;
    let unresolved: number = 0;
    let done: number = 0;
    const total: number = records.length;
    for (const record of records) {
      if (isCancelled()) {
        throw new Error('读取已取消');
      }
      done++;
      if (record.chapterId.length === 0) {
        continue;
      }
      onProgress(`解析小说 ${done}/${total}，已匹配 ${matched} 个章节`);
      try {
        const chapters: FqChapter[] =
          await FqBackend.get().directoryChapters(record.id, '小说');
        let index: number = -1;
        for (let i: number = 0; i < chapters.length; i++) {
          if (chapters[i].itemId === record.chapterId) {
            index = i;
            break;
          }
        }
        if (index >= 0) {
          record.episode = index;
          record.epText = `第 ${index + 1} 章`;
          matched++;
        } else {
          unresolved++;
        }
      } catch (error) {
        // 保留官方章节 ID；打开该书时阅读页会按当前目录重新匹配
        unresolved++;
      }
    }
    return new FqFanqieImportPreview(records, matched, unresolved, parser.skipped, sourceLabel);
  }

  /** 合并到本机：书架只补缺失（已有条目回填空封面），进度仅本机无记录时写入。 */
  public merge(preview: FqFanqieImportPreview): FqFanqieMergeResult {
    let shelfAdded: number = 0;
    let coverFilled: number = 0;
    let progressAdded: number = 0;
    for (const record of preview.records) {
      const title: string = record.title.length > 0 ? record.title : '未知作品';
      const item: FqShelfItem = new FqShelfItem(record.id, 'book', title, record.cover);
      if (FqShelfStore.addIfAbsent(item)) {
        shelfAdded++;
      } else if (record.cover.length > 0 && FqShelfStore.updateCover(record.id, record.cover)) {
        coverFilled++;
      }
      if (record.episode >= 0 && FqReaderStore.getProgress(record.id).chapterIndex < 0) {
        FqReaderStore.saveProgress(record.id, record.episode, '');
        progressAdded++;
      }
    }
    return new FqFanqieMergeResult(shelfAdded, coverFilled, progressAdded);
  }

  /** 解析导入文件文本：fqapp 采集 JSON 或官方 read_history 单页响应（合成采集文档）。 */
  public static parseFileText(text: string): FqFanqieCapture {
    let clean: string = text;
    if (clean.startsWith('\uFEFF')) {
      clean = clean.substring(1);
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(clean);
    } catch (error) {
      throw new Error('文件不是有效的 JSON');
    }
    const root: Record<string, Object> | null = fqAsRecord(parsed);
    if (root === null) {
      throw new Error('请选择番茄书架采集 JSON 或官方历史响应文件');
    }
    if (root['format'] === FQ_FANQIE_CAPTURE_FORMAT) {
      return FqFanqieCapture.decode(clean);
    }
    // 官方 read_history 单页响应：code=0 + data.data_list + has_more=false
    const code: Object | undefined = root['code'];
    if (code !== 0 && code !== '0') {
      throw new Error('请选择番茄书架采集 JSON 或官方历史响应文件');
    }
    const data: Record<string, Object> | null = fqAsRecord(root['data']);
    if (data === null || fqAsArray(data['data_list']) === null
      || typeof data['has_more'] !== 'boolean') {
      throw new Error('官方历史响应格式不兼容');
    }
    if (data['has_more'] === true) {
      throw new Error('该响应还有下一页，请先获取完整历史，避免误以为已导入全部');
    }
    const source: Record<string, Object> = {};
    source['resource'] = 'history';
    source['bookType'] = 0;
    source['offset'] = 0;
    source['status'] = 'received';
    source['payload'] = root;
    const sources: Object[] = [source];
    const document: Record<string, Object> = {};
    document['format'] = FQ_FANQIE_CAPTURE_FORMAT;
    document['version'] = 2;
    document['createdAt'] = new Date().toISOString();
    document['stopReason'] = '';
    document['sources'] = sources;
    return new FqFanqieCapture(document);
  }
}

/** 最近一次采集持久化（filesDir 单文件，≤16MB）。 */
export class FqFanqieCaptureStore {
  private static readonly FILE_NAME: string = 'fanqie_library_capture.json';

  public static save(context: common.Context, capture: FqFanqieCapture): void {
    const text: string = capture.encode();
    const path: string = `${context.filesDir}/${FqFanqieCaptureStore.FILE_NAME}`;
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

  public static load(context: common.Context): FqFanqieCapture | null {
    const path: string = `${context.filesDir}/${FqFanqieCaptureStore.FILE_NAME}`;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        if (stat.size <= 0 || stat.size > FQ_FANQIE_CAPTURE_MAX_BYTES) {
          return null;
        }
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
        const text: string = decoder.decodeWithStream(new Uint8Array(buffer), { stream: false });
        return FqFanqieCapture.decode(text);
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
}

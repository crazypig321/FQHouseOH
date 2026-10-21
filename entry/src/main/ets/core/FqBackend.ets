/**
 * 后端服务：Rust 核心生命周期 + API 客户端。
 *
 * 移植 fqapp BackendService/RustBackendTransport/ApiClient 的启动链路与
 * 请求语义（部署 → setDevicePoolKey → init → 缓存 baseUrl/capability；
 * GET 合并、并发闸、全局 `fq-N` requestId、20s 超时）。
 * 差异：napi uv 线程池较薄，并发上限 3（Flutter 侧为 16）。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fq, { FqBridgeResponse } from 'libfqapi_napi.so';
import { FqDeployer } from './FqDeployer';
import { FqKeyStore } from './FqKeyStore';
import { fqParseBookDetail, fqParseChapterSummaries, fqParseDirectory, fqParseHomepage, fqParseRankBoard, fqParseRankCatalog, fqParseSearchTabs, fqParseSeriesFeed, fqLegacyChapterText, fqNormalizeChapterText, fqParseNovelChapter } from './FqParser';
import { fqParseObject } from './FqJson';
import {
  FqBookDetail,
  FqChapter,
  FqHomePage,
  FqRankBoard,
  FqRankCatalog,
  FqSearchTab,
} from '../model/FqModels';

const PORT: number = 8080;
const REQUEST_TIMEOUT_MS: number = 20000;
const MAX_CONCURRENCY: number = 3;

export class FqRequestError extends Error {
  readonly statusCode: number;

  constructor(message: string, statusCode: number) {
    super(message);
    this.statusCode = statusCode;
  }
}

export class FqBackend {
  private static readonly instance: FqBackend = new FqBackend();

  private startPromise: Promise<void> | null = null;
  private baseUrlValue: string = '';
  private capabilityValue: string = '';
  private requestIdCounter: number = 0;
  private active: number = 0;
  private waiters: Array<() => void> = [];
  private inflightGet: Map<string, Promise<Record<string, Object>>> = new Map();

  private constructor() {
  }

  public static get(): FqBackend {
    return FqBackend.instance;
  }

  public get baseUrl(): string {
    return this.baseUrlValue;
  }

  public get capability(): string {
    return this.capabilityValue;
  }

  /**
   * 启动后端。幂等：并发/重复调用共享同一次启动；失败后清除缓存，允许重试。
   */
  public start(context: common.Context): Promise<void> {
    if (this.startPromise === null) {
      const attempt: Promise<void> = this.startInternal(context);
      attempt.catch((): void => {
        if (this.startPromise === attempt) {
          this.startPromise = null;
        }
      });
      this.startPromise = attempt;
    }
    return this.startPromise;
  }

  private async startInternal(context: common.Context): Promise<void> {
    const deployer: FqDeployer = new FqDeployer();
    await deployer.deploy(context);
    const backendDir: string = `${context.filesDir}/backend`;
    const poolKey: Uint8Array | null = await FqKeyStore.get().devicePoolKey();
    if (poolKey !== null) {
      fq.setDevicePoolKey(poolKey);
    }
    const result: string = await fq.init(
      `${backendDir}/config/config.json`,
      `${backendDir}/config/device_pool.json`,
      `${backendDir}/config/filter.json`,
      backendDir,
      PORT,
      '',
    );
    if (result !== 'running') {
      throw new Error(`Rust core init failed: ${result}`);
    }
    this.baseUrlValue = await fq.baseUrl();
    this.capabilityValue = await fq.sessionCapability();
  }

  /**
   * 把后端相对资源（/src/...）锚定到带 capability 的 loopback 前缀。
   * 绝对 http(s) URL 原样返回（CDN 签名不可重编码）。
   */
  public resourceUrl(rawPath: string): string {
    if (rawPath.startsWith('http://') || rawPath.startsWith('https://')) {
      return rawPath;
    }
    let path: string = rawPath;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    const capPrefix: string = this.capabilityValue.length > 0
      ? `/_session/${this.capabilityValue}/`
      : '/';
    return `${this.baseUrlValue}${capPrefix}${path}`;
  }

  // ---------------------------------------------------------------------------
  // 请求层
  // ---------------------------------------------------------------------------

  private nextRequestId(): string {
    this.requestIdCounter += 1;
    return `fq-${this.requestIdCounter}`;
  }

  private async acquire<T>(task: () => Promise<T>): Promise<T> {
    while (this.active >= MAX_CONCURRENCY) {
      await new Promise<void>((resolve: () => void) => {
        this.waiters.push(resolve);
      });
    }
    this.active += 1;
    try {
      return await task();
    } finally {
      this.active -= 1;
      const next: (() => void) | undefined = this.waiters.shift();
      if (next !== undefined) {
        next();
      }
    }
  }

  /**
   * GET 并解析 JSON。相同 path+query 的并发请求合并为一次。
   */
  public getJson(path: string, query: string): Promise<Record<string, Object>> {
    const cacheKey: string = `${path}?${query}`;
    const existing: Promise<Record<string, Object>> | undefined = this.inflightGet.get(cacheKey);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<Record<string, Object>> = this.acquire(
      (): Promise<Record<string, Object>> => this.fetchJson(path, query),
    );
    this.inflightGet.set(cacheKey, task);
    task.then(
      (): void => {
        this.inflightGet.delete(cacheKey);
      },
      (): void => {
        this.inflightGet.delete(cacheKey);
      },
    );
    return task;
  }

  private async fetchJson(path: string, query: string): Promise<Record<string, Object>> {
    const requestId: string = this.nextRequestId();
    const resp: FqBridgeResponse = await fq.request(requestId, 'GET', path, query, new Uint8Array(0), REQUEST_TIMEOUT_MS);
    const status: number = resp.status;
    if (status === 499) {
      throw new FqRequestError('请求已取消', 499);
    }
    if (status === 504) {
      throw new FqRequestError('请求超时', 504);
    }
    if (status !== 200) {
      throw new FqRequestError(`后端错误(${status})`, status);
    }
    const text: string = this.decodeText(resp.body);
    const payload: Record<string, Object> | null = fqParseObject(text);
    if (payload === null) {
      throw new FqRequestError('响应不是有效 JSON', status);
    }
    return payload;
  }

  private decodeText(data: ArrayBuffer): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(new Uint8Array(data));
  }

  // ---------------------------------------------------------------------------
  // 业务 API
  // ---------------------------------------------------------------------------

  /** 首页推荐一页（/api/v1/recommend/homepage）。 */
  public async homepagePage(tabType: number, offset: number, sessionId: string): Promise<FqHomePage> {
    let query: string = `tab_type=${tabType}&offset=${offset}`;
    if (sessionId.length > 0) {
      query = `${query}&session_id=${encodeURIComponent(sessionId)}`;
    }
    const payload: Record<string, Object> = await this.getJson('/api/v1/recommend/homepage', query);
    return fqParseHomepage(payload, tabType);
  }

  /**
   * 官方第二段一页（/api/v1/recommend/series-feed，即 bookmall/cell/change）。
   * 短剧（t8）视频流与听书（t5）有声书流的实际分页接口：
   * offset 取上一页 data.next_offset；unlimited_selector_change_type
   * 首屏 2（ChangeFilter）、翻页 1（GetMore）。
   */
  public async seriesFeedPage(tabType: number, cellId: string, offset: number,
    sessionId: string): Promise<FqHomePage> {
    const safeOffset: number = offset < 0 ? 0 : offset;
    let query: string = `cell_id=${encodeURIComponent(cellId)}&tab_type=${tabType}`
      + `&client_template=2&client_req_type=2&offset=${safeOffset}`
      + `&unlimited_selector_change_type=${safeOffset > 0 ? 1 : 2}`;
    if (sessionId.length > 0) {
      query = `${query}&session_id=${encodeURIComponent(sessionId)}`;
    }
    const payload: Record<string, Object> = await this.getJson('/api/v1/recommend/series-feed', query);
    return fqParseSeriesFeed(payload);
  }

  /** 搜索（/api/v1/search，按 tab_type 取分栏）。 */
  public async searchTabs(query: string, tabType: number, offset: number): Promise<FqSearchTab[]> {
    const encoded: string = `query=${encodeURIComponent(query)}&tab_type=${tabType}`
      + `&offset=${offset < 0 ? 0 : offset}&count=10`;
    const payload: Record<string, Object> = await this.getJson('/api/v1/search', encoded);
    return fqParseSearchTabs(payload, tabType);
  }

  /** 旧版搜索（/api/search，页码分页：offset=(page-1)*9）。 */
  public async searchTabsPaged(query: string, page: number): Promise<FqSearchTab[]> {
    const encoded: string = `source=${encodeURIComponent('番茄')}&query=${encodeURIComponent(query)}`
      + `&page=${page < 1 ? 1 : page}`;
    const payload: Record<string, Object> = await this.getJson('/api/search', encoded);
    return fqParseSearchTabs(payload, 0);
  }

  /** 书籍详情（/api/detail）。 */
  public async bookDetail(bookId: string, tab: string): Promise<FqBookDetail> {
    const query: string = `source=${encodeURIComponent('番茄')}&book_id=${encodeURIComponent(bookId)}`
      + `&tab=${encodeURIComponent(tab)}`;
    const payload: Record<string, Object> = await this.getJson('/api/detail', query);
    return fqParseBookDetail(payload);
  }

  /**
   * 排行榜目录（藏于 novel homepage tab_type=2 载荷）。
   */
  public async rankCatalog(): Promise<FqRankCatalog> {
    const payload: Record<string, Object> = await this.getJson('/api/v1/recommend/homepage', 'tab_type=2&offset=0');
    return fqParseRankCatalog(payload);
  }

  /**
   * 榜单一页（/api/v1/rank/{rankId}）。
   * @param algo rank_algo（algo_type）。
   * @param categoryId rank_sub_info_id。
   * @param offset 已加载条数（服务端续拉游标）。
   * @param startAt 第一名的名次（首页 1）。
   */
  public async rankBoard(rankId: string, algo: number, categoryId: number, offset: number,
    startAt: number): Promise<FqRankBoard> {
    let query: string = `algo_type=${algo}&rank_sub_info_id=${categoryId}`;
    if (offset > 0) {
      query = `${query}&offset=${offset}`;
    }
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/rank/${encodeURIComponent(rankId)}`, query);
    return fqParseRankBoard(payload, startAt);
  }

  /** 目录章节（/api/directory，多卷平铺）。 */
  public async directoryChapters(bookId: string, tab: string): Promise<FqChapter[]> {
    const query: string = `source=${encodeURIComponent('番茄')}&book_id=${encodeURIComponent(bookId)}`
      + `&tab=${encodeURIComponent(tab)}`;
    const payload: Record<string, Object> = await this.getJson('/api/directory', query);
    return fqParseDirectory(payload);
  }

  /** 章节试读（/api/v1/books/{id}/chapters/summary）；装饰性数据，失败返回空 Map。 */
  public async chapterSummaries(bookId: string, itemIds: string[]): Promise<Map<string, string>> {
    if (itemIds.length === 0) {
      return new Map();
    }
    try {
      const ids: string = itemIds.map((value: string): string => encodeURIComponent(value)).join(',');
      const payload: Record<string, Object> = await this.getJson(
        `/api/v1/books/${encodeURIComponent(bookId)}/chapters/summary`, `item_ids=${ids}`);
      return fqParseChapterSummaries(payload);
    } catch (error) {
      return new Map();
    }
  }

  /**
   * 章节正文（fqapp chapterContent/contentText 语义）：
   * v1 图文接口（/api/v1/chapters/{id}/novel，后端 DH 解密）优先，
   * 失败/未解密回退旧版 /api/content 文本桥（深度取 content/text 等字段）。
   */
  public async chapterText(itemId: string, chapterTitle: string): Promise<string> {
    try {
      const novelPayload: Record<string, Object> = await this.getJson(
        `/api/v1/chapters/${encodeURIComponent(itemId)}/novel`, '');
      const novelText: string =
        fqNormalizeChapterText(fqParseNovelChapter(novelPayload), chapterTitle);
      if (novelText.trim().length > 0) {
        return novelText;
      }
    } catch (error) {
      // 回退旧版文本桥
    }
    const query: string = `source=${encodeURIComponent('番茄')}&item_id=${encodeURIComponent(itemId)}`
      + `&tab=${encodeURIComponent('小说')}`;
    const payload: Record<string, Object> = await this.getJson('/api/content', query);
    return fqNormalizeChapterText(fqLegacyChapterText(payload), chapterTitle);
  }
}

/** 统一错误文案：FqRequestError 优先，其余退化为字符串。 */
export function fqErrorMessage(error: Object): string {
  if (error instanceof FqRequestError) {
    const message: string = error.message;
    if (message.length > 0) {
      return message;
    }
  }
  const text: string = `${error}`;
  if (text.length > 0 && text !== '[object Object]') {
    return text;
  }
  return '请求失败，请稍后重试';
}

/**
 * 后端服务：Rust 核心生命周期 + API 客户端。
 *
 * 移植 fqapp BackendService/RustBackendTransport/ApiClient 的启动链路与
 * 请求语义（部署 → setDevicePoolKey → init → 缓存 baseUrl/capability；
 * GET 合并、并发闸、全局 `fq-N` requestId、20s/10s 分级超时）。
 * 差异：napi uv 线程池较薄，并发上限 6（Flutter 侧为 16）；
 * 与 Rust 侧 tokio 4 worker 配套，列表页/详情页的多接口并发不再排队。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fq, { FqBridgeResponse } from 'libfqapi_napi.so';
import { FqDeployer } from './FqDeployer';
import { FqKeyStore } from './FqKeyStore';
import {   fqParseAuthorProfile, fqParseBookComments, fqParseBookDetail, fqParseChapterCommentPage, fqParseChapterIdeaCounts, fqParseChapterIdeaMeta, fqParseChapterSummaries,
  fqParseDanmaku, fqParseDirectory, fqParseEpisodeComments, fqParseEpisodeSource, fqParseHomepage, fqParseParagraphCommentPage, fqParseRankBoard, fqParseRankCatalog,
  fqParseSearchTabs, fqParseSeriesFeed, fqParseSeriesRelateBook, fqLegacyChapterText, fqNormalizeChapterText, fqParseNovelChapter,
  fqIsValidMediaId, fqParseMediaIdResult,
  fqParseChapterImages } from './FqParser';
import {
  fqParseAudioToneSet,
  fqParseAudioVoices,
  fqParseLegacyAudioSource,
  fqParsePlayinfoSource,
  fqParseRelatedWorks,
  fqParseSubtitleTrack,
  fqSubtitleUnavailable,
} from './FqAudioParser';
import { fqParseObject } from './FqJson';
import {
  FqAuthorProfile,
  FqBookCommentPage,
  FqBookDetail,
  FqChapter,
  FqChapterIdeaMeta,
  FqDanmakuPage,
  FqEpisodeCommentPage,
  FqEpisodeSource,
  FqEpisodeVariant,
  FqHomePage,
  FqMediaItem,
  FqRankBoard,
  FqRankCatalog,
  FqSearchTab,
  FqSeriesRelateBook,
} from '../model/FqModels';
import { FqParagraphCommentPage } from '../reader/ReaderTypes';
import {
  FqAudioSource,
  FqAudioToneSet,
  FqAudioVoice,
  fqDefaultVoices,
  FqRelatedWork,
  FqSubtitleTrack,
  fqEmptySubtitleTrack,
} from '../model/FqAudioModels';

const PORT: number = 8080;
const REQUEST_TIMEOUT_MS: number = 20000;
/** 短超时（ms）：装饰性数据（失败静默降级）与可回退链路（chapterText v1→legacy）。 */
export const FQ_SHORT_TIMEOUT_MS: number = 10000;
/** rankCatalog 内存 TTL（ms）：每次进排行榜页必拉，短缓存内直接复用。 */
const RANK_CATALOG_TTL_MS: number = 30000;
const MAX_CONCURRENCY: number = 6;

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
  private rankCatalogValue: FqRankCatalog | null = null;
  private rankCatalogCachedAtMs: number = 0;

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
   * 内置 Web UI 入口（对齐 fqapp BackendService.webUiEntryUrl）：
   * loopback 适配器只响应携带 capability 的请求，浏览器打开此入口会以会话
   * cookie 形式下发 capability 后重定向到 /；直接打开裸 baseUrl 会 401。
   */
  public get webUiEntryUrl(): string {
    const capPrefix: string = this.capabilityValue.length > 0
      ? `/_session/${this.capabilityValue}`
      : '';
    return `${this.baseUrlValue}${capPrefix}/`;
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
   * @param timeoutMs 超时（ms）；装饰性/可回退链路传 FQ_SHORT_TIMEOUT_MS。
   */
  public getJson(path: string, query: string,
    timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Record<string, Object>> {
    const cacheKey: string = `${path}?${query}`;
    const existing: Promise<Record<string, Object>> | undefined = this.inflightGet.get(cacheKey);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<Record<string, Object>> = this.acquire(
      (): Promise<Record<string, Object>> => this.fetchJson(path, query, timeoutMs),
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

  private async fetchJson(path: string, query: string,
    timeoutMs: number): Promise<Record<string, Object>> {
    const requestId: string = this.nextRequestId();
    const resp: FqBridgeResponse = await fq.request(requestId, 'GET', path, query, new Uint8Array(0), timeoutMs);
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

  /**
   * 作品 ID 精确查找（fqapp ApiClient.lookupMediaById）：
   * /api/v1/books/{id}/detail 未命中再试 directory；404 继续，其余错误记住并在
   * 两端点都未命中后抛出（源不可用可重试，不能误报「无结果」）。
   */
  public async lookupMediaById(input: string): Promise<FqMediaItem | null> {
    const id: string = input.trim();
    if (!fqIsValidMediaId(id)) {
      throw new FqRequestError('作品 ID 需为 1 至 20 位数字，且不能全为 0', 400);
    }
    let failure: Error | null = null;
    const endpoints: string[] = ['detail', 'directory'];
    for (const endpoint of endpoints) {
      try {
        const payload: Record<string, Object> =
          await this.getJson(`/api/v1/books/${id}/${endpoint}`, '');
        const item: FqMediaItem | null = fqParseMediaIdResult(payload, id);
        if (item !== null) {
          return item;
        }
      } catch (error) {
        if (error instanceof FqRequestError && error.statusCode === 404) {
          continue;
        }
        if (failure === null) {
          failure = error instanceof Error ? error : new Error(fqErrorMessage(error));
        }
      }
    }
    if (failure !== null) {
      throw failure;
    }
    return null;
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

  /** 作者主页 + 全部作品（/api/v1/authors/{id}，作品取自 author_book_info）。 */
  public async authorProfile(authorId: string): Promise<FqAuthorProfile> {
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/authors/${encodeURIComponent(authorId)}`, '');
    return fqParseAuthorProfile(payload);
  }

  /** 书评一页 + 头部计数（/api/v1/books/{id}/comments，count/offset 分页）。
   *  详情页预览传 FQ_SHORT_TIMEOUT_MS；评论面板翻页保持默认 20s。 */
  public async bookComments(bookId: string, count: number, offset: number,
    timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<FqBookCommentPage> {
    const query: string = `count=${count < 1 ? 10 : count}&offset=${offset < 0 ? 0 : offset}`;
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/books/${encodeURIComponent(bookId)}/comments`, query, timeoutMs);
    return fqParseBookComments(payload);
  }

  /**
   * 短剧弹幕一页（/api/v1/videos/{vid}/danmaku，官方 DanmakuRequestHelper）：
   * vid 为当前集 id（group_id），seriesId 进 series_id；时间单位毫秒，cursor 续拉。
   */
  public async videoDanmaku(vid: string, seriesId: string, startOffsetMs: number,
    itemDurationSec: number, cursor: string): Promise<FqDanmakuPage> {
    const query: string = `series_id=${encodeURIComponent(seriesId)}`
      + `&start_offset_time=${startOffsetMs < 0 ? 0 : startOffsetMs}`
      + `&playlet_item_duration=${itemDurationSec < 0 ? 0 : itemDurationSec}`
      + (cursor.length > 0 ? `&cursor=${encodeURIComponent(cursor)}` : '');
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/videos/${encodeURIComponent(vid)}/danmaku`, query, FQ_SHORT_TIMEOUT_MS);
    return fqParseDanmaku(payload);
  }

  /**
   * 短剧当前集评论一页（/api/v1/videos/{vid}/danmaku 全量列表形态：
   * start_offset_time=0 + cursor 续拉，官方每集评论区即弹幕流）；
   * vid 为当前集 id（group_id），seriesId 进 series_id，cursor 为不透明续拉串。
   */
  public async episodeComments(vid: string, seriesId: string,
    cursor: string): Promise<FqEpisodeCommentPage> {
    const query: string = `series_id=${encodeURIComponent(seriesId)}`
      + '&start_offset_time=0&playlet_item_duration=0'
      + (cursor.length > 0 ? `&cursor=${encodeURIComponent(cursor)}` : '');
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/videos/${encodeURIComponent(vid)}/danmaku`, query);
    return fqParseEpisodeComments(payload);
  }

  /**
   * 短剧关联原著（/api/v1/series/{id} 的 data.video_relate_book.book_info，
   * 官方播放页底部 BottomRelateBookView 数据源）。剧无原著关联返回 null；
   * 装饰性数据，异常由调用方静默降级。
   */
  public async seriesRelateBook(seriesId: string): Promise<FqSeriesRelateBook | null> {
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/series/${encodeURIComponent(seriesId)}`, '', FQ_SHORT_TIMEOUT_MS);
    return fqParseSeriesRelateBook(payload);
  }

  /** 章段评气泡计数（/api/v1/chapters/{itemId}/reviews?comment_source=3，data.data 按段 map）；
   *  装饰性数据，失败返回全 0。 */
  public async chapterIdeaCounts(itemId: string, paragraphCount: number): Promise<number[]> {
    try {
      const payload: Record<string, Object> = await this.getJson(
        `/api/v1/chapters/${encodeURIComponent(itemId)}/reviews`, 'comment_source=3', FQ_SHORT_TIMEOUT_MS);
      return fqParseChapterIdeaCounts(payload, paragraphCount);
    } catch (error) {
      const counts: number[] = [];
      for (let index: number = 0; index < paragraphCount; index++) {
        counts.push(0);
      }
      return counts;
    }
  }

  /**
   * 某段段评一页（/api/v1/books/{bookId}/reviews 段评配方，fqapp paragraphComments）：
   * group_id=章节 itemId、group_type=15、server_channel=38（43 官方值恒空、39 仅部分书命中）、
   * item_version 必传（目录 version）；cursor 为上页 common_list_info.cursor 数字串（首页空）。
   */
  public async paragraphComments(bookId: string, itemId: string, itemVersion: string,
    paraIndex: number, count: number, cursor: string): Promise<FqParagraphCommentPage> {
    let query: string = `book_id=${encodeURIComponent(bookId)}`
      + `&group_id=${encodeURIComponent(itemId)}`
      + `&group_type=15&comment_source=2&comment_type=1&server_channel=38`
      + `&para_index=${paraIndex}`
      + `&item_version=${encodeURIComponent(itemVersion)}`
      + `&count=${count < 1 ? 20 : count}`;
    if (cursor.length > 0) {
      query += `&cursor=${encodeURIComponent(cursor)}`;
    }
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/books/${encodeURIComponent(bookId)}/reviews`, query);
    const page: FqParagraphCommentPage = fqParseParagraphCommentPage(payload);
    hilog.info(0x0001, 'FqBackend',
      `paragraphComments ver=${itemVersion} para=${paraIndex} code=${payload['code']} n=${page.comments.length} total=${page.totalCount} more=${page.hasMore}`);
    return page;
  }

  /**
   * 章末章评聚合信息（/api/v1/chapters/{itemId}/reviews?comment_source=3 的
   * 最大段键桶，官方端章评入口；业务码非 0/200 视为无章评，传输错误抛出由调用方处理）。
   */
  public async chapterIdeaMeta(itemId: string): Promise<FqChapterIdeaMeta> {
    const payload: Record<string, Object> = await this.getJson(
      `/api/v1/chapters/${encodeURIComponent(itemId)}/reviews`, 'comment_source=3');
    return fqParseChapterIdeaMeta(payload);
  }

  /**
   * 章评一页（/api/v1/books/{bookId}/reviews 段评配方 + 章末聚合段键 para_index）：
   * group_id=章节 itemId、group_type=15、comment_source=2、comment_type=1、
   * server_channel=38、item_version 必传；cursor 为上页 common_list_info.cursor 数字串。
   */
  public async chapterComments(bookId: string, itemId: string, itemVersion: string,
    paraIndex: number, count: number, cursor: string): Promise<FqBookCommentPage> {
    let query: string = `book_id=${encodeURIComponent(bookId)}`
      + `&group_id=${encodeURIComponent(itemId)}`
      + `&group_type=15&comment_source=2&comment_type=1&server_channel=38`
      + `&para_index=${paraIndex}`
      + `&item_version=${encodeURIComponent(itemVersion)}`
      + `&count=${count < 1 ? 20 : count}`;
    if (cursor.length > 0) {
      query += `&cursor=${encodeURIComponent(cursor)}`;
    }
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/books/${encodeURIComponent(bookId)}/reviews`, query);
    const page: FqBookCommentPage = fqParseChapterCommentPage(payload);
    hilog.info(0x0001, 'FqBackend',
      `chapterComments ver=${itemVersion} para=${paraIndex} code=${payload['code']} n=${page.comments.length} total=${page.totalCount}`);
    return page;
  }

  /**
   * 排行榜目录（藏于 novel homepage tab_type=2 载荷）。
   * 30s 内存 TTL：每次进排行榜页必拉，短缓存内直接复用。
   */
  public async rankCatalog(): Promise<FqRankCatalog> {
    const now: number = Date.now();
    if (this.rankCatalogValue !== null && now - this.rankCatalogCachedAtMs < RANK_CATALOG_TTL_MS) {
      return this.rankCatalogValue;
    }
    const payload: Record<string, Object> = await this.getJson('/api/v1/recommend/homepage', 'tab_type=2&offset=0');
    const catalog: FqRankCatalog = fqParseRankCatalog(payload);
    this.rankCatalogValue = catalog;
    this.rankCatalogCachedAtMs = now;
    return catalog;
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
    const chapters: FqChapter[] = fqParseDirectory(payload);
    let versioned: number = 0;
    for (const chapter of chapters) {
      if (chapter.version.length > 0) {
        versioned++;
      }
    }
    hilog.info(0x0001, 'FqBackend', `directoryChapters n=${chapters.length} versioned=${versioned}`);
    return chapters;
  }

  /**
   * 剧集可播放流（/api/content，ohos 不带 mode → 后端 c1 整集下载解密后
   * loopback /src/ Range 供流，mpv 拉明文无需 key_hex 解密）。
   * quality 为用户选定的清晰度档名（空 = 默认最高档）：后端命中 variants
   * 档时按该档取流，并以 quality 回显实际起播档。
   * 相对路径由 resourceUrl 锚定；锚定后仍非 http(s) 视为失败。
   */
  public async episodeSource(itemId: string, tab: string, quality: string = ''): Promise<FqEpisodeSource> {
    let query: string = `source=${encodeURIComponent('番茄')}&item_id=${encodeURIComponent(itemId)}`
      + `&tab=${encodeURIComponent(tab)}`;
    if (quality.length > 0) {
      query = `${query}&quality=${encodeURIComponent(quality)}`;
    }
    const payload: Record<string, Object> = await this.getJson('/api/content', query);
    const source: FqEpisodeSource = fqParseEpisodeSource(payload);
    const url: string = this.resourceUrl(source.url);
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw new Error('获取播放地址失败');
    }
    const variants: FqEpisodeVariant[] = [];
    for (const variant of source.variants) {
      const variantUrl: string = this.resourceUrl(variant.url);
      if (variantUrl.startsWith('http://') || variantUrl.startsWith('https://')) {
        variants.push(new FqEpisodeVariant(variant.name, variantUrl, variant.keyHex, variant.height));
      }
    }
    return new FqEpisodeSource(url, source.keyHex, variants, source.quality);
  }

  /** 章节试读（/api/v1/books/{id}/chapters/summary）；装饰性数据，失败返回空 Map。 */
  public async chapterSummaries(bookId: string, itemIds: string[]): Promise<Map<string, string>> {
    if (itemIds.length === 0) {
      return new Map();
    }
    try {
      const ids: string = itemIds.map((value: string): string => encodeURIComponent(value)).join(',');
      const payload: Record<string, Object> = await this.getJson(
        `/api/v1/books/${encodeURIComponent(bookId)}/chapters/summary`, `item_ids=${ids}`,
        FQ_SHORT_TIMEOUT_MS);
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
        `/api/v1/chapters/${encodeURIComponent(itemId)}/novel`, '', FQ_SHORT_TIMEOUT_MS);
      const rawNovel: string = fqParseNovelChapter(novelPayload);
      const novelText: string = fqNormalizeChapterText(rawNovel, chapterTitle);
      if (novelText.trim().length > 0) {
        return novelText;
      }
    } catch (error) {
      // 回退旧版文本桥
    }
    const query: string = `source=${encodeURIComponent('番茄')}&item_id=${encodeURIComponent(itemId)}`
      + `&tab=${encodeURIComponent('小说')}`;
    const payload: Record<string, Object> = await this.getJson('/api/content', query);
    const legacyText: string = fqNormalizeChapterText(fqLegacyChapterText(payload), chapterTitle);
    return legacyText;
  }

  // ---------------------------------------------------------------------------
  // 听书 API
  // ---------------------------------------------------------------------------

  /**
   * 漫画章节图片（/api/content?tab=漫画&cmd=1，对齐 comic.html）：
   * data.images 数组或 content/images 字符串（base64 解码后 <img> 抽取）。
   * 相对路径由 resourceUrl 锚定；锚定后仍非 http(s) 的条目丢弃。
   */
  public async chapterImages(itemId: string): Promise<string[]> {
    const query: string = `source=${encodeURIComponent('番茄')}&item_id=${encodeURIComponent(itemId)}`
      + `&tab=${encodeURIComponent('漫画')}&cmd=1`;
    const payload: Record<string, Object> = await this.getJson('/api/content', query);
    const rawImages: string[] = fqParseChapterImages(payload);
    const images: string[] = [];
    for (const raw of rawImages) {
      const url: string = this.resourceUrl(raw.trim());
      if (url.startsWith('http://') || url.startsWith('https://')) {
        images.push(url);
      }
    }
    if (images.length === 0) {
      throw new Error('未获取到漫画图片');
    }
    return images;
  }

  /**
   * 章节可播放流（/reading/reader/audio/playinfo 桥）。
   * OH 恒带 mode=download：后端整章下载解密，地址改写为 /src/ 相对路径，
   * 由 resourceUrl 锚定（avPlayer 解不了 CENC 密文）。
   * 上游业务错误（NO_THIS_TONE 等）原样抛出，由会话层做音色回退。
   */
  public async audioChapterSource(bookId: string, chapterId: string,
    toneId: string): Promise<FqAudioSource> {
    const tone: string = toneId.trim().length > 0 ? toneId.trim() : '0';
    const path: string = `/api/v1/audio/books/${encodeURIComponent(bookId)}`
      + `/chapters/${encodeURIComponent(chapterId)}`;
    const payload: Record<string, Object> =
      await this.getJson(path, `tone_id=${encodeURIComponent(tone)}&mode=download`);
    let source: FqAudioSource;
    try {
      source = fqParsePlayinfoSource(payload, chapterId, tone);
    } catch (error) {
      const message: string = error instanceof Error ? error.message : `${error}`;
      // 只有「形状对不上」才回退 legacy mget；业务错误（NO_THIS_TONE 等）必须透传
      if (!message.includes('未获取到音频地址')) {
        throw new Error(message);
      }
      source = fqParseLegacyAudioSource(payload, chapterId, tone);
    }
    return new FqAudioSource(source.itemId, this.resourceUrl(source.url), source.toneId,
      source.durationSec);
  }

  /** 音色表（智能朗读 tts + 真人讲书）。 */
  public async audioTones(bookId: string): Promise<FqAudioToneSet> {
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/books/${encodeURIComponent(bookId)}/tones`, '');
    return fqParseAudioToneSet(payload);
  }

  /**
   * 小说 detail 的 tones CSV voices（fqapp ApiClient.audioVoices）：
   * /tones 无 tts 音色时智能朗读面板的回退数据源。失败退默认音色。
   */
  public async audioVoices(bookId: string): Promise<FqAudioVoice[]> {
    try {
      const query: string = `source=${encodeURIComponent('番茄')}`
        + `&book_id=${encodeURIComponent(bookId)}&tab=${encodeURIComponent('小说')}`;
      const payload: Record<string, Object> = await this.getJson('/api/detail', query, FQ_SHORT_TIMEOUT_MS);
      return fqParseAudioVoices(payload);
    } catch (error) {
      return fqDefaultVoices();
    }
  }

  /** 相关作品（原著小说 / 改编短剧）。 */
  public async relatedWorks(bookId: string): Promise<FqRelatedWork[]> {
    const payload: Record<string, Object> =
      await this.getJson(`/api/v1/books/${encodeURIComponent(bookId)}/related`, '', FQ_SHORT_TIMEOUT_MS);
    return fqParseRelatedWorks(payload);
  }

  /**
   * 边听边读字幕（speech-text 桥）。装饰性数据：
   * 业务错误（1301008 无字幕）与请求失败一律退空轨，不阻塞播放。
   */
  public async chapterTimeline(itemId: string, toneId: string): Promise<FqSubtitleTrack> {
    const tone: string = toneId.trim().length > 0 ? toneId.trim() : '1';
    try {
      const payload: Record<string, Object> = await this.getJson(
        `/api/v1/chapters/${encodeURIComponent(itemId)}/timeline`,
        `genre=1&tone_id=${encodeURIComponent(tone)}`, FQ_SHORT_TIMEOUT_MS);
      if (fqSubtitleUnavailable(payload)) {
        return fqEmptySubtitleTrack();
      }
      return fqParseSubtitleTrack(payload);
    } catch (error) {
      return fqEmptySubtitleTrack();
    }
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

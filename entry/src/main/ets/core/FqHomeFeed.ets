/**
 * 主页多源频道流控制器。
 *
 * 对齐 fqapp lib/features/home/home_provider.dart 的 6 频道语义：
 * - homepage 源：/api/v1/recommend/homepage（tab_type 频道，next_offset/session_id 游标）。
 *   听书（t5）/短剧（t8）的 tab 游标是装饰性的，内容分页走官方第二段
 *   /api/v1/recommend/series-feed（cell/change，fqapp `homepagePage` 两段语义）。
 *   游标停走（fqapp recommendExhausted）或请求失败时转入 search 兜底续页
 *   （fqapp `_loadInitial`/`_loadNext` 的 `_searchByType` 语义）。
 * - v1 search 源：/api/v1/search 分栏（漫画/漫剧，next_offset 游标）。
 * - 旧版 paged search 兜底：/api/search 页码分页（小说/短剧/听书），
 *   hasMore = 本页有匹配条目（fqapp `_searchProgress` 非 漫画/漫剧 分支）。
 * - forceKind 对齐 fqapp `_forceKind`：homepage 阶段剔除异类并强制 kind；
 *   search 阶段按 fqapp `_searchItems` 过滤 kind。
 */

import { FqBackend, FqRequestError, fqErrorMessage } from './FqBackend';
import { FqHomePage, FqMediaItem, FqSearchTab } from '../model/FqModels';

export const FQ_SOURCE_HOMEPAGE: number = 0;
export const FQ_SOURCE_SEARCH: number = 1;
export const FQ_SOURCE_SEARCH_PAGED: number = 2;

/**
 * 走官方第二段（series-feed/cell/change）分页的 homepage 频道。
 * 听书（5）/短剧（8）的 tab 游标是装饰性的（offset 翻页一律 101116），
 * 真实分页由 cell 内容接口承载。
 */
const FQ_SERIES_FLOW_TABS: number[] = [5, 8];

/** 单个推荐源及其游标状态（含 search 兜底阶段配置）。 */
export class FqHomeSource {
  /** 初始阶段（reset 回退目标）。 */
  readonly primaryMode: number;
  readonly primaryTabType: number;
  readonly primaryQuery: string;
  /** 目标内容类型：homepage 阶段强制映射，search 阶段按此过滤。 */
  readonly forcedKind: string;
  /** 兜底阶段模式；-1 表示无兜底。 */
  readonly fallbackMode: number;
  readonly fallbackQuery: string;
  readonly fallbackTabType: number;
  /** 当前阶段。 */
  mode: number;
  tabType: number;
  query: string;
  offset: number;
  /** paged 兜底阶段：下一次请求页码。 */
  page: number;
  sessionId: string;
  /** 官方第二段 cell（cell_id_str）；跨刷新缓存（fqapp `_seriesCellIds` 语义）。 */
  cellId: string;
  hasMore: boolean;
  loaded: boolean;

  constructor(mode: number, tabType: number, query: string, forcedKind: string,
    fallbackMode: number, fallbackQuery: string, fallbackTabType: number) {
    this.primaryMode = mode;
    this.primaryTabType = tabType;
    this.primaryQuery = query;
    this.forcedKind = forcedKind;
    this.fallbackMode = fallbackMode;
    this.fallbackQuery = fallbackQuery;
    this.fallbackTabType = fallbackTabType;
    this.mode = mode;
    this.tabType = tabType;
    this.query = query;
    this.offset = 0;
    this.page = 1;
    this.sessionId = '';
    this.cellId = '';
    this.hasMore = true;
    this.loaded = false;
  }

  public static homepage(tabType: number, forcedKind: string): FqHomeSource {
    return new FqHomeSource(FQ_SOURCE_HOMEPAGE, tabType, '', forcedKind, -1, '', 0);
  }

  /** homepage 推荐 + search 兜底：推荐游标停走后由 search 续页。 */
  public static homepageFallback(tabType: number, forcedKind: string,
    fallbackMode: number, fallbackQuery: string, fallbackTabType: number): FqHomeSource {
    return new FqHomeSource(FQ_SOURCE_HOMEPAGE, tabType, '', forcedKind,
      fallbackMode, fallbackQuery, fallbackTabType);
  }

  public static search(query: string, tabType: number, forcedKind: string): FqHomeSource {
    return new FqHomeSource(FQ_SOURCE_SEARCH, tabType, query, forcedKind, -1, '', 0);
  }

  /** 回到初始阶段（loadFirst/restore 前调用）。 */
  public reset(): void {
    this.mode = this.primaryMode;
    this.tabType = this.primaryTabType;
    this.query = this.primaryQuery;
    this.offset = 0;
    this.page = 1;
    this.sessionId = '';
    this.hasMore = true;
    this.loaded = false;
  }
}

/** 一个频道的聚合流：多源加载、交错合并、去重。 */
export class FqHomeFeed {
  private readonly sources: FqHomeSource[];
  private merged: FqMediaItem[] = [];
  private seen: Set<string> = new Set<string>();
  private exhausted: boolean = false;
  private pendingErrorMessage: string = '';

  constructor(sources: FqHomeSource[]) {
    this.sources = sources;
  }

  /** 由持久化缓存条目构建（冷启动秒显用）：直接填充 merged，无游标、不可翻页。 */
  public static fromCached(items: FqMediaItem[]): FqHomeFeed {
    const feed: FqHomeFeed = new FqHomeFeed([]);
    feed.merged = items;
    const seen: Set<string> = new Set<string>();
    for (const item of items) {
      seen.add(item.id);
    }
    feed.seen = seen;
    feed.exhausted = true;
    return feed;
  }

  /** 当前全量条目（前 3 项供焦点轮播，其余供网格）。 */
  public items(): FqMediaItem[] {
    return this.merged;
  }

  public totalCount(): number {
    return this.merged.length;
  }

  public get hasMore(): boolean {
    if (this.exhausted) {
      return false;
    }
    for (const source of this.sources) {
      if (source.hasMore) {
        return true;
      }
    }
    return false;
  }

  /** 首屏：各源并发首页；全败抛首个错误，部分失败降级继续。 */
  public async loadFirst(): Promise<void> {
    this.merged = [];
    this.seen.clear();
    this.exhausted = false;
    this.pendingErrorMessage = '';

    const groups: FqMediaItem[][] = [];
    const tasks: Promise<boolean>[] = [];
    for (const source of this.sources) {
      source.reset();
      tasks.push(this.loadSourceSafe(source, groups));
    }
    const results: boolean[] = await Promise.all(tasks);
    this.mergeGroups(groups);

    let succeeded: number = 0;
    for (const ok of results) {
      if (ok) {
        succeeded += 1;
      }
    }
    if (this.sources.length > 0 && succeeded === 0 && this.pendingErrorMessage.length > 0) {
      throw new FqRequestError(this.pendingErrorMessage, 0);
    }
    this.pendingErrorMessage = '';
  }

  /** 翻页：对仍有游标且已加载过的源并发下一页并追加。 */
  public async loadMore(): Promise<void> {
    if (this.exhausted) {
      return;
    }
    const active: FqHomeSource[] = [];
    for (const source of this.sources) {
      if (source.loaded && source.hasMore) {
        active.push(source);
      }
    }
    if (active.length === 0) {
      this.exhausted = true;
      return;
    }
    const groups: FqMediaItem[][] = [];
    const tasks: Promise<boolean>[] = [];
    for (const source of active) {
      tasks.push(this.loadSourceSafe(source, groups));
    }
    await Promise.all(tasks);
    const added: number = this.mergeGroups(groups);
    // fqapp `_applyFetched`：整页重复且各源均无游标时才收尾；
    // 兜底阶段已武装/游标仍在推进时继续等待下次触底。
    if (added === 0 && !this.hasMore) {
      this.exhausted = true;
    }
  }

  private async loadSourceSafe(source: FqHomeSource, groups: FqMediaItem[][]): Promise<boolean> {
    try {
      const items: FqMediaItem[] = await this.loadSource(source);
      source.loaded = true;
      if (items.length > 0) {
        groups.push(items);
      }
      return true;
    } catch (error) {
      source.loaded = true;
      source.hasMore = false;
      if (this.pendingErrorMessage.length === 0) {
        this.pendingErrorMessage = fqErrorMessage(error);
      }
      return false;
    }
  }

  private async loadSource(source: FqHomeSource): Promise<FqMediaItem[]> {
    if (source.mode === FQ_SOURCE_HOMEPAGE) {
      let items: FqMediaItem[] = [];
      let failed: boolean = false;
      try {
        items = await this.loadHomepageStage(source);
      } catch (error) {
        if (source.fallbackMode < 0) {
          throw new FqRequestError(fqErrorMessage(error), 0);
        }
        // 推荐接口故障不应让整个频道停摆（fqapp：fall through to search）。
        failed = true;
        this.enterFallback(source);
      }
      if (!failed && (items.length > 0 || source.mode === FQ_SOURCE_HOMEPAGE)) {
        return items;
      }
      // 空页且无游标：立即请求 search 兜底首页（fqapp `_loadInitial` 同语义）。
    }
    if (source.mode === FQ_SOURCE_SEARCH_PAGED) {
      return await this.loadPagedStage(source);
    }
    return await this.loadCursorStage(source);
  }

  /**
   * homepage 推荐阶段（fqapp `homepagePage` 两段语义）：
   * - series-flow 频道（t5/t8）：第一段只负责开 cell（cell_id_str + session），
   *   内容翻页走官方第二段 series-feed（cell/change）；已知 cell 的翻页直接打第二段。
   * - 其余频道：tab 游标推进，游标停走转入 search 兜底（fqapp recommendExhausted）。
   */
  private async loadHomepageStage(source: FqHomeSource): Promise<FqMediaItem[]> {
    const backend: FqBackend = FqBackend.get();
    const seriesFlow: boolean = FQ_SERIES_FLOW_TABS.indexOf(source.tabType) >= 0;
    // 已知 cell 的翻页：第二段游标与第一段不是一回事，直接打第二段。
    if (seriesFlow && source.offset > 0 && source.cellId.length > 0) {
      const flow: FqHomePage = await backend.seriesFeedPage(
        source.tabType, source.cellId, source.offset, source.sessionId);
      if (flow.items.length > 0) {
        this.advanceSeriesCursor(source, flow);
        return this.applyForcedKind(flow.items, source.forcedKind);
      }
      // 第二段空页：退回第一段结果。
    }
    const page: FqHomePage = await backend.homepagePage(source.tabType, source.offset, source.sessionId);
    const items: FqMediaItem[] = this.applyForcedKind(page.items, source.forcedKind);
    if (!seriesFlow) {
      if (page.nextOffset > 0) {
        source.offset = page.nextOffset;
        if (page.sessionId.length > 0) {
          source.sessionId = page.sessionId;
        }
      } else {
        this.enterFallback(source);
      }
      return items;
    }
    // series-flow：第一段成功且尚未用当前参数试过第二段时，提取 cell 走第二段
    //（fqapp：`flow ?? tab.page`，第二段结果整体替换第一段）。
    if (!(source.offset > 0 && source.cellId.length > 0)) {
      const cellId: string = page.cellId.length > 0 ? page.cellId : source.cellId;
      if (cellId.length > 0) {
        source.cellId = cellId;
        const sessionId: string = source.sessionId.length > 0 ? source.sessionId : page.sessionId;
        const flow: FqHomePage =
          await backend.seriesFeedPage(source.tabType, cellId, source.offset, sessionId);
        if (flow.items.length > 0) {
          this.advanceSeriesCursor(source, flow);
          return this.applyForcedKind(flow.items, source.forcedKind);
        }
      }
    }
    if (page.nextOffset > 0) {
      source.offset = page.nextOffset;
      if (page.sessionId.length > 0) {
        source.sessionId = page.sessionId;
      }
    } else {
      this.enterFallback(source);
    }
    return items;
  }

  /** 第二段游标推进；游标停走（≤当前 offset）视为推荐流走完，转入 search 兜底。 */
  private advanceSeriesCursor(source: FqHomeSource, flow: FqHomePage): void {
    if (flow.nextOffset > 0 && flow.nextOffset > source.offset) {
      source.offset = flow.nextOffset;
      if (flow.sessionId.length > 0) {
        source.sessionId = flow.sessionId;
      }
    } else {
      this.enterFallback(source);
    }
  }

  /** 旧版 /api/search 页码阶段：hasMore = 本页有匹配条目（fqapp `_searchProgress` 非 漫画/漫剧 分支）。 */
  private async loadPagedStage(source: FqHomeSource): Promise<FqMediaItem[]> {
    const backend: FqBackend = FqBackend.get();
    const tabs: FqSearchTab[] = await backend.searchTabsPaged(source.query, source.page);
    const items: FqMediaItem[] = this.searchStageItems(tabs, source.query, source.forcedKind);
    source.hasMore = items.length > 0;
    source.page += 1;
    return items;
  }

  /** v1 /api/v1/search 游标阶段（漫画/漫剧）。 */
  private async loadCursorStage(source: FqHomeSource): Promise<FqMediaItem[]> {
    const backend: FqBackend = FqBackend.get();
    const tabs: FqSearchTab[] = await backend.searchTabs(source.query, source.tabType, source.offset);
    let matched: FqSearchTab | null = null;
    for (const tab of tabs) {
      if (tab.title === source.query) {
        matched = tab;
        break;
      }
    }
    if (matched === null) {
      source.hasMore = false;
      return [];
    }
    const items: FqMediaItem[] = this.filterByKind(matched.items, source.forcedKind);
    if (matched.hasMore !== false && matched.nextOffset > source.offset) {
      source.offset = matched.nextOffset;
    } else {
      source.hasMore = false;
    }
    return items;
  }

  /** 转入 search 兜底阶段；无兜底则收尾。 */
  private enterFallback(source: FqHomeSource): void {
    if (source.fallbackMode < 0) {
      source.hasMore = false;
      return;
    }
    source.mode = source.fallbackMode;
    source.query = source.fallbackQuery;
    source.tabType = source.fallbackTabType;
    source.offset = 0;
    source.page = 1;
  }

  /** fqapp `_searchItems`：标题互含匹配（无匹配取全部分栏），按 kind 过滤。 */
  private searchStageItems(tabs: FqSearchTab[], label: string, kind: string): FqMediaItem[] {
    const matching: FqSearchTab[] = [];
    for (const tab of tabs) {
      if (tab.title.length > 0 && (tab.title.includes(label) || label.includes(tab.title))) {
        matching.push(tab);
      }
    }
    const selected: FqSearchTab[] = matching.length > 0 ? matching : tabs;
    const out: FqMediaItem[] = [];
    for (const tab of selected) {
      for (const item of tab.items) {
        if (item.kind === kind) {
          out.push(item);
        }
      }
    }
    return out;
  }

  private filterByKind(items: FqMediaItem[], kind: string): FqMediaItem[] {
    const out: FqMediaItem[] = [];
    for (const item of items) {
      if (item.kind === kind) {
        out.push(item);
      }
    }
    return out;
  }

  /** fqapp `_forceKind`：目标非 manju 时剔除 manju 项，其余强制 kind。 */
  private applyForcedKind(items: FqMediaItem[], forcedKind: string): FqMediaItem[] {
    if (forcedKind.length === 0) {
      return items;
    }
    const out: FqMediaItem[] = [];
    for (const item of items) {
      if (forcedKind !== 'manju' && item.kind === 'manju') {
        continue;
      }
      if (item.kind === forcedKind) {
        out.push(item);
        continue;
      }
      out.push(new FqMediaItem(
        item.id,
        item.title,
        item.cover,
        item.author,
        item.badge,
        item.ep,
        forcedKind,
        item.score,
        item.intro,
        item.seriesId,
        item.episodeId,
        item.followerCount,
      ));
    }
    return out;
  }

  /** fqapp `_interleave`：按索引轮询拼接各组。 */
  private interleave(groups: FqMediaItem[][]): FqMediaItem[] {
    const out: FqMediaItem[] = [];
    let index: number = 0;
    let remaining: boolean = true;
    while (remaining) {
      remaining = false;
      for (const group of groups) {
        if (index < group.length) {
          out.push(group[index]);
          remaining = true;
        }
      }
      index += 1;
    }
    return out;
  }

  /** 交错合并并入全量数组（'kind:id' 去重），返回新增条数。 */
  private mergeGroups(groups: FqMediaItem[][]): number {
    const interleaved: FqMediaItem[] = this.interleave(groups);
    let added: number = 0;
    for (const item of interleaved) {
      if (item.id.length === 0) {
        continue;
      }
      const key: string = `${item.kind}:${item.id}`;
      if (this.seen.has(key)) {
        continue;
      }
      this.seen.add(key);
      this.merged.push(item);
      added += 1;
    }
    return added;
  }
}

/** 3 列封面网格的行数据源：一行 = slice(startSkip + row*3, +3)。 */
export class FqHomeRowDataSource implements IDataSource {
  private items: FqMediaItem[] = [];
  private readonly startSkip: number;
  private listeners: DataChangeListener[] = [];

  constructor(startSkip: number) {
    this.startSkip = startSkip;
  }

  totalCount(): number {
    return Math.max(0, this.items.length - this.startSkip);
  }

  getData(index: number): FqMediaItem {
    return this.items[this.startSkip + index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 整体替换（首屏/切换频道）。 */
  setItems(items: FqMediaItem[]): void {
    this.items = items;
    this.notifyReload();
  }

  private notifyReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

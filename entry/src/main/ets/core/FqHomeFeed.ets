/**
 * 主页多源频道流控制器。
 *
 * 对齐 fqapp lib/features/home/home_provider.dart 的 6 频道语义，
 * 简化为「每源独立游标 + 轮询交错合并」：
 * - homepage 源：/api/v1/recommend/homepage（tab_type 频道，next_offset/session_id 游标）。
 * - search 源：/api/v1/search 分栏（漫画频道分页，next_offset 游标）。
 * - forceKind 对齐 fqapp `_forceKind`：非 manju 目标剔除 manju 项，其余强制 kind。
 */

import { FqBackend, FqRequestError, fqErrorMessage } from './FqBackend';
import { FqHomePage, FqMediaItem, FqSearchTab } from '../model/FqModels';

export const FQ_SOURCE_HOMEPAGE: number = 0;
export const FQ_SOURCE_SEARCH: number = 1;

/** 单个推荐源及其游标状态。 */
export class FqHomeSource {
  readonly mode: number;
  readonly tabType: number;
  readonly query: string;
  readonly forcedKind: string;
  offset: number;
  sessionId: string;
  hasMore: boolean;
  loaded: boolean;

  constructor(mode: number, tabType: number, query: string, forcedKind: string) {
    this.mode = mode;
    this.tabType = tabType;
    this.query = query;
    this.forcedKind = forcedKind;
    this.offset = 0;
    this.sessionId = '';
    this.hasMore = true;
    this.loaded = false;
  }

  public static homepage(tabType: number, forcedKind: string): FqHomeSource {
    return new FqHomeSource(FQ_SOURCE_HOMEPAGE, tabType, '', forcedKind);
  }

  public static search(query: string, tabType: number, forcedKind: string): FqHomeSource {
    return new FqHomeSource(FQ_SOURCE_SEARCH, tabType, query, forcedKind);
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

  /** 从磁盘缓存恢复条目：无翻页游标，标记 exhausted，等待下次刷新重置。 */
  public restore(items: FqMediaItem[]): void {
    this.merged = [];
    this.seen.clear();
    this.exhausted = true;
    this.pendingErrorMessage = '';
    for (const item of items) {
      const key: string = `${item.kind}:${item.id}`;
      this.seen.add(key);
      this.merged.push(item);
    }
    for (const source of this.sources) {
      source.loaded = false;
      source.hasMore = false;
    }
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
      source.offset = 0;
      source.sessionId = '';
      source.hasMore = true;
      source.loaded = false;
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
    if (added === 0) {
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
    const backend: FqBackend = FqBackend.get();
    if (source.mode === FQ_SOURCE_SEARCH) {
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
      const items: FqMediaItem[] = this.applyForcedKind(matched.items, source.forcedKind);
      if (matched.hasMore !== false && matched.nextOffset > source.offset) {
        source.offset = matched.nextOffset;
      } else {
        source.hasMore = false;
      }
      return items;
    }
    const page: FqHomePage = await backend.homepagePage(source.tabType, source.offset, source.sessionId);
    const items: FqMediaItem[] = this.applyForcedKind(page.items, source.forcedKind);
    if (page.nextOffset > 0) {
      source.offset = page.nextOffset;
      if (page.sessionId.length > 0) {
        source.sessionId = page.sessionId;
      }
    } else {
      source.hasMore = false;
    }
    return items;
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
  private readonly columns: number;
  private listeners: DataChangeListener[] = [];

  constructor(startSkip: number, columns: number) {
    this.startSkip = startSkip;
    this.columns = columns;
  }

  totalCount(): number {
    const usable: number = Math.max(0, this.items.length - this.startSkip);
    return Math.ceil(usable / this.columns);
  }

  getData(index: number): FqMediaItem[] {
    const from: number = this.startSkip + index * this.columns;
    const to: number = Math.min(this.items.length, from + this.columns);
    return this.items.slice(from, to);
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

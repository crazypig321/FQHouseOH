/**
 * 阅读时长统计（书架页「今日已读 N 分钟」+「我的」页阅读与视听统计）。
 *
 * 双层累计（键均为本地日期 'yyyy-M-d'，单位秒）：
 * - 全局日累计 days（书架今日已读、我的页概览/热力图/每日记录）；
 * - 按书 bookId → { 日期: 秒 }（我的页最近阅读/阅读排行；对齐 fqapp
 *   LibraryStore.readTimeSnapshot 语义）。
 * 累计来源：阅读页/漫画页 30s 心跳、听书会话播放中每 5s、视频页播放中每 15s。
 * preferences 持久化（days / books 两个 key）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqNum, fqParseObject, fqStr } from './FqJson';

const FQ_READ_STATS_NAME: string = 'fq_read_stats';
const FQ_READ_STATS_KEY: string = 'days';
const FQ_READ_BOOKS_KEY: string = 'books';
const FQ_READ_META_KEY: string = 'books_meta';

/** 书目元数据（阅读/视听计时时随手记录；最近阅读/阅读排行无浏览记录时回填显示用）。 */
export class FqStatsBookMeta {
  public readonly kind: string;
  public readonly title: string;
  public readonly cover: string;

  constructor(kind: string, title: string, cover: string) {
    this.kind = kind;
    this.title = title;
    this.cover = cover;
  }
}

export class FqReadStatsStore {
  private static pref: preferences.Preferences | null = null;
  private static days: Map<string, number> = new Map<string, number>();
  /** bookId → { 'yyyy-M-d': 秒 }（按书日累计）。 */
  private static books: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  /** bookId → 书目元数据（kind/title/cover）。 */
  private static metas: Map<string, FqStatsBookMeta> = new Map<string, FqStatsBookMeta>();

  public static init(context: common.Context): void {
    if (FqReadStatsStore.pref !== null) {
      return;
    }
    try {
      FqReadStatsStore.pref = preferences.getPreferencesSync(context, { name: FQ_READ_STATS_NAME });
    } catch (error) {
      FqReadStatsStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqReadStatsStore.pref.getSync(FQ_READ_STATS_KEY, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length > 0) {
      const rec: Record<string, Object> | null = fqParseObject(text);
      if (rec !== null) {
        const keys: string[] = Object.keys(rec);
        for (const key of keys) {
          FqReadStatsStore.days.set(key, fqNum(rec, key));
        }
      }
    }
    FqReadStatsStore.loadBooks();
    FqReadStatsStore.loadMetas();
  }

  /** 未初始化时静默跳过（调用方遍布播放/阅读心跳，不可因未初始化抛错）。 */
  public static addSeconds(seconds: number): void {
    if (seconds <= 0) {
      return;
    }
    const key: string = FqReadStatsStore.todayKey();
    const current: number = FqReadStatsStore.days.get(key) ?? 0;
    FqReadStatsStore.days.set(key, current + seconds);
    FqReadStatsStore.persist();
  }

  /** 按书累计（全局日累计 + 按书日累计 + 可选书目元数据记录；bookId 空退化为仅全局累计）。 */
  public static addBookSeconds(bookId: string, seconds: number,
    kind?: string, title?: string, cover?: string): void {
    if (seconds <= 0) {
      return;
    }
    if (bookId.length === 0) {
      FqReadStatsStore.addSeconds(seconds);
      return;
    }
    const key: string = FqReadStatsStore.todayKey();
    FqReadStatsStore.days.set(key, (FqReadStatsStore.days.get(key) ?? 0) + seconds);
    let bookDays: Map<string, number> | undefined = FqReadStatsStore.books.get(bookId);
    if (bookDays === undefined) {
      bookDays = new Map<string, number>();
      FqReadStatsStore.books.set(bookId, bookDays);
    }
    bookDays.set(key, (bookDays.get(key) ?? 0) + seconds);
    FqReadStatsStore.noteBookMeta(bookId, kind, title, cover);
    FqReadStatsStore.persist();
  }

  /** 今日累计阅读分钟数（向下取整）。 */
  public static todayMinutes(): number {
    const seconds: number = FqReadStatsStore.days.get(FqReadStatsStore.todayKey()) ?? 0;
    return Math.floor(seconds / 60);
  }

  /** 全局日累计（'yyyy-M-d' → 秒；统计页概览/热力图/每日记录数据源）。 */
  public static allDays(): Map<string, number> {
    return FqReadStatsStore.days;
  }

  /** 按书日累计（bookId → { 'yyyy-M-d': 秒 }；最近阅读/阅读排行数据源）。 */
  public static bookDays(): Map<string, Map<string, number>> {
    return FqReadStatsStore.books;
  }

  /** 书目元数据（bookId → kind/title/cover；最近阅读/阅读排行回填显示用，无记录返回 null）。 */
  public static bookMeta(bookId: string): FqStatsBookMeta | null {
    return FqReadStatsStore.metas.get(bookId) ?? null;
  }

  /** 批量删除按书累计（阅读排行编辑模式多选删除；全局日累计与其余书不受影响）。 */
  public static removeBooks(bookIds: string[]): void {
    if (bookIds.length === 0) {
      return;
    }
    let changed: boolean = false;
    for (const bookId of bookIds) {
      if (FqReadStatsStore.books.delete(bookId)) {
        changed = true;
      }
      if (FqReadStatsStore.metas.delete(bookId)) {
        changed = true;
      }
    }
    if (changed) {
      FqReadStatsStore.persist();
    }
  }

  /** 清空全部阅读统计（设置-清空历史）。 */
  public static clear(): void {
    FqReadStatsStore.days.clear();
    FqReadStatsStore.books.clear();
    FqReadStatsStore.metas.clear();
    FqReadStatsStore.persist();
  }

  /** 加载按书日累计（books key：bookId → JSON 字符串 { 日期: 秒 }）。 */
  private static loadBooks(): void {
    const pref: preferences.Preferences | null = FqReadStatsStore.pref;
    if (pref === null) {
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_READ_BOOKS_KEY, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    const rec: Record<string, Object> | null = fqParseObject(text);
    if (rec === null) {
      return;
    }
    const bookIds: string[] = Object.keys(rec);
    for (const bookId of bookIds) {
      const daysText: string = fqStr(rec, bookId);
      if (daysText.length === 0) {
        continue;
      }
      const daysRec: Record<string, Object> | null = fqParseObject(daysText);
      if (daysRec === null) {
        continue;
      }
      const dayMap: Map<string, number> = new Map<string, number>();
      const dayKeys: string[] = Object.keys(daysRec);
      for (const day of dayKeys) {
        dayMap.set(day, fqNum(daysRec, day));
      }
      FqReadStatsStore.books.set(bookId, dayMap);
    }
  }

  /** 记录书目元数据（新值非空则覆盖，空值保留已有；全未提供或无变化跳过）。 */
  private static noteBookMeta(bookId: string, kind?: string, title?: string, cover?: string): void {
    if (kind === undefined && title === undefined && cover === undefined) {
      return;
    }
    const existing: FqStatsBookMeta | undefined = FqReadStatsStore.metas.get(bookId);
    const kindValue: string = kind !== undefined && kind.length > 0
      ? kind : (existing !== undefined ? existing.kind : '');
    const titleValue: string = title !== undefined && title.length > 0
      ? title : (existing !== undefined ? existing.title : '');
    const coverValue: string = cover !== undefined && cover.length > 0
      ? cover : (existing !== undefined ? existing.cover : '');
    if (existing !== undefined && existing.kind === kindValue
      && existing.title === titleValue && existing.cover === coverValue) {
      return;
    }
    FqReadStatsStore.metas.set(bookId, new FqStatsBookMeta(kindValue, titleValue, coverValue));
  }

  /** 加载书目元数据（books_meta key：bookId → JSON 字符串 { kind, title, cover }）。 */
  private static loadMetas(): void {
    const pref: preferences.Preferences | null = FqReadStatsStore.pref;
    if (pref === null) {
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_READ_META_KEY, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    const rec: Record<string, Object> | null = fqParseObject(text);
    if (rec === null) {
      return;
    }
    const bookIds: string[] = Object.keys(rec);
    for (const bookId of bookIds) {
      const metaText: string = fqStr(rec, bookId);
      if (metaText.length === 0) {
        continue;
      }
      const metaRec: Record<string, Object> | null = fqParseObject(metaText);
      if (metaRec === null) {
        continue;
      }
      FqReadStatsStore.metas.set(bookId,
        new FqStatsBookMeta(fqStr(metaRec, 'kind'), fqStr(metaRec, 'title'), fqStr(metaRec, 'cover')));
    }
  }

  private static todayKey(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqReadStatsStore.pref;
    if (pref === null) {
      return;
    }
    const rec: Record<string, Object> = {};
    FqReadStatsStore.days.forEach((seconds: number, key: string): void => {
      rec[key] = seconds;
    });
    const booksRec: Record<string, Object> = {};
    FqReadStatsStore.books.forEach((dayMap: Map<string, number>, bookId: string): void => {
      const dayRec: Record<string, Object> = {};
      dayMap.forEach((seconds: number, day: string): void => {
        dayRec[day] = seconds;
      });
      // 值存 JSON 字符串：两层 Record 序列化保持类型简单（读侧 fqParseObject 还原）
      booksRec[bookId] = JSON.stringify(dayRec);
    });
    const metasRec: Record<string, Object> = {};
    FqReadStatsStore.metas.forEach((meta: FqStatsBookMeta, bookId: string): void => {
      const metaRec: Record<string, Object> = {};
      metaRec['kind'] = meta.kind;
      metaRec['title'] = meta.title;
      metaRec['cover'] = meta.cover;
      metasRec[bookId] = JSON.stringify(metaRec);
    });
    try {
      pref.putSync(FQ_READ_STATS_KEY, JSON.stringify(rec));
      pref.putSync(FQ_READ_BOOKS_KEY, JSON.stringify(booksRec));
      pref.putSync(FQ_READ_META_KEY, JSON.stringify(metasRec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

/**
 * 阅读书签持久化（preferences，对齐 fqapp ReaderBookmarkStore 语义）：
 * - 书签锚点：bookId + chapterItemId + domPos（'p2:段:字符'，与阅读进度同一编码）；
 * - 本机合并语义：add 按锚点去重，全局上限 2000 条（达上限拒绝新增）；
 * - 全量数据供备份链路采集（local_ 本地书由备份侧排除）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsRecord, fqAsArray, fqStr, fqNum } from './FqJson';

const FQ_BOOKMARK_STORE_NAME: string = 'fq_reader_bookmarks';
const FQ_BOOKMARK_KEY_LIST: string = 'bookmarks';
/** 全局书签条数上限（对齐 fqapp maxEntries）。 */
export const FQ_BOOKMARK_MAX_ENTRIES: number = 2000;
/** 书签摘录文本上限（预览用，超长截断）。 */
export const FQ_BOOKMARK_EXCERPT_MAX: number = 80;

/** 单条阅读书签（章 + 段内位置；标题/摘录为预览文本）。 */
export class FqReaderBookmark {
  readonly bookId: string;
  readonly chapterIndex: number;
  /** 章节 itemId（目录定位主键：目录更新后按 id 找回章节）。 */
  readonly chapterItemId: string;
  readonly chapterTitle: string;
  readonly domPos: string;
  readonly excerpt: string;
  readonly createdAt: number;

  constructor(bookId: string, chapterIndex: number, chapterItemId: string,
    chapterTitle: string, domPos: string, excerpt: string, createdAt: number) {
    this.bookId = bookId;
    this.chapterIndex = chapterIndex;
    this.chapterItemId = chapterItemId;
    this.chapterTitle = chapterTitle;
    this.domPos = domPos;
    this.excerpt = excerpt;
    this.createdAt = createdAt;
  }

  /** 去重主键：书 + 章 + 章内位置。 */
  public get key(): string {
    return `${this.bookId}|${this.chapterItemId}|${this.domPos}`;
  }
}

export class FqReaderBookmarkStore {
  private static pref: preferences.Preferences | null = null;
  private static items: FqReaderBookmark[] = [];

  public static init(context: common.Context): void {
    if (FqReaderBookmarkStore.pref !== null) {
      return;
    }
    try {
      FqReaderBookmarkStore.pref = preferences.getPreferencesSync(context,
        { name: FQ_BOOKMARK_STORE_NAME });
    } catch (error) {
      FqReaderBookmarkStore.pref = null;
      return;
    }
    FqReaderBookmarkStore.items = FqReaderBookmarkStore.loadFromPref();
  }

  /** 重建内存列表（启动 / 恢复备份后）。 */
  private static loadFromPref(): FqReaderBookmark[] {
    const pref: preferences.Preferences | null = FqReaderBookmarkStore.pref;
    if (pref === null) {
      return [];
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_BOOKMARK_KEY_LIST, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return [];
    }
    if (text.length === 0) {
      return [];
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const array: Object[] | null = parsed === null ? null : fqAsArray(parsed);
      if (array === null) {
        return [];
      }
      const items: FqReaderBookmark[] = [];
      const keys: Set<string> = new Set<string>();
      for (const value of array) {
        const record: FqReaderBookmark | null = FqReaderBookmarkStore.decodeEntry(value);
        if (record === null || keys.has(record.key)) {
          // 坏条目/重复条目跳过，不阻断整表
          continue;
        }
        keys.add(record.key);
        items.push(record);
      }
      return items;
    } catch (error) {
      return [];
    }
  }

  /** 单条解析：字段类型/范围校验，不合规返回 null。 */
  private static decodeEntry(value: Object): FqReaderBookmark | null {
    const rec: Record<string, Object> | null = fqAsRecord(value);
    if (rec === null) {
      return null;
    }
    const bookId: string = fqStr(rec, 'bookId');
    const chapterIndex: number = fqNum(rec, 'chapterIndex');
    const chapterItemId: string = fqStr(rec, 'chapterItemId');
    const chapterTitle: string = fqStr(rec, 'chapterTitle');
    const domPos: string = fqStr(rec, 'domPos');
    const excerpt: string = fqStr(rec, 'excerpt');
    const createdAt: number = fqNum(rec, 'createdAt');
    if (bookId.length === 0 || chapterIndex < 0 || domPos.length === 0 || createdAt < 0) {
      return null;
    }
    return new FqReaderBookmark(bookId, Math.trunc(chapterIndex), chapterItemId,
      chapterTitle, domPos, excerpt, Math.trunc(createdAt));
  }

  /** 落盘（内存列表 → JSON 数组）。 */
  private static persist(): void {
    const pref: preferences.Preferences | null = FqReaderBookmarkStore.pref;
    if (pref === null) {
      return;
    }
    const array: Object[] = [];
    for (const item of FqReaderBookmarkStore.items) {
      const rec: Record<string, Object> = {};
      rec['bookId'] = item.bookId;
      rec['chapterIndex'] = item.chapterIndex;
      rec['chapterItemId'] = item.chapterItemId;
      rec['chapterTitle'] = item.chapterTitle;
      rec['domPos'] = item.domPos;
      rec['excerpt'] = item.excerpt;
      rec['createdAt'] = item.createdAt;
      array.push(rec);
    }
    try {
      pref.putSync(FQ_BOOKMARK_KEY_LIST, JSON.stringify(array));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 单书书签（新增在前，对齐 fqapp createdAt 倒序）。 */
  public static loadBook(bookId: string): FqReaderBookmark[] {
    const result: FqReaderBookmark[] = [];
    for (const item of FqReaderBookmarkStore.items) {
      if (item.bookId === bookId) {
        result.push(item);
      }
    }
    result.sort((a: FqReaderBookmark, b: FqReaderBookmark): number => {
      const order: number = b.createdAt - a.createdAt;
      return order === 0 ? (a.key < b.key ? -1 : 1) : order;
    });
    return result;
  }

  /** 全量书签（备份采集用）。 */
  public static all(): FqReaderBookmark[] {
    return FqReaderBookmarkStore.items.slice();
  }

  /** 锚点是否已有书签（下拉起手判定已书签页用）。 */
  public static has(key: string): boolean {
    return FqReaderBookmarkStore.indexOf(key) >= 0;
  }

  /**
   * 新增书签：锚点已存在返回 false；达上限抛错（对齐 fqapp 上限语义）。
   */
  public static add(record: FqReaderBookmark): boolean {
    if (FqReaderBookmarkStore.indexOf(record.key) >= 0) {
      return false;
    }
    if (FqReaderBookmarkStore.items.length >= FQ_BOOKMARK_MAX_ENTRIES) {
      throw new Error(`书签已达 ${FQ_BOOKMARK_MAX_ENTRIES} 条上限，请先删除不需要的书签`);
    }
    FqReaderBookmarkStore.items.push(record);
    FqReaderBookmarkStore.persist();
    return true;
  }

  /** 删除书签（锚点不存在静默通过）。 */
  public static remove(key: string): void {
    const index: number = FqReaderBookmarkStore.indexOf(key);
    if (index < 0) {
      return;
    }
    FqReaderBookmarkStore.items.splice(index, 1);
    FqReaderBookmarkStore.persist();
  }

  /** 合并恢复（备份链路）：锚点已存在的跳过，达上限静默停止；返回新增条数。 */
  public static merge(records: FqReaderBookmark[]): number {
    let added: number = 0;
    for (const record of records) {
      if (FqReaderBookmarkStore.items.length >= FQ_BOOKMARK_MAX_ENTRIES) {
        break;
      }
      if (FqReaderBookmarkStore.indexOf(record.key) >= 0) {
        continue;
      }
      FqReaderBookmarkStore.items.push(record);
      added++;
    }
    if (added > 0) {
      FqReaderBookmarkStore.persist();
    }
    return added;
  }

  private static indexOf(key: string): number {
    for (let i: number = 0; i < FqReaderBookmarkStore.items.length; i++) {
      if (FqReaderBookmarkStore.items[i].key === key) {
        return i;
      }
    }
    return -1;
  }
}

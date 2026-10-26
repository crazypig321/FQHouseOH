/**
 * 漫画缓存存储（双层缓存治「每次进去都要加载」）：
 *
 * A. 图片列表缓存（秒开层）：每话图片 URL 列表落盘（preferences），
 *    重进目录/本话图片列表不再请求后端，直接秒开（图片仍在线加载，
 *    图片 URL 可能带签名会过期，列表带 TTL 防毒缓存）。
 * B. 离线章记录（离线层，FqComicDownloader 下载完成后写入）：
 *    整话图片落盘 files/offline_comic/<bookId>__<itemId>/<i>，
 *    命中返回 file:// 本地路径列表，图片不走网络（永久有效）。
 *
 * 变更后 fqStoreBus.comicCacheVersion++ 驱动管理页刷新。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fqNum, fqParseObject, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_COMIC_CACHE_STORE_NAME: string = 'fq_comic_cache';
const FQ_LIST_KEY_PREFIX: string = 'list.';
const FQ_CHAPTER_KEY_PREFIX: string = 'ch.';
const FQ_COMIC_DIR: string = 'offline_comic';
const FQ_SAFE_ID: RegExp = /^[A-Za-z0-9_-]{1,128}$/;
/** 图片列表缓存有效期（24h；图片 URL 可能带过期签名，列表过期后重拉）。 */
const FQ_LIST_TTL_MS: number = 24 * 60 * 60 * 1000;

/** 离线漫画章记录（整话图片下载完成后写入）。 */
export class FqCachedComicChapter {
  /** 复合键（bookId__itemId）。 */
  public readonly key: string;
  public readonly bookId: string;
  public readonly itemId: string;
  /** 话标题。 */
  public readonly title: string;
  /** 书名（管理页分组标题兜底）。 */
  public readonly bookTitle: string;
  /** 话序号（1 起）。 */
  public readonly index: number;
  /** 图片张数。 */
  public readonly imageCount: number;
  public readonly bytes: number;
  public readonly cachedAt: number;

  constructor(key: string, bookId: string, itemId: string, title: string,
    bookTitle: string, index: number, imageCount: number, bytes: number,
    cachedAt: number) {
    this.key = key;
    this.bookId = bookId;
    this.itemId = itemId;
    this.title = title;
    this.bookTitle = bookTitle;
    this.index = index;
    this.imageCount = imageCount;
    this.bytes = bytes;
    this.cachedAt = cachedAt;
  }
}

/** 管理页按书聚合的缓存摘要。 */
export class FqCachedComicBookSummary {
  public readonly bookId: string;
  public readonly title: string;
  public readonly chapterCount: number;
  public readonly imageCount: number;
  public readonly byteCount: number;

  constructor(bookId: string, title: string, chapterCount: number,
    imageCount: number, byteCount: number) {
    this.bookId = bookId;
    this.title = title;
    this.chapterCount = chapterCount;
    this.imageCount = imageCount;
    this.byteCount = byteCount;
  }
}

export class FqComicCacheStore {
  private static pref: preferences.Preferences | null = null;
  private static filesDir: string = '';
  /** 复合键 → 离线章记录（init 时全量载入内存）。 */
  private static chapters: Map<string, FqCachedComicChapter> = new Map<string, FqCachedComicChapter>();

  public static init(context: common.Context): void {
    if (FqComicCacheStore.pref !== null) {
      return;
    }
    try {
      FqComicCacheStore.pref = preferences.getPreferencesSync(context,
        { name: FQ_COMIC_CACHE_STORE_NAME });
    } catch (error) {
      FqComicCacheStore.pref = null;
    }
    FqComicCacheStore.filesDir = context.filesDir;
    try {
      fs.mkdirSync(FqComicCacheStore.comicDir(), true);
    } catch (error) {
      // 已存在或失败，写文件时按需再建
    }
    FqComicCacheStore.loadAll();
  }

  private static comicDir(): string {
    return `${FqComicCacheStore.filesDir}/${FQ_COMIC_DIR}`;
  }

  /** 章目录（一话一目录）。 */
  public static chapterDir(key: string): string {
    return `${FqComicCacheStore.comicDir()}/${key}`;
  }

  /** 离线图片文件路径（i 为章内图下标）。 */
  public static imagePath(key: string, i: number): string {
    return `${FqComicCacheStore.chapterDir(key)}/${i}`;
  }

  /** 复合键（bookId__itemId）；任一段非法返回空串（不支持缓存）。 */
  public static key(bookId: string, itemId: string): string {
    if (!FQ_SAFE_ID.test(bookId) || !FQ_SAFE_ID.test(itemId)) {
      return '';
    }
    return `${bookId}__${itemId}`;
  }

  private static loadAll(): void {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const raw: preferences.ValueType = pref.getSync('ids', '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: Object | null = JSON.parse(raw);
        if (parsed !== null && Array.isArray(parsed)) {
          const arr: Object[] = parsed as Object[];
          for (const entry of arr) {
            if (typeof entry === 'string') {
              FqComicCacheStore.loadOne(entry);
            }
          }
        }
      }
    } catch (error) {
      // 损坏索引按空处理
    }
  }

  private static loadOne(key: string): void {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_CHAPTER_KEY_PREFIX + key, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return;
      }
      const rec: Record<string, Object> | null = fqParseObject(raw);
      if (rec === null) {
        return;
      }
      const bookId: string = fqStr(rec, 'bookId');
      if (bookId.length === 0) {
        return;
      }
      FqComicCacheStore.chapters.set(key, new FqCachedComicChapter(key, bookId,
        fqStr(rec, 'itemId'), fqStr(rec, 'title'), fqStr(rec, 'bookTitle'),
        fqNum(rec, 'index'), fqNum(rec, 'imageCount'), fqNum(rec, 'bytes'),
        fqNum(rec, 'cachedAt')));
    } catch (error) {
      // 单条损坏跳过
    }
  }

  // ---------------------------------------------------------------------------
  // A. 图片列表缓存（秒开层，TTL 24h）
  // ---------------------------------------------------------------------------

  /** 保存一话的图片 URL 列表。 */
  public static saveImageList(bookId: string, itemId: string, urls: string[]): void {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    const key: string = FqComicCacheStore.key(bookId, itemId);
    if (pref === null || key.length === 0 || urls.length === 0) {
      return;
    }
    try {
      const rec: Record<string, Object> = {};
      rec['at'] = Date.now();
      rec['urls'] = urls;
      pref.putSync(FQ_LIST_KEY_PREFIX + key, JSON.stringify(rec));
      pref.flush().catch((): void => {
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 命中未过期的图片 URL 列表（无缓存/过期返回 null）。 */
  public static cachedImageList(bookId: string, itemId: string): string[] | null {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    const key: string = FqComicCacheStore.key(bookId, itemId);
    if (pref === null || key.length === 0) {
      return null;
    }
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_LIST_KEY_PREFIX + key, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return null;
      }
      const rec: Record<string, Object> | null = fqParseObject(raw);
      if (rec === null) {
        return null;
      }
      const at: number = fqNum(rec, 'at');
      if (at <= 0 || Date.now() - at > FQ_LIST_TTL_MS) {
        return null;
      }
      const rawUrls: Object | undefined = rec['urls'];
      if (rawUrls === null || !Array.isArray(rawUrls)) {
        return null;
      }
      const arr: Object[] = rawUrls as Object[];
      const urls: string[] = [];
      for (const entry of arr) {
        if (typeof entry === 'string' && entry.length > 0) {
          urls.push(entry);
        }
      }
      return urls.length > 0 ? urls : null;
    } catch (error) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // B. 离线章记录（离线层，永久有效）
  // ---------------------------------------------------------------------------

  /** 某话是否已完整离线（有记录且图片文件齐备）。 */
  public static has(key: string): boolean {
    const chapter: FqCachedComicChapter | undefined = FqComicCacheStore.chapters.get(key);
    if (chapter === undefined) {
      return false;
    }
    try {
      return fs.accessSync(FqComicCacheStore.imagePath(key, chapter.imageCount - 1));
    } catch (error) {
      return false;
    }
  }

  /** 离线命中：整话本地图片路径列表（file:// 形式，无离线返回 null）。 */
  public static cachedChapterImages(bookId: string, itemId: string): string[] | null {
    const key: string = FqComicCacheStore.key(bookId, itemId);
    const chapter: FqCachedComicChapter | undefined = FqComicCacheStore.chapters.get(key);
    if (chapter === undefined || !FqComicCacheStore.has(key)) {
      return null;
    }
    const images: string[] = [];
    for (let i: number = 0; i < chapter.imageCount; i++) {
      images.push(`file://${FqComicCacheStore.imagePath(key, i)}`);
    }
    return images;
  }

  /** 某书已离线话 itemId 集合（缓存 sheet downloadedIds）。 */
  public static cachedItemIds(bookId: string): Set<string> {
    const ids: Set<string> = new Set<string>();
    FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
      if (chapter.bookId === bookId && FqComicCacheStore.has(chapter.key)) {
        ids.add(chapter.itemId);
      }
    });
    return ids;
  }

  /** 完成一话：写记录 + 索引。 */
  public static addChapter(chapter: FqCachedComicChapter): void {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    if (pref === null || chapter.key.length === 0) {
      return;
    }
    FqComicCacheStore.chapters.set(chapter.key, chapter);
    const rec: Record<string, Object> = {};
    rec['key'] = chapter.key;
    rec['bookId'] = chapter.bookId;
    rec['itemId'] = chapter.itemId;
    rec['title'] = chapter.title;
    rec['bookTitle'] = chapter.bookTitle;
    rec['index'] = chapter.index;
    rec['imageCount'] = chapter.imageCount;
    rec['bytes'] = chapter.bytes;
    rec['cachedAt'] = chapter.cachedAt;
    try {
      pref.putSync(FQ_CHAPTER_KEY_PREFIX + chapter.key, JSON.stringify(rec));
      FqComicCacheStore.persistIndex();
    } catch (error) {
      // 忽略写入失败
    }
    fqStoreBus.comicCacheVersion++;
  }

  /** 删除单话离线缓存（目录 + 记录 + 列表缓存）。 */
  public static removeChapter(key: string): void {
    try {
      fs.rmdirSync(FqComicCacheStore.chapterDir(key));
    } catch (error) {
      // 目录不存在跳过
    }
    if (FqComicCacheStore.chapters.delete(key)) {
      FqComicCacheStore.persistIndex();
      fqStoreBus.comicCacheVersion++;
    }
  }

  /** 删除整书离线缓存。 */
  public static removeBook(bookId: string): void {
    const keys: string[] = [];
    FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
      if (chapter.bookId === bookId) {
        keys.push(chapter.key);
      }
    });
    for (const key of keys) {
      FqComicCacheStore.removeChapter(key);
    }
  }

  /** 清空全部漫画离线缓存。 */
  public static clearAll(): void {
    const keys: string[] = [];
    FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
      keys.push(chapter.key);
    });
    for (const key of keys) {
      FqComicCacheStore.removeChapter(key);
    }
    fqStoreBus.comicCacheVersion++;
  }

  private static persistIndex(): void {
    const pref: preferences.Preferences | null = FqComicCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const keys: string[] = [];
      FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
        keys.push(chapter.key);
      });
      pref.putSync('ids', JSON.stringify(keys));
      pref.flush().catch((): void => {
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 某书全部离线话（按话序号升序）。 */
  public static chaptersOf(bookId: string): FqCachedComicChapter[] {
    const result: FqCachedComicChapter[] = [];
    FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
      if (chapter.bookId === bookId && FqComicCacheStore.has(chapter.key)) {
        result.push(chapter);
      }
    });
    result.sort((a: FqCachedComicChapter, b: FqCachedComicChapter): number => a.index - b.index);
    return result;
  }

  /** 管理页：按书聚合摘要（话数降序）。 */
  public static books(): FqCachedComicBookSummary[] {
    const groups: Map<string, FqCachedComicChapter[]> = new Map<string, FqCachedComicChapter[]>();
    FqComicCacheStore.chapters.forEach((chapter: FqCachedComicChapter): void => {
      if (!FqComicCacheStore.has(chapter.key)) {
        return;
      }
      const list: FqCachedComicChapter[] | undefined = groups.get(chapter.bookId);
      if (list !== undefined) {
        list.push(chapter);
      } else {
        const newList: FqCachedComicChapter[] = [chapter];
        groups.set(chapter.bookId, newList);
      }
    });
    const summaries: FqCachedComicBookSummary[] = [];
    groups.forEach((chapters: FqCachedComicChapter[], bookId: string): void => {
      let title: string = bookId;
      let images: number = 0;
      let bytes: number = 0;
      for (const chapter of chapters) {
        if (chapter.bookTitle.length > 0) {
          title = chapter.bookTitle;
        }
        images += chapter.imageCount;
        bytes += chapter.bytes;
      }
      summaries.push(new FqCachedComicBookSummary(bookId, title, chapters.length,
        images, bytes));
    });
    summaries.sort((a: FqCachedComicBookSummary, b: FqCachedComicBookSummary): number =>
      b.chapterCount - a.chapterCount);
    return summaries;
  }
}

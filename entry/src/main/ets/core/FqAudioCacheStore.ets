/**
 * 听书音频缓存存储（对齐 FqDramaCacheStore 语义）：
 * - 文件：files/offline_audio/<bookId>__<itemId>__<toneId>.m4a
 *   （下载中 .m4a.part，完成 rename）；
 * - 元数据：preferences fq_audio_cache，key `ch.<复合键>` 存单章记录
 *   （书 id/章节 id/音色 id/章标题/排序/字节数/时间），管理页按书分组展示；
 * - 复合键 = `<bookId>__<itemId>__<toneId>`（音色专属缓存：TTS 每音色一套，
 *   真人讲书 toneId 恒 '0'）；
 * - 只持久化「已完成」的章（下载中任务由 FqAudioDownloader 持有，重启后
 *   .part 残留按缺章处理，重新发起时 Range 续传复用）；
 * - 变更后 fqStoreBus.audioCacheVersion++ 驱动管理页刷新。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fqNum, fqParseObject, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_AUDIO_CACHE_STORE_NAME: string = 'fq_audio_cache';
const FQ_CHAPTER_KEY_PREFIX: string = 'ch.';
const FQ_AUDIO_DIR: string = 'offline_audio';
const FQ_PART_SUFFIX: string = '.part';
const FQ_SAFE_ID: RegExp = /^[A-Za-z0-9_-]{1,128}$/;

/** 单章音频缓存记录（完成后写入）。 */
export class FqCachedAudioChapter {
  /** 复合键（bookId__itemId__toneId）。 */
  public readonly key: string;
  public readonly bookId: string;
  public readonly itemId: string;
  /** 下载时音色 id（'0' 默认/真人讲书固定录音）。 */
  public readonly toneId: string;
  /** 章标题。 */
  public readonly title: string;
  /** 书名（管理页分组标题兜底）。 */
  public readonly bookTitle: string;
  public readonly cover: string;
  /** 章序号（1 起）。 */
  public readonly index: number;
  public readonly bytes: number;
  public readonly cachedAt: number;

  constructor(key: string, bookId: string, itemId: string, toneId: string,
    title: string, bookTitle: string, cover: string, index: number,
    bytes: number, cachedAt: number) {
    this.key = key;
    this.bookId = bookId;
    this.itemId = itemId;
    this.toneId = toneId;
    this.title = title;
    this.bookTitle = bookTitle;
    this.cover = cover;
    this.index = index;
    this.bytes = bytes;
    this.cachedAt = cachedAt;
  }
}

/** 管理页按书聚合的缓存摘要。 */
export class FqCachedAudioBookSummary {
  public readonly bookId: string;
  public readonly title: string;
  public readonly cover: string;
  public readonly chapterCount: number;
  public readonly byteCount: number;

  constructor(bookId: string, title: string, cover: string,
    chapterCount: number, byteCount: number) {
    this.bookId = bookId;
    this.title = title;
    this.cover = cover;
    this.chapterCount = chapterCount;
    this.byteCount = byteCount;
  }
}

export class FqAudioCacheStore {
  private static pref: preferences.Preferences | null = null;
  private static filesDir: string = '';
  /** 复合键 → 单章记录（init 时全量载入内存）。 */
  private static cache: Map<string, FqCachedAudioChapter> = new Map<string, FqCachedAudioChapter>();

  public static init(context: common.Context): void {
    if (FqAudioCacheStore.pref !== null) {
      return;
    }
    try {
      FqAudioCacheStore.pref = preferences.getPreferencesSync(context,
        { name: FQ_AUDIO_CACHE_STORE_NAME });
    } catch (error) {
      FqAudioCacheStore.pref = null;
    }
    FqAudioCacheStore.filesDir = context.filesDir;
    try {
      fs.mkdirSync(FqAudioCacheStore.audioDir(), true);
    } catch (error) {
      // 已存在或失败，写文件时按需再建
    }
    FqAudioCacheStore.loadAll();
  }

  private static audioDir(): string {
    return `${FqAudioCacheStore.filesDir}/${FQ_AUDIO_DIR}`;
  }

  /** 复合键（bookId__itemId__toneId）；任一段非法返回空串（不支持缓存）。 */
  public static key(bookId: string, itemId: string, toneId: string): string {
    const tone: string = toneId.trim().length > 0 ? toneId.trim() : '0';
    if (!FQ_SAFE_ID.test(bookId) || !FQ_SAFE_ID.test(itemId) || !FQ_SAFE_ID.test(tone)) {
      return '';
    }
    return `${bookId}__${itemId}__${tone}`;
  }

  public static filePath(key: string): string {
    return `${FqAudioCacheStore.audioDir()}/${key}.m4a`;
  }

  public static partPath(key: string): string {
    return `${FqAudioCacheStore.audioDir()}/${key}.m4a${FQ_PART_SUFFIX}`;
  }

  private static loadAll(): void {
    const pref: preferences.Preferences | null = FqAudioCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const keysSync: string[] = [];
      const raw: preferences.ValueType = pref.getSync('ids', '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: Object | null = JSON.parse(raw);
        if (parsed !== null && Array.isArray(parsed)) {
          const arr: Object[] = parsed as Object[];
          for (const entry of arr) {
            if (typeof entry === 'string') {
              keysSync.push(entry);
            }
          }
        }
      }
      for (const key of keysSync) {
        FqAudioCacheStore.loadOne(key);
      }
    } catch (error) {
      // 损坏索引按空处理
    }
  }

  private static loadOne(key: string): void {
    const pref: preferences.Preferences | null = FqAudioCacheStore.pref;
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
      FqAudioCacheStore.cache.set(key, new FqCachedAudioChapter(key, bookId,
        fqStr(rec, 'itemId'), fqStr(rec, 'toneId'), fqStr(rec, 'title'),
        fqStr(rec, 'bookTitle'), fqStr(rec, 'cover'), fqNum(rec, 'index'),
        fqNum(rec, 'bytes'), fqNum(rec, 'cachedAt')));
    } catch (error) {
      // 单条损坏跳过
    }
  }

  /** 某章（书 + 章节音色）是否已完整缓存（最终文件存在且有记录）。 */
  public static has(key: string): boolean {
    if (key.length === 0 || !FqAudioCacheStore.cache.has(key)) {
      return false;
    }
    try {
      return fs.accessSync(FqAudioCacheStore.filePath(key));
    } catch (error) {
      return false;
    }
  }

  /** 缓存命中：本地文件绝对路径（无缓存返回 null，播放会话离线命中点）。 */
  public static cachedFilePath(bookId: string, itemId: string, toneId: string): string | null {
    const key: string = FqAudioCacheStore.key(bookId, itemId, toneId);
    if (!FqAudioCacheStore.has(key)) {
      return null;
    }
    return FqAudioCacheStore.filePath(key);
  }

  /** 某书 + 音色已缓存章节 itemId 集合（缓存 sheet downloadedIds）。 */
  public static cachedItemIds(bookId: string, toneId: string): Set<string> {
    const ids: Set<string> = new Set<string>();
    FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
      if (chapter.bookId === bookId && chapter.toneId === (toneId.length > 0 ? toneId : '0')
        && FqAudioCacheStore.has(chapter.key)) {
        ids.add(chapter.itemId);
      }
    });
    return ids;
  }

  /** 完成一章：写记录 + 索引 + 落盘。 */
  public static addChapter(chapter: FqCachedAudioChapter): void {
    const pref: preferences.Preferences | null = FqAudioCacheStore.pref;
    if (pref === null || chapter.key.length === 0) {
      return;
    }
    FqAudioCacheStore.cache.set(chapter.key, chapter);
    const rec: Record<string, Object> = {};
    rec['key'] = chapter.key;
    rec['bookId'] = chapter.bookId;
    rec['itemId'] = chapter.itemId;
    rec['toneId'] = chapter.toneId;
    rec['title'] = chapter.title;
    rec['bookTitle'] = chapter.bookTitle;
    rec['cover'] = chapter.cover;
    rec['index'] = chapter.index;
    rec['bytes'] = chapter.bytes;
    rec['cachedAt'] = chapter.cachedAt;
    try {
      pref.putSync(FQ_CHAPTER_KEY_PREFIX + chapter.key, JSON.stringify(rec));
      FqAudioCacheStore.persistIndex();
    } catch (error) {
      // 忽略写入失败
    }
    fqStoreBus.audioCacheVersion++;
  }

  /** 删除单章缓存（文件 + 记录）。 */
  public static removeChapter(key: string): void {
    for (const suffix of ['', FQ_PART_SUFFIX]) {
      try {
        fs.unlinkSync(`${FqAudioCacheStore.audioDir()}/${key}.m4a${suffix}`);
      } catch (error) {
        // 文件不存在跳过
      }
    }
    if (FqAudioCacheStore.cache.delete(key)) {
      FqAudioCacheStore.persistIndex();
      fqStoreBus.audioCacheVersion++;
    }
  }

  /** 删除整书音频缓存。 */
  public static removeBook(bookId: string): void {
    const keys: string[] = [];
    FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
      if (chapter.bookId === bookId) {
        keys.push(chapter.key);
      }
    });
    for (const key of keys) {
      FqAudioCacheStore.removeChapter(key);
    }
  }

  /** 清空全部听书音频缓存（文件 + 记录）。 */
  public static clearAll(): void {
    const keys: string[] = [];
    FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
      keys.push(chapter.key);
    });
    for (const key of keys) {
      FqAudioCacheStore.removeChapter(key);
    }
    fqStoreBus.audioCacheVersion++;
  }

  private static persistIndex(): void {
    const pref: preferences.Preferences | null = FqAudioCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const keys: string[] = [];
      FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
        keys.push(chapter.key);
      });
      pref.putSync('ids', JSON.stringify(keys));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 某书全部缓存章（按章序号升序）。 */
  public static chaptersOf(bookId: string): FqCachedAudioChapter[] {
    const result: FqCachedAudioChapter[] = [];
    FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
      if (chapter.bookId === bookId && FqAudioCacheStore.has(chapter.key)) {
        result.push(chapter);
      }
    });
    result.sort((a: FqCachedAudioChapter, b: FqCachedAudioChapter): number => a.index - b.index);
    return result;
  }

  /** 管理页：按书聚合摘要（章数降序）。 */
  public static books(): FqCachedAudioBookSummary[] {
    const groups: Map<string, FqCachedAudioChapter[]> = new Map<string, FqCachedAudioChapter[]>();
    FqAudioCacheStore.cache.forEach((chapter: FqCachedAudioChapter): void => {
      if (!FqAudioCacheStore.has(chapter.key)) {
        return;
      }
      const list: FqCachedAudioChapter[] | undefined = groups.get(chapter.bookId);
      if (list !== undefined) {
        list.push(chapter);
      } else {
        const newList: FqCachedAudioChapter[] = [chapter];
        groups.set(chapter.bookId, newList);
      }
    });
    const summaries: FqCachedAudioBookSummary[] = [];
    groups.forEach((chapters: FqCachedAudioChapter[], bookId: string): void => {
      let title: string = bookId;
      let cover: string = '';
      let bytes: number = 0;
      for (const chapter of chapters) {
        if (chapter.bookTitle.length > 0) {
          title = chapter.bookTitle;
        }
        if (chapter.cover.length > 0) {
          cover = chapter.cover;
        }
        bytes += chapter.bytes;
      }
      summaries.push(new FqCachedAudioBookSummary(bookId, title, cover,
        chapters.length, bytes));
    });
    summaries.sort((a: FqCachedAudioBookSummary, b: FqCachedAudioBookSummary): number =>
      b.chapterCount - a.chapterCount);
    return summaries;
  }
}

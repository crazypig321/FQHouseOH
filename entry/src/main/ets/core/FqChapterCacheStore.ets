/**
 * 章节缓存存储（对齐 fqapp ChapterCacheStore 的文件型子集）：
 * - 正文：files/chapter_cache/<bookId>/<itemId>.txt（UTF-8）；
 * - 目录：files/chapter_cache/<bookId>/catalog.json（书名/封面/类型/章节表，
 *   阅读页目录加载成功后写入；离线打开缓存书与管理页展示的兜底数据源）；
 * - 阅读页 fetchChapterText 成功后自动 write（阅读即缓存）；
 * - 详情页「下载」走 downloadBook 整本顺序缓存；
 * - 变更后 fqStoreBus.chapterCacheVersion++ 驱动管理页刷新。
 * v1 无 LRU 淘汰与加密落盘（后端已解密明文，存应用沙箱），清理靠用户手动。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqChapter } from '../model/FqModels';
import { FqBackend } from './FqBackend';
import { fqAsArray, fqAsRecord, fqParseObject, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const TAG: string = 'FqChapterCache';
const FQ_CACHE_DIR: string = 'chapter_cache';
const FQ_CATALOG_FILE: string = 'catalog.json';
/** 目录/章节文件名安全字符（防路径穿越）。 */
const FQ_SAFE_ID: RegExp = /^[A-Za-z0-9_-]{1,128}$/;

/** 缓存书目录元数据（catalog.json 反解；离线打开缓存书的兜底数据）。 */
export class FqCachedCatalog {
  public readonly title: string;
  public readonly cover: string;
  public readonly kind: string;
  public readonly chapters: FqChapter[];

  constructor(title: string, cover: string, kind: string, chapters: FqChapter[]) {
    this.title = title;
    this.cover = cover;
    this.kind = kind;
    this.chapters = chapters;
  }
}

/** 管理页按书聚合的缓存摘要。 */
export class FqCachedBookSummary {
  public readonly bookId: string;
  public readonly title: string;
  public readonly cover: string;
  public readonly kind: string;
  public readonly chapterCount: number;
  public readonly byteCount: number;

  constructor(bookId: string, title: string, cover: string, kind: string,
    chapterCount: number, byteCount: number) {
    this.bookId = bookId;
    this.title = title;
    this.cover = cover;
    this.kind = kind;
    this.chapterCount = chapterCount;
    this.byteCount = byteCount;
  }
}

export class FqChapterCacheStore {
  private static filesDir: string = '';

  public static init(context: common.Context): void {
    if (FqChapterCacheStore.filesDir.length > 0) {
      return;
    }
    FqChapterCacheStore.filesDir = context.filesDir;
    try {
      fs.mkdirSync(FqChapterCacheStore.cacheRoot(), true);
    } catch (error) {
      // 已存在或创建失败（后续写按需再建）
    }
  }

  private static cacheRoot(): string {
    return `${FqChapterCacheStore.filesDir}/${FQ_CACHE_DIR}`;
  }

  private static bookDir(bookId: string): string {
    return `${FqChapterCacheStore.cacheRoot()}/${bookId}`;
  }

  private static chapterPath(bookId: string, chapterId: string): string {
    return `${FqChapterCacheStore.bookDir(bookId)}/${chapterId}.txt`;
  }

  private static ensureBookDir(bookId: string): boolean {
    if (FqChapterCacheStore.filesDir.length === 0 || !FQ_SAFE_ID.test(bookId)) {
      return false;
    }
    try {
      fs.mkdirSync(FqChapterCacheStore.bookDir(bookId), true);
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 写入一章正文（阅读自动缓存/整本下载共用）；成功返回 true。 */
  public static write(bookId: string, chapterId: string, title: string, text: string): boolean {
    if (chapterId.length === 0 || text.trim().length === 0
      || !FQ_SAFE_ID.test(chapterId) || !FqChapterCacheStore.ensureBookDir(bookId)) {
      return false;
    }
    const path: string = FqChapterCacheStore.chapterPath(bookId, chapterId);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
      fqStoreBus.chapterCacheVersion++;
      return true;
    } catch (error) {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 句柄关闭失败不影响结果
        }
      }
      return false;
    }
  }

  /** 读一章缓存正文（未命中返回空串）。 */
  public static read(bookId: string, chapterId: string): string {
    if (!FQ_SAFE_ID.test(bookId) || !FQ_SAFE_ID.test(chapterId)) {
      return '';
    }
    try {
      return fs.readTextSync(FqChapterCacheStore.chapterPath(bookId, chapterId));
    } catch (error) {
      return '';
    }
  }

  public static has(bookId: string, chapterId: string): boolean {
    try {
      fs.accessSync(FqChapterCacheStore.chapterPath(bookId, chapterId));
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 已缓存章节 itemId 集合（详情页/下载去重用）。 */
  public static cachedChapterIds(bookId: string): Set<string> {
    const ids: Set<string> = new Set<string>();
    if (!FQ_SAFE_ID.test(bookId)) {
      return ids;
    }
    const dir: string = FqChapterCacheStore.bookDir(bookId);
    try {
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        if (name.endsWith('.txt')) {
          ids.add(name.substring(0, name.length - 4));
        }
      }
    } catch (error) {
      // 无缓存目录
    }
    return ids;
  }

  /** 写入/刷新书目录（catalog.json）；已存在且 overwrite=false 时跳过（避免阅读页反复整写）。 */
  public static saveCatalog(bookId: string, title: string, cover: string, kind: string,
    chapters: FqChapter[], overwrite: boolean = false): void {
    if (chapters.length === 0 || !FqChapterCacheStore.ensureBookDir(bookId)) {
      return;
    }
    const path: string = `${FqChapterCacheStore.bookDir(bookId)}/${FQ_CATALOG_FILE}`;
    if (!overwrite) {
      try {
        fs.accessSync(path);
        return;
      } catch (error) {
        // 尚无目录，继续写入
      }
    }
    const chapterRecs: Record<string, Object>[] = [];
    for (const chapter of chapters) {
      const rec: Record<string, Object> = {
        'itemId': chapter.itemId,
        'title': chapter.title,
      };
      chapterRecs.push(rec);
    }
    const catalog: Record<string, Object> = {
      'id': bookId,
      'title': title,
      'cover': cover,
      'kind': kind,
      'chapters': chapterRecs,
    };
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(catalog));
      fs.closeSync(file);
    } catch (error) {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 忽略
        }
      }
    }
  }

  /** 读缓存书目录（catalog.json；无目录返回 null）。 */
  public static catalog(bookId: string): FqCachedCatalog | null {
    if (!FQ_SAFE_ID.test(bookId)) {
      return null;
    }
    let text: string = '';
    try {
      text = fs.readTextSync(`${FqChapterCacheStore.bookDir(bookId)}/${FQ_CATALOG_FILE}`);
    } catch (error) {
      return null;
    }
    const rec: Record<string, Object> | null = fqParseObject(text);
    if (rec === null) {
      return null;
    }
    const rawChapters: Object[] | null = fqAsArray(rec['chapters']);
    const chapters: FqChapter[] = [];
    if (rawChapters !== null) {
      for (const raw of rawChapters) {
        const chapterRec: Record<string, Object> | null = fqAsRecord(raw);
        if (chapterRec === null) {
          continue;
        }
        const itemId: string = fqStr(chapterRec, 'itemId');
        if (itemId.length === 0) {
          continue;
        }
        chapters.push(new FqChapter(itemId, fqStr(chapterRec, 'title'), ''));
      }
    }
    if (chapters.length === 0) {
      return null;
    }
    return new FqCachedCatalog(fqStr(rec, 'title'), fqStr(rec, 'cover'), fqStr(rec, 'kind'), chapters);
  }

  /** 管理页：按书聚合的缓存摘要（按最近缓存时间倒序）。 */
  public static books(): FqCachedBookSummary[] {
    const summaries: FqCachedBookSummary[] = [];
    let bookIds: string[] = [];
    try {
      bookIds = fs.listFileSync(FqChapterCacheStore.cacheRoot());
    } catch (error) {
      return summaries;
    }
    for (const bookId of bookIds) {
      if (!FQ_SAFE_ID.test(bookId)) {
        continue;
      }
      const dir: string = FqChapterCacheStore.bookDir(bookId);
      let names: string[] = [];
      try {
        names = fs.listFileSync(dir);
      } catch (error) {
        continue;
      }
      const catalog: FqCachedCatalog | null = FqChapterCacheStore.catalog(bookId);
      let count: number = 0;
      let bytes: number = 0;
      let latestMtime: number = 0;
      for (const name of names) {
        if (!name.endsWith('.txt')) {
          continue;
        }
        try {
          const stat: fs.Stat = fs.statSync(`${dir}/${name}`);
          count++;
          bytes += stat.size;
          if (stat.mtime > latestMtime) {
            latestMtime = stat.mtime;
          }
        } catch (error) {
          // 单文件统计失败跳过
        }
      }
      if (count === 0) {
        continue;
      }
      const title: string = catalog !== null && catalog.title.length > 0 ? catalog.title : bookId;
      const cover: string = catalog !== null ? catalog.cover : '';
      const kind: string = catalog !== null && catalog.kind.length > 0 ? catalog.kind : 'book';
      summaries.push(new FqCachedBookSummary(bookId, title, cover, kind, count, bytes));
    }
    summaries.sort((a: FqCachedBookSummary, b: FqCachedBookSummary): number => b.chapterCount - a.chapterCount);
    return summaries;
  }

  /** 删除单本书缓存（正文 + 目录）；成功返回 true。 */
  public static removeBook(bookId: string): boolean {
    if (!FQ_SAFE_ID.test(bookId)) {
      return false;
    }
    const dir: string = FqChapterCacheStore.bookDir(bookId);
    try {
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        try {
          fs.unlinkSync(`${dir}/${name}`);
        } catch (error) {
          // 单文件删除失败继续
        }
      }
      fs.rmdirSync(dir);
      fqStoreBus.chapterCacheVersion++;
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 清空全部章节缓存。 */
  public static clearAll(): void {
    let bookIds: string[] = [];
    try {
      bookIds = fs.listFileSync(FqChapterCacheStore.cacheRoot());
    } catch (error) {
      return;
    }
    for (const bookId of bookIds) {
      FqChapterCacheStore.removeBook(bookId);
    }
    fqStoreBus.chapterCacheVersion++;
  }

  /**
   * 整本缓存（详情页「下载」）：顺序拉取目录章节正文写入缓存，
   * 已缓存章节跳过；onProgress 汇报累计完成/总数。
   */
  public static async downloadBook(context: common.Context, bookId: string, title: string,
    cover: string, kind: string, tab: string,
    onProgress: (done: number, total: number) => void): Promise<void> {
    await FqBackend.get().start(context);
    const chapters: FqChapter[] =
      await FqBackend.get().directoryChapters(bookId, tab);
    if (chapters.length === 0) {
      throw new Error('未获取到目录章节');
    }
    FqChapterCacheStore.saveCatalog(bookId, title, cover, kind, chapters, true);
    const cached: Set<string> = FqChapterCacheStore.cachedChapterIds(bookId);
    let done: number = 0;
    for (const chapter of chapters) {
      if (cached.has(chapter.itemId)) {
        done++;
        onProgress(done, chapters.length);
        continue;
      }
      try {
        const text: string = await FqBackend.get().chapterText(chapter.itemId, chapter.title);
        if (text.trim().length > 0) {
          FqChapterCacheStore.write(bookId, chapter.itemId, chapter.title, text);
        }
      } catch (error) {
        hilog.warn(0x0001, TAG, `downloadBook chapter failed: ${chapter.itemId}`);
      }
      done++;
      onProgress(done, chapters.length);
    }
    fqStoreBus.chapterCacheVersion++;
  }
}

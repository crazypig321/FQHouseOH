/**
 * 详情页缓存（kind+id → 详情 + 目录 + 试读 + 书评预览）：
 * 内存 LRU(24) + 磁盘持久化（files/detail_cache/<kind>_<id>.json）。
 *
 * 对齐「复进详情秒开」诉求：命中直接回填五块状态、不再发请求；
 * 标题栏刷新按钮强制重载（force 绕过缓存）后回写最新数据。
 * 二次进入：内存 miss 自动回源磁盘并回填内存 LRU；
 * 磁盘层不淘汰（单条几十 KB，浏览规模可控），清缓存随应用数据删除。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqBookComment, FqBookDetail, FqChapter } from '../model/FqModels';
import { fqAsArray, fqAsRecord, fqBool, fqNum, fqParseObject, fqStr } from './FqJson';

/** 一份详情页快照。 */
export class FqDetailCacheEntry {
  readonly detail: FqBookDetail;
  readonly chapters: FqChapter[];
  readonly previews: Map<string, string>;
  readonly previewComments: FqBookComment[];
  readonly commentTotal: number;

  constructor(detail: FqBookDetail, chapters: FqChapter[], previews: Map<string, string>,
    previewComments: FqBookComment[], commentTotal: number) {
    this.detail = detail;
    this.chapters = chapters;
    this.previews = previews;
    this.previewComments = previewComments;
    this.commentTotal = commentTotal;
  }
}

const TAG: string = 'FqDetailCache';
const MAX_ENTRIES: number = 24;
const FQ_CACHE_DIR: string = 'detail_cache';
const FQ_SAFE_ID: RegExp = /^[A-Za-z0-9_-]{1,128}$/;

const cache: Map<string, FqDetailCacheEntry> = new Map<string, FqDetailCacheEntry>();
/** 插入序（去重）：LRU 淘汰依据。 */
const order: string[] = [];

let filesDir: string = '';

function keyOf(kind: string, id: string): string {
  return `${kind}:${id}`;
}

function diskPath(kind: string, id: string): string {
  return `${filesDir}/${FQ_CACHE_DIR}/${kind}_${id}.json`;
}

/** LRU 触碰：移到序尾。 */
function touch(key: string): void {
  const at: number = order.indexOf(key);
  if (at >= 0) {
    order.splice(at, 1);
  }
  order.push(key);
}

/** 进程内初始化（EntryAbility/首页任一处调用一次即可）。 */
export function fqDetailCacheInit(context: common.Context): void {
  if (filesDir.length > 0) {
    return;
  }
  filesDir = context.filesDir;
  try {
    fs.mkdirSync(`${filesDir}/${FQ_CACHE_DIR}`, true);
  } catch (error) {
    // 已存在或失败（写文件时按需再建）
  }
}

// ---------------------------------------------------------------------------
// 序列化 / 反序列化
// ---------------------------------------------------------------------------

function detailToRecord(detail: FqBookDetail): Record<string, Object> {
  return {
    'bookId': detail.bookId,
    'title': detail.title,
    'author': detail.author,
    'abstractText': detail.abstractText,
    'cover': detail.cover,
    'category': detail.category,
    'creationStatus': detail.creationStatus,
    'wordNumber': detail.wordNumber,
    'serialCount': detail.serialCount,
    'subInfo': detail.subInfo,
    'scoreText': detail.scoreText,
    'tags': detail.tags,
    'original': detail.original,
    'authorTitle': detail.authorTitle,
    'authorAvatar': detail.authorAvatar,
    'readLabel': detail.readLabel,
    'authorId': detail.authorId,
  };
}

function detailFromRecord(rec: Record<string, Object>): FqBookDetail {
  const rawTags: Object[] | null = fqAsArray(rec['tags']);
  const tags: string[] = [];
  if (rawTags !== null) {
    for (const tag of rawTags) {
      if (typeof tag === 'string') {
        tags.push(tag);
      }
    }
  }
  return new FqBookDetail(
    fqStr(rec, 'bookId'),
    fqStr(rec, 'title'),
    fqStr(rec, 'author'),
    fqStr(rec, 'abstractText'),
    fqStr(rec, 'cover'),
    fqStr(rec, 'category'),
    fqNum(rec, 'creationStatus'),
    fqNum(rec, 'wordNumber'),
    fqNum(rec, 'serialCount'),
    fqStr(rec, 'subInfo'),
    fqStr(rec, 'scoreText'),
    tags,
    fqBool(rec, 'original'),
    fqStr(rec, 'authorTitle'),
    fqStr(rec, 'authorAvatar'),
    fqStr(rec, 'readLabel'),
    fqStr(rec, 'authorId'));
}

function commentToRecord(comment: FqBookComment): Record<string, Object> {
  return {
    'id': comment.id,
    'text': comment.text,
    'imageUrls': comment.imageUrls,
    'score': comment.score,
    'diggCount': comment.diggCount,
    'replyCount': comment.replyCount,
    'readSeconds': comment.readSeconds,
    'createdAtMs': comment.createdAtMs,
    'userName': comment.userName,
    'userAvatar': comment.userAvatar,
    'isAuthor': comment.isAuthor,
  };
}

function commentFromRecord(rec: Record<string, Object>): FqBookComment {
  const rawImages: Object[] | null = fqAsArray(rec['imageUrls']);
  const imageUrls: string[] = [];
  if (rawImages !== null) {
    for (const url of rawImages) {
      if (typeof url === 'string') {
        imageUrls.push(url);
      }
    }
  }
  return new FqBookComment(
    fqStr(rec, 'id'),
    fqStr(rec, 'text'),
    imageUrls,
    fqNum(rec, 'score'),
    fqNum(rec, 'diggCount'),
    fqNum(rec, 'replyCount'),
    fqNum(rec, 'readSeconds'),
    fqNum(rec, 'createdAtMs'),
    fqStr(rec, 'userName'),
    fqStr(rec, 'userAvatar'),
    fqBool(rec, 'isAuthor'));
}

function entryToRecord(entry: FqDetailCacheEntry): Record<string, Object> {
  const chapterRecs: Record<string, Object>[] = [];
  for (const chapter of entry.chapters) {
    chapterRecs.push({
      'itemId': chapter.itemId,
      'title': chapter.title,
      'version': chapter.version,
    });
  }
  const previewPairs: Record<string, Object>[] = [];
  entry.previews.forEach((text: string, itemId: string): void => {
    previewPairs.push({ 'k': itemId, 'v': text });
  });
  const commentRecs: Record<string, Object>[] = [];
  for (const comment of entry.previewComments) {
    commentRecs.push(commentToRecord(comment));
  }
  return {
    'v': 1,
    'detail': detailToRecord(entry.detail),
    'chapters': chapterRecs,
    'previews': previewPairs,
    'previewComments': commentRecs,
    'commentTotal': entry.commentTotal,
  };
}

function entryFromRecord(rec: Record<string, Object>): FqDetailCacheEntry | null {
  const rawDetail: Object | undefined = rec['detail'];
  const detailRec: Record<string, Object> | null =
    rawDetail !== undefined ? fqAsRecord(rawDetail) : null;
  if (detailRec === null) {
    return null;
  }
  const chapters: FqChapter[] = [];
  const rawChapters: Object[] | null = fqAsArray(rec['chapters']);
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
      chapters.push(new FqChapter(itemId, fqStr(chapterRec, 'title'), fqStr(chapterRec, 'version')));
    }
  }
  const previews: Map<string, string> = new Map<string, string>();
  const rawPairs: Object[] | null = fqAsArray(rec['previews']);
  if (rawPairs !== null) {
    for (const raw of rawPairs) {
      const pairRec: Record<string, Object> | null = fqAsRecord(raw);
      if (pairRec === null) {
        continue;
      }
      const k: string = fqStr(pairRec, 'k');
      if (k.length === 0) {
        continue;
      }
      previews.set(k, fqStr(pairRec, 'v'));
    }
  }
  const previewComments: FqBookComment[] = [];
  const rawComments: Object[] | null = fqAsArray(rec['previewComments']);
  if (rawComments !== null) {
    for (const raw of rawComments) {
      const commentRec: Record<string, Object> | null = fqAsRecord(raw);
      if (commentRec === null) {
        continue;
      }
      const id: string = fqStr(commentRec, 'id');
      if (id.length === 0) {
        continue;
      }
      previewComments.push(commentFromRecord(commentRec));
    }
  }
  return new FqDetailCacheEntry(detailFromRecord(detailRec), chapters, previews,
    previewComments, fqNum(rec, 'commentTotal'));
}

function readDisk(kind: string, id: string): FqDetailCacheEntry | null {
  if (filesDir.length === 0 || !FQ_SAFE_ID.test(kind) || !FQ_SAFE_ID.test(id)) {
    return null;
  }
  let text: string = '';
  try {
    text = fs.readTextSync(diskPath(kind, id));
  } catch (error) {
    return null;
  }
  const rec: Record<string, Object> | null = fqParseObject(text);
  if (rec === null) {
    return null;
  }
  return entryFromRecord(rec);
}

function writeDisk(kind: string, id: string, entry: FqDetailCacheEntry): void {
  if (filesDir.length === 0 || !FQ_SAFE_ID.test(kind) || !FQ_SAFE_ID.test(id)) {
    return;
  }
  const path: string = diskPath(kind, id);
  let file: fs.File | null = null;
  try {
    fs.mkdirSync(`${filesDir}/${FQ_CACHE_DIR}`, true);
  } catch (error) {
    // 已存在
  }
  try {
    file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(entryToRecord(entry)));
    fs.closeSync(file);
  } catch (error) {
    const err = error as BusinessError;
    hilog.warn(0x0001, TAG, `writeDisk failed: ${path} code=${err.code}`);
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeError) {
        // 忽略
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

/** 取缓存：内存命中触碰 LRU；内存 miss 回源磁盘并回填内存；均未命中返回 null。 */
export function fqDetailCacheGet(kind: string, id: string): FqDetailCacheEntry | null {
  const key: string = keyOf(kind, id);
  const entry: FqDetailCacheEntry | undefined = cache.get(key);
  if (entry !== undefined) {
    touch(key);
    return entry;
  }
  const diskEntry: FqDetailCacheEntry | null = readDisk(kind, id);
  if (diskEntry === null) {
    return null;
  }
  cache.set(key, diskEntry);
  touch(key);
  while (order.length > MAX_ENTRIES) {
    const oldestKey: string | undefined = order.shift();
    if (oldestKey === undefined) {
      break;
    }
    cache.delete(oldestKey);
  }
  return diskEntry;
}

/** 写缓存：内存 LRU + 磁盘同步落盘。 */
export function fqDetailCachePut(kind: string, id: string, entry: FqDetailCacheEntry): void {
  const key: string = keyOf(kind, id);
  cache.delete(key);
  cache.set(key, entry);
  touch(key);
  while (order.length > MAX_ENTRIES) {
    const oldestKey: string | undefined = order.shift();
    if (oldestKey === undefined) {
      break;
    }
    cache.delete(oldestKey);
  }
  writeDisk(kind, id, entry);
}

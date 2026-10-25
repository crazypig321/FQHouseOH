/**
 * 详情页内存缓存（kind+id → 详情 + 目录 + 试读 + 书评预览）。
 *
 * 对齐「复进详情秒开」诉求：命中直接回填五块状态、不再发请求；
 * 标题栏刷新按钮强制重载（force 绕过缓存）后回写最新数据。
 * LRU 上限 24 条（书架在册 + 最近浏览规模），进程内存级、不持久化。
 */

import { FqBookComment, FqBookDetail, FqChapter } from '../model/FqModels';

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

const MAX_ENTRIES: number = 24;

const cache: Map<string, FqDetailCacheEntry> = new Map<string, FqDetailCacheEntry>();
/** 插入序（去重）：LRU 淘汰依据。 */
const order: string[] = [];

function keyOf(kind: string, id: string): string {
  return `${kind}:${id}`;
}

/** LRU 触碰：移到序尾。 */
function touch(key: string): void {
  const at: number = order.indexOf(key);
  if (at >= 0) {
    order.splice(at, 1);
  }
  order.push(key);
}

/** 取缓存（命中会触碰 LRU）；未命中返回 null。 */
export function fqDetailCacheGet(kind: string, id: string): FqDetailCacheEntry | null {
  const key: string = keyOf(kind, id);
  const entry: FqDetailCacheEntry | undefined = cache.get(key);
  if (entry === undefined) {
    return null;
  }
  touch(key);
  return entry;
}

/** 写缓存并淘汰最旧条目。 */
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
}

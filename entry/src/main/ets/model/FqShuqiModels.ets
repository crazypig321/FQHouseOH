/**
 * 书旗数据源的模型与解析（对齐 fqapp lib/models/shuqi_book.dart）。
 * 后端 /api/v1/shuqi/* 已把上游字段归一化成稳定形状，这里只做类型包装，
 * 不再重做一遍字段兜底。这条链路是只读的：不写历史/书架/章节缓存/进度。
 */

import { FqBookDetail, FqChapter, FqMediaItem } from './FqModels';
import { fqAsArray, fqAsInt, fqAsRecord, fqBool, fqStr } from '../core/FqJson';

/** FqMediaItem.source 的书旗取值（fqapp shuqiSourceId）。 */
export const FQ_SHUQI_SOURCE_ID: string = 'shuqi';

/** 书旗条目判据（fqapp isShuqiItem）。 */
export function fqIsShuqiItem(item: FqMediaItem): boolean {
  return item.source === FQ_SHUQI_SOURCE_ID;
}

/** 书籍详情（/api/v1/shuqi/book 的 data）。 */
export class FqShuqiBook {
  readonly bookId: string;
  readonly name: string;
  readonly author: string;
  readonly intro: string;
  /** 分类/标签/状态/评分逗号串（后端已拼接）。 */
  readonly kind: string;
  readonly coverUrl: string;
  /** 字数文案（后端已归一化成「132.8万字」形态）。 */
  readonly wordCount: string;
  readonly lastChapter: string;
  /** 完结 / 连载 / 空串未知。 */
  readonly status: string;
  /** 总章数（目录回退递推用）；0 表示详情没拿全。 */
  readonly chapterTotalNum: number;

  constructor(bookId: string, name: string, author: string, intro: string, kind: string,
    coverUrl: string, wordCount: string, lastChapter: string, status: string,
    chapterTotalNum: number) {
    this.bookId = bookId;
    this.name = name;
    this.author = author;
    this.intro = intro;
    this.kind = kind;
    this.coverUrl = coverUrl;
    this.wordCount = wordCount;
    this.lastChapter = lastChapter;
    this.status = status;
    this.chapterTotalNum = chapterTotalNum;
  }

  /** 转搜索卡片同款条目（书旗只读来源标记）。 */
  toMediaItem(): FqMediaItem {
    return new FqMediaItem(this.bookId, this.name, this.coverUrl, this.author,
      '', '', 'book', 0, this.intro, '', '', 0, null, FQ_SHUQI_SOURCE_ID);
  }
}

/** 空详情占位（组件默认值用）。 */
export function fqEmptyShuqiBook(): FqShuqiBook {
  return new FqShuqiBook('', '', '', '', '', '', '', '', '', 0);
}

/** 书旗状态文案 → FqBookDetail.creationStatus（0 完结 / 1 连载 / -1 未知）。 */
function fqShuqiCreationStatus(status: string): number {
  if (status === '完结') {
    return 0;
  }
  if (status === '连载') {
    return 1;
  }
  return -1;
}

/** 「132.8万字」形态文案 → 字数（解析失败 0，FqBookDetail.wordLabel 再格式化回同形态）。 */
function fqShuqiWordNumber(wordCount: string): number {
  const label: string = wordCount.trim();
  if (label.length === 0) {
    return 0;
  }
  let scale: number = 1;
  let digits: string = label;
  if (label.endsWith('万字')) {
    scale = 10000;
    digits = label.substring(0, label.length - 2);
  } else if (label.endsWith('亿字')) {
    scale = 100000000;
    digits = label.substring(0, label.length - 2);
  } else if (label.endsWith('字')) {
    digits = label.substring(0, label.length - 1);
  }
  const value: number = Number.parseFloat(digits);
  if (Number.isNaN(value) || value < 0) {
    return 0;
  }
  return Math.round(value * scale);
}

/** 书旗详情 → 番茄详情模型（复用 DetailPage 展示；无评分/标签/作者头像，评论区隐藏）。 */
export function fqShuqiBookToDetail(book: FqShuqiBook): FqBookDetail {
  return new FqBookDetail(
    book.bookId,
    book.name,
    book.author,
    book.intro,
    book.coverUrl,
    book.kind,
    fqShuqiCreationStatus(book.status),
    fqShuqiWordNumber(book.wordCount),
    book.chapterTotalNum,
    '',
    '',
    [],
    false,
    '',
    '',
    '',
    '',
  );
}

/** 目录里的一章。 */
export class FqShuqiChapter {
  readonly chapterId: string;
  readonly title: string;
  readonly isVip: boolean;

  constructor(chapterId: string, title: string, isVip: boolean) {
    this.chapterId = chapterId;
    this.title = title;
    this.isVip = isVip;
  }
}

/** 目录响应的 data：path 是 'h5'（真章名）或 'index'（递推「第N章」占位）。 */
export class FqShuqiToc {
  readonly path: string;
  readonly total: number;
  readonly chapters: FqShuqiChapter[];

  constructor(path: string, total: number, chapters: FqShuqiChapter[]) {
    this.path = path;
    this.total = total;
    this.chapters = chapters;
  }

  /** 回退路径下的章名是「第N章」占位，界面据此提示（fqapp hasRealTitles）。 */
  get hasRealTitles(): boolean {
    return this.path === 'h5';
  }

  /** 转阅读器章节列表。 */
  toReaderChapters(): FqChapter[] {
    const list: FqChapter[] = [];
    for (const chapter of this.chapters) {
      list.push(new FqChapter(chapter.chapterId, chapter.title, ''));
    }
    return list;
  }
}

/** 搜索响应 → 卡片条目（后端已按 书名|作者 去重；这里再按 kind:id 兜底，fqapp loadShuqiSearch）。 */
export function fqParseShuqiSearch(payload: Record<string, Object>): FqMediaItem[] {
  const items: FqMediaItem[] = [];
  const seen: Set<string> = new Set<string>();
  const rows: Object[] | null = fqAsArray(payload['data']);
  if (rows === null) {
    return items;
  }
  for (const row of rows) {
    const rec: Record<string, Object> | null = fqAsRecord(row);
    if (rec === null) {
      continue;
    }
    const item: FqMediaItem = fqShuqiItemFromSearch(rec);
    if (item.id.length === 0) {
      continue;
    }
    const key: string = `${item.kind}:${item.id}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    items.push(item);
  }
  return items;
}

/** 搜索条目 → FqMediaItem（fqapp shuqiMediaItemFromSearch：badge/ep 置空、kind 固定 book、无评分）。 */
function fqShuqiItemFromSearch(rec: Record<string, Object>): FqMediaItem {
  return new FqMediaItem(
    fqStr(rec, 'bookId'),
    fqStr(rec, 'name'),
    fqStr(rec, 'coverUrl'),
    fqStr(rec, 'author'),
    '',
    '',
    'book',
    0,
    fqStr(rec, 'intro'),
    '',
    '',
    0,
    null,
    FQ_SHUQI_SOURCE_ID,
  );
}

/** 详情响应 data → FqShuqiBook；data 缺失返回空占位。 */
export function fqParseShuqiBook(payload: Record<string, Object>): FqShuqiBook {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return fqEmptyShuqiBook();
  }
  return new FqShuqiBook(
    fqStr(data, 'bookId'),
    fqStr(data, 'name'),
    fqStr(data, 'author'),
    fqStr(data, 'intro'),
    fqStr(data, 'kind'),
    fqStr(data, 'coverUrl'),
    fqStr(data, 'wordCount'),
    fqStr(data, 'lastChapter'),
    fqStr(data, 'status'),
    fqAsInt(data['chapterTotalNum'], 0),
  );
}

/** 目录响应 data → FqShuqiToc；data 缺失返回空目录。 */
export function fqParseShuqiToc(payload: Record<string, Object>): FqShuqiToc {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return new FqShuqiToc('', 0, []);
  }
  const chapters: FqShuqiChapter[] = [];
  const rows: Object[] | null = fqAsArray(data['chapters']);
  if (rows !== null) {
    for (const row of rows) {
      const rec: Record<string, Object> | null = fqAsRecord(row);
      if (rec === null) {
        continue;
      }
      const id: string = fqStr(rec, 'chapterId');
      if (id.length === 0) {
        continue;
      }
      chapters.push(new FqShuqiChapter(id, fqStr(rec, 'title'), fqBool(rec, 'isVip')));
    }
  }
  const total: number = fqAsInt(data['total'], 0);
  return new FqShuqiToc(fqStr(data, 'path'), total > 0 ? total : chapters.length, chapters);
}

/** 正文响应 data.content → 章节文本；缺失返回空串（调用方按空章报错）。 */
export function fqParseShuqiChapterText(payload: Record<string, Object>): string {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return '';
  }
  return fqStr(data, 'content');
}

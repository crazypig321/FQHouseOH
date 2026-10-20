/**
 * 业务展示模型（M1 简化子集）。
 * 字段语义对齐 fqapp lib/models/media_item.dart 的 MediaItem / SearchTab
 * 与 lib/models/book_detail.dart 的 BookDetail。
 */

/** 内容卡片。kind: 'book' | 'video' | 'manju' | 'manga' | 'audio'。 */
export class FqMediaItem {
  readonly id: string;
  readonly title: string;
  readonly cover: string;
  readonly author: string;
  readonly badge: string;
  readonly ep: string;
  readonly kind: string;
  /** 0-10 评分，0 表示未知。 */
  readonly score: number;
  readonly intro: string;
  readonly seriesId: string;
  readonly episodeId: string;
  readonly followerCount: number;

  constructor(
    id: string,
    title: string,
    cover: string,
    author: string,
    badge: string,
    ep: string,
    kind: string,
    score: number,
    intro: string,
    seriesId: string,
    episodeId: string,
    followerCount: number,
  ) {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
    this.badge = badge;
    this.ep = ep;
    this.kind = kind;
    this.score = score;
    this.intro = intro;
    this.seriesId = seriesId;
    this.episodeId = episodeId;
    this.followerCount = followerCount;
  }
}

/** 首页推荐一页：条目 + 翻页游标。nextOffset < 0 表示无更多。 */
export class FqHomePage {
  readonly items: FqMediaItem[];
  readonly nextOffset: number;
  readonly sessionId: string;

  constructor(items: FqMediaItem[], nextOffset: number, sessionId: string) {
    this.items = items;
    this.nextOffset = nextOffset;
    this.sessionId = sessionId;
  }
}

/** 搜索结果分栏。hasMore=false 表示服务端明确告知无更多。 */
export class FqSearchTab {
  readonly title: string;
  readonly items: FqMediaItem[];
  readonly hasMore: boolean;
  readonly nextOffset: number;

  constructor(title: string, items: FqMediaItem[], hasMore: boolean, nextOffset: number) {
    this.title = title;
    this.items = items;
    this.hasMore = hasMore;
    this.nextOffset = nextOffset;
  }
}

/** 书籍详情（/api/detail）。 */
export class FqBookDetail {
  readonly bookId: string;
  readonly title: string;
  readonly author: string;
  readonly abstractText: string;
  readonly cover: string;
  readonly category: string;
  /** 0 完结 / 1 连载中 / 4 停更 / -1 未知。 */
  readonly creationStatus: number;
  readonly wordNumber: number;
  readonly serialCount: number;
  readonly subInfo: string;
  readonly scoreText: string;

  constructor(
    bookId: string,
    title: string,
    author: string,
    abstractText: string,
    cover: string,
    category: string,
    creationStatus: number,
    wordNumber: number,
    serialCount: number,
    subInfo: string,
    scoreText: string,
  ) {
    this.bookId = bookId;
    this.title = title;
    this.author = author;
    this.abstractText = abstractText;
    this.cover = cover;
    this.category = category;
    this.creationStatus = creationStatus;
    this.wordNumber = wordNumber;
    this.serialCount = serialCount;
    this.subInfo = subInfo;
    this.scoreText = scoreText;
  }

  get statusLabel(): string {
    if (this.creationStatus === 0) {
      return '完结';
    }
    if (this.creationStatus === 1) {
      return '连载中';
    }
    if (this.creationStatus === 4) {
      return '停更';
    }
    return '';
  }

  get wordLabel(): string {
    return formatFqWordCount(this.wordNumber);
  }
}

/** 空详情占位（组件默认值用）。 */
export function fqEmptyBookDetail(): FqBookDetail {
  return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '');
}

/** 对齐 fqapp formatWordCount：1328318 -> 132.8万字。 */
export function formatFqWordCount(words: number): string {
  if (words <= 0) {
    return '';
  }
  if (words >= 100000000) {
    return `${trimFqZero((words / 100000000).toFixed(1))}亿字`;
  }
  if (words >= 10000) {
    return `${trimFqZero((words / 10000).toFixed(1))}万字`;
  }
  return `${words}字`;
}

function trimFqZero(label: string): string {
  if (label.endsWith('.0')) {
    return label.substring(0, label.length - 2);
  }
  return label;
}

/** 空卡片占位（组件默认值用）。 */
export function fqEmptyMediaItem(): FqMediaItem {
  return new FqMediaItem('', '', '', '', '', '', 'book', 0, '', '', '', 0);
}

/** kind -> 详情/目录接口使用的 tab 名。 */
export function fqKindToTab(kind: string): string {
  if (kind === 'video') {
    return '短剧';
  }
  if (kind === 'manju') {
    return '漫剧';
  }
  if (kind === 'manga') {
    return '漫画';
  }
  if (kind === 'audio') {
    return '听书';
  }
  return '小说';
}

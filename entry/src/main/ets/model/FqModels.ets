/**
 * 业务展示模型（M1 简化子集）。
 * 字段语义对齐 fqapp lib/models/media_item.dart 的 MediaItem / SearchTab
 * 与 lib/models/book_detail.dart 的 BookDetail。
 */

/** 内容卡片。kind: 'book' | 'video' | 'manju' | 'manga' | 'audio'。 */
export class FqMediaItem {
  /** 内容唯一标识。 */
  readonly id: string;
  /** 标题。 */
  readonly title: string;
  /** 封面图 URL。 */
  readonly cover: string;
  /** 作者。 */
  readonly author: string;
  /** 徽标文案（如"独家"、"VIP"等）。 */
  readonly badge: string;
  /** 集数/章节信息文案。 */
  readonly ep: string;
  /** 内容类型：'book' | 'video' | 'manju' | 'manga' | 'audio'。 */
  readonly kind: string;
  /** 0-10 评分，0 表示未知。 */
  readonly score: number;
  /** 简介。 */
  readonly intro: string;
  /** 系列 ID。 */
  readonly seriesId: string;
  /** 章节/集 ID。 */
  readonly episodeId: string;
  /** 关注人数。 */
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

/**
 * 首页推荐一页：条目 + 翻页游标。nextOffset < 0 表示无更多。
 * cellId 为官方第二段（series-feed/cell/change）所需的首个 cell_id_str；
 * 数字型 cell_id 在 JSON 里是 double，会被精度截断成上游认不出的值。
 */
export class FqHomePage {
  readonly items: FqMediaItem[];
  readonly nextOffset: number;
  readonly sessionId: string;
  readonly cellId: string;

  constructor(items: FqMediaItem[], nextOffset: number, sessionId: string, cellId: string) {
    this.items = items;
    this.nextOffset = nextOffset;
    this.sessionId = sessionId;
    this.cellId = cellId;
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
  /** 分类标签（tags 拆分）。 */
  readonly tags: string[];
  /** authorize_type == '1' 即原创。 */
  readonly original: boolean;
  /** 作者头衔徽标（author_info.user_title_infos.title_text，如 作家Lv.5）。 */
  readonly authorTitle: string;
  /** 作者头像（完整 URL 或后端相对路径）。 */
  readonly authorAvatar: string;
  /** 在读人数展示文案：优先 formatCounter(read_count)，否则 sub_info。 */
  readonly readLabel: string;

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
    tags: string[],
    original: boolean,
    authorTitle: string,
    authorAvatar: string,
    readLabel: string,
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
    this.tags = tags;
    this.original = original;
    this.authorTitle = authorTitle;
    this.authorAvatar = authorAvatar;
    this.readLabel = readLabel;
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
  return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '', [], false, '', '', '');
}

/** 目录章节（/api/directory，M1 仅取标题与 itemId）。 */
export class FqChapter {
  readonly itemId: string;
  readonly title: string;

  constructor(itemId: string, title: string) {
    this.itemId = itemId;
    this.title = title;
  }
}

/** 对齐 fqapp formatCounter：纯数字 79528 -> 7.9万，非数字原样返回。 */
export function fqFormatCounter(raw: string): string {
  const text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  const parsed: number = Number.parseInt(text, 10);
  if (Number.isNaN(parsed)) {
    return text;
  }
  if (parsed < 10000) {
    return `${parsed}`;
  }
  if (parsed >= 100000000) {
    return `${trimFqZero((parsed / 100000000).toFixed(1))}亿`;
  }
  return `${trimFqZero((parsed / 10000).toFixed(1))}万`;
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

/** kind -> 详情/目录接口使用的 tab 名（同时用作界面上的 kind 标签文案）。 */
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

/** kind -> 界面标签文案。与 fqKindToTab 同映射。 */
export function fqKindLabel(kind: string): string {
  return fqKindToTab(kind);
}

/** 排行榜单（算法维度）：rank_algo 即请求参数 algo_type。 */
export class FqRankTab {
  readonly name: string;
  readonly algo: number;

  constructor(name: string, algo: number) {
    this.name = name;
    this.algo = algo;
  }

  get isDrama(): boolean {
    return this.name.indexOf('短剧') >= 0 || this.name.indexOf('漫剧') >= 0;
  }
}

/** 排行榜分类：info_id 即请求参数 rank_sub_info_id。 */
export class FqRankCategory {
  readonly name: string;
  readonly id: number;

  constructor(name: string, id: number) {
    this.name = name;
    this.id = id;
  }
}

/** 排行榜条目。kind: 'book' | 'video' | 'manju'。 */
export class FqRankEntry {
  readonly position: number;
  readonly id: string;
  readonly title: string;
  readonly cover: string;
  readonly author: string;
  readonly abstractText: string;
  readonly category: string;
  /** 0 完结 / 1 连载中 / 4 停更 / -1 未知。 */
  readonly creationStatus: number;
  readonly wordNumber: number;
  readonly readCount: number;
  readonly kind: string;
  readonly seriesId: string;

  constructor(
    position: number,
    id: string,
    title: string,
    cover: string,
    author: string,
    abstractText: string,
    category: string,
    creationStatus: number,
    wordNumber: number,
    readCount: number,
    kind: string,
    seriesId: string,
  ) {
    this.position = position;
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
    this.abstractText = abstractText;
    this.category = category;
    this.creationStatus = creationStatus;
    this.wordNumber = wordNumber;
    this.readCount = readCount;
    this.kind = kind;
    this.seriesId = seriesId;
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

  get metaLabel(): string {
    const parts: string[] = [];
    if (this.author.length > 0) {
      parts.push(this.author);
    }
    if (this.category.length > 0) {
      parts.push(this.category);
    }
    const status = this.statusLabel;
    if (status.length > 0) {
      parts.push(status);
    }
    return parts.join(' · ');
  }
}

/** 榜单一页：条目 + 是否还有下一页。 */
export class FqRankBoard {
  readonly entries: FqRankEntry[];
  readonly hasMore: boolean;

  constructor(entries: FqRankEntry[], hasMore: boolean) {
    this.entries = entries;
    this.hasMore = hasMore;
  }

  get isEmpty(): boolean {
    return this.entries.length === 0;
  }
}

/** 排行榜目录：一个 rankId 下的算法 tab 与分类。 */
export class FqRankCatalog {
  readonly rankId: string;
  readonly tabs: FqRankTab[];
  readonly categories: FqRankCategory[];

  constructor(rankId: string, tabs: FqRankTab[], categories: FqRankCategory[]) {
    this.rankId = rankId;
    this.tabs = tabs;
    this.categories = categories;
  }

  get isEmpty(): boolean {
    return this.rankId.length === 0 || this.tabs.length === 0;
  }
}

/** 空目录占位（页面默认值用）。 */
export function fqEmptyRankCatalog(): FqRankCatalog {
  return new FqRankCatalog('', [], []);
}

// ---------------------------------------------------------------------------
// 书评（fqapp lib/models/book_comment.dart）
// ---------------------------------------------------------------------------

/** 单条书评（/api/v1/books/{id}/comments 的 data.comment[] 条目）。 */
export class FqBookComment {
  readonly id: string;
  readonly text: string;
  readonly imageUrls: string[];
  /** 上游 0-10 评分，0 表示未评。 */
  readonly score: number;
  readonly diggCount: number;
  readonly replyCount: number;
  /** 读者已读时长（秒）。 */
  readonly readSeconds: number;
  /** 发布时间（毫秒），0 表示未知。 */
  readonly createdAtMs: number;
  readonly userName: string;
  readonly userAvatar: string;
  readonly isAuthor: boolean;

  constructor(
    id: string,
    text: string,
    imageUrls: string[],
    score: number,
    diggCount: number,
    replyCount: number,
    readSeconds: number,
    createdAtMs: number,
    userName: string,
    userAvatar: string,
    isAuthor: boolean,
  ) {
    this.id = id;
    this.text = text;
    this.imageUrls = imageUrls;
    this.score = score;
    this.diggCount = diggCount;
    this.replyCount = replyCount;
    this.readSeconds = readSeconds;
    this.createdAtMs = createdAtMs;
    this.userName = userName;
    this.userAvatar = userAvatar;
    this.isAuthor = isAuthor;
  }

  /** 上游 0-10 评分换算五星制（含半星）。 */
  get stars(): number {
    const clamped: number = this.score < 0 ? 0 : (this.score > 10 ? 10 : this.score);
    return clamped / 2;
  }

  /** 相对发布时间（`1天前`），未知时间返回空串。 */
  relativeTime(nowMs?: number): string {
    if (this.createdAtMs <= 0) {
      return '';
    }
    const reference: number = nowMs !== undefined ? nowMs : Date.now();
    const seconds: number = Math.floor((reference - this.createdAtMs) / 1000);
    if (seconds < 60) {
      return '刚刚';
    }
    if (seconds < 3600) {
      return `${Math.floor(seconds / 60)}分钟前`;
    }
    if (seconds < 86400) {
      return `${Math.floor(seconds / 3600)}小时前`;
    }
    if (seconds < 86400 * 30) {
      return `${Math.floor(seconds / 86400)}天前`;
    }
    if (seconds < 86400 * 365) {
      return `${Math.floor(seconds / (86400 * 30))}个月前`;
    }
    return `${Math.floor(seconds / (86400 * 365))}年前`;
  }

  /** `阅读14小时后点评` 文案，未读时为空。 */
  get readDurationLabel(): string {
    if (this.readSeconds <= 0) {
      return '';
    }
    const hours: number = Math.floor(this.readSeconds / 3600);
    if (hours >= 1) {
      return `阅读${hours}小时后点评`;
    }
    const minutes: number = Math.floor(this.readSeconds / 60);
    if (minutes >= 1) {
      return `阅读${minutes}分钟后点评`;
    }
    return `阅读${this.readSeconds}秒后点评`;
  }
}

/** 书评一页 + 详情页头部计数。 */
export class FqBookCommentPage {
  readonly comments: FqBookComment[];
  /** comment_cnt：书评总数。 */
  readonly totalCount: number;
  /** score_cnt：评分人数。 */
  readonly scoreCount: number;
  /** context：上游现成展示串（如 `2.6万人点评`）。 */
  readonly scoreContext: string;
  readonly hasMore: boolean;
  readonly nextOffset: number;

  constructor(
    comments: FqBookComment[],
    totalCount: number,
    scoreCount: number,
    scoreContext: string,
    hasMore: boolean,
    nextOffset: number,
  ) {
    this.comments = comments;
    this.totalCount = totalCount;
    this.scoreCount = scoreCount;
    this.scoreContext = scoreContext;
    this.hasMore = hasMore;
    this.nextOffset = nextOffset;
  }

  get isEmpty(): boolean {
    return this.comments.length === 0;
  }
}

/** 数字计数 79528 -> 7.9万（对齐 fqapp formatCount，用于点赞/回复数）。 */
export function fqFormatCountInt(value: number): string {
  if (value < 10000) {
    return `${value}`;
  }
  if (value < 100000000) {
    return `${trimFqZero((value / 10000).toFixed(1))}万`;
  }
  return `${trimFqZero((value / 100000000).toFixed(1))}亿`;
}

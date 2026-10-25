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
  /** 作者主页 ID（author_info.user_id；漫画/漫剧的 1_ 前缀不可解析，置空）。 */
  readonly authorId: string;

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
    authorId: string,
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
    this.authorId = authorId;
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
  return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '', [], false, '', '', '', '');
}

/** 作者主页作品（/api/v1/authors/{id} 的 author_book_info 条目）。 */
export class FqAuthorWork {
  readonly id: string;
  readonly title: string;
  readonly cover: string;
  readonly intro: string;
  /** 主分类（category 逗号列表取首项）。 */
  readonly category: string;
  /** 0 完结 / 1 连载中 / 4 停更 / -1 未知。 */
  readonly creationStatus: number;
  readonly wordNumber: number;
  /** 原始在读计数（纯数字字符串）。 */
  readonly readCount: string;

  constructor(id: string, title: string, cover: string, intro: string, category: string,
    creationStatus: number, wordNumber: number, readCount: string) {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.intro = intro;
    this.category = category;
    this.creationStatus = creationStatus;
    this.wordNumber = wordNumber;
    this.readCount = readCount;
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

  /** 分类 · 状态 · 字数（对齐详情页元信息行）。 */
  get metaLabel(): string {
    const parts: string[] = [];
    if (this.category.length > 0) {
      parts.push(this.category);
    }
    if (this.statusLabel.length > 0) {
      parts.push(this.statusLabel);
    }
    if (this.wordLabel.length > 0) {
      parts.push(this.wordLabel);
    }
    return parts.join(' · ');
  }
}

/** 作者主页（/api/v1/authors/{id}，上游 /reading/user/basic_info/get/v）。 */
export class FqAuthorProfile {
  readonly id: string;
  readonly name: string;
  readonly avatar: string;
  /** 作者简介（description，author_desc 通常为空）。 */
  readonly description: string;
  /** 等级徽标文案（user_title_infos[].title_text，如 作家Lv.5）。 */
  readonly level: string;
  readonly followerCount: number;
  /** 上游报告的作品总数（可能多于 works 实际条数）。 */
  readonly workCount: number;
  readonly works: FqAuthorWork[];

  constructor(id: string, name: string, avatar: string, description: string, level: string,
    followerCount: number, workCount: number, works: FqAuthorWork[]) {
    this.id = id;
    this.name = name;
    this.avatar = avatar;
    this.description = description;
    this.level = level;
    this.followerCount = followerCount;
    this.workCount = workCount;
    this.works = works;
  }

  get isEmpty(): boolean {
    return this.id.length === 0 && this.name.length === 0;
  }

  /** 「2.1万粉丝」；计数未知或为 0 时返回空（0粉丝 是噪音）。 */
  get followerLabel(): string {
    if (this.followerCount <= 0) {
      return '';
    }
    const formatted: string = fqFormatCounter(`${this.followerCount}`);
    if (formatted.length === 0 || formatted === '0') {
      return '';
    }
    return `${formatted}粉丝`;
  }

  get workCountLabel(): string {
    return this.workCount > 0 ? `${this.workCount} 部作品` : '';
  }
}

/** 目录章节（/api/directory：标题 + itemId + 内容版本 version）。 */
export class FqChapter {
  readonly itemId: string;
  readonly title: string;
  /** 章节内容版本（目录 item_data_list.version；段评接口必传，缺失回目录刷新）。 */
  readonly version: string;

  constructor(itemId: string, title: string, version: string = '') {
    this.itemId = itemId;
    this.title = title;
    this.version = version;
  }
}

/** 剧集单个清晰度档（/api/content data.variants 行）。 */
export class FqEpisodeVariant {
  readonly name: string;
  readonly url: string;
  readonly keyHex: string;
  readonly height: number;

  constructor(name: string, url: string, keyHex: string, height: number) {
    this.name = name;
    this.url = url;
    this.keyHex = keyHex;
    this.height = height;
  }
}

/** 剧集可播放流（/api/content；ohos 不带 mode → 后端 c1 供流，/src/ 相对路径由 resourceUrl 锚定）。 */
export class FqEpisodeSource {
  readonly url: string;
  readonly keyHex: string;
  /** 全部清晰度档（官方面板高→低）；上游只给一路时为空。 */
  readonly variants: FqEpisodeVariant[];

  constructor(url: string, keyHex: string = '', variants: FqEpisodeVariant[] = []) {
    this.url = url;
    this.keyHex = keyHex;
    this.variants = variants;
  }
}

/** 弹幕条目（/api/v1/videos/{vid}/danmaku 的 data_list[i]，时间点毫秒）。 */
export class FqDanmaku {
  readonly id: string;
  readonly text: string;
  /** 出现时间点（comment.expand.offset_time，毫秒）。 */
  readonly offsetMs: number;

  constructor(id: string, text: string, offsetMs: number) {
    this.id = id;
    this.text = text;
    this.offsetMs = offsetMs;
  }
}

/** 弹幕一页（cursor 续拉；nextQueryMs 为官方建议的下一次查询时间，毫秒）。 */
export class FqDanmakuPage {
  readonly items: FqDanmaku[];
  readonly hasMore: boolean;
  readonly cursor: string;
  readonly nextQueryMs: number;

  constructor(items: FqDanmaku[], hasMore: boolean, cursor: string, nextQueryMs: number) {
    this.items = items;
    this.hasMore = hasMore;
    this.cursor = cursor;
    this.nextQueryMs = nextQueryMs;
  }
}

/**
 * 短剧关联原著（/api/v1/series/{id} 的 data.video_relate_book.book_info，
 * 官方 SaasBookInfo 子集：book_id/book_name/thumb_url）。剧无原著关联为 null。
 */
export class FqSeriesRelateBook {
  readonly id: string;
  readonly title: string;
  readonly cover: string;

  constructor(id: string, title: string, cover: string) {
    this.id = id;
    this.title = title;
    this.cover = cover;
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

/**
 * 集评一页（/api/v1/videos/{vid}/danmaku 全量列表形态：官方每集评论区即弹幕流，
 * start_offset_time=0 + cursor 续拉；对齐 fqapp playletDanmaku）。
 * cursor 为不透明续拉串（不能用数字 offset 表达）。
 */
export class FqEpisodeCommentPage {
  readonly comments: FqBookComment[];
  readonly totalCount: number;
  readonly hasMore: boolean;
  readonly cursor: string;

  constructor(comments: FqBookComment[], totalCount: number, hasMore: boolean, cursor: string) {
    this.comments = comments;
    this.totalCount = totalCount;
    this.hasMore = hasMore;
    this.cursor = cursor;
  }
}

/** 章末章评聚合信息（/api/v1/chapters/{itemId}/reviews 的最大段键桶，官方章评入口）。 */
export class FqChapterIdeaMeta {
  /** 章末章评段键（ideas data.data 最大键，如 10000；-1 无章评）。 */
  readonly endParaIndex: number;
  /** 章末章评数。 */
  readonly endCount: number;

  constructor(endParaIndex: number, endCount: number) {
    this.endParaIndex = endParaIndex;
    this.endCount = endCount;
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

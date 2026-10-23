/**
 * 后端 JSON 载荷解析器。
 *
 * 忠实移植 fqapp lib/models/media_item.dart 的
 * MediaItem.fromRaw / parseMediaItems / parseSearchTabs / separateManjuSearchTabs
 * 与 lib/models/book_detail.dart 的 BookDetail.fromPayload（M1 用到的子集）。
 */

import {
  fqAsArray,
  fqAsInt,
  fqAsRecord,
  fqEmptyRecord,
  fqFirstString,
  fqKeys,
  fqNum,
  fqParseObject,
  fqShallowMergeInto,
  fqStr,
  fqTruthyAny,
} from './FqJson';
import {
  FqAuthorProfile,
  FqAuthorWork,
  FqBookComment,
  FqBookCommentPage,
  FqBookDetail,
  FqChapter,
  FqHomePage,
  FqMediaItem,
  FqRankBoard,
  FqRankCatalog,
  FqRankCategory,
  FqRankEntry,
  FqRankTab,
  FqSearchTab,
  fqEmptyRankCatalog,
  fqFormatCounter,
} from '../model/FqModels';
import { FqParagraphComment } from '../reader/ReaderTypes';

const VIDEO_RE: RegExp = /短剧|短片|剧集|video|drama/i;
const MANGA_RE: RegExp = /漫画|轻漫|条漫|comic|manga/i;
const AUDIO_RE: RegExp = /有声|听书|音频|朗读|audio|novelfm/i;

const VIDEO_KEYS: string[] = ['video_id', 'vid', 'pseries_id', 'series_id', 'video_platform', 'use_video_model'];
const MANGA_KEYS: string[] = ['manga_id', 'comic_id', 'manga_type', 'manga_info', 'comic_info', 'is_manga', 'is_comic'];
const AUDIO_KEYS: string[] = [
  'album_id', 'audio_book_id', 'audio_id', 'listen_book_id',
  'audio_info', 'tone_id', 'is_audio', 'is_listen',
];
const TEXT_BLOB_KEYS: string[] = ['category', 'type', 'book_type_name', 'cell_alias', 'card_tips'];

const IDENTITY_KEYS: string[] = [
  'book_id', 'video_id', 'vid', 'series_id', 'pseries_id',
  'manga_id', 'comic_id', 'audio_book_id', 'audio_id', 'id', 'item_id',
];

const VISIT_KEYS: string[] = [
  'tab_item', 'cell_data', 'cell_view', 'book_data', 'search_tabs',
  'data', 'items', 'lists', 'item_data_list', 'recommend_list',
];

const SEARCH_MEDIA_ID_KEYS: string[] = [
  'book_id', 'video_id', 'vid', 'series_id', 'pseries_id',
  'manga_id', 'comic_id', 'audio_book_id', 'audio_id', 'album_id',
  'item_id', 'id',
];
const SEARCH_MEDIA_CONTENT_KEYS: string[] = [
  'title', 'name', 'raw_book_name', 'book_name',
  'thumb_url', 'cover', 'cover_url', 'poster', 'author', 'author_name',
];

// ---------------------------------------------------------------------------
// MediaItem.fromRaw
// ---------------------------------------------------------------------------

function fqNormalizeKind(value: Object | undefined): string {
  const raw: string = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (raw === 'manju' || raw === 'comic_drama' || raw === '漫剧' || raw === '动态漫') {
    return 'manju';
  }
  if (raw === 'video' || raw === 'drama' || raw === 'short_drama' || raw === 'short-drama' || raw === '短剧' || raw === '短片') {
    return 'video';
  }
  if (raw === 'manga' || raw === 'comic' || raw === '漫画') {
    return 'manga';
  }
  if (raw === 'audio' || raw === 'audiobook' || raw === 'audio_book' || raw === '听书' || raw === '有声') {
    return 'audio';
  }
  if (raw === 'book' || raw === 'novel' || raw === '小说') {
    return 'book';
  }
  return '';
}

/** Dart `_mapFrom`：Map 取本体，非空 List 取首元素。 */
function fqMapFrom(value: Object | undefined): Record<string, Object> | null {
  const asRec: Record<string, Object> | null = fqAsRecord(value);
  if (asRec !== null) {
    return asRec;
  }
  const asArr: Object[] | null = fqAsArray(value);
  if (asArr !== null && asArr.length > 0) {
    return fqAsRecord(asArr[0]);
  }
  return null;
}

function fqDig(value: Object | undefined, keys: string[]): string {
  let current: Object | undefined = value;
  for (const key of keys) {
    const rec: Record<string, Object> | null = fqAsRecord(current);
    if (rec === null) {
      return '';
    }
    current = rec[key];
  }
  if (typeof current === 'string' && current.length > 0) {
    return current;
  }
  return '';
}

function fqMatchesGenre(rec: Record<string, Object>, genre: number, genreType: number): boolean {
  const rawGenre: Object | undefined = rec['genre'];
  const genreOk: boolean = typeof rawGenre === 'number'
    ? rawGenre === genre
    : (typeof rawGenre === 'string' && rawGenre.trim() === genre.toString());
  if (!genreOk) {
    return false;
  }
  if (genreType < 0) {
    return true;
  }
  const rawType: Object | undefined = rec['genre_type'];
  return typeof rawType === 'number'
    ? rawType === genreType
    : (typeof rawType === 'string' && rawType.trim() === genreType.toString());
}

function fqTextBlob(values: Object[]): string {
  const parts: string[] = [];
  const visit = (value: Object): void => {
    if (value === null || value === undefined) {
      return;
    }
    const arr: Object[] | null = fqAsArray(value);
    if (arr !== null) {
      for (const child of arr) {
        visit(child);
      }
      return;
    }
    const rec: Record<string, Object> | null = fqAsRecord(value);
    if (rec !== null) {
      visit(rec['name']);
      visit(rec['title']);
      visit(rec['text']);
      visit(rec['category']);
      visit(rec['type']);
      visit(rec['tag_name']);
      visit(rec['tag_title']);
      return;
    }
    parts.push(`${value}`);
  };
  for (const value of values) {
    visit(value);
  }
  return parts.join(' ');
}

function fqBlobKeysOf(rec: Record<string, Object>): Object[] {
  const values: Object[] = [];
  for (const key of TEXT_BLOB_KEYS) {
    values.push(rec[key]);
  }
  return values;
}

function fqIsVideoItem(item: Record<string, Object>, bd: Record<string, Object>): boolean {
  const text: string = fqTextBlob(fqBlobKeysOf(item).concat(fqBlobKeysOf(bd)));
  return fqMatchesGenre(item, 203, -1)
    || fqMatchesGenre(bd, 203, -1)
    || fqTruthyAny(item, VIDEO_KEYS)
    || fqTruthyAny(bd, VIDEO_KEYS)
    || VIDEO_RE.test(text);
}

function fqHasManjuTag(value: Object | undefined): boolean {
  if (value === null || value === undefined) {
    return false;
  }
  const rec: Record<string, Object> | null = fqAsRecord(value);
  if (rec !== null) {
    return fqHasManjuTag(rec['text']);
  }
  const arr: Object[] | null = fqAsArray(value);
  if (arr !== null) {
    for (const child of arr) {
      if (fqHasManjuTag(child)) {
        return true;
      }
    }
    return false;
  }
  if (typeof value === 'string') {
    const trimmed: string = value.trim();
    return trimmed === '漫剧' || trimmed === '动态漫' || trimmed === '动态漫画';
  }
  return false;
}

function fqIsManjuItem(item: Record<string, Object>, bd: Record<string, Object>): boolean {
  const matches = (rec: Record<string, Object>): boolean => {
    return fqMatchesGenre(rec, 205, -1)
      || fqHasManjuTag(rec['tag_info'])
      || fqHasManjuTag(rec['cover_tag_info_list'])
      || fqHasManjuTag(rec['book_type_name'])
      || fqHasManjuTag(rec['type']);
  };
  return matches(item) || matches(bd);
}

function fqIsMangaItem(item: Record<string, Object>, bd: Record<string, Object>): boolean {
  const text: string = fqTextBlob(fqBlobKeysOf(item).concat(fqBlobKeysOf(bd)));
  return fqMatchesGenre(item, 1, 110)
    || fqMatchesGenre(bd, 1, 110)
    || fqTruthyAny(item, MANGA_KEYS)
    || fqTruthyAny(bd, MANGA_KEYS)
    || MANGA_RE.test(text);
}

function fqIsAudioItem(item: Record<string, Object>, bd: Record<string, Object>): boolean {
  const text: string = fqTextBlob(fqBlobKeysOf(item).concat(fqBlobKeysOf(bd)));
  return fqMatchesGenre(item, 4, -1)
    || fqMatchesGenre(bd, 4, -1)
    || fqTruthyAny(item, AUDIO_KEYS)
    || fqTruthyAny(bd, AUDIO_KEYS)
    || AUDIO_RE.test(text);
}

function fqValidScore(raw: Object | undefined): number {
  const text: string = typeof raw === 'string'
    ? raw.trim()
    : (typeof raw === 'number' ? raw.toString() : '');
  if (text.length === 0) {
    return 0;
  }
  const value: number = Number.parseFloat(text);
  if (!Number.isFinite(value) || value <= 0 || value > 10) {
    return 0;
  }
  return value;
}

function fqIdKeysOfKind(kind: string): string[] {
  if (kind === 'video' || kind === 'manju') {
    return ['series_id_str', 'video_id', 'vid', 'pseries_id', 'series_id', 'item_id', 'id', 'book_id', 'cell_id'];
  }
  if (kind === 'manga') {
    return ['manga_id', 'comic_id', 'book_id', 'item_id', 'id', 'cell_id'];
  }
  if (kind === 'audio') {
    return ['audio_book_id', 'audio_id', 'album_id', 'book_id', 'item_id', 'id', 'cell_id'];
  }
  return ['book_id', 'item_id', 'id', 'cell_id'];
}

/**
 * 从原始卡片记录构造 FqMediaItem。
 * @param forcedKind 非空时覆盖类型推断（如漫剧 tab 强制 'manju'）。
 */
export function fqItemFromRaw(rec: Record<string, Object>, forcedKind: string): FqMediaItem {
  const bd: Record<string, Object> = fqMapFrom(rec['book_data']) ?? rec;
  const highlightTitle: string = fqDig(rec['search_high_light'] ?? rec['title'], ['text']);

  let kind: string = forcedKind;
  if (kind.length === 0) {
    const explicitKind: string = fqNormalizeKind(rec['kind']);
    if (explicitKind.length > 0) {
      kind = explicitKind;
    } else if (fqIsManjuItem(rec, bd)) {
      kind = 'manju';
    } else if (fqIsVideoItem(rec, bd)) {
      kind = 'video';
    } else if (fqIsMangaItem(rec, bd)) {
      kind = 'manga';
    } else if (fqIsAudioItem(rec, bd)) {
      kind = 'audio';
    } else {
      kind = 'book';
    }
  }

  const isVideoKind: boolean = kind === 'video' || kind === 'manju';

  let seriesId: string = '';
  let episodeId: string = '';
  if (isVideoKind) {
    const seriesKeys: string[] = ['series_id_str', 'pseries_id', 'series_id'];
    if (fqAsArray(rec['video_data']) !== null) {
      seriesKeys.push('book_id');
    }
    seriesId = fqFirstString(rec, ['seriesId']) || fqFirstString(rec, seriesKeys) || fqFirstString(bd, seriesKeys);
    episodeId = fqFirstString(rec, ['episodeId', 'video_id', 'vid', 'item_id', 'id'])
      || fqFirstString(bd, ['video_id', 'vid', 'item_id', 'id']);
  }

  const idKeys: string[] = fqIdKeysOfKind(kind);
  const id: string = seriesId || fqFirstString(bd, idKeys) || fqFirstString(rec, idKeys);

  const title: string = highlightTitle
    || fqFirstString(rec, ['series_title', 'title', 'name', 'raw_book_name'])
    || fqFirstString(bd, ['title', 'name', 'raw_book_name', 'book_name'])
    || fqFirstString(rec, ['book_name'])
    || fqFirstString(rec, ['cell_name'])
    || '未知';

  const cover: string = fqFirstString(rec, ['series_cover', 'thumb_url', 'cover', 'cover_url', 'poster'])
    || fqFirstString(bd, ['thumb_url', 'cover', 'cover_url', 'poster']);

  const author: string = fqFirstString(rec, ['author', 'author_name'])
    || fqFirstString(bd, ['author', 'author_name']);

  const badge: string = fqFirstString(rec, ['badge', 'category', 'type', 'cell_alias', 'card_tips', 'book_type_name'])
    || fqFirstString(bd, ['badge', 'category', 'type', 'cell_alias', 'card_tips', 'book_type_name']);

  const ep: string = fqFirstString(rec, ['ep', 'serial_count', 'item_count', 'episode_count', 'episode_cnt'])
    || fqFirstString(bd, ['ep', 'serial_count', 'item_count', 'episode_count', 'episode_cnt']);

  const intro: string = fqFirstString(rec, ['series_intro', 'intro'])
    || fqFirstString(bd, ['series_intro', 'intro']);

  const scoreRawBd: Object | undefined = bd['score'];
  const scoreRaw: Object | undefined = scoreRawBd !== undefined && scoreRawBd !== null ? scoreRawBd : rec['score'];
  const score: number = fqValidScore(scoreRaw);

  const followerCount: number = Math.max(
    fqAsInt(rec['followed_cnt'], 0),
    fqAsInt(bd['followed_cnt'], 0),
  );

  return new FqMediaItem(
    id, title, cover, author, badge, ep, kind, score, intro, seriesId, episodeId, followerCount,
  );
}

// ---------------------------------------------------------------------------
// parseMediaItems（首页推荐递归收集）
// ---------------------------------------------------------------------------

export function fqParseMediaItems(payload: Record<string, Object>, forcedKind: string): FqMediaItem[] {
  const root: Object = payload['data'] !== undefined ? payload['data'] : payload;
  const out: FqMediaItem[] = [];
  const seen: Set<string> = new Set<string>();

  const add = (raw: Record<string, Object>): void => {
    const item: FqMediaItem = fqItemFromRaw(raw, forcedKind);
    if (item.id.length === 0) {
      return;
    }
    const key: string = `${item.kind}:${item.id}`;
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    out.push(item);
  };

  const visit = (value: Object, depth: number): void => {
    if (depth > 14 || value === null || value === undefined) {
      return;
    }
    const arr: Object[] | null = fqAsArray(value);
    if (arr !== null) {
      for (const child of arr) {
        visit(child, depth + 1);
      }
      return;
    }
    const map: Record<string, Object> | null = fqAsRecord(value);
    if (map === null) {
      return;
    }

    // 搜索卡片可能带嵌套 video_data：把父字段与 video_detail 摊平进每个子项。
    const videoData: Object[] | null = fqAsArray(map['video_data']);
    if (videoData !== null && videoData.length > 0) {
      for (const childValue of videoData) {
        const child: Record<string, Object> | null = fqAsRecord(childValue);
        if (child === null) {
          continue;
        }
        const merged: Record<string, Object> = fqEmptyRecord();
        fqShallowMergeInto(merged, map);
        const detail: Record<string, Object> | null = fqAsRecord(child['video_detail']);
        if (detail !== null) {
          fqShallowMergeInto(merged, detail);
        }
        fqShallowMergeInto(merged, child);
        add(merged);
      }
    }

    let hasIdentity: boolean = false;
    for (const key of IDENTITY_KEYS) {
      const v: Object | undefined = map[key];
      if (v !== null && v !== undefined && `${v}`.length > 0) {
        hasIdentity = true;
        break;
      }
    }
    if (hasIdentity) {
      add(map);
    }

    for (const key of VISIT_KEYS) {
      const child: Object | undefined = map[key];
      if (child !== undefined) {
        visit(child, depth + 1);
      }
    }
  };

  visit(root, 0);
  return out;
}

// ---------------------------------------------------------------------------
// 首页：data.tab_item 选卡 + 游标提取
// ---------------------------------------------------------------------------

/** 上游 tab_item 形状非确定（数组或以序号为键的映射），统一收窄为数组。 */
function fqHomepageTabItems(data: Record<string, Object>): Object[] | null {
  const raw: Object | undefined = data['tab_item'];
  const arr: Object[] | null = fqAsArray(raw);
  if (arr !== null) {
    return arr;
  }
  const map: Record<string, Object> | null = fqAsRecord(raw);
  if (map === null) {
    return null;
  }
  const out: Object[] = [];
  for (const key of fqKeys(map)) {
    out.push(map[key]);
  }
  return out;
}

/** 深度优先取第一个非空字符串字段（对齐 Dart `_firstStringField`）。 */
function fqFirstStringField(node: Object | undefined, field: string): string {
  const rec: Record<string, Object> | null = fqAsRecord(node);
  if (rec !== null) {
    const direct: Object | undefined = rec[field];
    if (typeof direct === 'string' && direct.length > 0) {
      return direct;
    }
    for (const key of fqKeys(rec)) {
      const found: string = fqFirstStringField(rec[key], field);
      if (found.length > 0) {
        return found;
      }
    }
    return '';
  }
  const arr: Object[] | null = fqAsArray(node);
  if (arr !== null) {
    for (const element of arr) {
      const found: string = fqFirstStringField(element, field);
      if (found.length > 0) {
        return found;
      }
    }
  }
  return '';
}

export function fqParseHomepage(payload: Record<string, Object>, tabType: number): FqHomePage {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  const tabItems: Object[] | null = data !== null ? fqHomepageTabItems(data) : null;

  let nextOffset: number = -1;
  let sessionId: string = '';
  let matched: Record<string, Object> | null = null;

  if (tabItems !== null) {
    for (const rawValue of tabItems) {
      const raw: Record<string, Object> | null = fqAsRecord(rawValue);
      if (raw === null) {
        continue;
      }
      const rawType: string = fqStr(raw, 'tab_type');
      if (rawType !== tabType.toString()) {
        continue;
      }
      matched = raw;
      const candidate: number = fqNum(raw, 'next_offset');
      if (candidate > 0 && candidate > (nextOffset < 0 ? 0 : nextOffset)) {
        nextOffset = candidate;
      }
      const candidateSession: string = fqStr(raw, 'session_id');
      if (candidateSession.length > 0) {
        sessionId = candidateSession;
      }
    }
  }

  const selected: Record<string, Object> = matched !== null
    ? matched
    : (tabItems !== null ? fqEmptyRecord() : payload);
  const cellId: string = matched !== null ? fqFirstStringField(matched, 'cell_id_str') : '';
  const forcedKind: string = tabType === 24 ? 'manju' : '';
  const items: FqMediaItem[] = fqParseMediaItems(selected, forcedKind);
  return new FqHomePage(items, nextOffset, sessionId, cellId);
}

/**
 * 官方第二段（/api/v1/recommend/series-feed，即 bookmall/cell/change）载荷：
 * 条目 + data.next_offset/session_id 游标。短剧（t8）视频流与听书（t5）
 * 有声书流的实际分页都由本接口承载（fqapp `_seriesFlowPage`）。
 */
export function fqParseSeriesFeed(payload: Record<string, Object>): FqHomePage {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return new FqHomePage([], -1, '', '');
  }
  const nextOffset: number = fqAsInt(data['next_offset'], 0);
  const sessionId: string = fqStr(data, 'session_id');
  const items: FqMediaItem[] = fqParseMediaItems(data, '');
  return new FqHomePage(items, nextOffset, sessionId, '');
}

// ---------------------------------------------------------------------------
// 搜索：parseSearchTabs + separateManju
// ---------------------------------------------------------------------------

function fqHasMediaId(candidate: Record<string, Object>): boolean {
  for (const key of SEARCH_MEDIA_ID_KEYS) {
    const value: Object | undefined = candidate[key];
    if (value === null || value === undefined) {
      continue;
    }
    const id: string = `${value}`.trim();
    if (id.length > 0 && id !== '0') {
      return true;
    }
  }
  return false;
}

function fqIsSearchMediaNode(item: Record<string, Object>): boolean {
  const bdRec: Record<string, Object> | null = fqAsRecord(item['book_data']);
  if (bdRec !== null && fqHasMediaId(bdRec)) {
    return true;
  }
  const bdArr: Object[] | null = fqAsArray(item['book_data']);
  if (bdArr !== null) {
    for (const value of bdArr) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec !== null && fqHasMediaId(rec)) {
        return true;
      }
    }
  }
  if (!fqHasMediaId(item)) {
    return false;
  }
  for (const key of SEARCH_MEDIA_CONTENT_KEYS) {
    const value: Object | undefined = item[key];
    if (value !== null && value !== undefined && `${value}`.trim().length > 0) {
      return true;
    }
  }
  return false;
}

export function fqSeparateManjuTabs(tabs: FqSearchTab[]): FqSearchTab[] {
  const manjuItems: FqMediaItem[] = [];
  const seen: Set<string> = new Set<string>();
  let source: FqSearchTab | null = null;
  for (const tab of tabs) {
    if (tab.title === '短剧' || tab.title === '漫剧') {
      source = tab;
    }
    for (const item of tab.items) {
      if (item.kind === 'manju' && item.id.length > 0 && !seen.has(item.id)) {
        seen.add(item.id);
        manjuItems.push(item);
      }
    }
  }
  if (source === null && manjuItems.length === 0) {
    return tabs;
  }
  const manjuTab: FqSearchTab = new FqSearchTab(
    '漫剧',
    manjuItems,
    source !== null ? source.hasMore : false,
    source !== null ? source.nextOffset : 0,
  );
  const result: FqSearchTab[] = [];
  let inserted: boolean = false;
  for (const tab of tabs) {
    if (tab.title === '漫剧') {
      continue;
    }
    const keepAll: boolean = tab.title !== '短剧' && tab.title !== '小说' && tab.title !== '书籍'
      && tab.title !== '漫画' && tab.title !== '听书';
    const items: FqMediaItem[] = keepAll
      ? tab.items
      : tab.items.filter((item: FqMediaItem): boolean => item.kind !== 'manju');
    result.push(new FqSearchTab(tab.title, items, tab.hasMore, tab.nextOffset));
    if (tab.title === '短剧') {
      result.push(manjuTab);
      inserted = true;
    }
  }
  if (!inserted) {
    result.push(manjuTab);
  }
  return result;
}

/**
 * 解析 /api/search 或 /api/v1/search 载荷为分栏。
 * @param tabType 非零时只保留该 tab_type 的分栏。
 */
export function fqParseSearchTabs(payload: Record<string, Object>, tabType: number): FqSearchTab[] {
  const data: Record<string, Object> = fqAsRecord(payload['data']) ?? payload;
  const tabs: Object[] | null = fqAsArray(data['search_tabs']);
  if (tabs === null) {
    return [];
  }

  const requestedTitle: string = fqRequestedTitleOf(tabType);
  const parsed: FqSearchTab[] = [];
  for (const rawTabValue of tabs) {
    const rawTab: Record<string, Object> | null = fqAsRecord(rawTabValue);
    if (rawTab === null) {
      continue;
    }
    if (tabType !== 0) {
      const type: number = fqAsInt(rawTab['tab_type'], 0);
      const title: string = fqStr(rawTab, 'title');
      const matchesType: boolean = type === tabType
        || (type === 0 && requestedTitle.length > 0 && title === requestedTitle);
      if (!matchesType) {
        continue;
      }
    }
    const title: string = requestedTitle.length > 0 ? requestedTitle : fqStr(rawTab, 'title');
    const rawItems: Object[] | null = fqAsArray(rawTab['data']);
    const items: FqMediaItem[] = [];
    if (rawItems !== null) {
      for (const rawItemValue of rawItems) {
        const rawItem: Record<string, Object> | null = fqAsRecord(rawItemValue);
        if (rawItem === null) {
          continue;
        }
        const videoData: Object[] | null = fqAsArray(rawItem['video_data']);
        if (videoData !== null && videoData.length > 0) {
          for (const childValue of videoData) {
            const child: Record<string, Object> | null = fqAsRecord(childValue);
            if (child === null) {
              continue;
            }
            const merged: Record<string, Object> = fqEmptyRecord();
            fqShallowMergeInto(merged, rawItem);
            fqShallowMergeInto(merged, child);
            const media: FqMediaItem = fqItemFromRaw(merged, '');
            if (media.id.length > 0) {
              items.push(media);
            }
          }
        } else if (fqAsArray(rawItem['book_data']) !== null) {
          const before: number = items.length;
          for (const childValue of fqAsArray(rawItem['book_data']) ?? []) {
            const child: Record<string, Object> | null = fqAsRecord(childValue);
            if (child === null) {
              continue;
            }
            if (!fqIsSearchMediaNode(child)) {
              continue;
            }
            const merged: Record<string, Object> = fqEmptyRecord();
            fqShallowMergeInto(merged, rawItem);
            fqShallowMergeInto(merged, child);
            merged['book_data'] = child;
            const media: FqMediaItem = fqItemFromRaw(merged, '');
            if (media.id.length > 0) {
              items.push(media);
            }
          }
          if (items.length === before && fqIsSearchMediaNode(rawItem)) {
            const media: FqMediaItem = fqItemFromRaw(rawItem, '');
            if (media.id.length > 0) {
              items.push(media);
            }
          }
        } else if (fqIsSearchMediaNode(rawItem)) {
          const media: FqMediaItem = fqItemFromRaw(rawItem, '');
          if (media.id.length > 0) {
            items.push(media);
          }
        }
      }
    }
    const rawHasMore: Object | undefined = rawTab['has_more'];
    const hasMore: boolean = typeof rawHasMore === 'boolean' ? rawHasMore : true;
    const nextOffset: number = fqAsInt(rawTab['next_offset'], 0);
    parsed.push(new FqSearchTab(title, items, hasMore, nextOffset));
  }
  return fqSeparateManjuTabs(parsed);
}

function fqRequestedTitleOf(tabType: number): string {
  if (tabType === 1) {
    return '综合';
  }
  if (tabType === 3) {
    return '书籍';
  }
  if (tabType === 11) {
    return '短剧';
  }
  if (tabType === 8) {
    return '漫画';
  }
  if (tabType === 2) {
    return '听书';
  }
  return '';
}

// ---------------------------------------------------------------------------
// 书籍详情 BookDetail.fromPayload
// ---------------------------------------------------------------------------

function fqResolveDetailData(payload: Record<string, Object>): Record<string, Object> | null {
  let data: Object | undefined = payload['data'] !== undefined ? payload['data'] : payload;
  const inner: Record<string, Object> | null = fqAsRecord(data);
  if (inner !== null && fqAsRecord(inner['data']) !== null) {
    data = inner['data'];
  }
  return fqAsRecord(data);
}

function fqAuthorOf(data: Record<string, Object>): string {
  const authorInfo: Record<string, Object> | null = fqAsRecord(data['author_info']);
  if (authorInfo !== null) {
    const name: string = fqStr(authorInfo, 'author_name') || fqStr(authorInfo, 'name')
      || fqStr(authorInfo, 'user_name');
    if (name.length > 0) {
      return name;
    }
  }
  return fqStr(data, 'author');
}

/** 作者头衔徽标：user_title_infos[].title_text 优先，回退 author_role。 */
function fqAuthorTitleOf(data: Record<string, Object>): string {
  const authorInfo: Record<string, Object> | null = fqAsRecord(data['author_info']);
  if (authorInfo === null) {
    return '';
  }
  const titles: Object[] | null = fqAsArray(authorInfo['user_title_infos']);
  if (titles !== null) {
    for (const entry of titles) {
      const rec: Record<string, Object> | null = fqAsRecord(entry);
      if (rec === null) {
        continue;
      }
      const text: string = fqStr(rec, 'title_text');
      if (text.length > 0) {
        return text;
      }
    }
  }
  return fqStr(authorInfo, 'author_role');
}

/** 在读人数展示文案：formatCounter(read_count) 优先，回退 sub_info。 */
function fqReadLabelOf(data: Record<string, Object>, subInfo: string): string {
  const formatted: string = fqFormatCounter(fqStr(data, 'read_count'));
  if (formatted.length > 0) {
    return formatted;
  }
  return subInfo;
}

export function fqParseBookDetail(payload: Record<string, Object>): FqBookDetail {
  const data: Record<string, Object> | null = fqResolveDetailData(payload);
  if (data === null) {
    return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '', [], false, '', '', '', '');
  }
  let category: string = fqStr(data, 'category');
  const tags: string[] = [];
  const rawTags: Object | undefined = data['tags'];
  if (typeof rawTags === 'string' && rawTags.trim().length > 0) {
    const parts: string[] = rawTags.split(/[,,]/);
    for (const part of parts) {
      if (part.trim().length > 0) {
        tags.push(part.trim());
      }
    }
  } else {
    const rawTagArr: Object[] | null = fqAsArray(rawTags);
    if (rawTagArr !== null) {
      for (const tagValue of rawTagArr) {
        if (typeof tagValue === 'string' && tagValue.trim().length > 0) {
          tags.push(tagValue.trim());
        }
      }
    }
  }
  if (category.length === 0 && tags.length > 0) {
    category = tags[0];
  }
  let cover: string = fqStr(data, 'detail_page_thumb_url');
  if (cover.length === 0) {
    cover = fqStr(data, 'thumb_url');
  }
  const serialCount: number = fqAsInt(data['serial_count'], fqAsInt(data['content_chapter_number'], 0));
  const subInfo: string = fqStr(data, 'sub_info');
  const authorInfo: Record<string, Object> | null = fqAsRecord(data['author_info']);
  let authorAvatar: string = '';
  let authorId: string = '';
  if (authorInfo !== null) {
    authorAvatar = fqStr(authorInfo, 'user_avatar') || fqStr(authorInfo, 'avatar');
    authorId = fqStr(authorInfo, 'user_id');
  }
  if (authorId.length === 0) {
    // 顶层 author_id 是唯一兜底，但带命名空间：2_ 小说作者可在
    // /reading/user/basic_info/get/v 解析，1_ 漫画/漫剧作者报 CALL_SERVICE_FAIL，
    // 裸数字部分会解析成占位非作者用户 — 两者都是死胡同，1_ 直接置空。
    const fallbackId: string = fqStr(data, 'author_id');
    authorId = fallbackId.startsWith('1_') ? '' : fallbackId;
  }
  return new FqBookDetail(
    fqStr(data, 'book_id'),
    fqStr(data, 'book_name'),
    fqAuthorOf(data),
    fqStr(data, 'abstract'),
    cover,
    category,
    fqAsInt(data['creation_status'], -1),
    fqAsInt(data['word_number'], 0),
    serialCount,
    subInfo,
    fqStr(data, 'score'),
    tags,
    fqStr(data, 'authorize_type') === '1',
    fqAuthorTitleOf(data),
    authorAvatar,
    fqReadLabelOf(data, subInfo),
    authorId,
  );
}

/** 解析 JSON 文本为 FqBookDetail；失败返回空详情。 */
export function fqParseBookDetailText(text: string): FqBookDetail {
  const payload: Record<string, Object> | null = fqParseObject(text);
  if (payload === null) {
    return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '', [], false, '', '', '', '');
  }
  return fqParseBookDetail(payload);
}

// ---------------------------------------------------------------------------
// 作者主页（fqapp lib/models/author_profile.dart AuthorProfile.fromPayload）
// ---------------------------------------------------------------------------

/** category 逗号列表取首项（对齐 fqapp AuthorWork._firstTag）。 */
function fqFirstTagOf(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  return raw.split(/[,,]/)[0].trim();
}

/**
 * 解析作者主页（/api/v1/authors/{id}，上游 /reading/user/basic_info/get/v）。
 * 作品来自 data.author_book_info（不走 /bookshelf，对齐 fqapp 结论）；
 * 业务错误码或缺失 data 返回空 profile，由页面转成重试态。
 */
export function fqParseAuthorProfile(payload: Record<string, Object>): FqAuthorProfile {
  const code: number = fqAsInt(payload['code'], 0);
  if (code !== 0 && code !== 200) {
    return new FqAuthorProfile('', '', '', '', '', 0, 0, []);
  }
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return new FqAuthorProfile('', '', '', '', '', 0, 0, []);
  }
  const works: FqAuthorWork[] = [];
  const rawWorks: Object[] | null = fqAsArray(data['author_book_info']);
  if (rawWorks !== null) {
    for (const entry of rawWorks) {
      const rec: Record<string, Object> | null = fqAsRecord(entry);
      if (rec === null) {
        continue;
      }
      const id: string = fqStr(rec, 'book_id');
      const title: string = fqStr(rec, 'book_name');
      if (id.length === 0 && title.length === 0) {
        continue;
      }
      works.push(new FqAuthorWork(
        id,
        title,
        fqStr(rec, 'thumb_url'),
        fqStr(rec, 'abstract'),
        fqFirstTagOf(fqStr(rec, 'category')),
        fqAsInt(rec['creation_status'], -1),
        fqAsInt(rec['word_number'], 0),
        fqStr(rec, 'read_count'),
      ));
    }
  }
  return new FqAuthorProfile(
    fqStr(data, 'user_id'),
    fqStr(data, 'user_name'),
    fqStr(data, 'user_avatar'),
    fqStr(data, 'description') || fqStr(data, 'author_desc'),
    fqAuthorTitleOf(data),
    fqAsInt(data['fans_num'], 0),
    fqAsInt(data['author_book_num'], 0),
    works,
  );
}

// ---------------------------------------------------------------------------
// 目录章节 + 章节试读（media_item.dart parseDirectory / chapter_summary.dart）
// ---------------------------------------------------------------------------

function fqDirectoryInner(payload: Record<string, Object>): Object | undefined {
  let data: Object | undefined = payload['data'] !== undefined ? payload['data'] : payload;
  const inner: Record<string, Object> | null = fqAsRecord(data);
  if (inner !== null && (fqAsRecord(inner['data']) !== null || fqAsArray(inner['data']) !== null)) {
    data = inner['data'];
  }
  return data;
}

function fqEntryIdOf(rec: Record<string, Object>): string {
  const id: string = fqStr(rec, 'itemId') || fqStr(rec, 'item_id')
    || fqStr(rec, 'chapter_id') || fqStr(rec, 'video_id')
    || fqStr(rec, 'vid') || fqStr(rec, 'episode_id') || fqStr(rec, 'id');
  if (id.length > 0 && id !== '0') {
    return id;
  }
  return '';
}

function fqChapterListOf(volume: Object): Object[] | null {
  if (fqAsArray(volume) !== null) {
    return fqAsArray(volume);
  }
  const rec: Record<string, Object> | null = fqAsRecord(volume);
  if (rec === null) {
    return null;
  }
  const list: Object[] | null = fqAsArray(rec['chapterList']) ?? fqAsArray(rec['chapter_list']);
  return list;
}

/** 目录载荷 -> 章节平铺列表（chapterListWithVolume 多卷拼接；version 优先条目自带，
 *  缺失从同层 item_data_list 兜底——段评接口必传 item_version）。 */
export function fqParseDirectory(payload: Record<string, Object>): FqChapter[] {
  const inner: Object | undefined = fqDirectoryInner(payload);
  const innerRec: Record<string, Object> | null = fqAsRecord(inner);
  if (innerRec === null) {
    return [];
  }
  const versions: Map<string, string> = fqDirectoryVersions(payload);
  const chapters: FqChapter[] = [];
  const volumes: Object[] | null = fqAsArray(innerRec['chapterListWithVolume']);
  if (volumes !== null) {
    for (const volume of volumes) {
      const entries: Object[] | null = fqChapterListOf(volume);
      if (entries === null) {
        continue;
      }
      for (const entry of entries) {
        const rec: Record<string, Object> | null = fqAsRecord(entry);
        if (rec === null) {
          continue;
        }
        const itemId: string = fqEntryIdOf(rec);
        if (itemId.length === 0) {
          continue;
        }
        let version: string = fqStr(rec, 'version');
        if (version.length === 0) {
          const fallback: string | undefined = versions.get(itemId);
          version = fallback !== undefined ? fallback : '';
        }
        chapters.push(new FqChapter(itemId, fqStr(rec, 'title') || fqStr(rec, 'chapter_title'), version));
      }
    }
  }
  return chapters;
}

/** 目录 item_data_list 深搜 itemId -> version（桥接 chapterList 条目缺 version 时兜底）。 */
function fqDirectoryVersions(root: Object | undefined, depth: number = 0): Map<string, string> {
  const versions: Map<string, string> = new Map();
  const rec: Record<string, Object> | null = fqAsRecord(root);
  if (rec === null || depth > 6) {
    return versions;
  }
  const list: Object[] | null = fqAsArray(rec['item_data_list']);
  if (list !== null) {
    for (const entry of list) {
      const itemRec: Record<string, Object> | null = fqAsRecord(entry);
      if (itemRec === null) {
        continue;
      }
      const id: string = fqFirstString(itemRec, ['item_id', 'itemId', 'id']);
      const version: string = fqStr(itemRec, 'version');
      if (id.length > 0 && version.length > 0) {
        versions.set(id, version);
      }
    }
  }
  if (versions.size > 0) {
    return versions;
  }
  for (const key of fqKeys(rec)) {
    const found: Map<string, string> = fqDirectoryVersions(rec[key], depth + 1);
    if (found.size > 0) {
      return found;
    }
  }
  return versions;
}

/** 章段评计数（/api/v1/chapters/{itemId}/reviews：data.data 按段索引为键的 map，
 *  每项 count；业务码非 0/200（103001 参数非法 / 1301008 无数据）按无段评处理）。 */
export function fqParseChapterIdeaCounts(payload: Record<string, Object>, paragraphCount: number): number[] {
  const counts: number[] = [];
  for (let index: number = 0; index < paragraphCount; index++) {
    counts.push(0);
  }
  const code: number = fqAsInt(payload['code'], 0);
  if (code !== 0 && code !== 200) {
    return counts;
  }
  const dataRec: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (dataRec === null) {
    return counts;
  }
  const buckets: Record<string, Object> | null = fqAsRecord(dataRec['data']);
  if (buckets === null) {
    return counts;
  }
  for (const key of fqKeys(buckets)) {
    const paraIndex: number = Number.parseInt(key, 10);
    if (Number.isNaN(paraIndex) || paraIndex < 0 || paraIndex >= paragraphCount) {
      continue;
    }
    const bucket: Record<string, Object> | null = fqAsRecord(buckets[key]);
    if (bucket === null) {
      continue;
    }
    counts[paraIndex] = fqAsInt(bucket['count'], 0);
  }
  return counts;
}

/** 某段段评列表（/api/v1/books/{bookId}/reviews 段评配方：data.data_list[i].comment 嵌套，
 *  计数藏于 comment.stat；业务码非 0/200 返回空）。 */
export function fqParseParagraphComments(payload: Record<string, Object>): FqParagraphComment[] {
  const comments: FqParagraphComment[] = [];
  const code: number = fqAsInt(payload['code'], 0);
  if (code !== 0 && code !== 200) {
    return comments;
  }
  const dataRec: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (dataRec === null) {
    return comments;
  }
  const list: Object[] | null = fqAsArray(dataRec['data_list']);
  if (list === null) {
    return comments;
  }
  for (const entry of list) {
    const entryRec: Record<string, Object> | null = fqAsRecord(entry);
    if (entryRec === null) {
      continue;
    }
    const commentRec: Record<string, Object> | null = fqAsRecord(entryRec['comment']);
    if (commentRec === null) {
      continue;
    }
    const common: Record<string, Object> | null = fqAsRecord(commentRec['common']);
    const content: Record<string, Object> | null = common !== null ? fqAsRecord(common['content']) : null;
    const text: string = content !== null ? fqStr(content, 'text') : '';
    if (text.trim().length === 0) {
      continue;
    }
    const userInfo: Record<string, Object> | null = common !== null ? fqAsRecord(common['user_info']) : null;
    const baseInfo: Record<string, Object> | null = userInfo !== null ? fqAsRecord(userInfo['base_info']) : null;
    const stat: Record<string, Object> | null = fqAsRecord(commentRec['stat']);
    const tag: Record<string, Object> | null = userInfo !== null ? fqAsRecord(userInfo['user_tag']) : null;
    const comment: FqParagraphComment = new FqParagraphComment();
    comment.id = fqStr(commentRec, 'comment_id');
    comment.text = text;
    comment.diggCount = stat !== null ? fqAsInt(stat['digg_count'], 0) : 0;
    comment.createdAtMs = common !== null ? fqCommentTimestampMs(common['create_timestamp']) : 0;
    comment.userName = baseInfo !== null ? fqStr(baseInfo, 'user_name') : '';
    comment.userAvatar = baseInfo !== null ? fqStr(baseInfo, 'user_avatar') : '';
    comment.isAuthor = tag !== null && tag['is_author'] === true;
    comments.push(comment);
  }
  return comments;
}

const FQ_PREVIEW_MARKER_RE: RegExp = new RegExp('\\{!--[\\s\\S]*?--\\}|<!--[\\s\\S]*?-->|\\{!--[\\s\\S]*$|<!--[\\s\\S]*$', 'g');
const FQ_PREVIEW_TAG_RE: RegExp = new RegExp('</?[a-zA-Z][^>]*>', 'g');
const FQ_PREVIEW_SPACE_RE: RegExp = new RegExp('\\s+', 'g');

/** 试读正文清洗：剥掉音频标记/HTML 注释/标签与实体，压缩空白。 */
function fqCleanPreview(raw: string): string {
  let text: string = raw.replace(FQ_PREVIEW_MARKER_RE, ' ');
  text = text.replace(FQ_PREVIEW_TAG_RE, ' ');
  text = text.replace('&nbsp;', ' ').replace('&lt;', '<').replace('&gt;', '>')
    .replace('&quot;', '"').replace('&#39;', '\'').replace('&apos;', '\'')
    .replace('&amp;', '&');
  return text.replace(FQ_PREVIEW_SPACE_RE, ' ').trim();
}

/** 试读载荷 -> itemId -> 正文开头（data.summary_item_data）。 */
export function fqParseChapterSummaries(payload: Record<string, Object>): Map<string, string> {
  const out: Map<string, string> = new Map();
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return out;
  }
  const entries: Object[] | null = fqAsArray(data['summary_item_data']);
  if (entries === null) {
    return out;
  }
  for (const entry of entries) {
    const rec: Record<string, Object> | null = fqAsRecord(entry);
    if (rec === null) {
      continue;
    }
    const itemId: string = fqStr(rec, 'item_id') || fqStr(rec, 'itemId');
    const summary: string = fqCleanPreview(fqStr(rec, 'summary'));
    if (itemId.length === 0 || summary.length === 0) {
      continue;
    }
    out.set(itemId, summary);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 排行榜目录：novel homepage(tab_type=2) 载荷深搜 rank_with_category_data
// ---------------------------------------------------------------------------

function fqFindRankNode(value: Object | undefined, depth: number): Record<string, Object> | null {
  if (depth > 12 || value === null || value === undefined) {
    return null;
  }
  const arr: Object[] | null = fqAsArray(value);
  if (arr !== null) {
    for (const child of arr) {
      const found: Record<string, Object> | null = fqFindRankNode(child, depth + 1);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }
  const rec: Record<string, Object> | null = fqAsRecord(value);
  if (rec === null) {
    return null;
  }
  if (fqAsRecord(rec['rank_with_category_data']) !== null) {
    return rec;
  }
  for (const key of fqKeys(rec)) {
    const found: Record<string, Object> | null = fqFindRankNode(rec[key], depth + 1);
    if (found !== null) {
      return found;
    }
  }
  return null;
}

export function fqParseRankCatalog(payload: Record<string, Object>): FqRankCatalog {
  const node: Record<string, Object> | null = fqFindRankNode(payload, 0);
  if (node === null) {
    return fqEmptyRankCatalog();
  }
  const rankData: Record<string, Object> = fqAsRecord(node['rank_with_category_data']) ?? fqEmptyRecord();

  const tabs: FqRankTab[] = [];
  const rawTabs: Object[] | null = fqAsArray(rankData['rank_algo_list']);
  if (rawTabs !== null) {
    for (const rawTabValue of rawTabs) {
      const rawTab: Record<string, Object> | null = fqAsRecord(rawTabValue);
      if (rawTab === null) {
        continue;
      }
      const name: string = fqStr(rawTab, 'rank_name');
      const algo: number = fqAsInt(rawTab['rank_algo'], -1);
      if (name.length === 0 || algo < 0) {
        continue;
      }
      tabs.push(new FqRankTab(name, algo));
    }
  }

  const categories: FqRankCategory[] = [];
  const rawCategories: Object[] | null = fqAsArray(rankData['sub_info_list']);
  if (rawCategories !== null) {
    for (const rawCategoryValue of rawCategories) {
      const rawCategory: Record<string, Object> | null = fqAsRecord(rawCategoryValue);
      if (rawCategory === null) {
        continue;
      }
      const name: string = fqStr(rawCategory, 'info_name');
      const id: number = fqAsInt(rawCategory['info_id'], -1);
      if (name.length === 0 || id < 0) {
        continue;
      }
      categories.push(new FqRankCategory(name, id));
    }
  }

  const rankId: string = fqFirstString(node, ['cell_id_str', 'cell_id']);
  return new FqRankCatalog(rankId, tabs, categories);
}

// ---------------------------------------------------------------------------
// 排行榜单页：data.cell_view.cell_data（book_data / video 双路径）
// ---------------------------------------------------------------------------

function fqRankCategoryText(raw: string): string {
  const comma: number = raw.indexOf(',');
  const commaCn: number = raw.indexOf('，');
  let cut: number = -1;
  if (comma >= 0 && commaCn >= 0) {
    cut = Math.min(comma, commaCn);
  } else if (comma >= 0) {
    cut = comma;
  } else if (commaCn >= 0) {
    cut = commaCn;
  }
  if (cut > 0) {
    return raw.substring(0, cut).trim();
  }
  return raw.trim();
}

function fqRankEntryFromBook(bd: Record<string, Object>): FqRankEntry | null {
  const id: string = fqFirstString(bd, ['book_id', 'item_id', 'id']);
  const title: string = fqFirstString(bd, ['book_name', 'title', 'name']);
  if (id.length === 0 && title.length === 0) {
    return null;
  }
  return new FqRankEntry(
    0,
    id,
    title,
    fqFirstString(bd, ['thumb_url', 'cover', 'cover_url', 'poster']),
    fqFirstString(bd, ['author', 'author_name']),
    fqFirstString(bd, ['abstract', 'intro']),
    fqRankCategoryText(fqFirstString(bd, ['category'])),
    fqAsInt(bd['creation_status'], -1),
    fqAsInt(bd['word_number'], 0),
    fqAsInt(bd['read_count'], 0),
    'book',
    '',
  );
}

function fqLooksLikeVideoCell(cell: Record<string, Object>): boolean {
  if (fqAsArray(cell['video_data']) !== null || fqAsRecord(cell['video_data']) !== null) {
    return true;
  }
  return fqFirstString(cell, ['series_id_str', 'pseries_id', 'video_id']).length > 0;
}

function fqRankVideoEntry(cell: Record<string, Object>): FqRankEntry | null {
  const item: FqMediaItem = fqItemFromRaw(cell, '');
  if (item.kind !== 'video' && item.kind !== 'manju') {
    return null;
  }
  if (item.seriesId.length === 0) {
    return null;
  }
  return new FqRankEntry(
    0,
    item.id,
    item.title,
    item.cover,
    item.author,
    item.intro,
    item.badge,
    -1,
    0,
    item.followerCount,
    item.kind,
    item.seriesId,
  );
}

function fqCollectRankCell(
  cell: Record<string, Object>,
  entries: FqRankEntry[],
  seen: Set<string>,
  startAt: number,
): void {
  let entry: FqRankEntry | null = null;

  const bdArray: Object[] | null = fqAsArray(cell['book_data']);
  if (entry === null && bdArray !== null && bdArray.length > 0) {
    const first: Record<string, Object> | null = fqAsRecord(bdArray[0]);
    if (first !== null) {
      entry = fqRankEntryFromBook(first);
    }
  }
  if (entry === null && bdArray === null) {
    const bdRec: Record<string, Object> | null = fqAsRecord(cell['book_data']);
    if (bdRec !== null) {
      entry = fqRankEntryFromBook(bdRec);
    }
  }
  if (entry === null && fqStr(cell, 'book_name').length > 0) {
    entry = fqRankEntryFromBook(cell);
  }
  if (entry === null && fqLooksLikeVideoCell(cell)) {
    entry = fqRankVideoEntry(cell);
  }
  if (entry === null) {
    return;
  }

  const key: string = entry.id.length > 0 ? entry.id : `t:${entry.title}`;
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  entries.push(new FqRankEntry(
    startAt + entries.length,
    entry.id,
    entry.title,
    entry.cover,
    entry.author,
    entry.abstractText,
    entry.category,
    entry.creationStatus,
    entry.wordNumber,
    entry.readCount,
    entry.kind,
    entry.seriesId,
  ));
}

/**
 * 解析 /api/v1/rank/{rankId} 载荷为榜单一页。
 * @param startAt 第一名的名次（首页 1，翻页 = 已有条数 + 1）。
 */
export function fqParseRankBoard(payload: Record<string, Object>, startAt: number): FqRankBoard {
  const codeRaw: Object | undefined = payload['code'];
  if (codeRaw !== undefined && codeRaw !== null) {
    const code: number = fqAsInt(codeRaw, -1);
    if (code !== 0 && code !== 200) {
      return new FqRankBoard([], false);
    }
  }

  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  const cellView: Record<string, Object> | null = data !== null ? fqAsRecord(data['cell_view']) : null;
  const cells: Object[] | null = cellView !== null ? fqAsArray(cellView['cell_data']) : null;

  const entries: FqRankEntry[] = [];
  const seen: Set<string> = new Set<string>();
  if (cells !== null) {
    for (const cellValue of cells) {
      const cell: Record<string, Object> | null = fqAsRecord(cellValue);
      if (cell === null) {
        continue;
      }
      const nested: Object[] | null = fqAsArray(cell['cell_data']);
      if (nested !== null) {
        for (const nestedValue of nested) {
          const nestedCell: Record<string, Object> | null = fqAsRecord(nestedValue);
          if (nestedCell !== null) {
            fqCollectRankCell(nestedCell, entries, seen, startAt);
          }
        }
      }
      fqCollectRankCell(cell, entries, seen, startAt);
    }
  }

  const hasMore: boolean = data !== null && data['has_more'] === true;
  return new FqRankBoard(entries, hasMore);
}

// ---------------------------------------------------------------------------
// 书评：BookCommentPage.fromPayload（fqapp lib/models/book_comment.dart）
// ---------------------------------------------------------------------------

/** 解包 {code, data}（及嵌套 data.data）到书评页记录。 */
function fqResolveCommentData(payload: Record<string, Object>): Record<string, Object> | null {
  let data: Object | undefined = payload['data'] !== undefined ? payload['data'] : payload;
  const inner: Record<string, Object> | null = fqAsRecord(data);
  if (inner !== null && fqAsRecord(inner['data']) !== null) {
    data = inner['data'];
  }
  return fqAsRecord(data);
}

/** 评论图片 URL 列表：legacy 字符串数组或 {web_url} 映射数组，仅收 http(s)。 */
function fqCommentImageUrls(value: Object | undefined): string[] {
  const arr: Object[] | null = fqAsArray(value);
  if (arr === null) {
    return [];
  }
  const urls: string[] = [];
  for (const image of arr) {
    const rec: Record<string, Object> | null = fqAsRecord(image);
    const raw: string = rec !== null
      ? fqStr(rec, 'web_url')
      : (typeof image === 'string' ? image.trim() : '');
    if (raw.startsWith('https://') || raw.startsWith('http://')) {
      urls.push(raw);
    }
  }
  return urls;
}

/** 上游时间戳秒转毫秒（容忍毫秒值），非法返回 0。 */
function fqCommentTimestampMs(value: Object | undefined): number {
  const raw: number = fqAsInt(value, 0);
  if (raw <= 0) {
    return 0;
  }
  const ms: number = raw > 100000000000 ? raw : raw * 1000;
  return ms > 8640000000000000 ? 0 : ms;
}

/**
 * 解析 /api/v1/books/{id}/comments 载荷为书评一页：
 * data.comment[]（text/score 0-10/digg_count/reply_count/read_duration 秒/
 * user_info 嵌套）+ 页级 comment_cnt/score_cnt/context/has_more/next_offset。
 */
export function fqParseBookComments(payload: Record<string, Object>): FqBookCommentPage {
  const data: Record<string, Object> | null = fqResolveCommentData(payload);
  if (data === null) {
    return new FqBookCommentPage([], 0, 0, '', false, 0);
  }
  const comments: FqBookComment[] = [];
  const rawList: Object[] | null = fqAsArray(data['comment']);
  if (rawList !== null) {
    for (const entry of rawList) {
      const rec: Record<string, Object> | null = fqAsRecord(entry);
      if (rec === null) {
        continue;
      }
      const text: string = fqStr(rec, 'text');
      const imageUrls: string[] = fqCommentImageUrls(rec['image_url']);
      if (text.length === 0 && imageUrls.length === 0) {
        continue;
      }
      const user: Record<string, Object> = fqAsRecord(rec['user_info']) ?? fqEmptyRecord();
      comments.push(new FqBookComment(
        fqStr(rec, 'comment_id'),
        text,
        imageUrls,
        fqAsInt(rec['score'], 0),
        fqAsInt(rec['digg_count'], 0),
        fqAsInt(rec['reply_count'], 0),
        fqAsInt(rec['read_duration'], 0),
        fqCommentTimestampMs(rec['create_timestamp']),
        fqStr(user, 'user_name'),
        fqStr(user, 'user_avatar'),
        user['is_author'] === true,
      ));
    }
  }
  return new FqBookCommentPage(
    comments,
    fqAsInt(data['comment_cnt'], 0),
    fqAsInt(data['score_cnt'], 0),
    fqStr(data, 'context'),
    data['has_more'] === true,
    fqAsInt(data['next_offset'], 0),
  );
}

// ---------------------------------------------------------------------------
// 章节正文：提取与清洗（对齐 fqapp _extractChapterText / normalizeChapterText）
// ---------------------------------------------------------------------------

/** 旧版 /api/content 深度取正文：content/text/article_content/body 任一命中即用。 */
export function fqLegacyChapterText(payload: Record<string, Object>): string {
  return fqVisitChapterText(payload, 0);
}

function fqVisitChapterText(value: Object | undefined, depth: number): string {
  if (depth > 7 || value === undefined) {
    return '';
  }
  const rec: Record<string, Object> | null = fqAsRecord(value);
  if (rec !== null) {
    const preferred: string[] = ['content', 'text', 'article_content', 'body'];
    for (const key of preferred) {
      const candidate: Object | undefined = rec[key];
      if (typeof candidate === 'string' && candidate.trim().length > 0) {
        return candidate;
      }
    }
    for (const key of fqKeys(rec)) {
      const found: string = fqVisitChapterText(rec[key], depth + 1);
      if (found.length > 0) {
        return found;
      }
    }
    return '';
  }
  const arr: Object[] | null = fqAsArray(value);
  if (arr !== null) {
    for (const child of arr) {
      const found: string = fqVisitChapterText(child, depth + 1);
      if (found.length > 0) {
        return found;
      }
    }
  }
  return '';
}

/**
 * v1 图文章节（/api/v1/chapters/{id}/novel，后端 DH 解密）：
 * 仅接受显式解密成功（content_decrypted）的 content 字符串。
 */
export function fqParseNovelChapter(payload: Record<string, Object>): string {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  if (data === null) {
    return '';
  }
  const flag: Object | undefined = data['content_decrypted'];
  if (typeof flag !== 'boolean' || !flag) {
    return '';
  }
  const content: Object | undefined = data['content'];
  if (typeof content !== 'string') {
    return '';
  }
  return content;
}

const FQ_HIDDEN_BLOCK_RE: RegExp = /<(script|style|head|template|noscript|title)[\s\S]*?<\/\1\s*>/gi;
const FQ_MARKER_RE: RegExp = /\{!--[\s\S]*?--\}|<!--[\s\S]*?-->/g;
const FQ_TRUNCATED_MARKER_RE: RegExp = /\{!--\s*PGC_[A-Z_]+:[^\n]*$/gm;
const FQ_BREAK_RE: RegExp =
  /<\/(p|div|h[1-6]|li|tr|dt|dd|blockquote|pre|section|article|ul|ol|dl|table|figure|figcaption|header|footer|aside|main|address)>|<(br|hr)\b[^>]*>/gi;
const FQ_TAG_RE: RegExp = /<\/?[a-zA-Z][^>]*>/g;
const FQ_LINE_BREAK_RE: RegExp = /\r\n?|[\u0085\u2028\u2029]/g;
const FQ_EDGE_MARKER_RE: RegExp = /^[\u200B\uFEFF]+|[\u200B\uFEFF]+$/g;
const FQ_TITLE_SPACE_RE: RegExp = /\s+/g;

/**
 * 章节正文清洗（fqapp normalizeChapterText 的正则版）：
 * 隐藏块 → 内容标记（音频头/注释）→ 块级标签转行 → 剥内联标签 →
 * 实体解码 → 行归一化；首行固定为章节标题（排版引擎把 txt 首行
 * 渲染为加大加粗的章题，标题须占住该行，正文段落才不会被套标题样式）。
 */
export function fqNormalizeChapterText(raw: string, chapterTitle: string): string {
  let text: string = raw;
  text = text.replace(FQ_HIDDEN_BLOCK_RE, '');
  text = text.replace(FQ_MARKER_RE, '');
  text = text.replace(FQ_TRUNCATED_MARKER_RE, '');
  text = text.replace(FQ_BREAK_RE, '\n');
  text = text.replace(FQ_TAG_RE, '');
  text = text.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, '\'').replace(/&apos;/g, '\'')
    .replace(/&ldquo;/g, '\u201C').replace(/&rdquo;/g, '\u201D')
    .replace(/&mdash;/g, '\u2014').replace(/&hellip;/g, '\u2026')
    .replace(/&amp;/g, '&');
  text = text.replace(/\u00A0/g, ' ');
  text = text.replace(FQ_LINE_BREAK_RE, '\n');

  const lines: string[] = text.split('\n');
  const paragraphs: string[] = [];
  for (const line of lines) {
    const trimmed: string = line.trim().replace(FQ_EDGE_MARKER_RE, '').trim();
    if (trimmed.length > 0) {
      paragraphs.push(trimmed);
    }
  }
  const title: string = chapterTitle.trim();
  if (title.length > 0) {
    if (paragraphs.length === 0
      || paragraphs[0].replace(FQ_TITLE_SPACE_RE, '') !== title.replace(FQ_TITLE_SPACE_RE, '')) {
      paragraphs.unshift(title);
    }
  }
  return paragraphs.join('\n');
}

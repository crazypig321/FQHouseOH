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
  fqNum,
  fqParseObject,
  fqShallowMergeInto,
  fqStr,
  fqTruthyAny,
} from './FqJson';
import { FqBookDetail, FqHomePage, FqMediaItem, FqSearchTab } from '../model/FqModels';

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

export function fqParseHomepage(payload: Record<string, Object>, tabType: number): FqHomePage {
  const data: Record<string, Object> | null = fqAsRecord(payload['data']);
  const tabItems: Object[] | null = data !== null ? fqAsArray(data['tab_item']) : null;

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
  const forcedKind: string = tabType === 24 ? 'manju' : '';
  const items: FqMediaItem[] = fqParseMediaItems(selected, forcedKind);
  return new FqHomePage(items, nextOffset, sessionId);
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
    const name: string = fqStr(authorInfo, 'author_name') || fqStr(authorInfo, 'name');
    if (name.length > 0) {
      return name;
    }
  }
  return fqStr(data, 'author');
}

export function fqParseBookDetail(payload: Record<string, Object>): FqBookDetail {
  const data: Record<string, Object> | null = fqResolveDetailData(payload);
  if (data === null) {
    return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '');
  }
  let category: string = fqStr(data, 'category');
  const tags: string[] = [];
  const rawTags: Object | undefined = data['tags'];
  const rawTagArr: Object[] | null = fqAsArray(rawTags);
  if (rawTagArr !== null) {
    for (const tagValue of rawTagArr) {
      if (typeof tagValue === 'string' && tagValue.trim().length > 0) {
        tags.push(tagValue.trim());
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
    fqStr(data, 'sub_info'),
    fqStr(data, 'score'),
  );
}

/** 解析 JSON 文本为 FqBookDetail；失败返回空详情。 */
export function fqParseBookDetailText(text: string): FqBookDetail {
  const payload: Record<string, Object> | null = fqParseObject(text);
  if (payload === null) {
    return new FqBookDetail('', '', '', '', '', '', -1, 0, 0, '', '');
  }
  return fqParseBookDetail(payload);
}

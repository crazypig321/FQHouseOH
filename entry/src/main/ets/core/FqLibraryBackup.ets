/**
 * 书架备份与恢复（对齐 fqapp library_backup.dart 的可移植白名单方案）：
 * - 备份是显式白名单 JSON（format/version/createdAt + 各业务段），绝不整档 dump preferences；
 * - 导出与恢复写入前走同一套校验（体积/条数/字段白名单/重复检测），坏数据一律拒绝；
 * - 恢复是合并语义：只补缺失（收藏/浏览/收听/阅读进度按 id 跳过已有，
 *   已看集做并集、续播仅本机无记录时写入），绝不覆盖本机数据，可重复导入；
 * - local_ 前缀（本地 TXT 书籍）依赖设备本地文件，导出时排除并计数，导入时拒绝。
 */

import { bundleManager } from '@kit.AbilityKit';
import { FqShelfItem, FqShelfStore } from './FqShelfStore';
import { FqBrowseItem, FqBrowseStore } from './FqBrowseStore';
import { FqListenRecord, FqAudioHistory } from './FqAudioHistory';
import { FqWatchedMergeOutcome, FqWatchedProgress, FqWatchedStore } from './FqWatchedStore';
import { FqReaderProgress, FqReaderStore, fqDecodeReadRanges, fqEncodeReadRanges } from './FqReaderStore';
import { fqAsArray, fqAsRecord, fqStr } from './FqJson';

const FQ_BACKUP_FORMAT: string = 'fqhouse.library-backup';
const FQ_BACKUP_VERSION: number = 1;
/** 备份文件体积上限（导入侧文件大小检查用）。 */
export const FQ_BACKUP_MAX_BYTES: number = 16 * 1024 * 1024;
const FQ_BACKUP_MAX_RECORDS: number = 10000;
const FQ_BACKUP_MAX_EPISODES: number = 100000;
const FQ_BACKUP_MAX_TIME: number = 8640000000000000;
const FQ_BACKUP_MAX_TEXT: number = 8192;
const FQ_BACKUP_KINDS: string[] = ['book', 'audio', 'manga', 'video', 'manju'];
const FQ_BACKUP_ID_PATTERN: RegExp = /^[A-Za-z0-9_-]{1,128}$/;
const FQ_BACKUP_HTTPS_PREFIX: RegExp = /^https?:\/\/[^/\s]+/;

/** 封面可移植化：仅保留 http(s) 且有主机名的网络地址，其余（本地路径/沙箱 uri）清空。 */
function fqBackupPortableCover(cover: string): string {
  return FQ_BACKUP_HTTPS_PREFIX.test(cover) ? cover : '';
}

/** 作品标识校验：白名单字符集 + 拒绝本地书记录。 */
function fqBackupCheckId(id: string): string {
  if (!FQ_BACKUP_ID_PATTERN.test(id) || id.startsWith('local_')) {
    throw new Error('备份含无效作品标识或本地书籍记录');
  }
  return id;
}

/** 作品类型白名单校验。 */
function fqBackupCheckKind(kind: string): void {
  if (FQ_BACKUP_KINDS.indexOf(kind) < 0) {
    throw new Error('备份含未知作品类型');
  }
}

/** 字符串字段校验（长度上限 8192）。 */
function fqBackupCheckText(rec: Record<string, Object>, key: string): string {
  const value: string = fqStr(rec, key);
  if (value.length > FQ_BACKUP_MAX_TEXT) {
    throw new Error(`备份字段 ${key} 无效或过长`);
  }
  return value;
}

/** 非负整数校验。 */
function fqBackupCheckInt(rec: Record<string, Object>, key: string, max: number): number {
  const raw: Object | undefined = rec[key];
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0 ||
    raw > max || Math.trunc(raw) !== raw) {
    throw new Error(`备份字段 ${key} 无效`);
  }
  return raw;
}

/** 非负数值校验（秒/速率等允许小数）。 */
function fqBackupCheckNumber(rec: Record<string, Object>, key: string, max: number): number {
  const raw: Object | undefined = rec[key];
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0 || raw > max) {
    throw new Error(`备份字段 ${key} 无效`);
  }
  return raw;
}

/** 列表段校验（存在且不超过 10000 条）。 */
function fqBackupCheckList(raw: Object | undefined): Object[] {
  const arr: Object[] | null = fqAsArray(raw ?? null);
  if (arr === null || arr.length > FQ_BACKUP_MAX_RECORDS) {
    throw new Error('备份列表无效或超过 10000 条');
  }
  return arr;
}

/** UTF-8 字节数（体积校验用，不额外分配大缓冲）。 */
function fqBackupUtf8Length(text: string): number {
  let total: number = 0;
  for (let index: number = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code < 0x80) {
      total += 1;
    } else if (code < 0x800) {
      total += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF) {
      total += 4;
      index++;
    } else {
      total += 3;
    }
  }
  return total;
}

/** 备份内单剧记录：已看集 itemId 列表 + 续播进度（可空）。 */
export class FqBackupWatched {
  readonly seriesId: string;
  readonly episodes: string[];
  readonly progress: FqWatchedProgress | null;

  constructor(seriesId: string, episodes: string[], progress: FqWatchedProgress | null) {
    this.seriesId = seriesId;
    this.episodes = episodes;
    this.progress = progress;
  }
}

/** 备份内单书阅读进度：章节下标 + 段内位置串 + 已读章节区间串（"a-b,c"）。 */
export class FqBackupReaderProgress {
  readonly bookId: string;
  readonly chapterIndex: number;
  readonly domPos: string;
  readonly readRanges: string;

  constructor(bookId: string, chapterIndex: number, domPos: string, readRanges: string) {
    this.bookId = bookId;
    this.chapterIndex = chapterIndex;
    this.domPos = domPos;
    this.readRanges = readRanges;
  }
}

/** 采集/解析完成并通过校验的备份数据。 */
export class FqLibraryBackupData {
  readonly createdAt: number;
  readonly appVersion: string;
  readonly shelf: FqShelfItem[];
  readonly browse: FqBrowseItem[];
  readonly listen: FqListenRecord[];
  readonly watched: FqBackupWatched[];
  readonly reader: FqBackupReaderProgress[];
  readonly excludedLocalRecords: number;

  constructor(createdAt: number, appVersion: string, shelf: FqShelfItem[],
    browse: FqBrowseItem[], listen: FqListenRecord[], watched: FqBackupWatched[],
    reader: FqBackupReaderProgress[], excludedLocalRecords: number) {
    this.createdAt = createdAt;
    this.appVersion = appVersion;
    this.shelf = shelf;
    this.browse = browse;
    this.listen = listen;
    this.watched = watched;
    this.reader = reader;
    this.excludedLocalRecords = excludedLocalRecords;
  }

  /** 已看集总数（预览统计用）。 */
  public episodeCount(): number {
    let total: number = 0;
    for (const entry of this.watched) {
      total += entry.episodes.length;
    }
    return total;
  }
}

/** 恢复结果统计（页面提示文案用）。 */
export class FqLibraryBackupRestoreResult {
  readonly shelfAdded: number;
  readonly browseAdded: number;
  readonly listenAdded: number;
  readonly readerAdded: number;
  readonly episodesAdded: number;
  readonly progressAdded: number;

  constructor(shelfAdded: number, browseAdded: number, listenAdded: number,
    readerAdded: number, episodesAdded: number, progressAdded: number) {
    this.shelfAdded = shelfAdded;
    this.browseAdded = browseAdded;
    this.listenAdded = listenAdded;
    this.readerAdded = readerAdded;
    this.episodesAdded = episodesAdded;
    this.progressAdded = progressAdded;
  }
}

export class FqLibraryBackup {
  /** 采集本机数据生成备份（排除 local_ 本地书记录并计数，其余字段过白名单校验）。 */
  public static capture(): FqLibraryBackupData {
    let excluded: number = 0;
    const shelf: FqShelfItem[] = [];
    for (const item of FqShelfStore.all()) {
      if (item.id.startsWith('local_')) {
        excluded++;
        continue;
      }
      fqBackupCheckId(item.id);
      fqBackupCheckKind(item.kind);
      shelf.push(new FqShelfItem(item.id, item.kind, item.title, fqBackupPortableCover(item.cover)));
    }
    const browse: FqBrowseItem[] = [];
    for (const item of FqBrowseStore.all()) {
      if (item.id.startsWith('local_')) {
        excluded++;
        continue;
      }
      fqBackupCheckId(item.id);
      fqBackupCheckKind(item.kind);
      browse.push(new FqBrowseItem(item.id, item.kind, item.title,
        fqBackupPortableCover(item.cover), item.visitedAt));
    }
    const listen: FqListenRecord[] = [];
    for (const record of FqAudioHistory.all()) {
      if (record.bookId.startsWith('local_')) {
        excluded++;
        continue;
      }
      fqBackupCheckId(record.bookId);
      listen.push(new FqListenRecord(record.bookId, record.chapterIndex, record.positionSec,
        record.durationSec, record.toneId, record.rate, record.completed, record.title,
        fqBackupPortableCover(record.cover)));
    }
    const watchedIds: Map<string, Set<string>> = FqWatchedStore.allWatched();
    const watchedProgress: Map<string, FqWatchedProgress> = FqWatchedStore.allProgress();
    const seriesIds: Set<string> = new Set<string>();
    watchedIds.forEach((_ids: Set<string>, seriesId: string): void => {
      seriesIds.add(seriesId);
    });
    watchedProgress.forEach((_progress: FqWatchedProgress, seriesId: string): void => {
      seriesIds.add(seriesId);
    });
    const watched: FqBackupWatched[] = [];
    seriesIds.forEach((seriesId: string): void => {
      if (seriesId.startsWith('local_')) {
        excluded++;
        return;
      }
      fqBackupCheckId(seriesId);
      const ids: Set<string> | undefined = watchedIds.get(seriesId);
      const episodes: string[] = [];
      if (ids !== undefined) {
        ids.forEach((episodeId: string): void => {
          episodes.push(episodeId);
        });
      }
      const progress: FqWatchedProgress | null = watchedProgress.get(seriesId) ?? null;
      if (episodes.length > 0 || progress !== null) {
        watched.push(new FqBackupWatched(seriesId, episodes, progress));
      }
    });
    const reader: FqBackupReaderProgress[] = [];
    for (const bookId of FqReaderStore.progressBookIds()) {
      if (bookId.startsWith('local_')) {
        excluded++;
        continue;
      }
      const progress: FqReaderProgress = FqReaderStore.getProgress(bookId);
      if (progress.chapterIndex < 0) {
        continue;
      }
      reader.push(new FqBackupReaderProgress(bookId, progress.chapterIndex, progress.domPos,
        fqEncodeReadRanges(FqReaderStore.getReadChapters(bookId))));
    }
    return new FqLibraryBackupData(Date.now(), FqLibraryBackup.appVersion(),
      shelf, browse, listen, watched, reader, excluded);
  }

  /** 序列化为备份 JSON 文本（体积超限抛错）。 */
  public static encode(data: FqLibraryBackupData): string {
    const root: Record<string, Object> = {};
    root['format'] = FQ_BACKUP_FORMAT;
    root['version'] = FQ_BACKUP_VERSION;
    root['createdAt'] = data.createdAt;
    root['appVersion'] = data.appVersion;
    root['excludedLocalRecords'] = data.excludedLocalRecords;
    const shelf: Object[] = [];
    for (const item of data.shelf) {
      const rec: Record<string, Object> = {};
      rec['id'] = item.id;
      rec['kind'] = item.kind;
      rec['title'] = item.title;
      rec['cover'] = item.cover;
      shelf.push(rec);
    }
    root['shelf'] = shelf;
    const browse: Object[] = [];
    for (const item of data.browse) {
      const rec: Record<string, Object> = {};
      rec['id'] = item.id;
      rec['kind'] = item.kind;
      rec['title'] = item.title;
      rec['cover'] = item.cover;
      rec['visitedAt'] = item.visitedAt;
      browse.push(rec);
    }
    root['browse'] = browse;
    const listen: Object[] = [];
    for (const record of data.listen) {
      const rec: Record<string, Object> = {};
      rec['bookId'] = record.bookId;
      rec['chapterIndex'] = record.chapterIndex;
      rec['positionSec'] = record.positionSec;
      rec['durationSec'] = record.durationSec;
      rec['toneId'] = record.toneId;
      rec['rate'] = record.rate;
      rec['completed'] = record.completed;
      rec['title'] = record.title;
      rec['cover'] = record.cover;
      listen.push(rec);
    }
    root['listen'] = listen;
    const watched: Object[] = [];
    for (const entry of data.watched) {
      const rec: Record<string, Object> = {};
      rec['seriesId'] = entry.seriesId;
      const episodes: Object[] = [];
      for (const episodeId of entry.episodes) {
        episodes.push(episodeId);
      }
      rec['episodes'] = episodes;
      if (entry.progress !== null) {
        const progressRec: Record<string, Object> = {};
        progressRec['episodeId'] = entry.progress.episodeId;
        progressRec['position'] = entry.progress.position;
        progressRec['duration'] = entry.progress.duration;
        rec['progress'] = progressRec;
      }
      watched.push(rec);
    }
    root['watched'] = watched;
    const reader: Object[] = [];
    for (const entry of data.reader) {
      const rec: Record<string, Object> = {};
      rec['bookId'] = entry.bookId;
      rec['chapterIndex'] = entry.chapterIndex;
      rec['domPos'] = entry.domPos;
      rec['read'] = entry.readRanges;
      reader.push(rec);
    }
    root['reader'] = reader;
    const text: string = JSON.stringify(root);
    if (fqBackupUtf8Length(text) > FQ_BACKUP_MAX_BYTES) {
      throw new Error('备份数据超过 16 MB');
    }
    return text;
  }

  /** 解析并全量校验备份文本；任何字段不合规即抛错（中文消息直呈用户）。 */
  public static decode(text: string): FqLibraryBackupData {
    let clean: string = text;
    if (clean.startsWith('\uFEFF')) {
      clean = clean.substring(1);
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(clean);
    } catch (error) {
      throw new Error('文件不是有效的 UTF-8 JSON 备份');
    }
    const root: Record<string, Object> | null = fqAsRecord(parsed);
    if (root === null) {
      throw new Error('文件不是有效的 UTF-8 JSON 备份');
    }
    if (fqStr(root, 'format') !== FQ_BACKUP_FORMAT || root['version'] !== FQ_BACKUP_VERSION) {
      throw new Error('不是受支持的备份文件，请使用本应用导出的备份');
    }
    const createdAt: number = fqBackupCheckInt(root, 'createdAt', FQ_BACKUP_MAX_TIME);
    const appVersion: string = root['appVersion'] === undefined
      ? '' : fqBackupCheckText(root, 'appVersion');
    const shelf: FqShelfItem[] = [];
    const shelfIds: Set<string> = new Set<string>();
    for (const value of fqBackupCheckList(root['shelf'])) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec === null) {
        throw new Error('备份收藏记录格式无效');
      }
      fqBackupCheckKind(fqStr(rec, 'kind'));
      const id: string = fqBackupCheckId(fqStr(rec, 'id'));
      if (shelfIds.has(id)) {
        throw new Error('备份中有重复的收藏');
      }
      shelfIds.add(id);
      shelf.push(new FqShelfItem(id, fqStr(rec, 'kind'),
        fqBackupCheckText(rec, 'title'),
        fqBackupPortableCover(fqBackupCheckText(rec, 'cover'))));
    }
    const browse: FqBrowseItem[] = [];
    const browseIds: Set<string> = new Set<string>();
    for (const value of fqBackupCheckList(root['browse'])) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec === null) {
        throw new Error('备份浏览记录格式无效');
      }
      fqBackupCheckKind(fqStr(rec, 'kind'));
      const id: string = fqBackupCheckId(fqStr(rec, 'id'));
      if (browseIds.has(id)) {
        throw new Error('备份中有重复的浏览记录');
      }
      browseIds.add(id);
      browse.push(new FqBrowseItem(id, fqStr(rec, 'kind'),
        fqBackupCheckText(rec, 'title'),
        fqBackupPortableCover(fqBackupCheckText(rec, 'cover')),
        fqBackupCheckInt(rec, 'visitedAt', FQ_BACKUP_MAX_TIME)));
    }
    const listen: FqListenRecord[] = [];
    const listenIds: Set<string> = new Set<string>();
    for (const value of fqBackupCheckList(root['listen'])) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec === null) {
        throw new Error('备份收听记录格式无效');
      }
      const bookId: string = fqBackupCheckId(fqStr(rec, 'bookId'));
      if (listenIds.has(bookId)) {
        throw new Error('备份中有重复的收听记录');
      }
      listenIds.add(bookId);
      const rate: number = fqBackupCheckNumber(rec, 'rate', 10);
      if (rate <= 0) {
        throw new Error('备份字段 rate 无效');
      }
      listen.push(new FqListenRecord(bookId,
        fqBackupCheckInt(rec, 'chapterIndex', 2147483647),
        fqBackupCheckNumber(rec, 'positionSec', 1e12),
        fqBackupCheckNumber(rec, 'durationSec', 1e12),
        fqBackupCheckText(rec, 'toneId'),
        rate,
        rec['completed'] === true,
        fqBackupCheckText(rec, 'title'),
        fqBackupPortableCover(fqBackupCheckText(rec, 'cover'))));
    }
    const watched: FqBackupWatched[] = [];
    const watchedKeys: Set<string> = new Set<string>();
    let episodeTotal: number = 0;
    for (const value of fqBackupCheckList(root['watched'])) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec === null) {
        throw new Error('备份已看记录格式无效');
      }
      const seriesId: string = fqBackupCheckId(fqStr(rec, 'seriesId'));
      if (watchedKeys.has(seriesId)) {
        throw new Error('备份中有重复的已看记录');
      }
      watchedKeys.add(seriesId);
      const episodes: string[] = [];
      for (const episodeValue of fqBackupCheckList(rec['episodes'])) {
        if (typeof episodeValue !== 'string') {
          throw new Error('备份已看集记录无效');
        }
        fqBackupCheckId(episodeValue);
        episodes.push(episodeValue);
      }
      episodeTotal += episodes.length;
      if (episodeTotal > FQ_BACKUP_MAX_EPISODES) {
        throw new Error('已看剧集超过 100000 条');
      }
      let progress: FqWatchedProgress | null = null;
      const progressRaw: Object | undefined = rec['progress'];
      if (progressRaw !== undefined) {
        const progressRec: Record<string, Object> | null = fqAsRecord(progressRaw);
        if (progressRec === null) {
          throw new Error('备份续播进度格式无效');
        }
        progress = new FqWatchedProgress(fqBackupCheckId(fqStr(progressRec, 'episodeId')),
          fqBackupCheckNumber(progressRec, 'position', 1e12),
          fqBackupCheckNumber(progressRec, 'duration', 1e12));
      }
      watched.push(new FqBackupWatched(seriesId, episodes, progress));
    }
    const reader: FqBackupReaderProgress[] = [];
    const readerIds: Set<string> = new Set<string>();
    for (const value of fqBackupCheckList(root['reader'])) {
      const rec: Record<string, Object> | null = fqAsRecord(value);
      if (rec === null) {
        throw new Error('备份阅读进度格式无效');
      }
      const bookId: string = fqBackupCheckId(fqStr(rec, 'bookId'));
      if (readerIds.has(bookId)) {
        throw new Error('备份中有重复的阅读进度');
      }
      readerIds.add(bookId);
      reader.push(new FqBackupReaderProgress(bookId,
        fqBackupCheckInt(rec, 'chapterIndex', 2147483647),
        fqBackupCheckText(rec, 'domPos'),
        fqBackupCheckText(rec, 'read')));
    }
    let excluded: number = 0;
    if (root['excludedLocalRecords'] !== undefined) {
      excluded = fqBackupCheckInt(root, 'excludedLocalRecords', 2147483647);
    }
    return new FqLibraryBackupData(createdAt, appVersion, shelf, browse, listen,
      watched, reader, excluded);
  }

  /** 合并恢复到本机（只补缺失，绝不覆盖本机已有记录）。 */
  public static restore(data: FqLibraryBackupData): FqLibraryBackupRestoreResult {
    let shelfAdded: number = 0;
    for (const item of data.shelf) {
      if (FqShelfStore.addIfAbsent(item)) {
        shelfAdded++;
      }
    }
    const browseAdded: number = FqBrowseStore.mergeItems(data.browse);
    const listenAdded: number = FqAudioHistory.mergeRecords(data.listen);
    let episodesAdded: number = 0;
    let progressAdded: number = 0;
    for (const entry of data.watched) {
      const outcome: FqWatchedMergeOutcome =
        FqWatchedStore.merge(entry.seriesId, entry.episodes, entry.progress);
      episodesAdded += outcome.episodesAdded;
      if (outcome.progressWritten) {
        progressAdded++;
      }
    }
    let readerAdded: number = 0;
    for (const entry of data.reader) {
      if (FqReaderStore.getProgress(entry.bookId).chapterIndex < 0) {
        FqReaderStore.saveProgress(entry.bookId, entry.chapterIndex, entry.domPos);
        const chapters: Set<number> = fqDecodeReadRanges(entry.readRanges);
        if (chapters.size > 0) {
          FqReaderStore.saveReadChapters(entry.bookId, chapters);
        }
        readerAdded++;
      }
    }
    return new FqLibraryBackupRestoreResult(shelfAdded, browseAdded, listenAdded,
      readerAdded, episodesAdded, progressAdded);
  }

  /** 当前应用版本号（备份元信息；获取失败返回空串）。 */
  private static appVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        return info.versionName;
      }
    } catch (error) {
      // 回退空串
    }
    return '';
  }
}

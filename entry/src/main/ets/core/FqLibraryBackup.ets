/**
 * 书架备份与恢复（对齐 fqapp library_backup.dart 的可移植白名单方案）：
 * - 备份是显式白名单 JSON（format/version/createdAt + 各业务段），绝不整档 dump preferences；
 * - 导出与恢复写入前走同一套校验（体积/条数/字段白名单/重复检测），坏数据一律拒绝；
 * - 恢复是合并语义：只补缺失（收藏/浏览/收听/阅读进度按 id 跳过已有，
 *   已看集做并集、续播仅本机无记录时写入），绝不覆盖本机数据，可重复导入；
 * - local_ 前缀（本地 TXT 书籍）依赖设备本地文件，导出时排除并计数，导入时拒绝。
 */

import { bundleManager } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { FqShelfItem, FqShelfStore } from './FqShelfStore';
import { FqBrowseItem, FqBrowseStore } from './FqBrowseStore';
import { FqListenRecord, FqAudioHistory } from './FqAudioHistory';
import { FqWatchedMergeOutcome, FqWatchedProgress, FqWatchedStore } from './FqWatchedStore';
import { FqReaderProgress, FqReaderSettings, FqReaderStore,
  fqDecodeReadRanges, fqEncodeReadRanges, fqNormalizeThemeFontColor } from './FqReaderStore';
import { FqAppSettingsStore } from './FqAppSettingsStore';
import { fqAsArray, fqAsRecord, fqStr } from './FqJson';

const FQ_BACKUP_FORMAT: string = 'fqhouse.library-backup';
/** 备份格式版本：v2 起包含应用设置段（外观/阅读偏好）；decode 兼容 v1（无设置段）。 */
const FQ_BACKUP_VERSION: number = 2;
/** 备份文件体积上限（导入侧文件大小检查用）。 */
export const FQ_BACKUP_MAX_BYTES: number = 16 * 1024 * 1024;
const FQ_BACKUP_MAX_RECORDS: number = 10000;
const FQ_BACKUP_MAX_EPISODES: number = 100000;
const FQ_BACKUP_MAX_THEMES: number = 50;
const FQ_BACKUP_MAX_TIME: number = 8640000000000000;
const FQ_BACKUP_MAX_TEXT: number = 8192;
const FQ_BACKUP_KINDS: string[] = ['book', 'audio', 'manga', 'video', 'manju'];
const FQ_BACKUP_ID_PATTERN: RegExp = /^[A-Za-z0-9_-]{1,128}$/;
const FQ_BACKUP_HTTPS_PREFIX: RegExp = /^https?:\/\/[^/\s]+/;
/** 背景图原文件 ≤ 此字节数直接内嵌；超限先压缩转 JPEG 再内嵌。 */
const FQ_BACKUP_BG_RAW_MAX: number = 512 * 1024;
/** 备份内背景图 base64 总预算（字符数；总 JSON 仍受 16MB 上限约束）。 */
const FQ_BACKUP_BG_B64_TOTAL: number = 10 * 1024 * 1024;
/** 单张背景图 base64 长度上限（decode 校验用）。 */
const FQ_BACKUP_BG_B64_PER: number = 3 * 1024 * 1024;
/** 主题色 key 白名单（与 FqAppSettingsStore 主题色档位一致）。 */
const FQ_BACKUP_THEME_COLORS: string[] =
  ['', 'orange', 'gold', 'green', 'teal', 'blue', 'violet', 'pink', 'red', 'custom'];
/** 自定义主题色 hex 校验（#RRGGBB / #AARRGGBB）。 */
const FQ_BACKUP_HEX_COLOR: RegExp = /^#[0-9A-Fa-f]{6,8}$/;

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

/** 整数区间校验（支持负值下界，如阅读主题 -1 跟随系统）。 */
function fqBackupCheckRange(rec: Record<string, Object>, key: string, min: number, max: number): number {
  const raw: Object | undefined = rec[key];
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < min || raw > max ||
    Math.trunc(raw) !== raw) {
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

/** 已看剧集续播进度内的整剧百分比（书架角标）：旧备份缺省 -1；非法值报错。 */
function fqBackupDecodePercent(progressRec: Record<string, Object>): number {
  const percentRaw: Object | undefined = progressRec['percent'];
  if (percentRaw === undefined) {
    return -1;
  }
  if (typeof percentRaw !== 'number' || percentRaw < 0 || percentRaw > 100
    || Math.trunc(percentRaw) !== percentRaw) {
    throw new Error('备份已看进度字段 percent 无效');
  }
  return percentRaw;
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

/** 备份内单书阅读进度：章节下标 + 段内位置串 + 已读章节区间串（"a-b,c"）+ 整书百分比。 */
export class FqBackupReaderProgress {
  readonly bookId: string;
  readonly chapterIndex: number;
  readonly domPos: string;
  readonly readRanges: string;
  /** 整书阅读百分比 0..100（书架封面角标）；-1 = 旧备份未记录。 */
  readonly percent: number;

  constructor(bookId: string, chapterIndex: number, domPos: string, readRanges: string,
    percent: number = -1) {
    this.bookId = bookId;
    this.chapterIndex = chapterIndex;
    this.domPos = domPos;
    this.readRanges = readRanges;
    this.percent = percent;
  }
}

/** 备份内自定义阅读主题：浅色/深色双模式参数白名单 + 背景图 base64 内嵌（跨设备迁移）。 */
export class FqBackupCustomTheme {
  readonly id: string;
  readonly name: string;
  readonly lightBgFile: string;
  readonly lightFontColor: string;
  readonly lightFontSize: number;
  readonly lightFontIndex: number;
  readonly lightLineHeight: number;
  readonly darkBgFile: string;
  readonly darkFontColor: string;
  readonly darkFontSize: number;
  readonly darkFontIndex: number;
  readonly darkLineHeight: number;
  /** 浅色背景图 base64（预算耗尽或本机文件缺失时为空串）。 */
  readonly lightBgData: string;
  /** 深色背景图 base64（预算耗尽或本机文件缺失时为空串）。 */
  readonly darkBgData: string;

  constructor(id: string, name: string,
    lightBgFile: string, lightFontColor: string, lightFontSize: number,
    lightFontIndex: number, lightLineHeight: number,
    darkBgFile: string, darkFontColor: string, darkFontSize: number,
    darkFontIndex: number, darkLineHeight: number,
    lightBgData: string = '', darkBgData: string = '') {
    this.id = id;
    this.name = name;
    this.lightBgFile = lightBgFile;
    this.lightFontColor = lightFontColor;
    this.lightFontSize = lightFontSize;
    this.lightFontIndex = lightFontIndex;
    this.lightLineHeight = lightLineHeight;
    this.darkBgFile = darkBgFile;
    this.darkFontColor = darkFontColor;
    this.darkFontSize = darkFontSize;
    this.darkFontIndex = darkFontIndex;
    this.darkLineHeight = darkLineHeight;
    this.lightBgData = lightBgData;
    this.darkBgData = darkBgData;
  }
}

/** 沙箱绝对路径 → 文件名（备份 bgFile 字段；空路径返回空串）。 */
function fqBackupBaseName(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}

/** 备份内应用设置段：外观（深浅模式/主题色）+ 阅读偏好（字号/行距/主题/翻页/字体）。 */
export class FqBackupAppSettings {
  readonly themeMode: number;
  readonly themeColor: string;
  readonly themeCustomColor: string;
  readonly backgroundAudio: boolean;
  readonly readerFontSize: number;
  readonly readerLineHeight: number;
  readonly readerThemeIndex: number;
  readonly readerFlipIndex: number;
  readonly readerComicFlipIndex: number;
  readonly readerFontIndex: number;
  readonly readerShowParagraphComment: boolean;
  /** 音量键翻页开关（旧备份缺省为 false）。 */
  readonly readerVolumeKeyPaging: boolean;
  /** 自定义阅读主题参数（旧备份缺省为空列表）。 */
  readonly readerCustomThemes: FqBackupCustomTheme[];
  /** 当前选中的自定义主题 id（旧备份缺省为空串）。 */
  readonly readerCustomThemeId: string;

  constructor(themeMode: number, themeColor: string, themeCustomColor: string,
    backgroundAudio: boolean, readerFontSize: number, readerLineHeight: number,
    readerThemeIndex: number, readerFlipIndex: number, readerComicFlipIndex: number,
    readerFontIndex: number, readerShowParagraphComment: boolean,
    readerVolumeKeyPaging: boolean,
    readerCustomThemes: FqBackupCustomTheme[], readerCustomThemeId: string) {
    this.themeMode = themeMode;
    this.themeColor = themeColor;
    this.themeCustomColor = themeCustomColor;
    this.backgroundAudio = backgroundAudio;
    this.readerFontSize = readerFontSize;
    this.readerLineHeight = readerLineHeight;
    this.readerThemeIndex = readerThemeIndex;
    this.readerFlipIndex = readerFlipIndex;
    this.readerComicFlipIndex = readerComicFlipIndex;
    this.readerFontIndex = readerFontIndex;
    this.readerShowParagraphComment = readerShowParagraphComment;
    this.readerVolumeKeyPaging = readerVolumeKeyPaging;
    this.readerCustomThemes = readerCustomThemes;
    this.readerCustomThemeId = readerCustomThemeId;
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
  /** 应用设置段（v1 备份无此段时为 null，恢复时跳过）。 */
  readonly settings: FqBackupAppSettings | null;

  constructor(createdAt: number, appVersion: string, shelf: FqShelfItem[],
    browse: FqBrowseItem[], listen: FqListenRecord[], watched: FqBackupWatched[],
    reader: FqBackupReaderProgress[], excludedLocalRecords: number,
    settings: FqBackupAppSettings | null) {
    this.createdAt = createdAt;
    this.appVersion = appVersion;
    this.shelf = shelf;
    this.browse = browse;
    this.listen = listen;
    this.watched = watched;
    this.reader = reader;
    this.excludedLocalRecords = excludedLocalRecords;
    this.settings = settings;
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
  /** 应用设置段是否已随恢复应用（v1 备份无设置段时为 false）。 */
  readonly settingsApplied: boolean;

  constructor(shelfAdded: number, browseAdded: number, listenAdded: number,
    readerAdded: number, episodesAdded: number, progressAdded: number,
    settingsApplied: boolean) {
    this.shelfAdded = shelfAdded;
    this.browseAdded = browseAdded;
    this.listenAdded = listenAdded;
    this.readerAdded = readerAdded;
    this.episodesAdded = episodesAdded;
    this.progressAdded = progressAdded;
    this.settingsApplied = settingsApplied;
  }
}

export class FqLibraryBackup {
  /** 采集本机数据生成备份（排除 local_ 本地书记录并计数，其余字段过白名单校验）。 */
  public static async capture(): Promise<FqLibraryBackupData> {
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
        fqEncodeReadRanges(FqReaderStore.getReadChapters(bookId)), progress.percent));
    }
    const readerSettings: FqReaderSettings = FqReaderStore.getSettings();
    // 自定义阅读主题：双模式参数（bgPath 取 basename）+ 背景图 base64 内嵌
    // （导入即压缩为小图；旧大图备份时再压缩；总预算超限的图降级为仅参数，不阻断备份）
    const customThemes: FqBackupCustomTheme[] = [];
    let bgBudget: number = FQ_BACKUP_BG_B64_TOTAL;
    for (const theme of readerSettings.customThemes) {
      const lightBgFile: string = fqBackupBaseName(theme.lightBgPath);
      const darkBgFile: string = fqBackupBaseName(theme.darkBgPath);
      let lightBgData: string = '';
      let darkBgData: string = '';
      if (lightBgFile.length > 0 && bgBudget > 0) {
        const bytes: ArrayBuffer | null =
          await FqReaderStore.loadBgBytesForBackup(lightBgFile, FQ_BACKUP_BG_RAW_MAX);
        if (bytes !== null) {
          lightBgData = buffer.from(bytes).toString('base64');
          bgBudget -= lightBgData.length;
        }
      }
      if (darkBgFile.length > 0 && bgBudget > 0) {
        const bytes: ArrayBuffer | null =
          await FqReaderStore.loadBgBytesForBackup(darkBgFile, FQ_BACKUP_BG_RAW_MAX);
        if (bytes !== null) {
          darkBgData = buffer.from(bytes).toString('base64');
          bgBudget -= darkBgData.length;
        }
      }
      customThemes.push(new FqBackupCustomTheme(theme.id, theme.name,
        lightBgFile, theme.lightFontColor, theme.lightFontSize,
        theme.lightFontIndex, theme.lightLineHeight,
        darkBgFile, theme.darkFontColor, theme.darkFontSize,
        theme.darkFontIndex, theme.darkLineHeight,
        lightBgData, darkBgData));
    }
    const settings: FqBackupAppSettings = new FqBackupAppSettings(
      FqAppSettingsStore.getThemeMode(),
      FqAppSettingsStore.getThemeColor(),
      FqAppSettingsStore.getThemeCustomColor(),
      FqAppSettingsStore.isBackgroundAudio(),
      readerSettings.fontSize,
      readerSettings.lineHeight,
      readerSettings.themeIndex,
      readerSettings.flipIndex,
      readerSettings.comicFlipIndex,
      readerSettings.fontIndex,
      readerSettings.showParagraphComment,
      readerSettings.volumeKeyPaging,
      customThemes,
      readerSettings.customThemeId);
    return new FqLibraryBackupData(Date.now(), FqLibraryBackup.appVersion(),
      shelf, browse, listen, watched, reader, excluded, settings);
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
        if (entry.progress.percent >= 0) {
          progressRec['percent'] = entry.progress.percent;
        }
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
      if (entry.percent >= 0) {
        rec['percent'] = entry.percent;
      }
      reader.push(rec);
    }
    root['reader'] = reader;
    if (data.settings !== null) {
      const settings: Record<string, Object> = {};
      settings['themeMode'] = data.settings.themeMode;
      settings['themeColor'] = data.settings.themeColor;
      settings['themeCustomColor'] = data.settings.themeCustomColor;
      settings['backgroundAudio'] = data.settings.backgroundAudio;
      settings['readerFontSize'] = data.settings.readerFontSize;
      settings['readerLineHeight'] = data.settings.readerLineHeight;
      settings['readerThemeIndex'] = data.settings.readerThemeIndex;
      settings['readerFlipIndex'] = data.settings.readerFlipIndex;
      settings['readerComicFlipIndex'] = data.settings.readerComicFlipIndex;
      settings['readerFontIndex'] = data.settings.readerFontIndex;
      settings['readerShowParagraphComment'] = data.settings.readerShowParagraphComment;
      settings['readerVolumeKeyPaging'] = data.settings.readerVolumeKeyPaging;
      const customThemes: Object[] = [];
      for (const theme of data.settings.readerCustomThemes) {
        const themeRec: Record<string, Object> = {};
        themeRec['id'] = theme.id;
        themeRec['name'] = theme.name;
        themeRec['lightBgFile'] = theme.lightBgFile;
        themeRec['lightFontColor'] = theme.lightFontColor;
        themeRec['lightFontSize'] = theme.lightFontSize;
        themeRec['lightFontIndex'] = theme.lightFontIndex;
        themeRec['lightLineHeight'] = theme.lightLineHeight;
        themeRec['darkBgFile'] = theme.darkBgFile;
        themeRec['darkFontColor'] = theme.darkFontColor;
        themeRec['darkFontSize'] = theme.darkFontSize;
        themeRec['darkFontIndex'] = theme.darkFontIndex;
        themeRec['darkLineHeight'] = theme.darkLineHeight;
        if (theme.lightBgData.length > 0) {
          themeRec['lightBgData'] = theme.lightBgData;
        }
        if (theme.darkBgData.length > 0) {
          themeRec['darkBgData'] = theme.darkBgData;
        }
        customThemes.push(themeRec);
      }
      settings['readerCustomThemes'] = customThemes;
      settings['readerCustomThemeId'] = data.settings.readerCustomThemeId;
      root['settings'] = settings;
    }
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
    const versionRaw: Object | undefined = root['version'];
    if (fqStr(root, 'format') !== FQ_BACKUP_FORMAT ||
      (versionRaw !== 1 && versionRaw !== 2)) {
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
          fqBackupCheckNumber(progressRec, 'duration', 1e12),
          fqBackupDecodePercent(progressRec));
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
      // 整书百分比（书架封面角标）：旧备份缺省 -1
      const percentRaw: Object | undefined = rec['percent'];
      let percent: number = -1;
      if (percentRaw !== undefined && typeof percentRaw === 'number') {
        if (percentRaw < 0 || percentRaw > 100 || Math.trunc(percentRaw) !== percentRaw) {
          throw new Error('备份字段 percent 无效');
        }
        percent = percentRaw;
      }
      reader.push(new FqBackupReaderProgress(bookId,
        fqBackupCheckInt(rec, 'chapterIndex', 2147483647),
        fqBackupCheckText(rec, 'domPos'),
        fqBackupCheckText(rec, 'read'),
        percent));
    }
    let excluded: number = 0;
    if (root['excludedLocalRecords'] !== undefined) {
      excluded = fqBackupCheckInt(root, 'excludedLocalRecords', 2147483647);
    }
    // 应用设置段：v1 备份无此段（settings 为 null，恢复时跳过）；v2 起必有且全量校验。
    let settings: FqBackupAppSettings | null = null;
    const settingsRaw: Object | undefined = root['settings'];
    if (settingsRaw !== undefined) {
      const settingsRec: Record<string, Object> | null = fqAsRecord(settingsRaw);
      if (settingsRec === null) {
        throw new Error('备份设置段格式无效');
      }
      const themeMode: number = fqBackupCheckInt(settingsRec, 'themeMode', 2);
      const themeColor: string = fqStr(settingsRec, 'themeColor');
      if (FQ_BACKUP_THEME_COLORS.indexOf(themeColor) < 0) {
        throw new Error('备份字段 themeColor 无效');
      }
      const themeCustomColor: string = fqStr(settingsRec, 'themeCustomColor');
      if (!FQ_BACKUP_HEX_COLOR.test(themeCustomColor)) {
        throw new Error('备份字段 themeCustomColor 无效');
      }
      const readerFontSize: number = fqBackupCheckInt(settingsRec, 'readerFontSize', 32);
      if (readerFontSize < 12) {
        throw new Error('备份字段 readerFontSize 无效');
      }
      const readerLineHeight: number = fqBackupCheckNumber(settingsRec, 'readerLineHeight', 2.6);
      if (readerLineHeight < 1.2) {
        throw new Error('备份字段 readerLineHeight 无效');
      }
      const showParaRaw: Object | undefined = settingsRec['readerShowParagraphComment'];
      // 音量键翻页开关（旧备份缺省 false）
      const volumeKeyRaw: Object | undefined = settingsRec['readerVolumeKeyPaging'];
      // 自定义阅读主题段（旧 v2 备份无此字段：空列表 + 空选中 id，全量白名单校验）
      const customThemes: FqBackupCustomTheme[] = [];
      const themesRaw: Object | undefined = settingsRec['readerCustomThemes'];
      if (themesRaw !== undefined) {
        const themesList: Object[] | null = fqAsArray(themesRaw);
        if (themesList === null || themesList.length > FQ_BACKUP_MAX_THEMES) {
          throw new Error('备份自定义主题段格式无效');
        }
          const themeIds: Set<string> = new Set<string>();
          let bgDataTotal: number = 0;
        for (const themeValue of themesList) {
          const themeRec: Record<string, Object> | null = fqAsRecord(themeValue);
          if (themeRec === null) {
            throw new Error('备份自定义主题格式无效');
          }
          const themeId: string = fqBackupCheckId(fqStr(themeRec, 'id'));
          if (themeIds.has(themeId)) {
            throw new Error('备份中有重复的自定义主题');
          }
          themeIds.add(themeId);
          let lightBgFile: string = fqStr(themeRec, 'lightBgFile');
          let darkBgFile: string = fqStr(themeRec, 'darkBgFile');
          let lightFontColor: string = '';
          let lightFontSize: number = 0;
          let lightFontIndex: number = -1;
          let lightLineHeight: number = 0;
          let darkFontColor: string = '';
          let darkFontSize: number = 0;
          let darkFontIndex: number = -1;
          let darkLineHeight: number = 0;
          if (lightBgFile.length === 0 && darkBgFile.length === 0) {
            // 旧版单模式备份（bgFile + dark 标记）：按 dark 路由到对应模式
            const legacyBgFile: string = fqStr(themeRec, 'bgFile');
            if (legacyBgFile.length === 0) {
              throw new Error('备份字段 bgFile 无效');
            }
            const legacyDark: boolean = themeRec['dark'] === true;
            if (legacyDark) {
              darkBgFile = legacyBgFile;
            } else {
              lightBgFile = legacyBgFile;
            }
            const legacyFontColor: string = fqNormalizeThemeFontColor(fqStr(themeRec, 'fontColor'));
            const legacyFontSize: number = fqBackupCheckInt(themeRec, 'fontSize', 32);
            if (legacyFontSize !== 0 && legacyFontSize < 12) {
              throw new Error('备份字段 fontSize 无效');
            }
            const legacyLineHeight: number = fqBackupCheckNumber(themeRec, 'lineHeight', 2.6);
            if (legacyLineHeight !== 0 && legacyLineHeight < 1.2) {
              throw new Error('备份字段 lineHeight 无效');
            }
            const legacyFontIndex: number = fqBackupCheckRange(themeRec, 'fontIndex', -1, 8);
            if (legacyDark) {
              darkFontColor = legacyFontColor;
              darkFontSize = legacyFontSize;
              darkFontIndex = legacyFontIndex;
              darkLineHeight = legacyLineHeight;
            } else {
              lightFontColor = legacyFontColor;
              lightFontSize = legacyFontSize;
              lightFontIndex = legacyFontIndex;
              lightLineHeight = legacyLineHeight;
            }
          } else {
            lightFontColor = fqNormalizeThemeFontColor(fqStr(themeRec, 'lightFontColor'));
            lightFontSize = fqBackupCheckInt(themeRec, 'lightFontSize', 32);
            if (lightFontSize !== 0 && lightFontSize < 12) {
              throw new Error('备份字段 lightFontSize 无效');
            }
            lightFontIndex = fqBackupCheckRange(themeRec, 'lightFontIndex', -1, 8);
            lightLineHeight = fqBackupCheckNumber(themeRec, 'lightLineHeight', 2.6);
            if (lightLineHeight !== 0 && lightLineHeight < 1.2) {
              throw new Error('备份字段 lightLineHeight 无效');
            }
            darkFontColor = fqNormalizeThemeFontColor(fqStr(themeRec, 'darkFontColor'));
            darkFontSize = fqBackupCheckInt(themeRec, 'darkFontSize', 32);
            if (darkFontSize !== 0 && darkFontSize < 12) {
              throw new Error('备份字段 darkFontSize 无效');
            }
            darkFontIndex = fqBackupCheckRange(themeRec, 'darkFontIndex', -1, 8);
            darkLineHeight = fqBackupCheckNumber(themeRec, 'darkLineHeight', 2.6);
            if (darkLineHeight !== 0 && darkLineHeight < 1.2) {
              throw new Error('备份字段 darkLineHeight 无效');
            }
          }
          if (lightBgFile.length > 0 && (lightBgFile.length > 128 || lightBgFile.indexOf('/') >= 0
            || lightBgFile.indexOf('\\') >= 0)) {
            throw new Error('备份字段 lightBgFile 无效');
          }
          if (darkBgFile.length > 0 && (darkBgFile.length > 128 || darkBgFile.indexOf('/') >= 0
            || darkBgFile.indexOf('\\') >= 0)) {
            throw new Error('备份字段 darkBgFile 无效');
          }
          if (lightBgFile.length === 0 && darkBgFile.length === 0) {
            throw new Error('备份字段 bgFile 无效');
          }
          // 背景图 base64 内嵌（旧备份缺省为空串；需有对应文件名；单张与总量设上限）
          let lightBgData: string = fqStr(themeRec, 'lightBgData');
          let darkBgData: string = fqStr(themeRec, 'darkBgData');
          if (lightBgData.length > FQ_BACKUP_BG_B64_PER || darkBgData.length > FQ_BACKUP_BG_B64_PER) {
            throw new Error('备份字段 bgData 无效');
          }
          if (lightBgFile.length === 0) {
            lightBgData = '';
          }
          if (darkBgFile.length === 0) {
            darkBgData = '';
          }
          bgDataTotal += lightBgData.length + darkBgData.length;
          if (bgDataTotal > FQ_BACKUP_BG_B64_TOTAL) {
            throw new Error('备份背景图数据超限');
          }
          customThemes.push(new FqBackupCustomTheme(themeId,
            fqBackupCheckText(themeRec, 'name'),
            lightBgFile, lightFontColor, lightFontSize, lightFontIndex, lightLineHeight,
            darkBgFile, darkFontColor, darkFontSize, darkFontIndex, darkLineHeight,
            lightBgData, darkBgData));
        }
      }
      const customThemeId: string = fqStr(settingsRec, 'readerCustomThemeId');
      if (customThemeId.length > 0 && !FQ_BACKUP_ID_PATTERN.test(customThemeId)) {
        throw new Error('备份字段 readerCustomThemeId 无效');
      }
      settings = new FqBackupAppSettings(themeMode, themeColor, themeCustomColor,
        settingsRec['backgroundAudio'] === true,
        readerFontSize,
        readerLineHeight,
        fqBackupCheckRange(settingsRec, 'readerThemeIndex', -1, 3),
        fqBackupCheckRange(settingsRec, 'readerFlipIndex', 0, 2),
        fqBackupCheckRange(settingsRec, 'readerComicFlipIndex', 0, 2),
        fqBackupCheckRange(settingsRec, 'readerFontIndex', 0, 8),
        typeof showParaRaw === 'boolean' ? showParaRaw : true,
        typeof volumeKeyRaw === 'boolean' ? volumeKeyRaw : false,
        customThemes,
        customThemeId);
    }
    return new FqLibraryBackupData(createdAt, appVersion, shelf, browse, listen,
      watched, reader, excluded, settings);
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
        FqReaderStore.saveProgress(entry.bookId, entry.chapterIndex, entry.domPos, entry.percent);
        const chapters: Set<number> = fqDecodeReadRanges(entry.readRanges);
        if (chapters.size > 0) {
          FqReaderStore.saveReadChapters(entry.bookId, chapters);
        }
        readerAdded++;
      }
    }
    // 应用设置段：深浅模式/主题色/后台播放 + 阅读偏好即时应用（v1 备份无此段跳过）。
    let settingsApplied: boolean = false;
    if (data.settings !== null) {
      const settings: FqBackupAppSettings = data.settings;
      FqAppSettingsStore.setThemeCustomColor(settings.themeCustomColor);
      FqAppSettingsStore.setThemeMode(settings.themeMode);
      FqAppSettingsStore.setThemeColor(settings.themeColor);
      FqAppSettingsStore.setBackgroundAudio(settings.backgroundAudio);
      FqReaderStore.saveSettings(settings.readerFontSize, settings.readerLineHeight,
        settings.readerThemeIndex, settings.readerFlipIndex, settings.readerFontIndex,
        settings.readerShowParagraphComment);
      FqReaderStore.saveComicFlip(settings.readerComicFlipIndex);
      FqReaderStore.saveVolumeKeyPaging(settings.readerVolumeKeyPaging);
      // 自定义阅读主题：先写回内嵌背景图文件（本机已有同名文件保留现状），
      // 再按模式校验重建条目（无内嵌数据的旧备份仍走沙箱文件存在性校验）
      for (const theme of settings.readerCustomThemes) {
        try {
          if (theme.lightBgData.length > 0) {
            FqReaderStore.writeBgBytes(theme.lightBgFile,
              buffer.from(theme.lightBgData, 'base64').buffer);
          }
          if (theme.darkBgData.length > 0) {
            FqReaderStore.writeBgBytes(theme.darkBgFile,
              buffer.from(theme.darkBgData, 'base64').buffer);
          }
        } catch (error) {
          // 单张背景图数据损坏时跳过该图，不阻断整份恢复
        }
      }
      for (const theme of settings.readerCustomThemes) {
        FqReaderStore.mergeCustomTheme(theme.id, theme.name,
          theme.lightBgFile, theme.lightFontColor, theme.lightFontSize,
          theme.lightFontIndex, theme.lightLineHeight,
          theme.darkBgFile, theme.darkFontColor, theme.darkFontSize,
          theme.darkFontIndex, theme.darkLineHeight);
      }
      if (settings.readerCustomThemeId.length > 0
        && FqReaderStore.hasCustomTheme(settings.readerCustomThemeId)) {
        FqReaderStore.selectCustomTheme(settings.readerCustomThemeId);
      }
      settingsApplied = true;
    }
    return new FqLibraryBackupRestoreResult(shelfAdded, browseAdded, listenAdded,
      readerAdded, episodesAdded, progressAdded, settingsApplied);
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

/**
 * 已看剧集记录 + 续播进度（播放页选集灰字/续播，对齐 fqapp watched_episodes.dart
 * 与 video_progress 一族）：已看按剧 id + 集 itemId 逐集持久化，与下标无关；
 * 续播进度按剧单条记录（集 itemId + 位置/时长），与已看集合分开存、互不推断；
 * 绝不按「当前集之前」补造中间集（跳集观看不误标）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsArray, fqAsRecord, fqNum, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_WATCHED_STORE_NAME: string = 'fq_watched';
/** 续播进度 key 前缀（与已看集合同文件、不同 key 命名空间）。 */
const FQ_WATCHED_PROGRESS_PREFIX: string = 'progress.';
/** 观看历史 key（同文件；短剧页「最近」频道数据源，最新在前）。 */
const FQ_WATCHED_HISTORY_KEY: string = 'history';
/** 观看历史容量上限（超出裁最旧）。 */
const FQ_WATCHED_HISTORY_MAX: number = 100;

/** 单剧续播进度（fqapp video_progress：集 itemId + 位置/时长，秒）。 */
export class FqWatchedProgress {
  readonly episodeId: string;
  /** 播放位置（秒）。 */
  readonly position: number;
  /** 时长（秒，未知 0）。 */
  readonly duration: number;
  /** 整剧百分比 0..100（书架角标：(集下标 + 集内比例)/总集数）；-1 未记录。 */
  readonly percent: number;

  constructor(episodeId: string, position: number, duration: number, percent: number = -1) {
    this.episodeId = episodeId;
    this.position = position;
    this.duration = duration;
    this.percent = percent;
  }
}

/**
 * 观看历史记录（短剧页「最近」频道：含元数据，按剧 upsert，最新在前；
 * 对齐 fqapp LibraryStore.history / media_history_store 的 DramaPage 语义）。
 */
export class FqWatchHistoryRecord {
  /** 剧 id（已看/续播同键 contentId）。 */
  readonly id: string;
  /** 内容类型（video/manju）。 */
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  /** 当前集 itemId（续播键）。 */
  readonly episodeId: string;
  /** 当前集下标（0 起；-1 未知，「已看到第N集」行缺省）。 */
  readonly episodeIndex: number;
  /** 播放位置（秒）。 */
  readonly position: number;
  /** 时长（秒，未知 0）。 */
  readonly duration: number;
  /** 整剧百分比 0..100；-1 未记录。 */
  readonly percent: number;
  /** 更新时间（ms）。 */
  readonly updatedAt: number;

  constructor(id: string, kind: string, title: string, cover: string, episodeId: string,
    episodeIndex: number, position: number, duration: number, percent: number, updatedAt: number) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.episodeId = episodeId;
    this.episodeIndex = episodeIndex;
    this.position = position;
    this.duration = duration;
    this.percent = percent;
    this.updatedAt = updatedAt;
  }
}

export class FqWatchedStore {
  private static pref: preferences.Preferences | null = null;
  /** 剧 id → 已看集 itemId 集合（内存缓存，读穿）。 */
  private static cache: Map<string, Set<string>> = new Map<string, Set<string>>();
  /** 观看历史缓存（null 未加载；写后即时更新）。 */
  private static historyCache: FqWatchHistoryRecord[] | null = null;

  public static init(context: common.Context): void {
    if (FqWatchedStore.pref !== null) {
      return;
    }
    try {
      FqWatchedStore.pref = preferences.getPreferencesSync(context, { name: FQ_WATCHED_STORE_NAME });
    } catch (error) {
      FqWatchedStore.pref = null;
    }
  }

  /** 某剧已看集 itemId 集合（首次读盘，之后走内存缓存）。 */
  public static ids(seriesId: string): Set<string> {
    const cached: Set<string> | undefined = FqWatchedStore.cache.get(seriesId);
    if (cached !== undefined) {
      return cached;
    }
    const result: Set<string> = new Set<string>();
    if (seriesId.length > 0) {
      const pref: preferences.Preferences | null = FqWatchedStore.pref;
      if (pref !== null) {
        let text: string = '';
        try {
          const raw: preferences.ValueType = pref.getSync(seriesId, '');
          if (typeof raw === 'string') {
            text = raw;
          }
        } catch (error) {
          text = '';
        }
        if (text.length > 0) {
          try {
            const parsed: Object | null = JSON.parse(text);
            const arr: Object[] | null = fqAsArray(parsed);
            if (arr !== null) {
              for (const entry of arr) {
                if (typeof entry === 'string' && entry.length > 0) {
                  result.add(entry);
                }
              }
            }
          } catch (error) {
            // 损坏数据按空集处理
          }
        }
      }
    }
    FqWatchedStore.cache.set(seriesId, result);
    return result;
  }

  /** 标记一集已看；返回是否新增（已看过不重复落盘）。 */
  public static mark(seriesId: string, episodeId: string): boolean {
    if (seriesId.length === 0 || episodeId.length === 0) {
      return false;
    }
    const current: Set<string> = FqWatchedStore.ids(seriesId);
    if (current.has(episodeId)) {
      return false;
    }
    current.add(episodeId);
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref !== null) {
      const items: string[] = [];
      current.forEach((id: string): void => {
        items.push(id);
      });
      try {
        pref.putSync(seriesId, JSON.stringify(items));
        pref.flush().catch((_error: BusinessError): void => {
          // 落盘失败不阻断
        });
      } catch (error) {
        // 忽略写入失败
      }
    }
    fqStoreBus.watchedVersion++;
    return true;
  }

  /** 清空全部已看记录与续播进度（设置-清空历史；本文件独立，整文件清空安全）。 */
  public static clear(): void {
    FqWatchedStore.cache.clear();
    FqWatchedStore.historyCache = null;
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.clearSync();
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
    fqStoreBus.watchedVersion++;
  }

  /** 读取某剧续播进度（无记录返回 null）。 */
  public static progress(seriesId: string): FqWatchedProgress | null {    if (seriesId.length === 0) {
      return null;
    }
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return null;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_WATCHED_PROGRESS_PREFIX + seriesId, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return null;
    }
    if (text.length === 0) {
      return null;
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = fqAsRecord(parsed);
      if (rec === null) {
        return null;
      }
      const episodeId: string = fqStr(rec, 'episodeId');
      if (episodeId.length === 0) {
        return null;
      }
      // 整剧百分比（书架角标）：旧记录缺省 -1（下次播放保存后补上）
      const percentRaw: Object | undefined = rec['percent'];
      let percent: number = -1;
      if (percentRaw !== undefined && typeof percentRaw === 'number'
        && percentRaw >= 0 && percentRaw <= 100 && Math.trunc(percentRaw) === percentRaw) {
        percent = percentRaw;
      }
      return new FqWatchedProgress(episodeId, fqNum(rec, 'position'), fqNum(rec, 'duration'),
        percent);
    } catch (error) {
      // 损坏数据按无续播处理
      return null;
    }
  }

  /** 保存某剧续播进度（高频调用：putSync 内存写 + flush 异步落盘）。 */
  public static saveProgress(seriesId: string, progress: FqWatchedProgress): void {
    if (seriesId.length === 0 || progress.episodeId.length === 0) {
      return;
    }
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return;
    }
    const rec: Record<string, Object> = {};
    rec['episodeId'] = progress.episodeId;
    rec['position'] = progress.position;
    rec['duration'] = progress.duration;
    rec['percent'] = progress.percent;
    try {
      pref.putSync(FQ_WATCHED_PROGRESS_PREFIX + seriesId, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
    fqStoreBus.watchedVersion++;
  }

  /** 全部已看记录（剧 id → 已看集集合；备份导出用，遍历落盘 key 走读穿缓存）。 */
  public static allWatched(): Map<string, Set<string>> {
    const result: Map<string, Set<string>> = new Map<string, Set<string>>();
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return result;
    }
    const all: Record<string, Object> | null = fqAsRecord(pref.getAllSync());
    if (all === null) {
      return result;
    }
    for (const key of Object.keys(all)) {
      if (key.startsWith(FQ_WATCHED_PROGRESS_PREFIX)) {
        continue;
      }
      const ids: Set<string> = FqWatchedStore.ids(key);
      if (ids.size > 0) {
        result.set(key, ids);
      }
    }
    return result;
  }

  /** 全部续播进度（剧 id → 续播记录；备份导出用）。 */
  public static allProgress(): Map<string, FqWatchedProgress> {
    const result: Map<string, FqWatchedProgress> = new Map<string, FqWatchedProgress>();
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return result;
    }
    const all: Record<string, Object> | null = fqAsRecord(pref.getAllSync());
    if (all === null) {
      return result;
    }
    for (const key of Object.keys(all)) {
      if (!key.startsWith(FQ_WATCHED_PROGRESS_PREFIX)) {
        continue;
      }
      const seriesId: string = key.substring(FQ_WATCHED_PROGRESS_PREFIX.length);
      const progress: FqWatchedProgress | null = FqWatchedStore.progress(seriesId);
      if (progress !== null) {
        result.set(seriesId, progress);
      }
    }
    return result;
  }

  /**
   * 合并恢复单剧的已看集与续播进度（只补缺失：已看集合并集、
   * 续播仅在本机无记录时写入），单剧至多各落盘一次；返回合并结果统计。
   */
  public static merge(seriesId: string, episodeIds: string[],
    progress: FqWatchedProgress | null): FqWatchedMergeOutcome {
    if (seriesId.length === 0) {
      return new FqWatchedMergeOutcome(0, false);
    }
    const current: Set<string> = FqWatchedStore.ids(seriesId);
    let added: number = 0;
    for (const episodeId of episodeIds) {
      if (episodeId.length === 0 || current.has(episodeId)) {
        continue;
      }
      current.add(episodeId);
      added++;
    }
    let progressWritten: boolean = false;
    if (progress !== null && progress.episodeId.length > 0 &&
      FqWatchedStore.progress(seriesId) === null) {
      progressWritten = true;
    }
    if (added === 0 && !progressWritten) {
      return new FqWatchedMergeOutcome(0, false);
    }
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref !== null) {
      try {
        if (added > 0) {
          const items: string[] = [];
          current.forEach((id: string): void => {
            items.push(id);
          });
          pref.putSync(seriesId, JSON.stringify(items));
        }
        if (progressWritten && progress !== null) {
          const rec: Record<string, Object> = {};
          rec['episodeId'] = progress.episodeId;
          rec['position'] = progress.position;
          rec['duration'] = progress.duration;
          pref.putSync(FQ_WATCHED_PROGRESS_PREFIX + seriesId, JSON.stringify(rec));
        }
        pref.flush().catch((_error: BusinessError): void => {
          // 落盘失败不阻断
        });
      } catch (error) {
        // 忽略写入失败
      }
    }
    fqStoreBus.watchedVersion++;
    return new FqWatchedMergeOutcome(added, progressWritten);
  }

  // -------------------------------------------------------------------------
  // 观看历史（短剧页「最近」频道）
  // -------------------------------------------------------------------------

  /** 全部观看历史（最新在前；首次读盘，之后走内存缓存）。 */
  public static historyAll(): FqWatchHistoryRecord[] {
    const cached: FqWatchHistoryRecord[] | null = FqWatchedStore.historyCache;
    if (cached !== null) {
      return cached;
    }
    const result: FqWatchHistoryRecord[] = [];
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref !== null) {
      try {
        const raw: preferences.ValueType = pref.getSync(FQ_WATCHED_HISTORY_KEY, '');
        if (typeof raw === 'string' && raw.length > 0) {
          const parsed: Object | null = JSON.parse(raw);
          const arr: Object[] | null = fqAsArray(parsed);
          if (arr !== null) {
            for (const entry of arr) {
              const record: FqWatchHistoryRecord | null = FqWatchedStore.historyRecordFrom(entry);
              if (record !== null) {
                result.push(record);
              }
            }
          }
        }
      } catch (error) {
        // 损坏数据按空历史处理
      }
    }
    FqWatchedStore.historyCache = result;
    return result;
  }

  /** 记录一条观看历史（按剧 id upsert：去旧插最前，超出容量裁最旧）。 */
  public static recordHistory(record: FqWatchHistoryRecord): void {
    if (record.id.length === 0 || FqWatchedStore.pref === null) {
      return;
    }
    const current: FqWatchHistoryRecord[] = FqWatchedStore.historyAll();
    const next: FqWatchHistoryRecord[] = [];
    for (const entry of current) {
      if (entry.id !== record.id) {
        next.push(entry);
      }
    }
    next.unshift(record);
    while (next.length > FQ_WATCHED_HISTORY_MAX) {
      next.pop();
    }
    FqWatchedStore.persistHistory(next);
  }

  /** 合并恢复观看历史（备份恢复：只补本机缺失的剧，不动已有记录与顺序）。 */
  public static mergeHistory(records: FqWatchHistoryRecord[]): number {
    if (records.length === 0 || FqWatchedStore.pref === null) {
      return 0;
    }
    const current: FqWatchHistoryRecord[] = FqWatchedStore.historyAll();
    const known: Set<string> = new Set<string>();
    for (const entry of current) {
      known.add(entry.id);
    }
    const next: FqWatchHistoryRecord[] = current.slice();
    let added: number = 0;
    for (const record of records) {
      if (record.id.length === 0 || known.has(record.id) || next.length >= FQ_WATCHED_HISTORY_MAX) {
        continue;
      }
      known.add(record.id);
      next.push(record);
      added++;
    }
    if (added > 0) {
      FqWatchedStore.persistHistory(next);
    }
    return added;
  }

  /** 历史记录落盘（含缓存更新与版本通知）。 */
  private static persistHistory(list: FqWatchHistoryRecord[]): void {
    const pref: preferences.Preferences | null = FqWatchedStore.pref;
    if (pref === null) {
      return;
    }
    const arr: Object[] = [];
    for (const record of list) {
      const rec: Record<string, Object> = {};
      rec['id'] = record.id;
      rec['kind'] = record.kind;
      rec['title'] = record.title;
      rec['cover'] = record.cover;
      rec['episodeId'] = record.episodeId;
      rec['episodeIndex'] = record.episodeIndex;
      rec['position'] = record.position;
      rec['duration'] = record.duration;
      rec['percent'] = record.percent;
      rec['updatedAt'] = record.updatedAt;
      arr.push(rec);
    }
    try {
      pref.putSync(FQ_WATCHED_HISTORY_KEY, JSON.stringify(arr));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
      return;
    }
    FqWatchedStore.historyCache = list;
    fqStoreBus.watchedVersion++;
  }

  /** 单条历史 JSON → 记录（id 空/字段畸形返回 null；数值做范围钳制）。 */
  private static historyRecordFrom(entry: Object): FqWatchHistoryRecord | null {
    const rec: Record<string, Object> | null = fqAsRecord(entry);
    if (rec === null) {
      return null;
    }
    const id: string = fqStr(rec, 'id');
    if (id.length === 0) {
      return null;
    }
    const kindRaw: string = fqStr(rec, 'kind');
    const kind: string = kindRaw === 'manju' ? 'manju' : 'video';
    const episodeIndex: number = Math.trunc(fqNum(rec, 'episodeIndex'));
    const percent: number = fqNum(rec, 'percent');
    return new FqWatchHistoryRecord(
      id,
      kind,
      fqStr(rec, 'title'),
      fqStr(rec, 'cover'),
      fqStr(rec, 'episodeId'),
      episodeIndex >= 0 ? episodeIndex : -1,
      Math.max(0, fqNum(rec, 'position')),
      Math.max(0, fqNum(rec, 'duration')),
      percent >= 0 && percent <= 100 ? Math.trunc(percent) : -1,
      Math.max(0, fqNum(rec, 'updatedAt')),
    );
  }
}

/** 单剧已看/续播合并结果（备份恢复统计用）。 */
export class FqWatchedMergeOutcome {
  readonly episodesAdded: number;
  readonly progressWritten: boolean;

  constructor(episodesAdded: number, progressWritten: boolean) {
    this.episodesAdded = episodesAdded;
    this.progressWritten = progressWritten;
  }
}

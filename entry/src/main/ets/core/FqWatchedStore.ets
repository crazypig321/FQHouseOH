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

const FQ_WATCHED_STORE_NAME: string = 'fq_watched';
/** 续播进度 key 前缀（与已看集合同文件、不同 key 命名空间）。 */
const FQ_WATCHED_PROGRESS_PREFIX: string = 'progress.';

/** 单剧续播进度（fqapp video_progress：集 itemId + 位置/时长，秒）。 */
export class FqWatchedProgress {
  readonly episodeId: string;
  /** 播放位置（秒）。 */
  readonly position: number;
  /** 时长（秒，未知 0）。 */
  readonly duration: number;

  constructor(episodeId: string, position: number, duration: number) {
    this.episodeId = episodeId;
    this.position = position;
    this.duration = duration;
  }
}

export class FqWatchedStore {
  private static pref: preferences.Preferences | null = null;
  /** 剧 id → 已看集 itemId 集合（内存缓存，读穿）。 */
  private static cache: Map<string, Set<string>> = new Map<string, Set<string>>();

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
    return true;
  }

  /** 读取某剧续播进度（无记录返回 null）。 */
  public static progress(seriesId: string): FqWatchedProgress | null {
    if (seriesId.length === 0) {
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
      return new FqWatchedProgress(episodeId, fqNum(rec, 'position'), fqNum(rec, 'duration'));
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
    try {
      pref.putSync(FQ_WATCHED_PROGRESS_PREFIX + seriesId, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

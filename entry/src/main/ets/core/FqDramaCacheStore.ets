/**
 * 剧集缓存存储（对齐 fqapp DramaDownloadStore 语义子集）：
 * - 文件：files/offline_video/<itemId>.mp4（下载中 .mp4.part，完成 rename）；
 * - 元数据：preferences fq_drama_cache，key `ep.<itemId>` 存单集记录
 *   （剧 id/集标题/排序/字节数/时间），管理页按剧分组展示；
 * - 只持久化「已完成」的集（下载中任务由 FqDramaDownloader 持有，重启后
 *   .part 残留按缺集处理，重新发起时 Range 续传复用）；
 * - 变更后 fqStoreBus.dramaCacheVersion++ 驱动管理页刷新。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fqAsRecord, fqNum, fqParseObject, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_DRAMA_CACHE_STORE_NAME: string = 'fq_drama_cache';
const FQ_EPISODE_KEY_PREFIX: string = 'ep.';
const FQ_VIDEO_DIR: string = 'offline_video';
const FQ_PART_SUFFIX: string = '.part';
const FQ_SAFE_ID: RegExp = /^[A-Za-z0-9_-]{1,128}$/;

/** 单集缓存记录（完成后写入）。 */
export class FqCachedEpisode {
  public readonly seriesId: string;
  public readonly itemId: string;
  /** 集标题。 */
  public readonly title: string;
  /** 剧名（管理页分组标题兜底）。 */
  public readonly seriesTitle: string;
  public readonly cover: string;
  /** 'video' | 'manju'。 */
  public readonly kind: string;
  /** 集序号（1 起）。 */
  public readonly index: number;
  public readonly bytes: number;
  public readonly cachedAt: number;

  constructor(seriesId: string, itemId: string, title: string, seriesTitle: string,
    cover: string, kind: string, index: number, bytes: number, cachedAt: number) {
    this.seriesId = seriesId;
    this.itemId = itemId;
    this.title = title;
    this.seriesTitle = seriesTitle;
    this.cover = cover;
    this.kind = kind;
    this.index = index;
    this.bytes = bytes;
    this.cachedAt = cachedAt;
  }
}

/** 管理页按剧聚合的缓存摘要。 */
export class FqCachedDramaSummary {
  public readonly seriesId: string;
  public readonly title: string;
  public readonly cover: string;
  public readonly kind: string;
  public readonly episodeCount: number;
  public readonly byteCount: number;

  constructor(seriesId: string, title: string, cover: string, kind: string,
    episodeCount: number, byteCount: number) {
    this.seriesId = seriesId;
    this.title = title;
    this.cover = cover;
    this.kind = kind;
    this.episodeCount = episodeCount;
    this.byteCount = byteCount;
  }
}

export class FqDramaCacheStore {
  private static pref: preferences.Preferences | null = null;
  private static filesDir: string = '';
  /** itemId → 单集记录（init 时全量载入内存）。 */
  private static cache: Map<string, FqCachedEpisode> = new Map<string, FqCachedEpisode>();

  public static init(context: common.Context): void {
    if (FqDramaCacheStore.pref !== null) {
      return;
    }
    try {
      FqDramaCacheStore.pref = preferences.getPreferencesSync(context,
        { name: FQ_DRAMA_CACHE_STORE_NAME });
    } catch (error) {
      FqDramaCacheStore.pref = null;
    }
    FqDramaCacheStore.filesDir = context.filesDir;
    try {
      fs.mkdirSync(FqDramaCacheStore.videoDir(), true);
    } catch (error) {
      // 已存在或失败，写文件时按需再建
    }
    FqDramaCacheStore.loadAll();
  }

  private static videoDir(): string {
    return `${FqDramaCacheStore.filesDir}/${FQ_VIDEO_DIR}`;
  }

  public static filePath(itemId: string): string {
    return `${FqDramaCacheStore.videoDir()}/${itemId}.mp4`;
  }

  public static partPath(itemId: string): string {
    return `${FqDramaCacheStore.videoDir()}/${itemId}.mp4${FQ_PART_SUFFIX}`;
  }

  private static loadAll(): void {
    const pref: preferences.Preferences | null = FqDramaCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      // preferences 无同步枚举全部 key 的 API，索引 key `ids` 存全部 itemId。
      const keysSync: string[] = [];
      const raw: preferences.ValueType = pref.getSync('ids', '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: Object | null = JSON.parse(raw);
        if (parsed !== null && Array.isArray(parsed)) {
          const arr: Object[] = parsed as Object[];
          for (const entry of arr) {
            if (typeof entry === 'string') {
              keysSync.push(entry);
            }
          }
        }
      }
      for (const itemId of keysSync) {
        FqDramaCacheStore.loadOne(itemId);
      }
    } catch (error) {
      // 损坏索引按空处理
    }
  }

  private static loadOne(itemId: string): void {
    const pref: preferences.Preferences | null = FqDramaCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_EPISODE_KEY_PREFIX + itemId, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return;
      }
      const rec: Record<string, Object> | null = fqParseObject(raw);
      if (rec === null) {
        return;
      }
      const seriesId: string = fqStr(rec, 'seriesId');
      if (seriesId.length === 0) {
        return;
      }
      FqDramaCacheStore.cache.set(itemId, new FqCachedEpisode(seriesId, itemId,
        fqStr(rec, 'title'), fqStr(rec, 'seriesTitle'), fqStr(rec, 'cover'),
        fqStr(rec, 'kind'), fqNum(rec, 'index'), fqNum(rec, 'bytes'), fqNum(rec, 'cachedAt')));
    } catch (error) {
      // 单条损坏跳过
    }
  }

  /** 某集是否已完整缓存（最终文件存在且有记录）。 */
  public static has(itemId: string): boolean {
    if (!FqDramaCacheStore.cache.has(itemId)) {
      return false;
    }
    try {
      fs.accessSync(FqDramaCacheStore.filePath(itemId));
      return true;
    } catch (error) {
      return false;
    }
  }

  /** 某剧已缓存集 itemId 集合。 */
  public static cachedEpisodeIds(seriesId: string): Set<string> {
    const ids: Set<string> = new Set<string>();
    FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
      if (episode.seriesId === seriesId && FqDramaCacheStore.has(episode.itemId)) {
        ids.add(episode.itemId);
      }
    });
    return ids;
  }

  /** 完成一集：写记录 + 索引 + 落盘。 */
  public static addEpisode(episode: FqCachedEpisode): void {
    const pref: preferences.Preferences | null = FqDramaCacheStore.pref;
    if (pref === null || !FQ_SAFE_ID.test(episode.itemId)) {
      return;
    }
    FqDramaCacheStore.cache.set(episode.itemId, episode);
    const rec: Record<string, Object> = {};
    rec['seriesId'] = episode.seriesId;
    rec['itemId'] = episode.itemId;
    rec['title'] = episode.title;
    rec['seriesTitle'] = episode.seriesTitle;
    rec['cover'] = episode.cover;
    rec['kind'] = episode.kind;
    rec['index'] = episode.index;
    rec['bytes'] = episode.bytes;
    rec['cachedAt'] = episode.cachedAt;
    try {
      pref.putSync(FQ_EPISODE_KEY_PREFIX + episode.itemId, JSON.stringify(rec));
      const ids: string[] = [];
      FqDramaCacheStore.cache.forEach((cached: FqCachedEpisode): void => {
        ids.push(cached.itemId);
      });
      pref.putSync('ids', JSON.stringify(ids));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
    fqStoreBus.dramaCacheVersion++;
  }

  /** 删除单集缓存（文件 + 记录）。 */
  public static removeEpisode(itemId: string): void {
    for (const suffix of ['', FQ_PART_SUFFIX]) {
      try {
        fs.unlinkSync(`${FqDramaCacheStore.videoDir()}/${itemId}.mp4${suffix}`);
      } catch (error) {
        // 文件不存在跳过
      }
    }
    if (FqDramaCacheStore.cache.delete(itemId)) {
      FqDramaCacheStore.persistIndex();
      fqStoreBus.dramaCacheVersion++;
    }
  }

  /** 删除整剧缓存。 */
  public static removeSeries(seriesId: string): void {
    const itemIds: string[] = [];
    FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
      if (episode.seriesId === seriesId) {
        itemIds.push(episode.itemId);
      }
    });
    for (const itemId of itemIds) {
      FqDramaCacheStore.removeEpisode(itemId);
    }
  }

  /** 清空全部剧集缓存（文件 + 记录）。 */
  public static clearAll(): void {
    const itemIds: string[] = [];
    FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
      itemIds.push(episode.itemId);
    });
    for (const itemId of itemIds) {
      FqDramaCacheStore.removeEpisode(itemId);
    }
    fqStoreBus.dramaCacheVersion++;
  }

  private static persistIndex(): void {
    const pref: preferences.Preferences | null = FqDramaCacheStore.pref;
    if (pref === null) {
      return;
    }
    try {
      const ids: string[] = [];
      FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
        ids.push(episode.itemId);
      });
      pref.putSync('ids', JSON.stringify(ids));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 某剧全部缓存集（按集序号升序）。 */
  public static episodesOf(seriesId: string): FqCachedEpisode[] {
    const result: FqCachedEpisode[] = [];
    FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
      if (episode.seriesId === seriesId && FqDramaCacheStore.has(episode.itemId)) {
        result.push(episode);
      }
    });
    result.sort((a: FqCachedEpisode, b: FqCachedEpisode): number => a.index - b.index);
    return result;
  }

  /** 管理页：按剧聚合摘要（集数降序）。 */
  public static dramas(): FqCachedDramaSummary[] {
    const groups: Map<string, FqCachedEpisode[]> = new Map<string, FqCachedEpisode[]>();
    FqDramaCacheStore.cache.forEach((episode: FqCachedEpisode): void => {
      if (!FqDramaCacheStore.has(episode.itemId)) {
        return;
      }
      const list: FqCachedEpisode[] | undefined = groups.get(episode.seriesId);
      if (list !== undefined) {
        list.push(episode);
      } else {
        const newList: FqCachedEpisode[] = [episode];
        groups.set(episode.seriesId, newList);
      }
    });
    const summaries: FqCachedDramaSummary[] = [];
    groups.forEach((episodes: FqCachedEpisode[], seriesId: string): void => {
      let title: string = seriesId;
      let cover: string = '';
      let kind: string = 'video';
      let bytes: number = 0;
      for (const episode of episodes) {
        if (episode.seriesTitle.length > 0) {
          title = episode.seriesTitle;
        }
        if (episode.cover.length > 0) {
          cover = episode.cover;
        }
        if (episode.kind.length > 0) {
          kind = episode.kind;
        }
        bytes += episode.bytes;
      }
      summaries.push(new FqCachedDramaSummary(seriesId, title, cover, kind,
        episodes.length, bytes));
    });
    summaries.sort((a: FqCachedDramaSummary, b: FqCachedDramaSummary): number =>
      b.episodeCount - a.episodeCount);
    return summaries;
  }
}

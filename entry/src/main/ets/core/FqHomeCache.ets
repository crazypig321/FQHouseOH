/**
 * 首页频道下标磁盘记忆 + 频道列表内容持久化。
 *
 * 参考 musicfreeOH infra/KVStore.ets 的 preferences 用法：
 * 同步读写 + 异步 flush 落盘。
 * 频道下标：preferences 记住用户上次选中的频道。
 * 列表内容：files/home_feed_cache/<channel>.json（冷启动有缓存直接展示，
 * 不自动刷新，右上角手动刷新后覆盖）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqMediaItem } from '../model/FqModels';
import { fqAsArray, fqAsRecord, fqNum, fqParseObject, fqStr } from './FqJson';

const FQ_CACHE_STORE_NAME: string = 'fq_home_cache';
const FQ_CACHE_KEY_CHANNEL_INDEX: string = 'channel_index';
const FQ_FEED_DIR: string = 'home_feed_cache';
/** 单频道持久化条目上限：只存列表前 15 条（冷启动秒显首屏即可，触底续拉补全）。 */
const FQ_FEED_MAX_ITEMS: number = 15;
const TAG: string = 'FqHomeCache';

export class FqHomeCache {
  private static pref: preferences.Preferences | null = null;
  private static filesDir: string = '';

  /** 初始化（进程内一次）；失败时降级为纯内存空实现。 */
  public static init(context: common.Context): void {
    if (FqHomeCache.pref === null) {
      try {
        FqHomeCache.pref = preferences.getPreferencesSync(context, { name: FQ_CACHE_STORE_NAME });
      } catch (error) {
        FqHomeCache.pref = null;
      }
    }
    if (FqHomeCache.filesDir.length === 0) {
      FqHomeCache.filesDir = context.filesDir;
      try {
        fs.mkdirSync(`${FqHomeCache.filesDir}/${FQ_FEED_DIR}`, true);
      } catch (error) {
        // 已存在或创建失败（保存时按需再建）
      }
    }
  }

  /** 读取上次选中的频道下标，越界/损坏回退 0。 */
  public static savedChannelIndex(): number {
    const pref: preferences.Preferences | null = FqHomeCache.pref;
    if (pref === null) {
      return 0;
    }
    try {
      const raw: preferences.ValueType = pref.getSync(FQ_CACHE_KEY_CHANNEL_INDEX, 0);
      if (typeof raw === 'number') {
        return Math.trunc(raw);
      }
    } catch (error) {
      // 读取失败按默认处理
    }
    return 0;
  }

  /** 记录当前频道下标。 */
  public static saveChannelIndex(index: number): void {
    const pref: preferences.Preferences | null = FqHomeCache.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_CACHE_KEY_CHANNEL_INDEX, index);
      FqHomeCache.flush(pref);
    } catch (error) {
      // 忽略写入失败
    }
  }

  private static flush(pref: preferences.Preferences): void {
    pref.flush().catch((_error: BusinessError): void => {
      // 落盘失败不阻断流程
    });
  }

  // -------------------------------------------------------------------------
  // 频道列表内容持久化（files/home_feed_cache/<channel>.json）
  // -------------------------------------------------------------------------

  private static feedPath(channelIndex: number): string {
    return `${FqHomeCache.filesDir}/${FQ_FEED_DIR}/ch_${channelIndex}.json`;
  }

  /** 保存某频道当前列表（截断上限；失败静默，下次成功覆盖）。 */
  public static saveFeedItems(channelIndex: number, items: FqMediaItem[]): void {
    if (FqHomeCache.filesDir.length === 0 || items.length === 0) {
      return;
    }
    const recs: Record<string, Object>[] = [];
    const count: number = Math.min(items.length, FQ_FEED_MAX_ITEMS);
    for (let i = 0; i < count; i++) {
      const item: FqMediaItem = items[i];
      const rec: Record<string, Object> = {
        'id': item.id,
        'title': item.title,
        'cover': item.cover,
        'author': item.author,
        'badge': item.badge,
        'ep': item.ep,
        'kind': item.kind,
        'score': item.score,
        'intro': item.intro,
        'seriesId': item.seriesId,
        'episodeId': item.episodeId,
        'followerCount': item.followerCount,
      };
      recs.push(rec);
    }
    const payload: Record<string, Object> = {
      'channel': channelIndex,
      'items': recs,
    };
    let file: fs.File | null = null;
    try {
      fs.mkdirSync(`${FqHomeCache.filesDir}/${FQ_FEED_DIR}`, true);
    } catch (error) {
      // 已存在
    }
    try {
      file = fs.openSync(FqHomeCache.feedPath(channelIndex),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(payload));
      fs.closeSync(file);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `saveFeedItems failed: ch=${channelIndex} code=${err.code}`);
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 忽略
        }
      }
    }
  }

  /** 读取某频道持久化列表；无缓存/损坏返回空数组。 */
  public static loadFeedItems(channelIndex: number): FqMediaItem[] {
    if (FqHomeCache.filesDir.length === 0) {
      return [];
    }
    let text: string = '';
    try {
      text = fs.readTextSync(FqHomeCache.feedPath(channelIndex));
    } catch (error) {
      return [];
    }
    const payload: Record<string, Object> | null = fqParseObject(text);
    if (payload === null) {
      return [];
    }
    const rawItems: Object[] | null = fqAsArray(payload['items']);
    if (rawItems === null) {
      return [];
    }
    const items: FqMediaItem[] = [];
    for (const raw of rawItems) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null) {
        continue;
      }
      const id: string = fqStr(rec, 'id');
      if (id.length === 0) {
        continue;
      }
      items.push(new FqMediaItem(id,
        fqStr(rec, 'title'),
        fqStr(rec, 'cover'),
        fqStr(rec, 'author'),
        fqStr(rec, 'badge'),
        fqStr(rec, 'ep'),
        fqStr(rec, 'kind'),
        fqNum(rec, 'score'),
        fqStr(rec, 'intro'),
        fqStr(rec, 'seriesId'),
        fqStr(rec, 'episodeId'),
        fqNum(rec, 'followerCount')));
    }
    return items;
  }
}

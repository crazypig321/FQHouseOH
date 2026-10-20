/**
 * 首页频道列表磁盘缓存。
 *
 * 参考 musicfreeOH infra/KVStore.ets 的 preferences 用法：
 * 同步读写 + 异步 flush 落盘，值为 JSON 字符串。
 * 冷启动先回填上次列表，当前频道随后静默刷新（stale-while-revalidate）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqMediaItem } from '../model/FqModels';
import { fqAsArray, fqAsInt, fqAsRecord, fqStr } from './FqJson';

const FQ_CACHE_STORE_NAME: string = 'fq_home_cache';
const FQ_CACHE_KEY_CHANNEL_INDEX: string = 'channel_index';
/** 单频道落盘条目上限，避免无限翻页撑爆存储。 */
const FQ_CACHE_MAX_ITEMS: number = 200;

export class FqHomeCache {
  private static pref: preferences.Preferences | null = null;

  /** 初始化（进程内一次）；失败时降级为纯内存空实现。 */
  public static init(context: common.Context): void {
    if (FqHomeCache.pref !== null) {
      return;
    }
    try {
      FqHomeCache.pref = preferences.getPreferencesSync(context, { name: FQ_CACHE_STORE_NAME });
    } catch (error) {
      FqHomeCache.pref = null;
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

  /** 读取频道缓存条目，空/损坏返回空数组。 */
  public static channelItems(index: number): FqMediaItem[] {
    const pref: preferences.Preferences | null = FqHomeCache.pref;
    if (pref === null) {
      return [];
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(FqHomeCache.itemKey(index), '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return [];
    }
    if (text.length === 0) {
      return [];
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      return FqHomeCache.parseItems(parsed);
    } catch (error) {
      return [];
    }
  }

  /** 条目序列化落盘（空列表跳过，避免清掉有效缓存）。 */
  public static saveChannelItems(index: number, items: FqMediaItem[]): void {
    const pref: preferences.Preferences | null = FqHomeCache.pref;
    if (pref === null || items.length === 0) {
      return;
    }
    const capped: FqMediaItem[] = items.length > FQ_CACHE_MAX_ITEMS ? items.slice(0, FQ_CACHE_MAX_ITEMS) : items;
    const recs: Object[] = [];
    for (const item of capped) {
      const rec: Record<string, Object> = {};
      rec['id'] = item.id;
      rec['title'] = item.title;
      rec['cover'] = item.cover;
      rec['author'] = item.author;
      rec['badge'] = item.badge;
      rec['ep'] = item.ep;
      rec['kind'] = item.kind;
      rec['score'] = item.score;
      rec['intro'] = item.intro;
      rec['seriesId'] = item.seriesId;
      rec['episodeId'] = item.episodeId;
      rec['followerCount'] = item.followerCount;
      recs.push(rec);
    }
    try {
      pref.putSync(FqHomeCache.itemKey(index), JSON.stringify(recs));
      FqHomeCache.flush(pref);
    } catch (error) {
      // 忽略写入失败
    }
  }

  private static itemKey(index: number): string {
    return `channel_${index}`;
  }

  private static parseItems(parsed: Object | null): FqMediaItem[] {
    const arr: Object[] | null = fqAsArray(parsed);
    if (arr === null) {
      return [];
    }
    const items: FqMediaItem[] = [];
    for (const raw of arr) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null) {
        continue;
      }
      const id: string = fqStr(rec, 'id');
      if (id.length === 0) {
        continue;
      }
      items.push(new FqMediaItem(
        id,
        fqStr(rec, 'title'),
        fqStr(rec, 'cover'),
        fqStr(rec, 'author'),
        fqStr(rec, 'badge'),
        fqStr(rec, 'ep'),
        fqStr(rec, 'kind'),
        fqAsInt(rec['score'], 0),
        fqStr(rec, 'intro'),
        fqStr(rec, 'seriesId'),
        fqStr(rec, 'episodeId'),
        fqAsInt(rec['followerCount'], 0),
      ));
    }
    return items;
  }

  private static flush(pref: preferences.Preferences): void {
    pref.flush().catch((_error: BusinessError): void => {
      // 落盘失败不阻断流程
    });
  }
}

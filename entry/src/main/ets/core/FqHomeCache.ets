/**
 * 首页频道下标磁盘记忆。
 *
 * 参考 musicfreeOH infra/KVStore.ets 的 preferences 用法：
 * 同步读写 + 异步 flush 落盘。
 * 列表条目不持久化：磁盘回填会在刷新时造成旧图重排的视觉错乱，
 * 仅记住用户上次选中的频道。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const FQ_CACHE_STORE_NAME: string = 'fq_home_cache';
const FQ_CACHE_KEY_CHANNEL_INDEX: string = 'channel_index';

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

  private static flush(pref: preferences.Preferences): void {
    pref.flush().catch((_error: BusinessError): void => {
      // 落盘失败不阻断流程
    });
  }
}

/**
 * 阅读时长统计（书架页「今日已读 N 分钟」数据源）。
 *
 * 按本地日期累计秒数（对齐 fqapp LibraryStore.readTimeSnapshot 语义的最小子集）：
 * - 阅读页每 30s 心跳累计；
 * - 听书会话播放中每 5s 累计；
 * preferences 持久化，days 键为 JSON 对象 { 'yyyy-M-d': 秒 }。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqParseObject, fqNum } from './FqJson';

const FQ_READ_STATS_NAME: string = 'fq_read_stats';
const FQ_READ_STATS_KEY: string = 'days';

export class FqReadStatsStore {
  private static pref: preferences.Preferences | null = null;
  private static days: Map<string, number> = new Map<string, number>();

  public static init(context: common.Context): void {
    if (FqReadStatsStore.pref !== null) {
      return;
    }
    try {
      FqReadStatsStore.pref = preferences.getPreferencesSync(context, { name: FQ_READ_STATS_NAME });
    } catch (error) {
      FqReadStatsStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqReadStatsStore.pref.getSync(FQ_READ_STATS_KEY, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    const rec: Record<string, Object> | null = fqParseObject(text);
    if (rec === null) {
      return;
    }
    const keys: string[] = Object.keys(rec);
    for (const key of keys) {
      FqReadStatsStore.days.set(key, fqNum(rec, key));
    }
  }

  /** 未初始化时静默跳过（调用方遍布播放/阅读心跳，不可因未初始化抛错）。 */
  public static addSeconds(seconds: number): void {
    if (seconds <= 0) {
      return;
    }
    const key: string = FqReadStatsStore.todayKey();
    const current: number = FqReadStatsStore.days.get(key) ?? 0;
    FqReadStatsStore.days.set(key, current + seconds);
    FqReadStatsStore.persist();
  }

  /** 今日累计阅读分钟数（向下取整）。 */
  public static todayMinutes(): number {
    const seconds: number = FqReadStatsStore.days.get(FqReadStatsStore.todayKey()) ?? 0;
    return Math.floor(seconds / 60);
  }

  private static todayKey(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqReadStatsStore.pref;
    if (pref === null) {
      return;
    }
    const rec: Record<string, Object> = {};
    FqReadStatsStore.days.forEach((seconds: number, key: string): void => {
      rec[key] = seconds;
    });
    try {
      pref.putSync(FQ_READ_STATS_KEY, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

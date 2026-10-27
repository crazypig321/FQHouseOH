/**
 * 听书历史（对齐 fqapp listen_history_store.dart 语义的最小子集）。
 *
 * preferences 独立存储（fq_listen_history），per-book 一条：
 * chapterIndex/positionSec/durationSec/toneId/rate/completed/title/cover。
 * 会话层 5s 周期持久化 + 暂停/切章/关闭时即时写入。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsArray, fqAsInt, fqAsRecord, fqNum, fqStr } from './FqJson';

const FQ_LISTEN_STORE_NAME: string = 'fq_listen_history';
const FQ_LISTEN_KEY_ITEMS: string = 'items';

/** 单本书的收听进度。 */
export class FqListenRecord {
  bookId: string;
  /** 当前章节下标（目录序）。 */
  chapterIndex: number;
  /** 当前章节内位置（秒）。 */
  positionSec: number;
  /** 当前章节时长（秒）。 */
  durationSec: number;
  /** 音色 id。 */
  toneId: string;
  /** 播放速率。 */
  rate: number;
  /** 当前章节是否已播完。 */
  completed: boolean;
  title: string;
  cover: string;

  constructor(bookId: string, chapterIndex: number, positionSec: number, durationSec: number,
    toneId: string, rate: number, completed: boolean, title: string, cover: string) {
    this.bookId = bookId;
    this.chapterIndex = chapterIndex;
    this.positionSec = positionSec;
    this.durationSec = durationSec;
    this.toneId = toneId;
    this.rate = rate;
    this.completed = completed;
    this.title = title;
    this.cover = cover;
  }
}

export class FqAudioHistory {
  private static pref: preferences.Preferences | null = null;
  private static records: Map<string, FqListenRecord> = new Map<string, FqListenRecord>();

  public static init(context: common.Context): void {
    if (FqAudioHistory.pref !== null) {
      return;
    }
    try {
      FqAudioHistory.pref =
        preferences.getPreferencesSync(context, { name: FQ_LISTEN_STORE_NAME });
    } catch (error) {
      FqAudioHistory.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqAudioHistory.pref.getSync(FQ_LISTEN_KEY_ITEMS, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const arr: Object[] | null = fqAsArray(parsed);
      if (arr === null) {
        return;
      }
      for (const entry of arr) {
        const rec: Record<string, Object> | null = fqAsRecord(entry);
        if (rec === null) {
          continue;
        }
        const bookId: string = fqStr(rec, 'bookId');
        if (bookId.length === 0) {
          continue;
        }
        FqAudioHistory.records.set(bookId, new FqListenRecord(bookId,
          fqAsInt(rec['chapterIndex'], 0), fqNum(rec, 'positionSec'), fqNum(rec, 'durationSec'),
          fqStr(rec, 'toneId'), fqNum(rec, 'rate') > 0 ? fqNum(rec, 'rate') : 1,
          rec['completed'] === true, fqStr(rec, 'title'), fqStr(rec, 'cover')));
      }
    } catch (error) {
      // 损坏缓存按空历史处理
    }
  }

  public static get(bookId: string): FqListenRecord | null {
    return FqAudioHistory.records.get(bookId) ?? null;
  }

  /** 写入（内存即时 + 落盘异步）。 */
  public static put(record: FqListenRecord): void {
    FqAudioHistory.records.delete(record.bookId);
    FqAudioHistory.records.set(record.bookId, record);
    FqAudioHistory.persist();
  }

  /** 全部收听记录（备份导出用）。 */
  public static all(): FqListenRecord[] {
    const result: FqListenRecord[] = [];
    FqAudioHistory.records.forEach((record: FqListenRecord): void => {
      result.push(record);
    });
    return result;
  }

  /** 合并恢复的收听记录（只补缺失 bookId，一次落盘）；返回新增条数。 */
  public static mergeRecords(records: FqListenRecord[]): number {
    let added: number = 0;
    for (const record of records) {
      if (record.bookId.length === 0 || FqAudioHistory.records.has(record.bookId)) {
        continue;
      }
      FqAudioHistory.records.set(record.bookId, record);
      added++;
    }
    if (added > 0) {
      FqAudioHistory.persist();
    }
    return added;
  }

  /** 清空全部收听历史（设置-清空历史）。 */
  public static clear(): void {
    FqAudioHistory.records.clear();
    FqAudioHistory.persist();
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqAudioHistory.pref;
    if (pref === null) {
      return;
    }
    const recs: Object[] = [];
    FqAudioHistory.records.forEach((record: FqListenRecord): void => {
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
      recs.push(rec);
    });
    try {
      pref.putSync(FQ_LISTEN_KEY_ITEMS, JSON.stringify(recs));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

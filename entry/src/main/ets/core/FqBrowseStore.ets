/**
 * 浏览历史（书架页「浏览历史」tab 数据源）。
 *
 * preferences 独立存储（fq_browse_history）：详情页加载成功即记录，
 * 按访问时间倒序（最新在前），同 id 去重置顶，容量上限 100 条。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsArray, fqAsRecord, fqNum, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_BROWSE_STORE_NAME: string = 'fq_browse_history';
const FQ_BROWSE_KEY_ITEMS: string = 'items';
const FQ_BROWSE_MAX_ITEMS: number = 100;

/** 单条浏览记录。 */
export class FqBrowseItem {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  /** 最近访问时间（毫秒时间戳）。 */
  readonly visitedAt: number;

  constructor(id: string, kind: string, title: string, cover: string, visitedAt: number) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.visitedAt = visitedAt;
  }
}

export class FqBrowseStore {
  private static pref: preferences.Preferences | null = null;
  private static items: FqBrowseItem[] = [];

  public static init(context: common.Context): void {
    if (FqBrowseStore.pref !== null) {
      return;
    }
    try {
      FqBrowseStore.pref = preferences.getPreferencesSync(context, { name: FQ_BROWSE_STORE_NAME });
    } catch (error) {
      FqBrowseStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqBrowseStore.pref.getSync(FQ_BROWSE_KEY_ITEMS, '');
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
        const id: string = fqStr(rec, 'id');
        if (id.length === 0) {
          continue;
        }
        FqBrowseStore.items.push(new FqBrowseItem(id, fqStr(rec, 'kind'), fqStr(rec, 'title'),
          fqStr(rec, 'cover'), fqNum(rec, 'visitedAt')));
      }
    } catch (error) {
      // 损坏缓存按空历史处理
    }
  }

  /** 记录一次访问：同 id 去重并置顶（最新在前）。 */
  public static record(item: FqBrowseItem): void {
    if (item.id.length === 0) {
      return;
    }
    const next: FqBrowseItem[] = [item];
    for (const entry of FqBrowseStore.items) {
      if (entry.id !== item.id && next.length < FQ_BROWSE_MAX_ITEMS) {
        next.push(entry);
      }
    }
    FqBrowseStore.items = next;
    FqBrowseStore.persist();
    fqStoreBus.browseVersion++;
  }

  /** 最新在前。 */
  public static all(): FqBrowseItem[] {
    return FqBrowseStore.items;
  }

  /** 清空全部浏览历史。 */
  public static clear(): void {
    FqBrowseStore.items = [];
    FqBrowseStore.persist();
    fqStoreBus.browseVersion++;
  }

  /** 批量删除浏览记录（书架页多选「删除」）。 */
  public static removeByIds(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    const removing: Set<string> = new Set<string>(ids);
    const next: FqBrowseItem[] = [];
    for (const entry of FqBrowseStore.items) {
      if (!removing.has(entry.id)) {
        next.push(entry);
      }
    }
    FqBrowseStore.items = next;
    FqBrowseStore.persist();
    fqStoreBus.browseVersion++;
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqBrowseStore.pref;
    if (pref === null) {
      return;
    }
    const recs: Object[] = [];
    for (const item of FqBrowseStore.items) {
      const rec: Record<string, Object> = {};
      rec['id'] = item.id;
      rec['kind'] = item.kind;
      rec['title'] = item.title;
      rec['cover'] = item.cover;
      rec['visitedAt'] = item.visitedAt;
      recs.push(rec);
    }
    try {
      pref.putSync(FQ_BROWSE_KEY_ITEMS, JSON.stringify(recs));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

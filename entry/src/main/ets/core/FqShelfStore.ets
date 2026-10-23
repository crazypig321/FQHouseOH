/**
 * 本地书架（对齐 fqapp lib/services/shelf_store.dart 的最小子集）。
 *
 * preferences 持久化（参考 musicfreeOH KVStore 用法）：
 * items 为 JSON 数组字符串，内存 Set 维护 inShelf 判断。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsArray, fqAsRecord, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_SHELF_STORE_NAME: string = 'fq_shelf';
const FQ_SHELF_KEY_ITEMS: string = 'items';

/** 书架条目（M1 仅记录识别与展示所需字段）。 */
export class FqShelfItem {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;

  constructor(id: string, kind: string, title: string, cover: string) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
  }
}

export class FqShelfStore {
  private static pref: preferences.Preferences | null = null;
  private static ids: Set<string> = new Set<string>();
  private static items: FqShelfItem[] = [];

  public static init(context: common.Context): void {
    if (FqShelfStore.pref !== null) {
      return;
    }
    try {
      FqShelfStore.pref = preferences.getPreferencesSync(context, { name: FQ_SHELF_STORE_NAME });
    } catch (error) {
      FqShelfStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqShelfStore.pref.getSync(FQ_SHELF_KEY_ITEMS, '');
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
        FqShelfStore.items.push(new FqShelfItem(id, fqStr(rec, 'kind'), fqStr(rec, 'title'), fqStr(rec, 'cover')));
        FqShelfStore.ids.add(id);
      }
    } catch (error) {
      // 损坏缓存按空书架处理
    }
  }

  public static contains(id: string): boolean {
    return FqShelfStore.ids.has(id);
  }

  /** 切换收藏状态；返回切换后是否在书架。 */
  public static toggle(item: FqShelfItem): boolean {
    if (FqShelfStore.ids.has(item.id)) {
      FqShelfStore.ids.delete(item.id);
      const next: FqShelfItem[] = [];
      for (const entry of FqShelfStore.items) {
        if (entry.id !== item.id) {
          next.push(entry);
        }
      }
      FqShelfStore.items = next;
      FqShelfStore.persist();
      fqStoreBus.shelfVersion++;
      return false;
    }
    if (item.id.length === 0) {
      return false;
    }
    FqShelfStore.ids.add(item.id);
    FqShelfStore.items.push(item);
    FqShelfStore.persist();
    fqStoreBus.shelfVersion++;
    return true;
  }

  public static all(): FqShelfItem[] {
    return FqShelfStore.items;
  }

  /** 批量移出书架（书架页多选「移出书架」）。 */
  public static removeByIds(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    const removing: Set<string> = new Set<string>(ids);
    const next: FqShelfItem[] = [];
    for (const entry of FqShelfStore.items) {
      if (!removing.has(entry.id)) {
        next.push(entry);
      } else {
        FqShelfStore.ids.delete(entry.id);
      }
    }
    FqShelfStore.items = next;
    FqShelfStore.persist();
    fqStoreBus.shelfVersion++;
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqShelfStore.pref;
    if (pref === null) {
      return;
    }
    const recs: Object[] = [];
    for (const item of FqShelfStore.items) {
      const rec: Record<string, Object> = {};
      rec['id'] = item.id;
      rec['kind'] = item.kind;
      rec['title'] = item.title;
      rec['cover'] = item.cover;
      recs.push(rec);
    }
    try {
      pref.putSync(FQ_SHELF_KEY_ITEMS, JSON.stringify(recs));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

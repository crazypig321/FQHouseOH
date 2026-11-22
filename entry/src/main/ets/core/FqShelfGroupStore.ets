/**
 * 书架自定义分组仓库（对齐 fqapp shelf_group_store.dart 的最小子集）：
 * - 具名分组（id/name）+ 每本书的分组归属（bookId → groupId）；
 * - preferences 持久化为单 JSON 文档（groups + assignments，插入序保留）；
 * - 删除分组时同步清理其归属；移出书架由调用方调 removeAssignments 清理；
 * - 备份恢复走 assignIfUnassigned（只补未分组书，绝不覆盖本机已有归属）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsArray, fqAsRecord, fqKeys, fqStr } from './FqJson';
import { fqStoreBus } from './FqStoreBus';

const FQ_SHELF_GROUP_STORE_NAME: string = 'fq_shelf_groups';
const FQ_SHELF_GROUP_KEY_DOC: string = 'doc_v1';
/** 分组名长度上限（与原版 fqapp 一致）。 */
const FQ_SHELF_GROUP_NAME_MAX: number = 30;
/** 分组数量上限。 */
const FQ_SHELF_GROUP_MAX: number = 50;

/** 书架分组（id 由本 store 生成：g<base36 时间戳>-<base36 随机>）。 */
export class FqShelfGroup {
  readonly id: string;
  readonly name: string;
  /** 是否加锁（进入分组需验证；锁定组内作品在书架/搜索/浏览历史中隐藏）。 */
  readonly locked: boolean;

  constructor(id: string, name: string, locked: boolean = false) {
    this.id = id;
    this.name = name;
    this.locked = locked;
  }
}

export class FqShelfGroupStore {
  private static pref: preferences.Preferences | null = null;
  private static groups: FqShelfGroup[] = [];
  /** 书 → 分组归属（groupId；值必须仍存在于 groups，读取时惰性校验）。 */
  private static assignment: Map<string, string> = new Map<string, string>();

  public static init(context: common.Context): void {
    if (FqShelfGroupStore.pref !== null) {
      return;
    }
    try {
      FqShelfGroupStore.pref = preferences.getPreferencesSync(context, { name: FQ_SHELF_GROUP_STORE_NAME });
    } catch (error) {
      FqShelfGroupStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqShelfGroupStore.pref.getSync(FQ_SHELF_GROUP_KEY_DOC, '');
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
      const doc: Record<string, Object> | null = fqAsRecord(parsed);
      if (doc === null) {
        return;
      }
      const ids: Set<string> = new Set<string>();
      const groupsRaw: Object[] | null = fqAsArray(doc['groups']);
      if (groupsRaw !== null) {
        for (const entry of groupsRaw) {
          const rec: Record<string, Object> | null = fqAsRecord(entry);
          if (rec === null) {
            continue;
          }
          const id: string = fqStr(rec, 'id');
          const name: string = fqStr(rec, 'name');
          if (id.length === 0 || name.length === 0 || ids.has(id)) {
            continue;
          }
          ids.add(id);
          FqShelfGroupStore.groups.push(new FqShelfGroup(id, name, rec['locked'] === true));
        }
      }
      const assignmentsRaw: Record<string, Object> | null = fqAsRecord(doc['assignments']);
      if (assignmentsRaw !== null) {
        for (const bookId of fqKeys(assignmentsRaw)) {
          const groupId: string = fqStr(assignmentsRaw, bookId);
          if (bookId.length > 0 && groupId.length > 0 && ids.has(groupId)) {
            FqShelfGroupStore.assignment.set(bookId, groupId);
          }
        }
      }
    } catch (error) {
      // 损坏文档按无分组处理
    }
  }

  /** 全部分组（插入序）。 */
  public static all(): FqShelfGroup[] {
    return FqShelfGroupStore.groups;
  }

  public static groupById(id: string): FqShelfGroup | null {
    for (const group of FqShelfGroupStore.groups) {
      if (group.id === id) {
        return group;
      }
    }
    return null;
  }

  public static groupByName(name: string): FqShelfGroup | null {
    for (const group of FqShelfGroupStore.groups) {
      if (group.name === name) {
        return group;
      }
    }
    return null;
  }

  /** 书的分组 id（'' = 未分组；分组已删除时视为未分组）。 */
  public static groupOf(bookId: string): string {
    const groupId: string | undefined = FqShelfGroupStore.assignment.get(bookId);
    if (groupId === undefined) {
      return '';
    }
    return FqShelfGroupStore.groupById(groupId) !== null ? groupId : '';
  }

  /** 分组内书的数量（含已不在书架的残留归属，展示计数前由调用方自行过滤）。 */
  public static countOf(groupId: string): number {
    let count: number = 0;
    FqShelfGroupStore.assignment.forEach((value: string): void => {
      if (value === groupId) {
        count++;
      }
    });
    return count;
  }

  /** 新建分组：名称 trim 后 1~30 字且不重名，超上限/重名返回 null。 */
  public static addGroup(name: string): FqShelfGroup | null {
    const trimmed: string = name.trim();
    if (trimmed.length === 0 || trimmed.length > FQ_SHELF_GROUP_NAME_MAX
      || FqShelfGroupStore.groupByName(trimmed) !== null
      || FqShelfGroupStore.groups.length >= FQ_SHELF_GROUP_MAX) {
      return null;
    }
    const group: FqShelfGroup = new FqShelfGroup(FqShelfGroupStore.newGroupId(), trimmed);
    FqShelfGroupStore.groups.push(group);
    FqShelfGroupStore.persist();
    fqStoreBus.shelfGroupVersion++;
    return group;
  }

  /** 重命名分组：名称 trim 后 1~30 字且不与其他分组重名。 */
  public static renameGroup(id: string, name: string): boolean {
    const trimmed: string = name.trim();
    if (trimmed.length === 0 || trimmed.length > FQ_SHELF_GROUP_NAME_MAX) {
      return false;
    }
    for (const group of FqShelfGroupStore.groups) {
      if (group.id !== id && group.name === trimmed) {
        return false;
      }
    }
    for (let index: number = 0; index < FqShelfGroupStore.groups.length; index++) {
      if (FqShelfGroupStore.groups[index].id === id) {
        FqShelfGroupStore.groups[index] =
          new FqShelfGroup(id, trimmed, FqShelfGroupStore.groups[index].locked);
        FqShelfGroupStore.persist();
        fqStoreBus.shelfGroupVersion++;
        return true;
      }
    }
    return false;
  }

  /** 分组加锁/解锁（进入解锁后的分组仍需按调用方门控重新验证）。 */
  public static setLocked(id: string, locked: boolean): boolean {
    for (let index: number = 0; index < FqShelfGroupStore.groups.length; index++) {
      if (FqShelfGroupStore.groups[index].id === id) {
        if (FqShelfGroupStore.groups[index].locked === locked) {
          return true;
        }
        FqShelfGroupStore.groups[index] =
          new FqShelfGroup(id, FqShelfGroupStore.groups[index].name, locked);
        FqShelfGroupStore.persist();
        fqStoreBus.shelfGroupVersion++;
        return true;
      }
    }
    return false;
  }

  /** 分组是否加锁（分组不存在 = 未加锁）。 */
  public static isLocked(id: string): boolean {
    const group: FqShelfGroup | null = FqShelfGroupStore.groupById(id);
    return group !== null && group.locked;
  }

  /** 删除分组：其下归属一并清除（书保留在书架，回到未分组）。 */
  public static removeGroup(id: string): boolean {
    if (FqShelfGroupStore.groupById(id) === null) {
      return false;
    }
    const next: FqShelfGroup[] = [];
    for (const group of FqShelfGroupStore.groups) {
      if (group.id !== id) {
        next.push(group);
      }
    }
    FqShelfGroupStore.groups = next;
    FqShelfGroupStore.removeAssignmentsOfGroup(id);
    FqShelfGroupStore.persist();
    fqStoreBus.shelfGroupVersion++;
    return true;
  }

  /** 重排分组：orderedIds 为新顺序的分组 id（未知 id 忽略，遗漏分组按原顺序补尾）；顺序无变化不落盘。 */
  public static reorder(orderedIds: string[]): boolean {
    const byId: Map<string, FqShelfGroup> = new Map<string, FqShelfGroup>();
    for (const group of FqShelfGroupStore.groups) {
      byId.set(group.id, group);
    }
    const next: FqShelfGroup[] = [];
    for (const id of orderedIds) {
      const group: FqShelfGroup | undefined = byId.get(id);
      if (group !== undefined) {
        next.push(group);
        byId.delete(id);
      }
    }
    for (const group of FqShelfGroupStore.groups) {
      if (byId.has(group.id)) {
        next.push(group);
      }
    }
    let changed: boolean = false;
    for (let index: number = 0; index < next.length; index++) {
      if (next[index].id !== FqShelfGroupStore.groups[index].id) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return false;
    }
    FqShelfGroupStore.groups = next;
    FqShelfGroupStore.persist();
    fqStoreBus.shelfGroupVersion++;
    return true;
  }

  /** 批量归组（groupId = '' 移出分组）；返回实际变更数。 */
  public static assign(bookIds: string[], groupId: string): number {
    if (groupId.length > 0 && FqShelfGroupStore.groupById(groupId) === null) {
      return 0;
    }
    let changed: number = 0;
    for (const bookId of bookIds) {
      const before: string | undefined = FqShelfGroupStore.assignment.get(bookId);
      const beforeValid: string = before === undefined ? ''
        : (FqShelfGroupStore.groupById(before) !== null ? before : '');
      if (beforeValid === groupId) {
        continue;
      }
      if (groupId.length === 0) {
        FqShelfGroupStore.assignment.delete(bookId);
      } else {
        FqShelfGroupStore.assignment.set(bookId, groupId);
      }
      changed++;
    }
    if (changed > 0) {
      FqShelfGroupStore.persist();
      fqStoreBus.shelfGroupVersion++;
    }
    return changed;
  }

  /** 只补未分组的书（备份恢复合并语义）；返回实际写入数。 */
  public static assignIfUnassigned(bookIds: string[], groupId: string): number {
    if (groupId.length === 0 || FqShelfGroupStore.groupById(groupId) === null) {
      return 0;
    }
    let changed: number = 0;
    for (const bookId of bookIds) {
      if (FqShelfGroupStore.groupOf(bookId).length > 0) {
        continue;
      }
      FqShelfGroupStore.assignment.set(bookId, groupId);
      changed++;
    }
    if (changed > 0) {
      FqShelfGroupStore.persist();
      fqStoreBus.shelfGroupVersion++;
    }
    return changed;
  }

  /** 移出书架时清理归属（书本身记录由 FqShelfStore 管理）。 */
  public static removeAssignments(bookIds: string[]): void {
    let changed: boolean = false;
    for (const bookId of bookIds) {
      if (FqShelfGroupStore.assignment.delete(bookId)) {
        changed = true;
      }
    }
    if (changed) {
      FqShelfGroupStore.persist();
      fqStoreBus.shelfGroupVersion++;
    }
  }

  /** 备份采集：分组 + 各分组归属的书（调用方过滤 local_ 与不在书架的书）。 */
  public static booksOf(groupId: string): string[] {
    const books: string[] = [];
    FqShelfGroupStore.assignment.forEach((value: string, key: string): void => {
      if (value === groupId) {
        books.push(key);
      }
    });
    return books;
  }

  private static removeAssignmentsOfGroup(groupId: string): void {
    const keys: string[] = [];
    FqShelfGroupStore.assignment.forEach((value: string, key: string): void => {
      if (value === groupId) {
        keys.push(key);
      }
    });
    for (const key of keys) {
      FqShelfGroupStore.assignment.delete(key);
    }
  }

  private static newGroupId(): string {
    return `g${Date.now().toString(36)}-${Math.floor(Math.random() * 0x100000000).toString(36)}`;
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqShelfGroupStore.pref;
    if (pref === null) {
      return;
    }
    const groupsRec: Object[] = [];
    for (const group of FqShelfGroupStore.groups) {
      const rec: Record<string, Object> = {};
      rec['id'] = group.id;
      rec['name'] = group.name;
      rec['locked'] = group.locked;
      groupsRec.push(rec);
    }
    const assignmentsRec: Record<string, Object> = {};
    FqShelfGroupStore.assignment.forEach((value: string, key: string): void => {
      if (FqShelfGroupStore.groupById(value) !== null) {
        assignmentsRec[key] = value;
      }
    });
    const doc: Record<string, Object> = {};
    doc['groups'] = groupsRec;
    doc['assignments'] = assignmentsRec;
    try {
      pref.putSync(FQ_SHELF_GROUP_KEY_DOC, JSON.stringify(doc));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

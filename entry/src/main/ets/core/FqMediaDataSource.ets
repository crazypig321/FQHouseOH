/**
 * 内容卡片懒加载数据源（对齐 musicfreeOH MusicDataSource 模式：
 * IDataSource + onDataReloaded 整体通知，供 LazyForEach 使用）。
 */

import { FqMediaItem } from '../model/FqModels';

export class FqMediaDataSource implements IDataSource {
  private items: FqMediaItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): FqMediaItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 追加一页数据（分页加载）。 */
  append(items: FqMediaItem[]): void {
    if (items.length === 0) {
      return;
    }
    this.items = this.items.concat(items);
    this.notifyReload();
  }

  /** 清空数据（切换频道/重新搜索/刷新）。 */
  reset(): void {
    this.items = [];
    this.notifyReload();
  }

  private notifyReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

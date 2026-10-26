/**
 * 书架页（对齐 fqapp LibraryPage 形态，一级 Tab 页）：
 * 标题栏「书架/浏览历史」胶囊 + 添加/搜索/更多菜单；
 * 菜单承载预览方式（网格/双列/列表，两 tab 共享）+ 离线缓存 + 清空（按 tab 区分）；
 * LazyForEach 懒加载；长按进入多选（musicfreeOH 批量底栏样式）。
 * 批量多选以 appState.isBatchMode 为单一数据源（Index 返回手势退出多选、主 TabBar 显隐共享）。
 */

import { ROUTE_DETAIL, ROUTE_READER2, ROUTE_CACHED_BOOKS, DetailNavParams, ReaderNavParams } from '../model/FqNavModels';
import { CommonNav, titleBarOf } from '../view/CommonNav';
import { FQ_ACCENT, CommonSearch, CommonBlur } from '../view/CommonCom';
import { FqMenu, FqMenuItem } from '../view/CommonMenu';
import { FqShelfStore, FqShelfItem } from '../core/FqShelfStore';
import { FqBrowseStore } from '../core/FqBrowseStore';
import { fqStoreBus, FqStoreBus } from '../core/FqStoreBus';
import { DialogManager } from '../utils/DialogUtils';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqLocalBookStore } from '../core/FqLocalBookStore';
import { FqBackend } from '../core/FqBackend';
import { FqMediaItem, FqSearchTab, fqKindLabel } from '../model/FqModels';
import { FqMediaCard } from '../view/FqMediaCard';
import { NavPathUtils } from '../utils/NavPathUtils';
import { appState, AppState } from '../entryability/AppState';
import { rowImmersiveModifier, stackImmersiveModifier } from '../utils/ModifierUtils';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import preferences from '@ohos.data.preferences';
import { BusinessError } from '@kit.BasicServicesKit';

/** 书架页「更多」菜单锚点 id */
const SHELF_MORE_ANCHOR_ID: string = 'shelf_more_anchor';
/** 书架页搜索框焦点 id（须与 SearchBar 中 CommonSearch focusId 一致） */
const SHELF_SEARCH_FOCUS_ID: string = 'shelf_page_search';
/** 版式偏好存储。 */
const SHELF_PREF_NAME: string = 'fq_shelf_prefs';
const SHELF_PREF_LAYOUT: string = 'layout';

/** 书架/浏览历史统一展示行（勾选态由 batchSelected 实时派生，不随行快照，避免批量操作整表重载闪烁）。 */
class ShelfRow {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  /** 列表版式副标题（kind 标签或相对时间）。 */
  readonly sub: string;

  constructor(id: string, kind: string, title: string, cover: string, sub: string) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.sub = sub;
  }
}

/** 书架页懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class ShelfDataSource implements IDataSource {
  private rows: ShelfRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ShelfRow {
    return this.rows[index];
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

  reload(rows: ShelfRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct ShelfPage {
  /** 0=书架 1=浏览历史 */
  @Local currentTab: number = 0;
  @Local showSearchBox: boolean = false;
  @Local searchInput: string = '';
  @Local searchKeyword: string = '';
  /** 0=网格 1=双列卡片 2=列表（两 tab 共享，持久化）。 */
  @Local layout: number = 0;
  @Local batchSelected: string[] = [];
  @Local todayMinutesNum: number = 0;
  @Local importing: boolean = false;
  @Local visibleCount: number = 0;
  /** store 版本总线（监听 shelf/browse 数据变化实时刷新列表）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 全局状态引用（监听批量多选被外部退出，如 Index 返回手势）。 */
  @Local appStateUse: AppState = appState;
  private scroller: Scroller = new Scroller();
  private dataSource: ShelfDataSource = new ShelfDataSource();
  private layoutPref: preferences.Preferences | null = null;
  /** 已尝试封面匹配的本地书（会话内去重，避免重复搜索）。 */
  private coverMatchTried: Set<string> = new Set<string>();

  /** 书架/浏览历史数据变化（详情页收藏、阅读记录、批量移除等）实时刷新列表。 */
  @Monitor('storeBus.shelfVersion', 'storeBus.browseVersion')
  onStoreDataChange(): void {
    this.refreshData();
  }

  /** 多选模式被外部退出（Index 返回手势）时清空勾选。 */
  @Monitor('appStateUse.isBatchMode')
  onBatchModeChange(): void {
    if (!this.appStateUse.isBatchMode) {
      this.batchSelected = [];
    }
  }

  aboutToAppear(): void {
    FqShelfStore.init(getContext(this));
    FqBrowseStore.init(getContext(this));
    FqReadStatsStore.init(getContext(this));
    FqLocalBookStore.init(getContext(this));
    try {
      this.layoutPref = preferences.getPreferencesSync(getContext(this), { name: SHELF_PREF_NAME });
      const raw: preferences.ValueType = this.layoutPref.getSync(SHELF_PREF_LAYOUT, 0);
      if (typeof raw === 'number' && raw >= 0 && raw <= 2) {
        this.layout = raw;
      }
    } catch (error) {
      this.layoutPref = null;
    }
    this.refreshData();
    this.matchUncoveredLocalBooks();
  }

  aboutToDisappear(): void {
    // 兜底：页面销毁时退出批量模式，恢复主 TabBar
    if (appState.isBatchMode) {
      appState.isBatchMode = false;
    }
  }

  build() {
    CommonNav({
      titleBarOp: titleBarOf('书架', `今日已读${this.todayMinutesNum}分钟`, this.titleMenus(),
        {
          builder: (): void => {
            this.TitleExtraBuilder();
          },
          height: this.showSearchBox ? 110 : 40
        }),
      isHideBackButton: true,
      scroller: this.scroller,
      // 胶囊常驻标题栏下方，不随滚动隐藏
      isSearchBarScroller: false,
      doubleTapToTop: true,
      scrollToTopYOffset: -this.listTopInset(),
      onShown: (): void => {
        this.refreshData();
      },
    }) {
      Stack({ alignContent: Alignment.Top }) {
        List({ space: 14, scroller: this.scroller }) {
          LazyForEach(this.dataSource, (row: ShelfRow, index: number) => {
            ListItem() {
              if (this.layout === 2) {
                this.ListRowBuilder(row)
              } else {
                FqMediaCard({
                  item: this.rowToMediaItem(row),
                  chipText: FqLocalBookStore.isLocalBookId(row.id) ? '本地书籍' : '',
                  onItemClick: (clicked: FqMediaItem): void => {
                    this.onRowTap(row);
                  },
                  batchMode: appState.isBatchMode,
                  selected: this.isSelectedId(row.id),
                })
              }
            }
            .gesture(LongPressGesture()
              .onAction((): void => {
                this.onRowLongPress(row);
              }))
          }, (row: ShelfRow, index: number): string =>
            `${row.id}_${row.cover.length > 0 ? 'c' : 'n'}_${this.layout}`)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .lanes(this.layout === 0 ? 3 : (this.layout === 1 ? 2 : 1), 20)
        .padding({
          left: this.layout === 2 ? 16 : 20,
          right: this.layout === 2 ? 16 : 20
        })
        .contentStartOffset(this.listTopInset())
        .contentEndOffset(appState.bottomRect + 60 + (appState.isBatchMode ? 130 : 0))

        if (this.visibleCount === 0) {
          this.EmptyHint()
        }

        // 多选模式底部操作栏（musicfreeOH 批量底栏样式）
        if (appState.isBatchMode) {
          Stack(){
            CommonBlur()

            Column({ space: 10 }) {
              Row() {
                Text(`已选 ${this.batchSelected.length} 本`)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                Blank()
                Text('取消')
                  .fontSize(16)
                  .fontColor($r('sys.color.font_secondary'))
                  .onClick(() => {
                    this.exitBatchMode();
                  })
              }
              .width('100%')

              Row({ space: 8 }) {
                Button(this.allSelected() ? '取消全选' : '全选')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .borderRadius(10)
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .fontColor($r('sys.color.font_primary'))
                  .onClick(() => {
                    this.toggleSelectAll();
                  })
                Button(this.currentTab === 0 ? '移出书架' : '删除')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .borderRadius(10)
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .fontColor($r('sys.color.font_primary'))
                  .onClick(() => {
                    this.batchClearSelected();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .position({ bottom: 0 })
            .padding({ top: 14, left: 16, right: 16, bottom: appState.bottomRect  })
            .transition(TransitionEffect.OPACITY)
          }.layoutGravity(LocalizedAlignment.BOTTOM_END)// stack组件中子组件对齐位置
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 300, curve: Curve.EaseOut }))
        }


        // 「更多」菜单锚点（对齐标题栏更多按钮：右缘 16、垂直居中于 56 高标题栏）
        Row() {
          Column()
            .id(SHELF_MORE_ANCHOR_ID)
            .width(24)
            .height(24)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ right: 16 })
        .margin({ top: appState.topRect + 16 })
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 列表顶部避让：标题栏 56 + 胶囊 54（+ 搜索行 56）。 */
  private listTopInset(): number {
    return appState.topRect + 110 + (this.showSearchBox ? 56 : 0);
  }

  /** 重新读取 store 并重建懒加载数据。 */
  private refreshData(): void {
    this.todayMinutesNum = FqReadStatsStore.todayMinutes();
    this.rebuildRows();
  }

  /** 当前 tab 应用搜索关键词后的展示行。 */
  private rebuildRows(): void {
    const keyword: string = this.searchKeyword;
    const rows: ShelfRow[] = [];
    if (this.currentTab === 0) {
      for (const entry of FqShelfStore.all()) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          rows.push(new ShelfRow(entry.id, entry.kind, entry.title, entry.cover,
            FqLocalBookStore.isLocalBookId(entry.id) ? '本地书籍' : fqKindLabel(entry.kind)));
        }
      }
    } else {
      for (const entry of FqBrowseStore.all()) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          rows.push(new ShelfRow(entry.id, entry.kind, entry.title, entry.cover,
            this.relativeTime(entry.visitedAt)));
        }
      }
    }
    this.visibleCount = rows.length;
    this.dataSource.reload(rows);
  }

  /** 相对时间文案（浏览历史副标题）。 */
  private relativeTime(ts: number): string {
    if (ts <= 0) {
      return fqKindLabel('book');
    }
    const diff: number = Date.now() - ts;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)}分钟前`;
    }
    if (diff < 86400000) {
      return `${Math.floor(diff / 3600000)}小时前`;
    }
    if (diff < 7 * 86400000) {
      return `${Math.floor(diff / 86400000)}天前`;
    }
    const date: Date = new Date(ts);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  private rowToMediaItem(row: ShelfRow): FqMediaItem {
    return new FqMediaItem(row.id, row.title, row.cover, '', '', '', row.kind, 0, '', '', '', 0);
  }

  /** titleBar 菜单按钮：添加（导入本地书籍）+ 搜索 + 更多。 */
  private titleMenus(): Array<HdsNavigationMenuItemOptions> {
    const add: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.plus'),
        label: '添加',
        action: (): void => {
          this.importLocalBook();
        }
      }
    };
    const search: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.magnifyingglass'),
        label: '搜索',
        action: (): void => {
          this.toggleSearchBox();
        }
      }
    };
    const menu: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.dot_grid_2x2'),
        label: '更多',
        action: (): void => {
          this.openMoreMenu();
        }
      }
    };
    return [add, search, menu];
  }

  /** 导入本地 TXT 书籍（选择器取消无提示）。 */
  private async importLocalBook(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const item: FqShelfItem | null = await FqLocalBookStore.pickAndImport(getContext(this));
      if (item === null) {
        return;
      }
      // 幂等入架：同文件重复导入复用同一本书（进度/已读保留），不产生重复条目
      const added: boolean = FqShelfStore.addIfAbsent(item);
      if (this.currentTab !== 0) {
        this.switchTab(0);
      }
      this.refreshData();
      this.showToast(added ? `已导入《${item.title}》` : `《${item.title}》已在书架，继续上次进度`);
      // 导入后按书名网络匹配封面（命中回填书架条目，失败保持图标占位）
      this.matchLocalBookCover(item.id, item.title);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.showToast(`导入失败：${err.message.length > 0 ? err.message : '请重试'}`);
    } finally {
      this.importing = false;
    }
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  /** 书架内无封面本地书批量匹配（进入页面时补齐历史导入的匹配机会）。 */
  private matchUncoveredLocalBooks(): void {
    for (const entry of FqShelfStore.all()) {
      if (FqLocalBookStore.isLocalBookId(entry.id) && entry.cover.length === 0) {
        this.matchLocalBookCover(entry.id, entry.title);
      }
    }
  }

  /** 本地书封面网络匹配：按书名搜小说源，命中同名作品则取封面回填书架条目。
   *  会话内每本只试一次（coverMatchTried 去重），失败静默保持图标占位。 */
  private async matchLocalBookCover(id: string, title: string): Promise<void> {
    if (title.trim().length === 0 || this.coverMatchTried.has(id)) {
      return;
    }
    this.coverMatchTried.add(id);
    try {
      await FqBackend.get().start(getContext(this));
      const tabs: FqSearchTab[] = await FqBackend.get().searchTabs(title.trim(), 3, 0);
      for (const tab of tabs) {
        for (const media of tab.items) {
          if (media.kind !== 'book' || media.cover.length === 0) {
            continue;
          }
          if (media.title.trim() === title.trim()) {
            if (FqShelfStore.updateCover(id, media.cover)) {
              this.showToast(`已匹配《${title}》封面`);
            }
            return;
          }
        }
      }
    } catch (error) {
      // 匹配失败保持图标占位（本会话不再重试）
    }
  }

  /** 更多菜单：预览方式（两 tab 共享）+ 离线缓存 + 清空（按 tab 区分）。 */
  private openMoreMenu(): void {
    const items: Array<FqMenuItem> = [];

    const gridItem = new FqMenuItem();
    gridItem.label = '网格视图';
    gridItem.endIcon = this.layout === 0 ? $r('sys.symbol.checkmark') : '';
    gridItem.onAction = (): void => {
      FqMenu.dismiss();
      this.setLayout(0);
    };
    items.push(gridItem);

    const doubleItem = new FqMenuItem();
    doubleItem.label = '双列卡片';
    doubleItem.endIcon = this.layout === 1 ? $r('sys.symbol.checkmark') : '';
    doubleItem.onAction = (): void => {
      FqMenu.dismiss();
      this.setLayout(1);
    };
    items.push(doubleItem);

    const listItem = new FqMenuItem();
    listItem.label = '列表视图';
    listItem.endIcon = this.layout === 2 ? $r('sys.symbol.checkmark') : '';
    listItem.onAction = (): void => {
      FqMenu.dismiss();
      this.setLayout(2);
    };
    items.push(listItem);

    const offlineItem = new FqMenuItem();
    offlineItem.icon = $r('sys.symbol.download');
    offlineItem.label = '离线缓存';
    offlineItem.onAction = (): void => {
      FqMenu.dismiss();
      NavPathUtils.push(ROUTE_CACHED_BOOKS);
    };
    items.push(offlineItem);

    const clearItem = new FqMenuItem();
    clearItem.icon = $r('sys.symbol.trash');
    clearItem.label = this.currentTab === 0 ? '清空书架' : '清空浏览历史';
    clearItem.onAction = (): void => {
      FqMenu.dismiss();
      this.confirmClearCurrentTab();
    };
    items.push(clearItem);

    FqMenu.open(this.getUIContext(), SHELF_MORE_ANCHOR_ID, items);
  }

  /** 切换预览方式（两 tab 共享，持久化）。 */
  private setLayout(layout: number): void {
    if (this.layout === layout) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
      this.layout = layout;
    });
    this.rebuildRows();
    const pref: preferences.Preferences | null = this.layoutPref;
    if (pref !== null) {
      try {
        pref.putSync(SHELF_PREF_LAYOUT, layout);
        pref.flush().catch((_error: BusinessError): void => {
          // 落盘失败不阻断
        });
      } catch (error) {
        // 忽略写入失败
      }
    }
  }

  /** 清空确认（按当前 tab：书架 / 浏览历史；共用确认弹窗）。 */
  private confirmClearCurrentTab(): void {
    const isShelf: boolean = this.currentTab === 0;
    DialogManager.ShowConfirm(
      isShelf ? '清空书架' : '清空浏览历史',
      isShelf ? '确定要清空书架全部作品吗？此操作不可恢复。'
        : '确定要清空全部浏览历史吗？此操作不可恢复。',
      '清空',
      (): void => {
        if (isShelf) {
          const ids: string[] = [];
          for (const entry of FqShelfStore.all()) {
            ids.push(entry.id);
          }
          FqShelfStore.removeByIds(ids);
        } else {
          FqBrowseStore.clear();
        }
        if (appState.isBatchMode) {
          this.exitBatchMode();
        }
        this.refreshData();
      }
    );
  }

  /** 展开/收起标题栏搜索框（收起时清空关键词恢复全部）。 */
  private toggleSearchBox(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.showSearchBox = !this.showSearchBox;
    });
    if (!this.showSearchBox) {
      this.searchKeyword = '';
      this.searchInput = '';
      this.rebuildRows();
      return;
    }
    // 展开后请求焦点呼出软键盘（延时等待插槽挂载与展开过渡完成）
    const focusController = this.getUIContext().getFocusController();
    setTimeout((): void => {
      try {
        focusController.requestFocus(SHELF_SEARCH_FOCUS_ID);
      } catch (e) {
        // 组件未挂载时忽略
      }
    }, 320);
    if (this.scroller.currentOffset().yOffset !== 0) {
      this.scroller.scrollTo({
        xOffset: 0,
        yOffset: -this.listTopInset(),
        animation: { duration: 250, curve: Curve.EaseOut }
      });
    }
  }

  /** 切换「书架/浏览历史」胶囊（滑块位移动画 + 列表回顶 + 退出多选）。 */
  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    if (appState.isBatchMode) {
      this.exitBatchMode();
    }
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.currentTab = index;
    });
    this.rebuildRows();
    this.scroller.scrollEdge(Edge.Top);
  }

  private onRowTap(row: ShelfRow): void {
    if (appState.isBatchMode) {
      this.toggleSelected(row.id);
      return;
    }
    this.openDetail(row);
  }

  /** 长按进入多选（多选中长按切换勾选）。 */
  private onRowLongPress(row: ShelfRow): void {
    if (!appState.isBatchMode) {
      this.enterBatchMode(row.id);
      return;
    }
    this.toggleSelected(row.id);
  }

  /** 进入多选（appState 单源 + key 稳定 + V2 参数绑定：列表原地淡入勾选态，不重载数据源）。 */
  private enterBatchMode(firstId: string): void {
    this.batchSelected = [firstId];
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      appState.isBatchMode = true;
    });
  }

  /** 退出多选（animateTo 包裹：勾选圈/角标淡出，不重载数据源）。 */
  private exitBatchMode(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      appState.isBatchMode = false;
    });
    this.batchSelected = [];
  }

  private isSelectedId(id: string): boolean {
    return this.batchSelected.indexOf(id) !== -1;
  }

  /** 勾选切换（batchSelected 整体替换驱动 V2 参数绑定原地刷新，不重载）。 */
  private toggleSelected(id: string): void {
    const next: string[] = this.batchSelected.slice();
    const idx: number = next.indexOf(id);
    if (idx === -1) {
      next.push(id);
    } else {
      next.splice(idx, 1);
    }
    this.batchSelected = next;
  }

  private allSelected(): boolean {
    return this.visibleCount > 0 && this.batchSelected.length === this.visibleCount;
  }

  private toggleSelectAll(): void {
    if (this.allSelected()) {
      this.batchSelected = [];
    } else {
      const ids: string[] = [];
      const count: number = this.dataSource.totalCount();
      for (let i = 0; i < count; i++) {
        ids.push(this.dataSource.getData(i).id);
      }
      this.batchSelected = ids;
    }
  }

  /** 多选清除（先弹共用确认弹窗）：书架 tab 移出书架，历史 tab 删除记录。 */
  private batchClearSelected(): void {
    if (this.batchSelected.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    const ids: string[] = this.batchSelected.slice();
    const count: number = ids.length;
    const isShelf: boolean = this.currentTab === 0;
    DialogManager.ShowConfirm(
      isShelf ? '移出书架' : '删除记录',
      isShelf ? `确定将选中的 ${count} 本作品移出书架吗？` : `确定删除选中的 ${count} 条浏览记录吗？`,
      isShelf ? '移出' : '删除',
      (): void => {
        if (isShelf) {
          FqShelfStore.removeByIds(ids);
          this.showToast(`已移出 ${count} 本`);
        } else {
          FqBrowseStore.removeByIds(ids);
          this.showToast(`已删除 ${count} 条`);
        }
        this.exitBatchMode();
        this.refreshData();
      }
    );
  }

  private openDetail(row: ShelfRow): void {
    // 本地导入书籍直接进阅读页
    if (FqLocalBookStore.isLocalBookId(row.id)) {
      ReaderNavParams.id = row.id;
      ReaderNavParams.kind = 'book';
      ReaderNavParams.title = row.title;
      ReaderNavParams.cover = row.cover;
      ReaderNavParams.chapterIndex = -1;
      ReaderNavParams.listenAlong = false;
      NavPathUtils.push(ROUTE_READER2);
      return;
    }
    DetailNavParams.id = row.id;
    DetailNavParams.kind = row.kind;
    DetailNavParams.title = row.title;
    DetailNavParams.cover = row.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 标题栏下方扩展区：「书架/浏览历史」胶囊滑块 + 可展开搜索框。 */
  @Builder
  private TitleExtraBuilder() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('50%')
          .height(26)
          .borderRadius(13)
          // 位移必须用绝对值：81 = 滑轨内宽 162 的一半
          .offset({ x: this.currentTab === 1 ? 81 : 0 })
          .attributeModifier(rowImmersiveModifier)

        Row() {
          Text('书架')
            .fontSize(12)
            .fontWeight(this.currentTab === 0 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.currentTab === 0 ? FQ_ACCENT : $r('sys.color.font_tertiary'))
            .height(26)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.switchTab(0);
            })
          Text('浏览历史')
            .fontSize(12)
            .fontWeight(this.currentTab === 1 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.currentTab === 1 ? FQ_ACCENT : $r('sys.color.font_tertiary'))
            .height(26)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.switchTab(1);
            })
        }
        .width('100%')
      }
      .width(168)
      .height(30)
      .borderRadius(15)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .padding(3)
      .margin({ top: 4, bottom: 10 })
      .attributeModifier(stackImmersiveModifier)

      if (this.showSearchBox) {
        this.SearchBar()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 搜索框（固定于标题栏下方；输入不即时过滤，
   * 点搜索按钮/软键盘回车后才应用关键词）。
   */
  @Builder
  private SearchBar() {
    CommonSearch({
      searchValue: this.searchInput,
      placeholderValue: this.currentTab === 0 ? '搜索书架作品' : '搜索浏览记录',
      focusId: SHELF_SEARCH_FOCUS_ID,
      submit: (_value: string, _event: SubmitEvent): void => {
        this.searchKeyword = this.searchInput.trim();
        this.rebuildRows();
      },
      change: (v: string): void => {
        this.searchInput = v;
      },
      didDelete: (): void => {
        this.searchInput = '';
        this.searchKeyword = '';
        this.rebuildRows();
      },
    })
      .width('100%')
      .padding({ left: 16, right: 16 })
      .transition(TransitionEffect.move(TransitionEdge.TOP))
  }

  /** 列表版式行：勾选圈 + 封面缩略 + 标题/副标题。 */
  @Builder
  private ListRowBuilder(row: ShelfRow) {
    Row({ space: 12 }) {
      if (appState.isBatchMode) {
        SymbolGlyph(this.isSelectedId(row.id) ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(24)
          .fontColor([this.isSelectedId(row.id) ? FQ_ACCENT : $r('sys.color.icon_tertiary')])
          .transition(TransitionEffect.OPACITY)
      }
      if (row.cover.length > 0) {
        Image(FqBackend.get().resourceUrl(row.cover))
          .width(60)
          .height(82)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .autoResize(true)
          .draggable(false)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_tertiary')])
        }
        .width(60)
        .height(82)
        .borderRadius(8)
        .backgroundColor($r('sys.color.comp_background_secondary'))
      }
      Column({ space: 4 }) {
        Text(row.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.sub)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      this.onRowTap(row);
    })
  }

  /** 空态：按 tab 与关键词区分文案（覆盖层居中，避开 lanes 三列挤压）。 */
  @Builder
  private EmptyHint() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(64)
          .height(64)
          .borderRadius(32)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
        SymbolGlyph(this.currentTab === 0 ? $r('sys.symbol.book') : $r('sys.symbol.clock'))
          .fontSize(32)
          .fontColor([FQ_ACCENT])
      }
      Text(this.emptyTitle())
        .fontSize(16)
        .fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
      Text(this.emptySub())
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private emptyTitle(): string {
    if (this.searchKeyword.length > 0) {
      return '未找到相关内容';
    }
    if (this.currentTab === 0) {
      return '书架还是空的';
    }
    return '暂无浏览记录';
  }

  private emptySub(): string {
    if (this.searchKeyword.length > 0) {
      return '换个关键词试试';
    }
    if (this.currentTab === 0) {
      return '去首页发现好故事，加入书架吧';
    }
    return '看过的作品会出现在这里';
  }
}

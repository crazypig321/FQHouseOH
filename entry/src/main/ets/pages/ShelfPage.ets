/**
 * 书架页（对齐 fqapp LibraryPage 形态，一级 Tab 页）：
 * 标题栏「书架/浏览历史」胶囊 + 添加/搜索/更多菜单；
 * 菜单承载预览方式（网格/双列/列表，两 tab 共享）+ 离线缓存 + 清空（按 tab 区分）；
 * LazyForEach 懒加载；长按进入多选（musicfreeOH 批量底栏样式）。
 * 批量多选以 appState.isBatchMode 为单一数据源（Index 返回手势退出多选、主 TabBar 显隐共享）。
 */

import { ROUTE_READER2, ROUTE_CACHE_MANAGE, ROUTE_DETAIL, DetailNavParams, fqPushBookOrDetail, ReaderNavParams } from '../model/FqNavModels';
import { CommonNav, titleBarOf } from '../view/CommonNav';
import { CommonSearch, CommonBlur } from '../view/CommonCom';
import { CommonSheet, FqSheetOptions } from '../view/sheet/CommonSheet';
import { FqMenu, FqMenuItem } from '../view/CommonMenu';
import { FqShelfStore, FqShelfItem } from '../core/FqShelfStore';
import { FqShelfGroupStore, FqShelfGroup } from '../core/FqShelfGroupStore';
import { FqBrowseStore } from '../core/FqBrowseStore';
import { FqReaderStore } from '../core/FqReaderStore';
import { FqWatchedProgress, FqWatchedStore } from '../core/FqWatchedStore';
import { fqStoreBus, FqStoreBus } from '../core/FqStoreBus';
import { DialogManager } from '../utils/DialogUtils';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqLocalBookStore } from '../core/FqLocalBookStore';
import { FqShareKit } from '../utils/share/FqShareKit';
import { FqBackend } from '../core/FqBackend';
import { FqMediaItem, FqSearchTab, fqKindLabel } from '../model/FqModels';
import { FqMediaCard } from '../view/FqMediaCard';
import { NavPathUtils } from '../utils/NavPathUtils';
import { appState, AppState } from '../entryability/AppState';
import { rowImmersiveModifier, stackImmersiveModifier } from '../utils/ModifierUtils';
import { shelfColumns, useSidebarLayout } from '../utils/BreakpointUtils';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import preferences from '@ohos.data.preferences';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqColorUtils } from '../utils/FqColorUtils';

/** 书架页「更多」菜单锚点 id */
const SHELF_MORE_ANCHOR_ID: string = 'shelf_more_anchor';
/** 书架页搜索框焦点 id（须与 SearchBar 中 CommonSearch focusId 一致） */
const SHELF_SEARCH_FOCUS_ID: string = 'shelf_page_search';
/** 版式偏好存储。 */
const SHELF_PREF_NAME: string = 'fq_shelf_prefs';
const SHELF_PREF_LAYOUT: string = 'layout';
/** 书架排序偏好（0..7，见 sortMode）。 */
const SHELF_PREF_SORT: string = 'sort';
/** 书架筛选偏好：状态（0=全部 1=未看完 2=已看完）。 */
const SHELF_PREF_FILTER_STATUS: string = 'filter_status';
/** 书架筛选偏好：来源（0=全部 1=本地 2=在线）。 */
const SHELF_PREF_FILTER_SOURCE: string = 'filter_source';
/** 书架筛选偏好：分组（''=全部，其余分组 id）。 */
const SHELF_PREF_FILTER_GROUP: string = 'filter_group';
/** 书架筛选 pill 锚点 id。 */
const SHELF_FILTER_ANCHOR_ID: string = 'shelf_filter_anchor';
/** 分组管理 sheet 内分组行菜单锚点 id 前缀。 */
const SHELF_GROUP_ROW_ANCHOR_PREFIX: string = 'shelf_group_row_';
/** 分组标签行长按菜单锚点 id 前缀（区别于管理 sheet 行锚点，避免重复 id）。 */
const SHELF_GROUP_TAG_ANCHOR_PREFIX: string = 'shelf_group_tag_';
/** 分组标签行高度（标题栏避让与滚动补偿共用）。 */
const SHELF_GROUP_TAGS_HEIGHT: number = 36;

/** 书架/浏览历史统一展示行（勾选态由 batchSelected 实时派生，不随行快照，避免批量操作整表重载闪烁）。 */
class ShelfRow {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  /** 列表版式副标题（kind 标签或相对时间）。 */
  readonly sub: string;
  /** 整书阅读百分比 0..100（封面右上角角标）；-1 = 无进度。 */
  readonly percent: number;

  constructor(id: string, kind: string, title: string, cover: string, sub: string, percent: number = -1) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.sub = sub;
    this.percent = percent;
  }
}

/** 书架排序辅助行：行数据随行携带加入顺序与最近浏览时间，排序后仅取 row。 */
class ShelfSortEntry {
  readonly row: ShelfRow;
  /** 加入顺序（书架 store 插入序，0 最早）。 */
  readonly addedIndex: number;
  /** 最近浏览时间戳（毫秒；0 = 未浏览过）。 */
  readonly visitedAt: number;

  constructor(row: ShelfRow, addedIndex: number, visitedAt: number) {
    this.row = row;
    this.addedIndex = addedIndex;
    this.visitedAt = visitedAt;
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
  /** 书架排序：0/1=名称正/倒序 2/3=进度正/倒序 4/5=最近观看正/倒序 6/7=加入时间正/倒序（持久化，默认 6 保持加入顺序）。 */
  @Local sortMode: number = 6;
  @Local todayMinutesNum: number = 0;
  @Local importing: boolean = false;
  @Local visibleCount: number = 0;
  /** 书架筛选：状态（0=全部 1=未看完 2=已看完，持久化，仅书架 tab）。 */
  @Local filterStatus: number = 0;
  /** 书架筛选：来源（0=全部 1=本地 2=在线，持久化，仅书架 tab）。 */
  @Local filterSource: number = 0;
  /** 书架筛选：分组（''=全部，其余分组 id，持久化，仅书架 tab）。 */
  @Local filterGroupId: string = '';
  /** 分组 sheet 是否可见（assign=多选归组 / manage=分组管理）。 */
  @Local groupSheetVisible: boolean = false;
  /** 分组 sheet 模式：'assign' 归组 / 'manage' 管理。 */
  @Local groupSheetMode: string = 'manage';
  /** 分组 sheet 展示的分组快照（store 变化时刷新）。 */
  @Local sheetGroups: FqShelfGroup[] = [];
  /** 筛选 pill 右侧可用区域实测宽度（vp，onAreaChange 捕获，用于长分组名省略号截断）。 */
  @Local filterAreaWidth: number = 0;
  /** store 版本总线（监听 shelf/browse 数据变化实时刷新列表）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 全局状态引用（监听批量多选被外部退出，如 Index 返回手势）。 */
  @Local appStateUse: AppState = appState;
  private scroller: Scroller = new Scroller();
  private dataSource: ShelfDataSource = new ShelfDataSource();
  private layoutPref: preferences.Preferences | null = null;
  /** 上一帧分组标签行是否可见（出现/消失翻转检测，驱动滚动补偿）。 */
  private tagsVisibleBefore: boolean = false;
  /** 已尝试封面匹配的本地书（会话内去重，避免重复搜索）。 */
  private coverMatchTried: Set<string> = new Set<string>();

  /** 书架/浏览历史/已看剧集/阅读进度/分组数据变化（详情页收藏、阅读记录、看剧/阅读进度、批量移除、归组等）实时刷新列表。 */
  @Monitor('storeBus.shelfVersion', 'storeBus.browseVersion', 'storeBus.watchedVersion',
    'storeBus.readerProgressVersion', 'storeBus.shelfGroupVersion')
  onStoreDataChange(): void {
    this.refreshData();
    // 分组快照常驻刷新：标签行与管理/归组 sheet 共用
    this.sheetGroups = FqShelfGroupStore.all().slice();
    this.compensateTagRowChange();
  }

  /** 分组标签行从无到有（首个分组创建）时顶部避让突增，滚动补偿避免标签行压住列表内容；
   * 消失（末组删除）时 ArkUI 自动把滚动位置钳回新上限，无需补偿。 */
  private compensateTagRowChange(): void {
    const tagsNow: boolean = this.groupTagsVisible();
    if (tagsNow && !this.tagsVisibleBefore
      && this.currentTab === 0
      && this.scroller.currentOffset().yOffset < 0) {
      this.scroller.scrollBy(0, -SHELF_GROUP_TAGS_HEIGHT);
    }
    this.tagsVisibleBefore = tagsNow;
  }

  /** 多选模式被外部退出（Index 返回手势）时清空勾选。 */
  @Monitor('appStateUse.isBatchMode')
  onBatchModeChange(): void {
    if (!this.appStateUse.isBatchMode) {
      appState.batchSelectedIds = [];
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
      const rawSort: preferences.ValueType = this.layoutPref.getSync(SHELF_PREF_SORT, 6);
      if (typeof rawSort === 'number' && rawSort >= 0 && rawSort <= 7) {
        this.sortMode = rawSort;
      }
      const rawStatus: preferences.ValueType = this.layoutPref.getSync(SHELF_PREF_FILTER_STATUS, 0);
      if (typeof rawStatus === 'number' && rawStatus >= 0 && rawStatus <= 2) {
        this.filterStatus = rawStatus;
      }
      const rawSource: preferences.ValueType = this.layoutPref.getSync(SHELF_PREF_FILTER_SOURCE, 0);
      if (typeof rawSource === 'number' && rawSource >= 0 && rawSource <= 2) {
        this.filterSource = rawSource;
      }
      const rawGroup: preferences.ValueType = this.layoutPref.getSync(SHELF_PREF_FILTER_GROUP, '');
      if (typeof rawGroup === 'string' && rawGroup.length > 0
        && FqShelfGroupStore.groupById(rawGroup) !== null) {
        this.filterGroupId = rawGroup;
      }
    } catch (error) {
      this.layoutPref = null;
    }
    this.sheetGroups = FqShelfGroupStore.all().slice();
    this.tagsVisibleBefore = this.groupTagsVisible();
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
          height: this.titleExtraHeight()
        }),
      embedded: true,
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
                  chipText: this.rowChip(row),
                  badgePercent: row.percent,
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
            `${row.id}_${row.cover.length > 0 ? 'c' : 'n'}_${this.layout}_${row.percent}`)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .lanes(shelfColumns(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp, this.layout), 20)
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
                Text(`已选 ${appState.batchSelectedIds.length} 本`)
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
                // 多选分享：所选作品生成书单链接（目标端打开直接导入书架）
                Button('分享')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .borderRadius(10)
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .fontColor($r('sys.color.font_primary'))
                  .onClick(() => {
                    this.shareBatchSelected();
                  })
                // 批量归组：所选作品移入自定义分组（仅书架 tab）
                if (this.currentTab === 0) {
                  Button('分组')
                    .layoutWeight(1)
                    .height(36)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .borderRadius(10)
                    .backgroundColor($r('sys.color.comp_background_tertiary'))
                    .fontColor($r('sys.color.font_primary'))
                    .onClick(() => {
                      this.openAssignSheet();
                    })
                }
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
            .padding({
              top: 14,
              left: 16,
              right: 16,
              // PC 侧边栏布局无底部手势条避让，固定留白 16；其余按手势条高度避让
              bottom: useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp) ? 16 : appState.bottomRect,
            })
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
      // 分组 sheet：assign=多选归组 / manage=分组管理（共用单 bindSheet）
      .bindSheet(this.groupSheetVisible, this.GroupSheetBuilder(),
        FqSheetOptions((): void => {
          this.groupSheetVisible = false;
        }, 480))
    }
  }

  /** 分组标签行是否可见：书架 tab 且存在分组。 */
  private groupTagsVisible(): boolean {
    return this.currentTab === 0 && this.sheetGroups.length > 0;
  }

  /** 列表顶部避让：标题栏 56 + 胶囊 54（+ 分组标签行）（+ 搜索行 56）。 */
  private listTopInset(): number {
    return appState.topRect + 110 + (this.groupTagsVisible() ? SHELF_GROUP_TAGS_HEIGHT : 0)
      + (this.showSearchBox ? 56 : 0);
  }

  /** 标题栏扩展区高度：胶囊 40 + 分组标签行 + 搜索行 70。 */
  private titleExtraHeight(): number {
    return 40 + (this.groupTagsVisible() ? SHELF_GROUP_TAGS_HEIGHT : 0) + (this.showSearchBox ? 70 : 0);
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
      // 最近观看排序依据：浏览记录的 visitedAt
      const visitedAtMap: Map<string, number> = new Map<string, number>();
      for (const browse of FqBrowseStore.all()) {
        visitedAtMap.set(browse.id, browse.visitedAt);
      }
      const entries: ShelfSortEntry[] = [];
      let addedIndex: number = 0;
      for (const entry of FqShelfStore.all()) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          const percent: number = this.entryPercent(entry.id, entry.kind);
          if (this.rowMatchesFilter(entry.id, percent)) {
            entries.push(new ShelfSortEntry(new ShelfRow(entry.id, entry.kind, entry.title, entry.cover,
              FqLocalBookStore.isLocalBookId(entry.id) ? '本地书籍' : fqKindLabel(entry.kind),
              percent), addedIndex, visitedAtMap.get(entry.id) ?? 0));
          }
        }
        addedIndex++;
      }
      entries.sort((a: ShelfSortEntry, b: ShelfSortEntry): number => this.compareShelfEntries(a, b));
      for (const entry of entries) {
        rows.push(entry.row);
      }
    } else {
      for (const entry of FqBrowseStore.all()) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          rows.push(new ShelfRow(entry.id, entry.kind, entry.title, entry.cover,
            this.relativeTime(entry.visitedAt),
            this.entryPercent(entry.id, entry.kind)));
        }
      }
    }
    this.visibleCount = rows.length;
    this.dataSource.reload(rows);
  }

  /** 封面角标百分比 0..100（-1 无进度不显示）：
   *  小说/漫画走阅读进度（整书百分比）；短剧/漫剧走续播记录内保存的整剧百分比
   *  （(集下标 + 集内比例)/总集数，播放页保存时计算；旧记录未存则不显示，下次播放后补上）。 */
  private entryPercent(id: string, kind: string): number {
    if (kind === 'video' || kind === 'manju') {
      const progress: FqWatchedProgress | null = FqWatchedStore.progress(id);
      if (progress === null || progress.percent < 0) {
        return -1;
      }
      return progress.percent;
    }
    return FqReaderStore.getProgress(id).percent;
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

  /** 封面角标文案：本地导入书 / 书旗来源；其余空。 */
  private rowChip(row: ShelfRow): string {
    if (FqLocalBookStore.isLocalBookId(row.id)) {
      return '本地书籍';
    }
    if (row.id.startsWith('shuqi:')) {
      return '书旗';
    }
    return '';
  }

  /** 筛选是否生效（状态/来源任一非「全部」；分组选择由标签行表达，不计入筛选 pill）。 */
  private hasActiveFilter(): boolean {
    return this.currentTab === 0
      && (this.filterStatus !== 0 || this.filterSource !== 0);
  }

  /** 书架行是否通过当前组合筛选（状态/来源/分组 AND）。 */
  private rowMatchesFilter(id: string, percent: number): boolean {
    // 已看完 = 进度 ≥ 100；未看完 = 除已看完外全部（含无进度）
    if (this.filterStatus === 2 && percent < 100) {
      return false;
    }
    if (this.filterStatus === 1 && percent >= 100) {
      return false;
    }
    const isLocal: boolean = FqLocalBookStore.isLocalBookId(id);
    if (this.filterSource === 1 && !isLocal) {
      return false;
    }
    if (this.filterSource === 2 && isLocal) {
      return false;
    }
    if (this.filterGroupId.length > 0 && FqShelfGroupStore.groupOf(id) !== this.filterGroupId) {
      return false;
    }
    return true;
  }

  /** 筛选 pill 标签：默认「筛选」，生效时组合状态/来源维度（分组选择由分组标签行表达，不进 pill 文案）。 */
  private filterPillLabel(): string {
    if (!this.hasActiveFilter()) {
      return '筛选';
    }
    const parts: string[] = [];
    if (this.filterStatus === 1) {
      parts.push('未看完');
    }
    if (this.filterStatus === 2) {
      parts.push('已看完');
    }
    if (this.filterSource === 1) {
      parts.push('本地');
    }
    if (this.filterSource === 2) {
      parts.push('在线');
    }
    return parts.length > 0 ? parts.join(' · ') : '筛选';
  }

  /** 筛选 pill 文案最大宽度（vp）：实测区域宽 - 箭头/间距/内边距占用；未测量前给保守小值。 */
  private filterLabelMaxWidth(): number {
    if (this.filterAreaWidth <= 0) {
      return 60;
    }
    return Math.max(this.filterAreaWidth - 34, 40);
  }

  /** 筛选偏好持久化。 */
  private persistFilterPref(key: string, value: number | string): void {
    const pref: preferences.Preferences | null = this.layoutPref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(key, value);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 筛选菜单：状态/来源级联 + 清除筛选（分组选择走胶囊下方的分组标签行）。 */
  private openFilterMenu(): void {
    const items: Array<FqMenuItem> = [];

    const statusLabels: string[] = ['全部', '未看完', '已看完'];
    const statusItem = new FqMenuItem();
    statusItem.label = this.filterStatus === 0 ? '状态' : `状态 · ${statusLabels[this.filterStatus]}`;
    statusItem.subItems = this.buildFilterEnumSubItems(statusLabels, this.filterStatus,
      (mode: number): void => {
        this.setFilterStatus(mode);
      });
    items.push(statusItem);

    const sourceLabels: string[] = ['全部', '本地', '在线'];
    const sourceItem = new FqMenuItem();
    sourceItem.label = this.filterSource === 0 ? '来源' : `来源 · ${sourceLabels[this.filterSource]}`;
    sourceItem.subItems = this.buildFilterEnumSubItems(sourceLabels, this.filterSource,
      (mode: number): void => {
        this.setFilterSource(mode);
      });
    items.push(sourceItem);

    const clearItem = new FqMenuItem();
    clearItem.icon = $r('sys.symbol.xmark');
    clearItem.label = '清除筛选';
    clearItem.onAction = (): void => {
      FqMenu.dismiss();
      this.clearAllFilters();
    };
    items.push(clearItem);

    FqMenu.open(this.getUIContext(), SHELF_FILTER_ANCHOR_ID, items);
  }

  /** 清除全部筛选：状态/来源还原默认值（含持久化）；分组选择由标签行表达，不受影响。 */
  private clearAllFilters(): void {
    let changed: boolean = false;
    if (this.filterStatus !== 0) {
      this.filterStatus = 0;
      this.persistFilterPref(SHELF_PREF_FILTER_STATUS, 0);
      changed = true;
    }
    if (this.filterSource !== 0) {
      this.filterSource = 0;
      this.persistFilterPref(SHELF_PREF_FILTER_SOURCE, 0);
      changed = true;
    }
    if (changed) {
      this.rebuildRows();
      this.showToast('已清除筛选');
    }
  }

  /** 状态/来源二级菜单（当前项打勾）。 */
  private buildFilterEnumSubItems(labels: string[], current: number,
    onPick: (mode: number) => void): Array<FqMenuItem> {
    const subItems: Array<FqMenuItem> = [];
    for (let mode: number = 0; mode < labels.length; mode++) {
      const sub = new FqMenuItem();
      sub.label = labels[mode];
      sub.endIcon = current === mode ? $r('sys.symbol.checkmark') : '';
      sub.onAction = (): void => {
        FqMenu.dismiss();
        onPick(mode);
      };
      subItems.push(sub);
    }
    return subItems;
  }

  private setFilterStatus(mode: number): void {
    if (this.filterStatus === mode) {
      return;
    }
    this.filterStatus = mode;
    this.persistFilterPref(SHELF_PREF_FILTER_STATUS, mode);
    this.rebuildRows();
  }

  private setFilterSource(mode: number): void {
    if (this.filterSource === mode) {
      return;
    }
    this.filterSource = mode;
    this.persistFilterPref(SHELF_PREF_FILTER_SOURCE, mode);
    this.rebuildRows();
  }

  private setFilterGroupId(groupId: string): void {
    if (this.filterGroupId === groupId) {
      return;
    }
    this.filterGroupId = groupId;
    this.persistFilterPref(SHELF_PREF_FILTER_GROUP, groupId);
    this.rebuildRows();
  }

  /** 新建分组（筛选菜单 / sheet 内共用）。 */
  private promptCreateGroup(): void {
    DialogManager.InputShelfGroupName('新建分组', '', (name: string): void => {
      const group: FqShelfGroup | null = FqShelfGroupStore.addGroup(name);
      if (group === null) {
        this.showToast('创建失败：名称重复或已达 50 组上限');
        return;
      }
      if (this.groupSheetVisible && this.groupSheetMode === 'assign') {
        this.assignSelectedTo(group.id, group.name);
        return;
      }
      this.showToast(`已创建分组「${group.name}」`);
    });
  }

  /** 打开分组管理 sheet。 */
  private openManageSheet(): void {
    this.groupSheetMode = 'manage';
    this.sheetGroups = FqShelfGroupStore.all().slice();
    this.groupSheetVisible = true;
  }

  /** 打开多选归组 sheet。 */
  private openAssignSheet(): void {
    if (appState.batchSelectedIds.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    this.groupSheetMode = 'assign';
    this.sheetGroups = FqShelfGroupStore.all().slice();
    this.groupSheetVisible = true;
  }

  /** 多选所选移入指定分组（关闭 sheet + 退出多选）。 */
  private assignSelectedTo(groupId: string, groupName: string): void {
    const ids: string[] = appState.batchSelectedIds.slice();
    if (ids.length === 0) {
      this.groupSheetVisible = false;
      return;
    }
    const changed: number = FqShelfGroupStore.assign(ids, groupId);
    this.groupSheetVisible = false;
    this.exitBatchMode();
    this.showToast(changed > 0 ? `已将 ${changed} 本移入「${groupName}」` : '所选作品已在分组中');
    this.refreshData();
  }

  /** 多选所选移出分组。 */
  private removeSelectedFromGroup(): void {
    const ids: string[] = appState.batchSelectedIds.slice();
    if (ids.length === 0) {
      this.groupSheetVisible = false;
      return;
    }
    const changed: number = FqShelfGroupStore.assign(ids, '');
    this.groupSheetVisible = false;
    this.exitBatchMode();
    this.showToast(changed > 0 ? `已将 ${changed} 本移出分组` : '所选作品均未分组');
    this.refreshData();
  }

  /** 分组内仍在书架的书数（展示计数用）。 */
  private groupShelfCount(groupId: string): number {
    let count: number = 0;
    for (const entry of FqShelfStore.all()) {
      if (FqShelfGroupStore.groupOf(entry.id) === groupId) {
        count++;
      }
    }
    return count;
  }

  /** 分组菜单：重命名 / 删除（管理 sheet 行点击、分组标签长按共用）。 */
  private openGroupManageMenu(group: FqShelfGroup, anchorId: string): void {
    const items: Array<FqMenuItem> = [];
    const renameItem = new FqMenuItem();
    renameItem.label = '重命名';
    renameItem.onAction = (): void => {
      FqMenu.dismiss();
      this.promptRenameGroup(group.id, group.name);
    };
    items.push(renameItem);
    const deleteItem = new FqMenuItem();
    deleteItem.label = '删除分组';
    deleteItem.onAction = (): void => {
      FqMenu.dismiss();
      DialogManager.ShowConfirm('删除分组', `删除「${group.name}」后，组内作品将回到未分组。`, '删除',
        (): void => {
          FqShelfGroupStore.removeGroup(group.id);
          if (this.filterGroupId === group.id) {
            this.setFilterGroupId('');
          }
          this.showToast('已删除分组');
        });
    };
    items.push(deleteItem);
    FqMenu.open(this.getUIContext(), anchorId, items);
  }

  private promptRenameGroup(id: string, name: string): void {
    DialogManager.InputShelfGroupName('重命名分组', name, (next: string): void => {
      if (!FqShelfGroupStore.renameGroup(id, next)) {
        this.showToast('重命名失败：名称重复或超出长度限制');
        return;
      }
      this.showToast('已重命名');
    });
  }

  /** 分组 sheet（assign 归组 / manage 管理，共用单 bindSheet）。 */
  @Builder
  private GroupSheetBuilder() {
    CommonSheet({
      sheetTitle: this.groupSheetMode === 'assign' ? '移入分组' : '分组管理',
      showClose: true,
      closeClick: (): void => {
        this.groupSheetVisible = false;
      },
    }) {
      List() {
        ListItem() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(15)
              .fontColor([appState.accentColor])
            Text('新建分组')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(appState.accentColor)
          }
          .width('100%')
          .height(48)
          .padding({ left: 20, right: 20 })
          .onClick(() => {
            this.promptCreateGroup();
          })
        }

        if (this.groupSheetMode === 'assign') {
          ListItem() {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([$r('sys.color.icon_secondary')])
              Text('移出分组')
                .fontSize(15)
                .fontColor($r('sys.color.font_primary'))
            }
            .width('100%')
            .height(48)
            .padding({ left: 20, right: 20 })
            .onClick(() => {
              this.removeSelectedFromGroup();
            })
          }
        }

        ForEach(this.sheetGroups, (group: FqShelfGroup) => {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(group.name)
                  .fontSize(15)
                  .fontColor($r('sys.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.groupShelfCount(group.id)} 本`)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (this.groupSheetMode === 'manage') {
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(12)
                  .fontColor([$r('sys.color.icon_tertiary')])
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 52 })
            .padding({ top: 6, bottom: 6, left: 20, right: 20 })
            .id(SHELF_GROUP_ROW_ANCHOR_PREFIX + group.id)
            .onClick(() => {
              if (this.groupSheetMode === 'assign') {
                this.assignSelectedTo(group.id, group.name);
              } else {
                this.openGroupManageMenu(group, SHELF_GROUP_ROW_ANCHOR_PREFIX + group.id);
              }
            })
          }
        }, (group: FqShelfGroup): string => group.id)

        if (this.sheetGroups.length === 0) {
          ListItem() {
            Text(this.groupSheetMode === 'assign' ? '还没有分组，先新建一个吧' : '还没有分组')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 24, bottom: 24 })
          }
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 0.6,
        color: $r('sys.color.comp_divider'),
        startMargin: 20,
        endMargin: 20
      })
    }
  }

  /** titleBar 菜单按钮：添加（导入本地书籍）+ 搜索 + 更多。 */
  private titleMenus(): Array<HdsNavigationMenuItemOptions> {    const add: HdsNavigationMenuItemOptions = {
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
      if (item.cover.length > 0) {
        // EPUB 内嵌封面：重复导入时补齐旧条目（旧版本导入的本地书无封面）
        if (!added) {
          FqShelfStore.updateCover(item.id, item.cover);
          this.refreshData();
        }
      } else {
        // 导入后按书名网络匹配封面（命中回填书架条目，失败保持图标占位）
        this.matchLocalBookCover(item.id, item.title);
      }
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

  /** 更多菜单：视图方式 + 排序方式（书架 tab）+ 离线缓存 + 清空（按 tab 区分）。 */
  private openMoreMenu(): void {
    const items: Array<FqMenuItem> = [];

    // 视图方式（两 tab 共享）：级联二级菜单
    const viewItem = new FqMenuItem();
    viewItem.label = '视图方式';
    viewItem.subItems = this.buildViewSubItems();
    items.push(viewItem);

    // 排序方式（仅书架 tab）：级联二级菜单
    if (this.currentTab === 0) {
      const sortItem = new FqMenuItem();
      sortItem.label = '排序方式';
      sortItem.subItems = this.buildSortSubItems();
      items.push(sortItem);
    }

    // 分组操作（仅书架 tab）：新建分组 / 管理分组
    if (this.currentTab === 0) {
      const groupOpItem = new FqMenuItem();
      groupOpItem.label = '分组操作';
      groupOpItem.subItems = this.buildGroupOpSubItems();
      items.push(groupOpItem);
    }

    const offlineItem = new FqMenuItem();
    offlineItem.icon = $r('sys.symbol.download');
    offlineItem.label = '离线缓存';
    offlineItem.onAction = (): void => {
      FqMenu.dismiss();
      NavPathUtils.push(ROUTE_CACHE_MANAGE);
    };
    items.push(offlineItem);

    // 整架分享：当前书架全量作品生成书单链接（目标端打开直接导入书架）
    if (this.currentTab === 0) {
      const shareItem = new FqMenuItem();
      shareItem.icon = $r('sys.symbol.share');
      shareItem.label = '分享书架';
      shareItem.onAction = (): void => {
        FqMenu.dismiss();
        this.shareWholeShelf();
      };
      items.push(shareItem);
    }

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

  /** 分组操作二级菜单：新建分组 + 管理分组。 */
  private buildGroupOpSubItems(): Array<FqMenuItem> {
    const subItems: Array<FqMenuItem> = [];
    const createSub = new FqMenuItem();
    createSub.label = '新建分组';
    createSub.onAction = (): void => {
      FqMenu.dismiss();
      this.promptCreateGroup();
    };
    subItems.push(createSub);
    const manageSub = new FqMenuItem();
    manageSub.label = '管理分组';
    manageSub.onAction = (): void => {
      FqMenu.dismiss();
      this.openManageSheet();
    };
    subItems.push(manageSub);
    return subItems;
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

  /** 视图方式二级菜单（3 项，当前项打勾）。 */
  private buildViewSubItems(): Array<FqMenuItem> {
    const labels: string[] = ['网格视图', '双列卡片', '列表视图'];
    const subItems: Array<FqMenuItem> = [];
    for (let layout: number = 0; layout < labels.length; layout++) {
      const sub = new FqMenuItem();
      sub.label = labels[layout];
      sub.endIcon = this.layout === layout ? $r('sys.symbol.checkmark') : '';
      sub.onAction = (): void => {
        FqMenu.dismiss();
        this.setLayout(layout);
      };
      subItems.push(sub);
    }
    return subItems;
  }

  /** 排序方式二级菜单（8 项，当前项打勾）。 */
  private buildSortSubItems(): Array<FqMenuItem> {
    const labels: string[] = ['名称（正序）', '名称（倒序）', '进度（正序）', '进度（倒序）',
      '最近观看（正序）', '最近观看（倒序）', '加入时间（正序）', '加入时间（倒序）'];
    const subItems: Array<FqMenuItem> = [];
    for (let mode: number = 0; mode < labels.length; mode++) {
      const sub = new FqMenuItem();
      sub.label = labels[mode];
      sub.endIcon = this.sortMode === mode ? $r('sys.symbol.checkmark') : '';
      sub.onAction = (): void => {
        FqMenu.dismiss();
        this.setSortMode(mode);
      };
      subItems.push(sub);
    }
    return subItems;
  }

  /** 切换书架排序（持久化，浏览历史不排序保持原序）。 */
  private setSortMode(mode: number): void {
    if (this.sortMode === mode) {
      return;
    }
    this.sortMode = mode;
    this.rebuildRows();
    const pref: preferences.Preferences | null = this.layoutPref;
    if (pref !== null) {
      try {
        pref.putSync(SHELF_PREF_SORT, mode);
        pref.flush().catch((_error: BusinessError): void => {
          // 落盘失败不阻断
        });
      } catch (error) {
        // 忽略写入失败
      }
    }
  }

  /** 书架排序比较器：按 sortMode 分发，同值按加入顺序稳定排列。 */
  private compareShelfEntries(a: ShelfSortEntry, b: ShelfSortEntry): number {
    switch (this.sortMode) {
      case 0:
        return this.stableByAdded(a, b, this.compareChineseTitle(a.row.title, b.row.title));
      case 1:
        return this.stableByAdded(a, b, this.compareChineseTitle(b.row.title, a.row.title));
      case 2:
        return this.stableByAdded(a, b, this.sortPercent(a) - this.sortPercent(b));
      case 3:
        return this.stableByAdded(a, b, this.sortPercent(b) - this.sortPercent(a));
      case 4:
        return this.compareByVisited(a, b, a.visitedAt - b.visitedAt);
      case 5:
        return this.compareByVisited(a, b, b.visitedAt - a.visitedAt);
      case 7:
        return b.addedIndex - a.addedIndex;
      default:
        return a.addedIndex - b.addedIndex;
    }
  }

  /** 名称排序按中文拼音序比较（zh 区域规则，非中文字符跟随系统规则）。 */
  private compareChineseTitle(a: string, b: string): number {
    return a.localeCompare(b, 'zh-Hans-CN');
  }

  /** 排序用进度（无进度视作 0）。 */
  private sortPercent(entry: ShelfSortEntry): number {
    return entry.row.percent < 0 ? 0 : entry.row.percent;
  }

  /** 同值按加入顺序稳定排列。 */
  private stableByAdded(a: ShelfSortEntry, b: ShelfSortEntry, cmp: number): number {
    return cmp !== 0 ? cmp : a.addedIndex - b.addedIndex;
  }

  /** 最近观看排序：从未浏览过的条目两种方向都排在末尾，其余按时间。 */
  private compareByVisited(a: ShelfSortEntry, b: ShelfSortEntry, cmp: number): number {
    if (a.visitedAt <= 0 && b.visitedAt <= 0) {
      return a.addedIndex - b.addedIndex;
    }
    if (a.visitedAt <= 0) {
      return 1;
    }
    if (b.visitedAt <= 0) {
      return -1;
    }
    return cmp !== 0 ? cmp : a.addedIndex - b.addedIndex;
  }

  /** 清空确认（按当前 tab：书架 / 浏览历史；共用确认弹窗）。 */
  private confirmClearCurrentTab(): void {
    const isShelf: boolean = this.currentTab === 0;
    let shelfHasLocal: boolean = false;
    if (isShelf) {
      for (const entry of FqShelfStore.all()) {
        if (FqLocalBookStore.isLocalBookId(entry.id)) {
          shelfHasLocal = true;
          break;
        }
      }
    }
    DialogManager.ShowConfirm(
      isShelf ? '清空书架' : '清空浏览历史',
      isShelf
        ? (shelfHasLocal ? '确定要清空书架全部作品吗？本地导入书的文件将一并删除，此操作不可恢复。'
          : '确定要清空书架全部作品吗？此操作不可恢复。')
        : '确定要清空全部浏览历史吗？此操作不可恢复。',
      '清空',
      (): void => {
        if (isShelf) {
          const ids: string[] = [];
          for (const entry of FqShelfStore.all()) {
            ids.push(entry.id);
          }
          FqLocalBookStore.deleteBooks(ids);
          FqShelfStore.removeByIds(ids);
          FqShelfGroupStore.removeAssignments(ids);
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
    appState.batchSelectedIds = [firstId];
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      appState.isBatchMode = true;
    });
  }

  /** 退出多选（animateTo 包裹：勾选圈/角标淡出，不重载数据源）。 */
  private exitBatchMode(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      appState.isBatchMode = false;
    });
    appState.batchSelectedIds = [];
  }

  private isSelectedId(id: string): boolean {
    return appState.batchSelectedIds.indexOf(id) !== -1;
  }

  /** 勾选切换（batchSelected 整体替换驱动 V2 参数绑定原地刷新，不重载）。 */
  private toggleSelected(id: string): void {
    const next: string[] = appState.batchSelectedIds.slice();
    const idx: number = next.indexOf(id);
    if (idx === -1) {
      next.push(id);
    } else {
      next.splice(idx, 1);
    }
    appState.batchSelectedIds = next;
  }

  private allSelected(): boolean {
    return this.visibleCount > 0 && appState.batchSelectedIds.length === this.visibleCount;
  }

  private toggleSelectAll(): void {
    if (this.allSelected()) {
      appState.batchSelectedIds = [];
    } else {
      const ids: string[] = [];
      const count: number = this.dataSource.totalCount();
      for (let i = 0; i < count; i++) {
        ids.push(this.dataSource.getData(i).id);
      }
      appState.batchSelectedIds = ids;
    }
  }

  /** 多选分享：所选作品生成书单链接拉起系统分享面板（目标端打开直接导入书架）。 */
  private shareBatchSelected(): void {
    if (appState.batchSelectedIds.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    const items: FqShelfItem[] = [];
    const count: number = this.dataSource.totalCount();
    for (let i = 0; i < count; i++) {
      const row: ShelfRow = this.dataSource.getData(i);
      if (this.isSelectedId(row.id)) {
        items.push(new FqShelfItem(row.id, row.kind, row.title, row.cover));
      }
    }
    if (!FqShareKit.shareShelf(items, '书单分享')) {
      this.showToast('所选作品均不支持分享');
    }
  }

  /** 整架分享：书架全量作品生成书单链接（本地导入/书旗自动过滤）。 */
  private shareWholeShelf(): void {
    const items: FqShelfItem[] = [];
    for (const entry of FqShelfStore.all()) {
      items.push(new FqShelfItem(entry.id, entry.kind, entry.title, entry.cover));
    }
    if (!FqShareKit.shareShelf(items, '我的书架')) {
      this.showToast('书架暂无可分享作品');
    }
  }

  /** 多选清除（先弹共用确认弹窗）：书架 tab 移出书架，历史 tab 删除记录。 */
  private batchClearSelected(): void {    if (appState.batchSelectedIds.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    const ids: string[] = appState.batchSelectedIds.slice();
    const count: number = ids.length;
    const isShelf: boolean = this.currentTab === 0;
    const hasLocal: boolean = ids.some((id: string): boolean => FqLocalBookStore.isLocalBookId(id));
    DialogManager.ShowConfirm(
      isShelf ? '移出书架' : '删除记录',
      isShelf
        ? (hasLocal ? `确定将选中的 ${count} 本作品移出书架吗？本地导入书的文件将一并删除。`
          : `确定将选中的 ${count} 本作品移出书架吗？`)
        : `确定删除选中的 ${count} 条浏览记录吗？`,
      isShelf ? '移出' : '删除',
      (): void => {
        if (isShelf) {
          FqLocalBookStore.deleteBooks(ids);
          FqShelfStore.removeByIds(ids);
          FqShelfGroupStore.removeAssignments(ids);
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
    // 书旗来源（shuqi: 前缀 id）：进书旗只读详情
    if (row.id.startsWith('shuqi:')) {
      DetailNavParams.id = row.id.substring('shuqi:'.length);
      DetailNavParams.kind = 'book';
      DetailNavParams.title = row.title;
      DetailNavParams.cover = row.cover;
      DetailNavParams.shuqi = true;
      NavPathUtils.push(ROUTE_DETAIL);
      return;
    }
    fqPushBookOrDetail(row.id, row.kind, row.title, row.cover);
  }

  /** 标题栏下方扩展区：「书架/浏览历史」胶囊滑块 + 筛选 pill + 可展开搜索框。 */
  @Builder
  private TitleExtraBuilder() {
    Column() {
      // 左滑块（书架/浏览历史胶囊）+ 右筛选 pill：分居两侧
      Row({ space: 10 }) {
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
              .fontColor(this.currentTab === 0 ? appState.accentColor : $r('sys.color.font_tertiary'))
              .height(26)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.switchTab(0);
              })
            Text('浏览历史')
              .fontSize(12)
              .fontWeight(this.currentTab === 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.currentTab === 1 ? appState.accentColor : $r('sys.color.font_tertiary'))
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

        // 筛选 pill（仅书架 tab）：状态/来源/分组组合筛选入口。
        // 文案按实测区域宽度封顶走省略号截断，防止长分组名把箭头图标挤出容器。
        if (this.currentTab === 0) {
          Row() {
            Row({ space: 3 }) {
              Text(this.filterPillLabel())
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasActiveFilter() ? appState.accentColor : $r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: this.filterLabelMaxWidth() })
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(10)
                .fontColor([this.hasActiveFilter() ? appState.accentColor : $r('sys.color.icon_tertiary')])
            }
            .constraintSize({ maxWidth: '100%' })
            .height(30)
            .padding({ left: 10, right: 9 })
            .borderRadius(15)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .margin({ top: 4, bottom: 10 })
            .attributeModifier(rowImmersiveModifier)
            .id(SHELF_FILTER_ANCHOR_ID)
            .onClick(() => {
              this.openFilterMenu();
            })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End)
          .onAreaChange((_old: Area, newArea: Area): void => {
            if (typeof newArea.width === 'number') {
              this.filterAreaWidth = newArea.width;
            }
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      // 分组标签行（书架 tab 且有分组）：横向滑动，「全部」+ 各分组；
      // 点击切换分组筛选，长按分组标签呼出重命名/删除菜单。
      // 标签 UI 直接内联（@Builder 值传参不随 filterGroupId 变化重渲染，会选中不变色）
      if (this.groupTagsVisible()) {
        List({ space: 22 }) {
          ListItem() {
            Column() {
              Text('全部')
                .fontSize(15)
                .fontWeight(this.filterGroupId.length === 0 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.filterGroupId.length === 0 ? appState.accentColor : $r('sys.color.font_secondary'))
              Row()
                .width(14)
                .height(3)
                .borderRadius(1.5)
                .backgroundColor(appState.accentColor)
                .margin({ top: 3 })
                .visibility(this.filterGroupId.length === 0 ? Visibility.Visible : Visibility.Hidden)
            }
            .justifyContent(FlexAlign.Center)
            .height(36)
            .id(SHELF_GROUP_TAG_ANCHOR_PREFIX + 'all')
            .onClick(() => {
              this.setFilterGroupId('');
            })
          }
          ForEach(this.sheetGroups, (group: FqShelfGroup) => {
            ListItem() {
              Column() {
                Text(group.name)
                  .fontSize(15)
                  .fontWeight(this.filterGroupId === group.id ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.filterGroupId === group.id ? appState.accentColor : $r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 140 })
                // 选中项底部主题色小横条（未选中占位隐藏，避免行高跳动）
                Row()
                  .width(14)
                  .height(3)
                  .borderRadius(1.5)
                  .backgroundColor(appState.accentColor)
                  .margin({ top: 3 })
                  .visibility(this.filterGroupId === group.id ? Visibility.Visible : Visibility.Hidden)
              }
              .justifyContent(FlexAlign.Center)
              .height(36)
              .id(SHELF_GROUP_TAG_ANCHOR_PREFIX + group.id)
              .onClick(() => {
                this.setFilterGroupId(this.filterGroupId === group.id ? '' : group.id);
              })
              .gesture(LongPressGesture()
                .onAction((): void => {
                  this.openGroupManageMenu(group, SHELF_GROUP_TAG_ANCHOR_PREFIX + group.id);
                }))
            }
          }, (group: FqShelfGroup): string => group.id)
        }
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(36)
        .scrollBar(BarState.Off)
        .alignListItem(ListItemAlign.Center)
        .padding({ left: 16, right: 16 })
        .onAppear(()=>{
          this.scroller.scrollTo({
            yOffset: -this.listTopInset(),
            xOffset: 0
          })
        })
      }

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
          .fontColor([this.isSelectedId(row.id) ? appState.accentColor : $r('sys.color.icon_tertiary')])
          .transition(TransitionEffect.OPACITY)
      }
      if (row.cover.length > 0) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(FqBackend.get().resourceUrl(row.cover))
            .width(60)
            .height(82)
            .borderRadius(8)
            .objectFit(ImageFit.Cover)
            .autoResize(true)
            .draggable(false)
          if (!appState.isBatchMode && row.percent >= 0) {
            Text(`${row.percent}%`)
              .fontSize(8)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .maxLines(1)
              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
              .borderRadius(3)
              .backgroundColor(appState.accentColor)
              .margin(3)
          }
        }
        .width(60)
        .height(82)
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
          .fontColor([appState.accentColor])
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
      if (this.hasActiveFilter()) {
        return '当前筛选无匹配作品';
      }
      return '书架还是空的';
    }
    return '暂无浏览记录';
  }

  private emptySub(): string {
    if (this.searchKeyword.length > 0) {
      return '换个关键词试试';
    }
    if (this.currentTab === 0) {
      if (this.hasActiveFilter()) {
        return '调整筛选条件或恢复「全部」后再试';
      }
      return '去首页发现好故事，加入书架吧';
    }
    return '看过的作品会出现在这里';
  }
}

/**
 * 离线缓存选集公共半模态（CommonSheet 承载，播放页剧集/听书页章节共用）：
 * - 标题栏：主标题 + 右侧「管理」「关闭」按钮（CommonSheet showManage/showClose 菜单）；
 * - 内容：>30 项分页条横向滚动直达；条目网格复选（已缓存置灰打勾、任务态实时
 *   进度/排队/暂停/失败、选中橙底描边打勾、打开默认全选未缓存项）；
 *   底部全选 + 下载行。
 * - 状态：勾选/分页/定位由组件自持；已缓存集合与任务态经 @Param 注入
 *   （taskViewOf 返回宿主 @ObservedV2 任务对象，@Trace 字段驱动实时进度）；
 *   下载/管理/关闭/任务格点击（失败重试、暂停继续由宿主定夺）经 @Event 回调宿主。
 * - openToken：宿主每次打开 +1，组件据此重置勾选并定位当前项居中。
 */

import { appState } from '../../entryability/AppState';
import { CommonSheet } from './CommonSheet';
import {
  FqCacheTaskView,
  FqChapter,
  FQ_CACHE_TASK_DOWNLOADING,
  FQ_CACHE_TASK_FAILED,
  FQ_CACHE_TASK_PAUSED,
  FQ_CACHE_TASK_WAITING,
} from '../../model/FqModels';

/** 缓存分页条粒度（与选集面板 FqStoryPanel 一致 30/段）。 */
const FQ_CACHE_PAGE_SIZE: number = 30;

/** 主题橙（选中/任务态/下载按钮）。 */
const FQ_CACHE_ORANGE: string = '#FFFA6725';

@ComponentV2
export struct FqCacheSheet {
  /** 标题栏主标题（「离线缓存 · xx」）。 */
  @Param sheetTitle: string = '';
  /** 集数/章节列表。 */
  @Param items: FqChapter[] = [];
  /** 当前项下标（打开后定位居中）。 */
  @Param currentIndex: number = 0;
  /** 已缓存 itemId 集合（打开时由宿主刷新）。 */
  @Param downloadedIds: Set<string> = new Set<string>();
  /** 任务态访问器（返回宿主下载器任务；空集章节时可为缺省）。 */
  @Param taskViewOf: (itemId: string) => FqCacheTaskView | null =
    (_itemId: string): FqCacheTaskView | null => null;
  /** 打开令牌（每次打开 +1：重置勾选 + 定位当前项）。 */
  @Param openToken: number = 0;
  /** 条目量词（集/章，默认文案「第 N 集」）。 */
  @Param itemLabel: string = '集';
  @Event manageClick: () => void = (): void => {};
  @Event closeClick: () => void = (): void => {};
  /** 下载勾选项（组件发出后清空勾选）。 */
  @Event download: (itemIds: string[]) => void = (_itemIds: string[]): void => {};
  /** 任务格点击（宿主按任务态决定失败重试/暂停继续）。 */
  @Event taskClick: (itemId: string) => void = (_itemId: string): void => {};

  /** 已勾选 itemId（打开时默认全选未缓存项）。 */
  @Local selectedIds: Set<string> = new Set<string>();
  /** 分页条当前段。 */
  @Local page: number = 0;
  /** 网格滚动器（分页条直达 + 定位当前项）。 */
  private scroller: Scroller = new Scroller();
  /** 定位当前项定时器（0 无任务）。 */
  private locateTimer: number = 0;

  aboutToAppear(): void {
    this.resetAndLocate();
  }

  aboutToDisappear(): void {
    this.cancelLocate();
  }

  /** 宿主每次打开（openToken +1）重置勾选并定位当前项。 */
  @Monitor('openToken')
  onOpenTokenChange(): void {
    this.resetAndLocate();
  }

  /** 重置勾选（默认全选未缓存项）+ 分段选中 + 延迟滚动当前项居中。 */
  private resetAndLocate(): void {
    const selected: Set<string> = new Set<string>();
    for (const item of this.items) {
      if (!this.downloadedIds.has(item.itemId)) {
        selected.add(item.itemId);
      }
    }
    this.selectedIds = selected;
    this.page = Math.floor(this.currentIndex / FQ_CACHE_PAGE_SIZE);
    this.cancelLocate();
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = 0;
      // 网格只含当前分页段：定位到段内相对下标
      this.scroller.scrollToIndex(this.currentIndex % FQ_CACHE_PAGE_SIZE, false, ScrollAlign.CENTER);
    }, 150);
  }

  private cancelLocate(): void {
    if (this.locateTimer !== 0) {
      clearTimeout(this.locateTimer);
      this.locateTimer = 0;
    }
  }

  build() {
    CommonSheet({
      sheetTitle: this.sheetTitle,
      showManage: true,
      showClose: true,
      manageClick: (): void => {
        this.manageClick();
      },
      closeClick: (): void => {
        this.closeClick();
      },
    }) {
      Column() {
        if (this.items.length > FQ_CACHE_PAGE_SIZE) {
          this.PagingStrip()
        }

        Grid(this.scroller) {
          ForEach(this.pageItems(), (item: FqChapter, index: number) => {
            GridItem() {
              this.Cell(item, this.page * FQ_CACHE_PAGE_SIZE + index)
            }
          }, (item: FqChapter) => item.itemId)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })

        Row() {
          Text(this.allSelected() ? '取消全选' : '全选')
            .fontSize(14)
            .fontColor(this.pendingCount() === 0 ? $r('sys.color.font_tertiary') : FQ_CACHE_ORANGE)
            .padding({ left: 4, right: 4, top: 10, bottom: 10 })
            .onClick((): void => {
              this.toggleSelectAll();
            })

          Blank()

          Button(`下载 (${this.selectedIds.size})`)
            .type(ButtonType.Capsule)
            .height(36)
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor(this.selectedIds.size > 0 ? FQ_CACHE_ORANGE : '#33000000')
            .enabled(this.selectedIds.size > 0)
            .onClick((): void => {
              this.confirmDownload();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: appState.bottomRect, top: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
    }
  }

  /** >30 项分页条（横向滚动「1-30/31-60/…」，点击直达，滚动联动）。 */
  @Builder
  private PagingStrip() {
    Scroll() {
      Row({ space: 20 }) {
        ForEach(this.pageLabels(), (label: string, pageIndex: number) => {
          Text(label)
            .fontSize(14)
            .fontWeight(pageIndex === this.page ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(pageIndex === this.page ?
              $r('sys.color.font_secondary') : $r('sys.color.font_tertiary'))
            .onClick((): void => {
              this.page = pageIndex;
              this.scroller.scrollToIndex(0, false, ScrollAlign.START);
            })
        }, (label: string) => label)
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(32)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  /** 缓存格：已缓存置灰打勾 / 任务态橙色（进度%/排队/暂停/失败）/ 可选项（选中橙底描边打勾）。 */
  @Builder
  private Cell(item: FqChapter, index: number) {
    Row({ space: 3 }) {
      Text(this.cellLabel(item, index))
        .fontSize(13)
        .fontColor(this.cellTextColor(item))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.cellShowCheck(item)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor([this.cellTextColor(item)])
      }
    }
    .height(32)
    .width('100%')
    .padding({ left: 6, right: 6 })
    .borderRadius(8)
    .backgroundColor(this.cellBg(item))
    .border({ width: this.cellSelected(item) ? 1 : 0, color: FQ_CACHE_ORANGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onCellClick(item);
    })
  }

  /** 分页条尾段下标。 */
  private lastPage(): number {
    return Math.max(0, Math.ceil(this.items.length / FQ_CACHE_PAGE_SIZE) - 1);
  }

  /** 当前分页段条目（>30 项时只构建本段 30 项：
   *  听书动辄上千章，一次性 ForEach 全量建格会冻结 UI（sheet 呼不出、整页点不动）。 */
  private pageItems(): FqChapter[] {
    if (this.items.length <= FQ_CACHE_PAGE_SIZE) {
      return this.items;
    }
    const start: number = this.page * FQ_CACHE_PAGE_SIZE;
    const end: number = Math.min(start + FQ_CACHE_PAGE_SIZE, this.items.length);
    return this.items.slice(start, end);
  }

  /** 分页条标签（「1-30」「31-60」…）。 */
  private pageLabels(): string[] {
    const labels: string[] = [];
    const pages: number = this.lastPage() + 1;
    for (let pageIndex: number = 0; pageIndex < pages; pageIndex++) {
      const start: number = pageIndex * FQ_CACHE_PAGE_SIZE + 1;
      const end: number = Math.min((pageIndex + 1) * FQ_CACHE_PAGE_SIZE, this.items.length);
      labels.push(`${start}-${end}`);
    }
    return labels;
  }

  /** 未缓存项数（全选按钮置灰判定）。 */
  private pendingCount(): number {
    let count: number = 0;
    for (const item of this.items) {
      if (!this.downloadedIds.has(item.itemId)) {
        count++;
      }
    }
    return count;
  }

  /** 全选判定（存在未缓存项且全部已勾选）。 */
  private allSelected(): boolean {
    if (this.pendingCount() === 0) {
      return false;
    }
    for (const item of this.items) {
      if (!this.downloadedIds.has(item.itemId) && !this.selectedIds.has(item.itemId)) {
        return false;
      }
    }
    return true;
  }

  /** 全选/取消全选未缓存项。 */
  private toggleSelectAll(): void {
    if (this.pendingCount() === 0) {
      return;
    }
    if (this.allSelected()) {
      this.selectedIds = new Set<string>();
      return;
    }
    const selected: Set<string> = new Set<string>();
    for (const item of this.items) {
      if (!this.downloadedIds.has(item.itemId)) {
        selected.add(item.itemId);
      }
    }
    this.selectedIds = selected;
  }

  /** 缓存格点击：已缓存不响应；任务格转发宿主（失败重试/暂停继续）；可选项勾选切换。 */
  private onCellClick(item: FqChapter): void {
    if (this.downloadedIds.has(item.itemId)) {
      return;
    }
    if (this.taskViewOf(item.itemId) !== null) {
      this.taskClick(item.itemId);
      return;
    }
    const next: Set<string> = new Set<string>(this.selectedIds);
    if (next.has(item.itemId)) {
      next.delete(item.itemId);
    } else {
      next.add(item.itemId);
    }
    this.selectedIds = next;
  }

  /** 下载勾选项（回调宿主后清空勾选）。 */
  private confirmDownload(): void {
    if (this.selectedIds.size === 0) {
      return;
    }
    const itemIds: string[] = [];
    for (const item of this.items) {
      if (this.selectedIds.has(item.itemId)) {
        itemIds.push(item.itemId);
      }
    }
    this.download(itemIds);
    this.selectedIds = new Set<string>();
  }

  /** 缓存格是否选中（未缓存、无任务且已勾选，橙色描边判定）。 */
  private cellSelected(item: FqChapter): boolean {
    return !this.downloadedIds.has(item.itemId)
      && this.taskViewOf(item.itemId) === null
      && this.selectedIds.has(item.itemId);
  }

  /** 缓存格文案：已缓存 / 任务态（下载百分比）/ 第 N 集（itemLabel 量词）。 */
  private cellLabel(item: FqChapter, index: number): string {
    if (this.downloadedIds.has(item.itemId)) {
      return '已缓存';
    }
    const task: FqCacheTaskView | null = this.taskViewOf(item.itemId);
    if (task !== null) {
      if (task.status === FQ_CACHE_TASK_DOWNLOADING) {
        if (task.totalBytes > 0) {
          return `${Math.floor(task.receivedBytes / task.totalBytes * 100)}%`;
        }
        return '下载中';
      }
      if (task.status === FQ_CACHE_TASK_WAITING) {
        return '排队中';
      }
      if (task.status === FQ_CACHE_TASK_PAUSED) {
        return '已暂停';
      }
      if (task.status === FQ_CACHE_TASK_FAILED) {
        return '失败';
      }
      return '已缓存';
    }
    return `第 ${index + 1} ${this.itemLabel}`;
  }

  /** 缓存格文字色：已缓存系统三级、失败红、任务/选中橙、普通系统主色。 */
  private cellTextColor(item: FqChapter): ResourceColor {
    if (this.downloadedIds.has(item.itemId)) {
      return $r('sys.color.font_tertiary');
    }
    const task: FqCacheTaskView | null = this.taskViewOf(item.itemId);
    if (task !== null) {
      if (task.status === FQ_CACHE_TASK_FAILED) {
        return '#FFD33918';
      }
      return FQ_CACHE_ORANGE;
    }
    if (this.selectedIds.has(item.itemId)) {
      return FQ_CACHE_ORANGE;
    }
    return $r('sys.color.font_primary');
  }

  /** 缓存格底色：任务/选中橙 8% 底，其余浅色黑 6% 底。 */
  private cellBg(item: FqChapter): ResourceColor {
    if (!this.downloadedIds.has(item.itemId)
      && (this.taskViewOf(item.itemId) !== null || this.selectedIds.has(item.itemId))) {
      return '#14FA6725';
    }
    return '#0F000000';
  }

  /** 缓存格尾随勾：已缓存或选中。 */
  private cellShowCheck(item: FqChapter): boolean {
    return this.downloadedIds.has(item.itemId) || this.cellSelected(item);
  }
}

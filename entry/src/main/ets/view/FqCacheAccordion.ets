/**
 * 缓存管理手风琴列表公共组件（剧集/听书/漫画缓存页共用）：
 * - 数据模型展示就绪（分组/明细文案由页面预拼装，组件不感知各页 store 类型）；
 * - 结构：统计卡（@BuilderParam 注入）+ 分组头行（图标块+标题+meta+删除+展开箭头）
 *   + 明细行（label+标题+meta+可选尾随按钮+删除）+ 任务行（页面 @BuilderParam 注入）；
 * - LazyForEach 懒加载；进入默认全部收起，点击头行 animateTo 展开/收起；
 * - 删除走页面回调（确认弹窗与 store 操作留在各页）。
 */

import { FqColorUtils } from '../utils/FqColorUtils';
import { appState } from '../entryability/AppState';

/** 行种类：分组头行 / 明细行 / 任务行组。 */
const FQ_ACCORDION_HEADER: number = 0;
const FQ_ACCORDION_DETAIL: number = 1;
const FQ_ACCORDION_TASKS: number = 2;

/** 明细行（展示就绪；id 供删除回调定位 store 记录）。 */
export class FqCacheDetailItem {
  public readonly id: string;
  /** 前置标签（“第 N 章/话/集”）。 */
  public readonly label: string;
  public readonly title: string;
  /** 尾部说明（大小/图数等）。 */
  public readonly metaText: string;

  constructor(id: string, label: string, title: string, metaText: string) {
    this.id = id;
    this.label = label;
    this.title = title;
    this.metaText = metaText;
  }
}

/** 分组（一本书/一部剧；展示就绪）。 */
export class FqCacheGroupItem {
  public readonly id: string;
  public readonly title: string;
  /** 头行说明（“N 章 · 大小”或“缓存中”）。 */
  public readonly metaText: string;
  public readonly tint: string;
  /** 展开时是否渲染任务行（未入库任务临时组 true）。 */
  public readonly hasTasks: boolean;
  public readonly details: FqCacheDetailItem[];

  constructor(id: string, title: string, metaText: string, tint: string,
    hasTasks: boolean, details: FqCacheDetailItem[]) {
    this.id = id;
    this.title = title;
    this.metaText = metaText;
    this.tint = tint;
    this.hasTasks = hasTasks;
    this.details = details;
  }
}

/** 手风琴扁平行（LazyForEach 数据源条目）。 */
class FqAccordionRow {
  public readonly kind: number;
  public readonly group: FqCacheGroupItem;
  /** 明细行条目（非明细行用共享空实例占位，保证非空收窄）。 */
  public readonly detail: FqCacheDetailItem;

  constructor(kind: number, group: FqCacheGroupItem, detail: FqCacheDetailItem) {
    this.kind = kind;
    this.group = group;
    this.detail = detail;
  }
}

/** 非明细行占位明细（共享实例，不参与渲染）。 */
const fqAccordionEmptyDetail: FqCacheDetailItem = new FqCacheDetailItem('', '', '', '');

/** 懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class FqAccordionSource implements IDataSource {
  private rows: FqAccordionRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): FqAccordionRow {
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

  reload(rows: FqAccordionRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@Builder
function fqAccordionEmptyBuilder() {
}

@ComponentV2
export struct FqCacheAccordionList {
  /** 分组数据（页面 refresh 重建；引用变化触发重排）。 */
  @Param groups: FqCacheGroupItem[] = [];
  /** 分组头行图标（各页差异化：film/waveform_headphones/picture 等）。 */
  @Param icon: Resource = $r('sys.symbol.book');
  /** 顶部固定偏移（标题栏下方，叠加系统避让区）。 */
  @Param topInset: number = 56;
  /** 底部留白（叠加系统避让区）。 */
  @Param bottomInset: number = 16;
  /** 滚动控制器（页面 CommonNav 共用）。 */
  @Param scroller: Scroller = new Scroller();
  /** 统计卡（列表首项，页面注入含操作按钮的 FqCacheStatsCard）。 */
  @BuilderParam statsBuilder: () => void = fqAccordionEmptyBuilder;
  /** 任务行组（页面 @Builder，绑各页 @Trace 任务列表实时渲染）。 */
  @BuilderParam taskRowsOf: (groupId: string) => void = fqAccordionEmptyBuilder;
  /** 明细行尾随按钮（剧集页“导出”；缺省不渲染）。 */
  @BuilderParam detailTrailingOf: (detail: FqCacheDetailItem) => void = fqAccordionEmptyBuilder;
  /** 删整组确认（页面弹确认并调 store）。 */
  @Event groupDeleteClick: (group: FqCacheGroupItem) => void = (group: FqCacheGroupItem) => {
  };
  /** 删单条确认（detail.id 由页面映射 store 记录键）。 */
  @Event detailDeleteClick: (detail: FqCacheDetailItem) => void = (detail: FqCacheDetailItem) => {
  };

  private source: FqAccordionSource = new FqAccordionSource();
  /** 展开的分组 id（进入默认收起）。 */
  private expandedIds: string[] = [];

  aboutToAppear(): void {
    this.rebuild();
  }

  @Monitor('groups')
  onGroupsChange(): void {
    this.rebuild();
  }

  /** 展开态分组 → 扁平行序列（头行 + 明细 + 任务行）。 */
  private rebuild(): void {
    const rows: FqAccordionRow[] = [];
    for (const group of this.groups) {
      rows.push(new FqAccordionRow(FQ_ACCORDION_HEADER, group, fqAccordionEmptyDetail));
      if (this.isExpanded(group.id)) {
        for (const detail of group.details) {
          rows.push(new FqAccordionRow(FQ_ACCORDION_DETAIL, group, detail));
        }
        if (group.hasTasks) {
          rows.push(new FqAccordionRow(FQ_ACCORDION_TASKS, group, fqAccordionEmptyDetail));
        }
      }
    }
    this.source.reload(rows);
  }

  private isExpanded(id: string): boolean {
    return this.expandedIds.indexOf(id) >= 0;
  }

  private toggleExpanded(id: string): void {
    const index: number = this.expandedIds.indexOf(id);
    if (index >= 0) {
      this.expandedIds.splice(index, 1);
    } else {
      this.expandedIds.push(id);
    }
    this.rebuild();
  }

  build() {
    List({ space: 10, scroller: this.scroller }) {
      ListItem() {
        this.statsBuilder()
      }

      LazyForEach(this.source, (row: FqAccordionRow) => {
        ListItem() {
          if (row.kind === FQ_ACCORDION_HEADER) {
            this.HeaderRow(row.group)
          } else if (row.kind === FQ_ACCORDION_DETAIL) {
            this.DetailRow(row.detail)
          } else {
            this.taskRowsOf(row.group.id)
          }
        }
      }, (row: FqAccordionRow) => `${row.kind}-${row.group.id}-${row.detail.id}`)
    }
    .padding({ left: 16, right: 16 })
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .contentStartOffset(appState.topRect + this.topInset)
    .contentEndOffset(appState.bottomRect + this.bottomInset)
  }

  /** 分组头行：图标块 + 标题 + 说明 + 删除整组 + 展开箭头。 */
  @Builder
  private HeaderRow(group: FqCacheGroupItem) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.icon)
          .fontSize(19)
          .fontColor([group.tint])
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(group.tint, 0.12))

      Column({ space: 3 }) {
        Text(group.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(group.metaText)
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_tertiary')])
        .padding({ left: 4, top: 8, bottom: 8 })
        .onClick((): void => {
          this.groupDeleteClick(group);
        })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
        .rotate({ angle: this.isExpanded(group.id) ? 90 : 0 })
    }
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
    .onClick((): void => {
      this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
        this.toggleExpanded(group.id);
      });
    })
  }

  /** 明细行：label · 标题 + 说明 + 尾随按钮（可选）+ 单条删除。 */
  @Builder
  private DetailRow(detail: FqCacheDetailItem) {
    Row({ space: 10 }) {
      Text(detail.label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      if (detail.title.length > 0) {
        Text(detail.title)
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      Text(detail.metaText)
        .fontSize(11.5)
        .fontColor($r('sys.color.font_tertiary'))
      this.detailTrailingOf(detail)
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
        .padding({ left: 4, top: 8, bottom: 8 })
        .onClick((): void => {
          this.detailDeleteClick(detail);
        })
    }
    .padding({ left: 16, right: 14, top: 9, bottom: 9 })
    .borderRadius(12)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .width('100%')
  }
}

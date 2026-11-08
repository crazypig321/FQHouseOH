/**
 * 目录公共半模态（阅读页 / 听书页 / 详情页共用）：
 * - 章节搜索过滤 / 正倒序 / 定位当前章在组件内自理；
 * - 分组目录（本地导入 EPUB 卷级 group 非空）：参考更新日志的手风琴交互，
 *   一次只展开一个分组（组头点击展开/收起，箭头旋转指示），组内章节懒加载；
 *   搜索时全部展开以便命中；无分组（在线书 / TXT 等）仍为纯 List + ListItem；
 * - 宿主注入：全量章节、字体色（阅读页墨色 / 详情页系统色）、当前章下标
 *   （-1 无阅读位置：隐藏定位按钮/当前章高亮/打开时定位，默认展开首个分组）、
 *   章节进度取值回调（返回空串隐藏进度列）、章节点击回调（宿主负责关 sheet 与跳转）；
 * - openToken 为打开令牌：宿主每次打开目录 +1，组件据此重置搜索/排序并定位当前章
 *   （兼容 bindSheet 内容重建/复用两种挂载方式，首建由 aboutToAppear 兜底）。
 */

import { FqChapter } from '../../model/FqModels';
import { CommonSearch } from '../CommonCom';
import { CommonSheet } from './CommonSheet';
import { appState } from '../../entryability/AppState';

/** 目录懒加载数据源（顶层分组/章节点与组内章节点共用）。 */
class FqCatalogNodeSource implements IDataSource {
  private items: FqCatalogNode[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqCatalogNode[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}

/** 目录渲染节点：分组头（chapter 为 null，children 为组内章节）或章节点。 */
class FqCatalogNode {
  readonly key: string;
  /** 分组标题：非空即分组头节点。 */
  readonly groupTitle: string;
  readonly chapter: FqChapter | null;
  /** 全量章节下标（分组头为 -1）。 */
  readonly index: number;
  /** 组内章节点（仅分组头非空）。 */
  readonly children: FqCatalogNode[];
  /** 组内懒加载源（仅分组头使用）。 */
  readonly childSource: FqCatalogNodeSource;

  constructor(key: string, groupTitle: string, chapter: FqChapter | null,
    index: number, children: FqCatalogNode[]) {
    this.key = key;
    this.groupTitle = groupTitle;
    this.chapter = chapter;
    this.index = index;
    this.children = children;
    this.childSource = new FqCatalogNodeSource();
    this.childSource.setItems(children);
  }
}

@ComponentV2
export struct FqCatalogSheet {
  /** 全量章节（组件内做搜索过滤与排序）。 */
  @Param chapters: FqChapter[] = [];
  /** 字体色随宿主主题（阅读页墨色 / 详情页系统色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 当前章下标：-1 无阅读位置（详情页），隐藏定位按钮与当前章高亮。 */
  @Param currentChapterIndex: number = -1;
  /** 章节进度取值（如 '100%' / '42%'；返回空串隐藏进度列）。 */
  @Param progressOf: (index: number) => string = (_index: number): string => '';
  /** 章节点击（回传全量下标），宿主负责关 sheet 与跳转。 */
  @Event chapterClick: (index: number) => void = (_index: number): void => {};
  /** 打开令牌：宿主每次打开目录 +1，组件据此重置搜索/排序并定位当前章。 */
  @Param openToken: number = 0;
  /** 列表底部额外避让（阅读页传 56 让出底部工具栏）。 */
  @Param contentEndExtra: number = 0;

  @Local keyword: string = '';
  @Local descending: boolean = false;
  /** 手风琴：当前展开的分组 key（空串全收起；搜索时忽略、全部展开）。 */
  @Local expandedGroupKey: string = '';
  /** 顶层渲染节点（分组头 / 章）：定位扫描用。 */
  private nodes: FqCatalogNode[] = [];
  private nodeSource: FqCatalogNodeSource = new FqCatalogNodeSource();
  private scroller: ListScroller = new ListScroller();

  aboutToAppear(): void {
    this.refreshSource();
    this.locateOnOpen();
  }

  @Monitor('openToken')
  onOpenTokenChange(): void {
    this.keyword = '';
    this.descending = false;
    this.expandedGroupKey = '';
    this.refreshSource();
    this.locateOnOpen();
  }

  /** 打开目录：延迟等 sheet 弹出后滚动到当前章（无阅读位置时展开首个分组）。 */
  private locateOnOpen(): void {
    if (this.currentChapterIndex < 0) {
      this.expandDefaultGroup();
      return;
    }
    const target: number = this.currentChapterIndex;
    setTimeout((): void => {
      this.scrollToChapter(target, false);
    }, 300);
  }

  /** 显示顺序的全量章节下标（关键字过滤 + 倒序反转）。 */
  private displayIndices(): number[] {
    const search: string = this.keyword.trim();
    const indices: number[] = [];
    for (let i: number = 0; i < this.chapters.length; i++) {
      const chapter: FqChapter | undefined = this.chapters[i];
      if (chapter === undefined) {
        continue;
      }
      if (search.length === 0 || chapter.title.includes(search) || chapter.group.includes(search)) {
        indices.push(i);
      }
    }
    if (this.descending) {
      indices.reverse();
    }
    return indices;
  }

  /** 构建渲染节点：连续同 group 章节合并为一个分组头节点（key 按标题去重）。 */
  private buildNodes(indices: number[]): FqCatalogNode[] {
    const nodes: FqCatalogNode[] = [];
    const usedKeys: Set<string> = new Set<string>();
    let i: number = 0;
    while (i < indices.length) {
      const first: FqChapter | undefined = this.chapters[indices[i]];
      if (first === undefined) {
        break;
      }
      if (first.group.length > 0) {
        const children: FqCatalogNode[] = [];
        while (i < indices.length) {
          const chapter: FqChapter | undefined = this.chapters[indices[i]];
          if (chapter === undefined || chapter.group !== first.group) {
            break;
          }
          children.push(new FqCatalogNode(`c_${chapter.itemId}`, '', chapter, indices[i], []));
          i++;
        }
        let key: string = `g_${first.group}`;
        let bump: number = 2;
        while (usedKeys.has(key)) {
          key = `g_${first.group}_${bump}`;
          bump++;
        }
        usedKeys.add(key);
        nodes.push(new FqCatalogNode(key, first.group, null, -1, children));
      } else {
        nodes.push(new FqCatalogNode(`f_${first.itemId}`, '', first, indices[i], []));
        i++;
      }
    }
    return nodes;
  }

  private refreshSource(): void {
    this.nodes = this.buildNodes(this.displayIndices());
    this.nodeSource.setItems(this.nodes);
  }

  /** 分组是否展开：搜索中全部展开（保证命中可见），否则手风琴比对 key。 */
  private isGroupExpanded(node: FqCatalogNode): boolean {
    return this.keyword.trim().length > 0 || this.expandedGroupKey === node.key;
  }

  /** 组头点击：展开本组 / 再点收起（手风琴，同时只展开一组）。 */
  private toggleGroup(node: FqCatalogNode): void {
    this.expandedGroupKey = this.expandedGroupKey === node.key ? '' : node.key;
  }

  /** 无阅读位置（详情页）时默认展开第一个分组，避免整页全收起。 */
  private expandDefaultGroup(): void {
    for (const node of this.nodes) {
      if (node.groupTitle.length > 0) {
        this.expandedGroupKey = node.key;
        return;
      }
    }
  }

  /** 定位章节：扁平直接滚动；分组未展开先展开（延迟等布局）再滚动到组内位置。 */
  private scrollToChapter(chapterIndex: number, smooth: boolean): void {
    let topIndex: number = 0;
    for (const node of this.nodes) {
      if (node.groupTitle.length > 0) {
        let itemIndex: number = -1;
        let scan: number = 0;
        for (const child of node.children) {
          if (child.index === chapterIndex) {
            itemIndex = scan;
            break;
          }
          scan++;
        }
        if (itemIndex >= 0) {
          const groupAt: number = topIndex;
          const itemAt: number = itemIndex;
          if (this.isGroupExpanded(node)) {
            this.scroller.scrollToItemInGroup(groupAt, itemAt, smooth);
          } else {
            this.expandedGroupKey = node.key;
            setTimeout((): void => {
              this.scroller.scrollToItemInGroup(groupAt, itemAt, false);
            }, 150);
          }
          return;
        }
      } else if (node.index === chapterIndex) {
        this.scroller.scrollToIndex(topIndex, smooth);
        return;
      }
      topIndex++;
    }
  }

  /** 定位按钮：滚动到当前章（当前章被搜索过滤时保持原位）。 */
  private locateCurrent(): void {
    if (this.currentChapterIndex < 0 || this.currentChapterIndex >= this.chapters.length) {
      return;
    }
    this.scrollToChapter(this.currentChapterIndex, true);
  }

  /** Sheet 标题：总数就绪后带计数（目录 · 123）。 */
  private sheetTitle(): string {
    return this.chapters.length > 0 ? `目录 · ${this.chapters.length}` : '目录';
  }

  /** 进度列颜色：当前章强调色、已读 100% 系统三级色、其余宿主字体色。 */
  private progressColorAt(index: number, text: string): ResourceColor {
    if (index === this.currentChapterIndex) {
      return appState.accentColor;
    }
    return text === '100%' ? $r('sys.color.font_tertiary') : this.fontColor;
  }

  /** 进度列透明度：当前章与已读 100% 为 1，其余 0.45。 */
  private progressOpacityAt(index: number, text: string): number {
    if (index === this.currentChapterIndex || text === '100%') {
      return 1;
    }
    return 0.45;
  }

  /** 章节行（组内与扁平共用；标题空回退「第N章」）。 */
  @Builder
  private ChapterRow(node: FqCatalogNode) {
    Row({ space: 14 }) {
      Text(node.chapter !== null && node.chapter.title.length > 0 ? node.chapter.title
        : `第${node.index + 1}章`)
        .fontSize(14)
        .fontColor(node.index === this.currentChapterIndex ? appState.accentColor : this.fontColor)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.progressOf(node.index).length > 0) {
        Text(this.progressOf(node.index))
          .fontSize(12)
          .fontColor(this.progressColorAt(node.index, this.progressOf(node.index)))
          .opacity(this.progressOpacityAt(node.index, this.progressOf(node.index)))
          .maxLines(1)
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14, right: 20, left: 20 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.chapterClick(node.index);
    })
  }

  /** 分组头（EPUB 卷 / spine 文档标题）：标题 + 章节数 + 展开箭头，点击切换。 */
  @Builder
  private GroupHeader(node: FqCatalogNode) {
    Row({ space: 10 }) {
      Text(node.groupTitle)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${node.children.length} 章`)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
        .rotate({ angle: this.isGroupExpanded(node) ? 90 : 0 })
        .animation({ duration: 200, curve: Curve.Smooth })
    }
    .width('100%')
    .padding({ top: 14, bottom: 12, right: 20, left: 20 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.toggleGroup(node);
    })
  }

  build() {
    CommonSheet({
      sheetTitle: this.sheetTitle(),
      showLocate: this.currentChapterIndex >= 0,
      locateClick: (): void => {
        this.locateCurrent();
      },
      showSort: true,
      sortAscending: !this.descending,
      sortClick: (): void => {
        this.descending = !this.descending;
        this.refreshSource();
      },
    }) {
      Column({ space: 16 }) {
        CommonSearch({
          searchValue: this.keyword,
          isDefaultFocus: false,
          placeholderValue: '搜索章节',
          focusId: 'fq_catalog_sheet_search',
          bgColor: $r('sys.color.comp_background_tertiary'),
          change: (value: string): void => {
            this.keyword = value;
            this.refreshSource();
          },
          submit: (value: string, _event: SubmitEvent): void => {
            this.keyword = value;
            this.refreshSource();
          },
          didDelete: (): void => {
            this.keyword = '';
            this.refreshSource();
          },
          click: (): void => {
          },
        }).height(36).padding({ right: 20, left: 20, bottom: 10 })

        List({ scroller: this.scroller }) {
          LazyForEach(this.nodeSource, (node: FqCatalogNode) => {
            if (node.groupTitle.length > 0) {
              ListItemGroup({ header: this.GroupHeader(node) }) {
                if (this.isGroupExpanded(node)) {
                  LazyForEach(node.childSource, (child: FqCatalogNode) => {
                    ListItem() {
                      this.ChapterRow(child)
                    }
                  }, (child: FqCatalogNode): string => child.key)
                }
              }
              .divider({
                strokeWidth: 0.5,
                color: $r('sys.color.comp_divider'),
                startMargin: 20,
                endMargin: 20,
              })
            } else {
              ListItem() {
                this.ChapterRow(node)
              }
            }
          }, (node: FqCatalogNode): string => node.key)
        }
        .contentEndOffset(appState.bottomRect + this.contentEndExtra)
        .cachedCount(12)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.5,
          color: $r('sys.color.comp_divider'),
          startMargin: 20,
          endMargin: 20,
        })
      }
    }
  }
}

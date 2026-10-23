/**
 * 目录公共半模态（阅读页与详情页共用）：
 * - 章节搜索过滤 / 正倒序 / 定位当前章在组件内自理；
 * - 宿主注入：全量章节、字体色（阅读页墨色 / 详情页系统色）、当前章下标
 *   （-1 无阅读位置：隐藏定位按钮/当前章高亮/打开时定位）、章节进度取值回调
 *   （返回空串隐藏进度列）、章节点击回调（宿主负责关 sheet 与跳转）；
 * - openToken 为打开令牌：宿主每次打开目录 +1，组件据此重置搜索/排序并定位当前章
 *   （兼容 bindSheet 内容重建/复用两种挂载方式，首建由 aboutToAppear 兜底）。
 */

import { FqChapter } from '../model/FqModels';
import { CommonSearch, FQ_ACCENT } from './CommonCom';
import { CommonSheet } from './CommonSheet';
import { appState } from '../entryability/AppState';

/** 目录懒加载数据源：持过滤后章节，变更时通知 LazyForEach 刷新。 */
class FqCatalogSource implements IDataSource {
  private items: FqChapter[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqChapter[]): void {
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
  private source: FqCatalogSource = new FqCatalogSource();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.refreshSource();
    this.locateOnOpen();
  }

  @Monitor('openToken')
  onOpenTokenChange(): void {
    this.keyword = '';
    this.descending = false;
    this.refreshSource();
    this.locateOnOpen();
  }

  /** 打开目录：延迟等 sheet 弹出后滚动到当前章。 */
  private locateOnOpen(): void {
    if (this.currentChapterIndex < 0) {
      return;
    }
    const target: number = this.currentChapterIndex;
    setTimeout((): void => {
      this.scroller.scrollToIndex(target, false);
    }, 300);
  }

  /** 目录搜索过滤：空关键字返回全量目录。 */
  private filteredChapters(): FqChapter[] {
    const search: string = this.keyword.trim();
    if (search.length === 0) {
      return this.chapters;
    }
    const result: FqChapter[] = [];
    for (const chapter of this.chapters) {
      if (chapter.title.includes(search)) {
        result.push(chapter);
      }
    }
    return result;
  }

  /** 目录显示列表：关键字过滤后按排序输出（倒序时反转）。 */
  private displayChapters(): FqChapter[] {
    const list: FqChapter[] = this.filteredChapters();
    if (!this.descending) {
      return list;
    }
    const reversed: FqChapter[] = list.slice();
    reversed.reverse();
    return reversed;
  }

  private refreshSource(): void {
    this.source.setItems(this.displayChapters());
  }

  /** 定位按钮：滚动到当前章（搜索过滤时按过滤后位置定位）。 */
  private locateCurrent(): void {
    if (this.currentChapterIndex < 0 || this.currentChapterIndex >= this.chapters.length) {
      return;
    }
    const current: FqChapter | undefined = this.chapters[this.currentChapterIndex];
    if (current === undefined) {
      return;
    }
    const pos: number = this.displayChapters().indexOf(current);
    this.scroller.scrollToIndex(pos >= 0 ? pos : this.currentChapterIndex, true);
  }

  /** Sheet 标题：总数就绪后带计数（目录 · 123）。 */
  private sheetTitle(): string {
    return this.chapters.length > 0 ? `目录 · ${this.chapters.length}` : '目录';
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
          LazyForEach(this.source, (chapter: FqChapter) => {
            ListItem() {
              Row({ space: 14 }) {
                Text(chapter.title.length > 0 ? chapter.title
                  : `第${this.chapters.indexOf(chapter) + 1}章`)
                  .fontSize(14)
                  .fontColor(this.chapters.indexOf(chapter) === this.currentChapterIndex
                    ? FQ_ACCENT : this.fontColor)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.progressOf(this.chapters.indexOf(chapter)).length > 0) {
                  Text(this.progressOf(this.chapters.indexOf(chapter)))
                    .fontSize(12)
                    .fontColor(this.chapters.indexOf(chapter) === this.currentChapterIndex
                      ? FQ_ACCENT : this.fontColor)
                    .opacity(this.chapters.indexOf(chapter) === this.currentChapterIndex ? 1 : 0.45)
                    .maxLines(1)
                }
              }
              .width('100%')
              .padding({ top: 14, bottom: 14, right: 20, left: 20 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.chapterClick(this.chapters.indexOf(chapter));
              })
            }
          }, (chapter: FqChapter): string => chapter.itemId)
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
      }.padding({ top: 56 })
    }
  }
}

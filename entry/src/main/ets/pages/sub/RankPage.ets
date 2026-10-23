/**
 * 排行榜页（NavDestination）：榜单药丸条 + 分类文本条 + 排名列表 + 分页。
 * 端点语义对齐 fqapp rank_page.dart / rank.dart：
 * 目录藏于 novel homepage(tab_type=2) 载荷，榜单 /api/v1/rank/{rankId} 分页。
 */

import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import {
  FqRankBoard,
  FqRankCatalog,
  FqRankCategory,
  FqRankEntry,
  FqRankTab,
  fqEmptyRankCatalog,
} from '../../model/FqModels';
import { DetailNavParams, FqTitleBarOptions, ROUTE_DETAIL } from '../../model/FqNavModels';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { CommonNav } from '../../view/CommonNav';
import { CommonLoading, FQ_ACCENT } from '../../view/CommonCom';

/** 排名行懒加载数据源。 */
class FqRankEntryDataSource implements IDataSource {
  private entries: FqRankEntry[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.entries.length;
  }

  getData(index: number): FqRankEntry {
    return this.entries[index];
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

  setEntries(entries: FqRankEntry[]): void {
    this.entries = entries;
    this.notifyReload();
  }

  appendEntries(entries: FqRankEntry[]): void {
    if (entries.length === 0) {
      return;
    }
    this.entries = this.entries.concat(entries);
    this.notifyReload();
  }

  private notifyReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct RankPage {
  @Local catalog: FqRankCatalog = fqEmptyRankCatalog();
  @Local rankIndex: number = 0;
  @Local categoryIndex: number = 0;
  @Local entryCount: number = 0;
  @Local loading: boolean = false;
  @Local loadingMore: boolean = false;
  @Local errorMsg: string = '';
  @Local loadMoreError: string = '';
  @Local hasMore: boolean = false;
  private dataSource: FqRankEntryDataSource = new FqRankEntryDataSource();
  private scroller: Scroller = new Scroller();
  private loadToken: number = 0;

  aboutToAppear(): void {
    this.bootstrap();
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('排行榜', false),
      scroller: this.scroller,
      doubleTapToTop: true,
    }) {
      Column() {
        if (this.loading && this.entryCount === 0) {
          Column({ space: 12 }) {
            CommonLoading({ sizeValue: 28, loadColor: FQ_ACCENT })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0 && this.entryCount === 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .backgroundColor('#FF7A3D')
              .onClick(() => this.retryLoad())
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          this.RankPills()
          if (!this.currentRank().isDrama && this.catalog.categories.length > 0) {
            this.CategoryStrip()
          }
          List({ space: 0, scroller: this.scroller }) {
            LazyForEach(this.dataSource, (entry: FqRankEntry) => {
              ListItem() {
                Row({ space: 12 }) {
                  Text(`${entry.position}`)
                    .width(30)
                    .fontSize(entry.position <= 3 ? 17 : 15)
                    .fontWeight(700)
                    .fontColor(entry.position <= 3 ? '#FF7A3D' : $r('sys.color.font_secondary'))
                    .textAlign(TextAlign.Center)
                  if (entry.cover.length > 0) {
                    Image(FqBackend.get().resourceUrl(entry.cover))
                      .width(56)
                      .height(78)
                      .borderRadius(8)
                      .objectFit(ImageFit.Cover)
                      .autoResize(true)
                      .draggable(false)
                  } else {
                    Column()
                      .width(56)
                      .height(78)
                      .borderRadius(8)
                      .backgroundColor($r('sys.color.comp_background_secondary'))
                  }
                  Column({ space: 4 }) {
                    Text(entry.title)
                      .fontSize(15)
                      .fontWeight(600)
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (entry.metaLabel.length > 0) {
                      Text(entry.metaLabel)
                        .fontSize(12)
                        .fontColor($r('sys.color.font_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    if (entry.abstractText.length > 0) {
                      Text(entry.abstractText)
                        .fontSize(12)
                        .fontColor($r('sys.color.font_secondary'))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Top)
                .onClick(() => this.openDetail(entry))
              }
            }, (entry: FqRankEntry): string => `${entry.position}:${entry.id}`)
            if (this.loadMoreError.length > 0) {
              ListItem() {
                Text(this.loadMoreError)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(12)
                  .onClick(() => this.loadMore())
              }
            } else if (this.loadingMore) {
              ListItem() {
                CommonLoading({ sizeValue: 18, loadColor: FQ_ACCENT })
                  .margin(12)
              }
            }
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .onReachEnd(() => this.loadMore())
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 榜单算法药丸条。 */
  @Builder
  private RankPills() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.catalog.tabs, (tab: FqRankTab, index: number) => {
          Text(tab.name)
            .fontSize(13)
            .fontWeight(this.rankIndex === index ? 700 : 500)
            .fontColor(this.rankIndex === index ? Color.White : $r('sys.color.font_primary'))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor(this.rankIndex === index ? '#FF7A3D' : $r('sys.color.comp_background_tertiary'))
            .onClick(() => this.selectRank(index))
        }, (tab: FqRankTab): string => tab.name)
      }
      .padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(46)
    .align(Alignment.Center)
  }

  /** 分类文本条（短剧/漫剧榜隐藏）。 */
  @Builder
  private CategoryStrip() {
    Scroll() {
      Row({ space: 4 }) {
        ForEach(this.catalog.categories, (category: FqRankCategory, index: number) => {
          Text(category.name)
            .fontSize(12)
            .fontWeight(this.categoryIndex === index ? 700 : 400)
            .fontColor(this.categoryIndex === index ? '#FF7A3D' : $r('sys.color.font_tertiary'))
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => this.selectCategory(index))
        }, (category: FqRankCategory): string => `${category.id}`)
      }
      .padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(38)
    .align(Alignment.Center)
  }

  private currentRank(): FqRankTab {
    if (this.rankIndex < this.catalog.tabs.length) {
      return this.catalog.tabs[this.rankIndex];
    }
    return new FqRankTab('', -1);
  }

  private currentCategoryId(): number {
    if (this.categoryIndex < this.catalog.categories.length) {
      return this.catalog.categories[this.categoryIndex].id;
    }
    return 0;
  }

  private selectRank(index: number): void {
    if (this.rankIndex === index) {
      return;
    }
    this.rankIndex = index;
    this.categoryIndex = 0;
    this.loadBoard(true);
  }

  private selectCategory(index: number): void {
    if (this.categoryIndex === index) {
      return;
    }
    this.categoryIndex = index;
    this.loadBoard(true);
  }

  private retryLoad(): void {
    if (this.catalog.isEmpty) {
      this.bootstrap();
    } else {
      this.loadBoard(true);
    }
  }

  private openDetail(entry: FqRankEntry): void {
    DetailNavParams.title = entry.title;
    DetailNavParams.cover = entry.cover;
    if (entry.kind === 'video' || entry.kind === 'manju') {
      DetailNavParams.id = entry.seriesId.length > 0 ? entry.seriesId : entry.id;
      DetailNavParams.kind = entry.kind;
    } else {
      DetailNavParams.id = entry.id;
      DetailNavParams.kind = 'book';
    }
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 目录加载：novel homepage(tab_type=2) 深搜 rank_with_category_data。 */
  private async bootstrap(): Promise<void> {
    const token: number = ++this.loadToken;
    this.loading = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const catalog: FqRankCatalog = await FqBackend.get().rankCatalog();
      if (token !== this.loadToken) {
        return;
      }
      if (catalog.isEmpty) {
        this.errorMsg = '排行榜暂时不可用';
        return;
      }
      this.catalog = catalog;
      this.rankIndex = 0;
      this.categoryIndex = 0;
      await this.loadBoard(true);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
      }
    }
  }

  private loadMore(): void {
    if (!this.hasMore || this.loadingMore || this.loading || this.entryCount === 0) {
      return;
    }
    this.loadBoard(false);
  }

  /** 榜单加载/翻页。 */
  private async loadBoard(reset: boolean): Promise<void> {
    const rank: FqRankTab = this.currentRank();
    if (this.catalog.rankId.length === 0 || rank.name.length === 0) {
      return;
    }
    const token: number = ++this.loadToken;
    const count: number = this.dataSource.totalCount();
    const categoryId: number = rank.isDrama ? 0 : this.currentCategoryId();
    if (reset) {
      this.loading = true;
      this.errorMsg = '';
      this.loadMoreError = '';
    } else {
      this.loadingMore = true;
      this.loadMoreError = '';
    }
    try {
      const board: FqRankBoard = await FqBackend.get().rankBoard(
        this.catalog.rankId,
        rank.algo,
        categoryId,
        reset ? 0 : count,
        reset ? 1 : count + 1,
      );
      if (token !== this.loadToken) {
        return;
      }
      if (reset) {
        this.dataSource.setEntries(board.entries);
        this.entryCount = this.dataSource.totalCount();
        this.hasMore = board.hasMore;
        if (board.isEmpty) {
          this.errorMsg = '该榜单暂无内容';
        }
      } else {
        this.dataSource.appendEntries(board.entries);
        this.entryCount = this.dataSource.totalCount();
        this.hasMore = board.hasMore;
      }
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      if (reset) {
        this.errorMsg = fqErrorMessage(error);
      } else {
        this.loadMoreError = '加载失败，点击重试';
      }
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
        this.loadingMore = false;
      }
    }
  }
}

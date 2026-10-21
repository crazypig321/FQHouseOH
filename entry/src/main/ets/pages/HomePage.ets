/**
 * 首页：fqapp 原版 6 频道多源推荐流
 * （推荐 = 首页流多 tab 交错 + 漫画搜索分页；单频道 = 单源）。
 * 布局：标题栏 bottomBuilder 搜索框 + 药丸频道条 + 今日焦点轮播 + 分区头 + 3 列封面网格。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqHomeFeed, FqHomeRowDataSource, FqHomeSource } from '../core/FqHomeFeed';
import { FqHomeCache } from '../core/FqHomeCache';
import { FqMediaItem } from '../model/FqModels';
import { FqMediaCard } from '../component/FqMediaCard';
import { FqSpotlight } from '../component/FqSpotlight';
import { CommonSearch, FQ_ACCENT, CommonLoading, RefreshOverlay } from '../view/CommonCom';
import { DetailNavParams, ROUTE_DETAIL, ROUTE_SEARCH, FqTitleBarOptions } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { CommonNav } from '../view/CommonNav';
import { appState } from '../entryability/AppState';

class FqChannelDef {
  readonly label: string;
  readonly buildSources: () => FqHomeSource[];

  constructor(label: string, buildSources: () => FqHomeSource[]) {
    this.label = label;
    this.buildSources = buildSources;
  }
}

const FQ_CHANNELS: FqChannelDef[] = [
  new FqChannelDef('推荐', (): FqHomeSource[] => [
    FqHomeSource.homepage(2, 'book'),
    FqHomeSource.homepage(8, 'video'),
    FqHomeSource.homepage(24, 'manju'),
    FqHomeSource.search('漫画', 8, 'manga'),
    FqHomeSource.homepage(5, 'audio'),
  ]),
  new FqChannelDef('小说', (): FqHomeSource[] => [FqHomeSource.homepage(2, 'book')]),
  new FqChannelDef('短剧', (): FqHomeSource[] => [FqHomeSource.homepage(8, 'video')]),
  new FqChannelDef('漫剧', (): FqHomeSource[] => [FqHomeSource.homepage(24, 'manju')]),
  new FqChannelDef('漫画', (): FqHomeSource[] => [FqHomeSource.search('漫画', 8, 'manga')]),
  new FqChannelDef('听书', (): FqHomeSource[] => [FqHomeSource.homepage(5, 'audio')]),
];

const FQ_CAPTIONS: string[] = [
  '换个故事，换一种心情',
  '翻开之后，就舍不得合上',
  '好戏开场，下一集更精彩',
  '画中的故事，正在上演',
  '每一格，都藏着一个新世界',
  '让好故事，陪你走过日常',
];

/** 列表内容起始偏移：标题栏 56 + 搜索行 52（Search 40 + 上下 padding 12） */
const FQ_HOME_TOP_INSET: number = 170;

/** bottomBuilder（108vp）完全收起所需滚动距离（hideRatio 默认 2，滚动 216vp 收完） */
const FQ_SEARCH_HIDE_OFFSET: number = 216;

@ComponentV2
export struct HomePage {
  @Local channelIndex: number = 0;
  @Local itemCount: number = 0;
  @Local loading: boolean = false;
  @Local loadingMore: boolean = false;
  @Local refreshing: boolean = false;
  @Local errorMsg: string = '';
  @Local hasMore: boolean = false;
  @Local spotlightItems: FqMediaItem[] = [];
  /** bottomBuilder（搜索条+频道条）已上滑收起：此时标题栏菜单透出搜索入口 */
  @Local searchBarHidden: boolean = false;
  private feed: FqHomeFeed = new FqHomeFeed([]);
  private rowSource: FqHomeRowDataSource = new FqHomeRowDataSource(3, 3);
  private scroller: Scroller = new Scroller();
  private loadToken: number = 0;
  /** 各频道流实例缓存（含翻页游标）；切回频道直接复用，不重新加载。 */
  private channelFeeds: (FqHomeFeed | null)[] = [null, null, null, null, null, null];

  aboutToAppear(): void {
    FqHomeCache.init(getContext(this));
    this.hydrateFromDisk();
    this.loadFirst();
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions($r('app.string.app_name'), this.searchBarHidden, {
        builder: (): void => {
          this.SearchBar();
        },
        height: 88
      }, (): void => {
        this.startRefresh();
      }, true),
      isHideBackButton: true,
      scroller: this.scroller,
      isSearchBarScroller: true,
      doubleTapToTop: true,
      scrollToTopYOffset: - appState.topRect - FQ_HOME_TOP_INSET,
      scrollMaskExtraHeight: undefined
    }) {
      Stack() {
        List({ space: 0, scroller: this.scroller }) {
          if (this.loading && this.itemCount === 0) {
            this.FeedLoading()
          } else if (this.errorMsg.length > 0 && this.itemCount === 0) {
            this.FeedError()
          } else if (this.itemCount === 0 && !this.hasMore) {
            this.FeedEmpty()
          } else if (this.itemCount === 0) {
            this.FeedLoading()
          } else {
            ListItem() {
              FqSpotlight({
                items: this.spotlightItems,
                onOpen: (item: FqMediaItem): void => {
                  this.openDetail(item);
                },
              })
                .margin({ top: 8 })
            }
            ListItem() {
              Row({ space: 8 }) {
                Column()
                  .width(4)
                  .height(18)
                  .borderRadius(2)
                  .backgroundColor('#FF7A3D')
                Column({ space: 2 }) {
                  Text('发现更多好故事')
                    .fontSize(20)
                    .fontWeight(800)
                    .fontColor($r('sys.color.font_primary'))
                  Text(`值得一看的${FQ_CHANNELS[this.channelIndex].label}`)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                Blank()
                Row({ space: 4 }) {
                  Text(this.caption())
                    .fontSize(12)
                    .fontColor($r('sys.color.font_tertiary'))
                    .maxLines(1)
                  SymbolGlyph($r('sys.symbol.compass'))
                    .fontSize(19)
                    .fontColor([$r('sys.color.icon_tertiary')])
                }
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 18, bottom: 12 })
              .alignItems(VerticalAlign.Center)
            }
            LazyForEach(this.rowSource, (row: FqMediaItem[]) => {
              ListItem() {
                Row({ space: 14 }) {
                  this.GridSlot(row, 0)
                  this.GridSlot(row, 1)
                  this.GridSlot(row, 2)
                }
                .width('100%')
                .padding({ left: 20, right: 20 })
                .margin({ bottom: 14 })
                .alignItems(VerticalAlign.Top)
              }
            }, (row: FqMediaItem[], index: number): string => this.rowKey(row, index))
            if (this.loadingMore) {
              ListItem() {
                Row({ space: 8 }) {
                  CommonLoading({ sizeValue: 18, loadColor: FQ_ACCENT })
                  Text('加载中…')
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              }
            } else if (!this.hasMore) {
              ListItem() {
                Row({ space: 10 }) {
                  Divider()
                    .strokeWidth(0.5)
                    .color($r('sys.color.comp_divider'))
                    .layoutWeight(1)
                  Text('好故事，未完待续')
                    .fontSize(11)
                    .fontColor($r('sys.color.font_tertiary'))
                  Divider()
                    .strokeWidth(0.5)
                    .color($r('sys.color.comp_divider'))
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 20, right: 20, top: 14, bottom: 14 })
                .alignItems(VerticalAlign.Center)
              }
            }
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .contentStartOffset(appState.topRect + FQ_HOME_TOP_INSET)
        .contentEndOffset(appState.bottomRect + 60)
        .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
          this.updateSearchBarHidden();
        })
        .onReachEnd(() => this.loadMore())
        if (this.refreshing) {
          RefreshOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 右上角刷新入口：展示全屏覆盖 loading 并重载当前频道。 */
  private startRefresh(): void {
    if (this.loading || this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.loadFirst();
  }

  /** 标题栏 bottomBuilder：搜索框（点击进搜索页，不可聚焦）。 */
  @Builder
  private SearchBar() {
    Column({ space: 10 }) {
      CommonSearch({
        searchValue: '',
        placeholderValue: '搜索你想看的故事',
        isFocusable: false,
        click: (): void => {
          NavPathUtils.push(ROUTE_SEARCH);
        },
      })
      this.ChannelStrip()
    }
    .padding({ left: 16, right: 16 })
  }

  /** fqapp 药丸频道条（随内容滚动，横向 List）。 */
  @Builder
  private ChannelStrip() {
      Column({ space: 5 }) {
        List({ space: 6 }) {
          ForEach(FQ_CHANNELS, (channel: FqChannelDef, index: number) => {
            ListItem() {
              Row({ space: 5 }) {
                SymbolGlyph(this.channelIcon(index))
                  .fontSize(14)
                  .fontColor([this.channelIconColor(index)])
                Text(channel.label)
                  .fontSize(13)
                  .fontWeight(this.channelIndex === index ? 700 : 500)
                  .fontColor(this.channelIndex === index ? Color.White : $r('sys.color.font_primary'))
              }
              .height(38)
              .padding({ left: 14, right: 14 })
              .borderRadius(19)
              .backgroundColor(this.channelIndex === index ? '#FF7A3D' : $r('sys.color.comp_background_tertiary'))
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.selectChannel(index))
            }
          }, (channel: FqChannelDef): string => channel.label)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .width('100%')
        .align(Alignment.Center)
      }
      .width('100%')
      .height(54)
      .justifyContent(FlexAlign.Center)
  }

  /** 首屏加载占位。 */
  @Builder
  private FeedLoading() {
    ListItem() {
      Column({ space: 12 }) {
        CommonLoading({ sizeValue: 24, loadColor: FQ_ACCENT })
        Text('正在寻找好故事')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .borderRadius(24)
      .justifyContent(FlexAlign.Center)
    }.margin({ top: 10 })
  }

  /** 首屏失败占位。 */
  @Builder
  private FeedError() {
    ListItem() {
      Column({ space: 12 }) {
        Text('故事还在路上')
          .fontSize(22)
          .fontWeight(800)
          .fontColor($r('sys.color.font_primary'))
        Text(this.errorMsg)
          .fontSize(13)
          .fontColor($r('sys.color.font_tertiary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
        Button('重试')
          .backgroundColor('#FF7A3D')
          .onClick(() => this.loadFirst())
      }
      .width('100%')
      .padding({ top: 48 })
      .alignItems(HorizontalAlign.Center)
    }
  }

  /** 首屏空态占位。 */
  @Builder
  private FeedEmpty() {
    ListItem() {
      Column({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(64)
            .height(64)
            .borderRadius(32)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
          SymbolGlyph($r('sys.symbol.compass'))
            .fontSize(32)
            .fontColor(['#FF7A3D'])
        }
        Text('暂无内容')
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
        Text('换个分类，或刷新发现新故事')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        Button('刷新推荐')
          .backgroundColor(Color.Transparent)
          .fontColor('#FF7A3D')
          .borderRadius(18)
          .border({ width: 1, color: '#FF7A3D' })
          .margin({ top: 6 })
          .onClick(() => this.loadFirst())
      }
      .width('100%')
      .padding({ top: 40 })
      .alignItems(HorizontalAlign.Center)
    }
  }

  /** 网格槽位：不足 3 个时用空占位保持等宽。 */
  @Builder
  private GridSlot(row: FqMediaItem[], slot: number) {
    if (slot < row.length) {
      FqMediaCard({
        item: row[slot],
        onItemClick: (clicked: FqMediaItem): void => {
          this.openDetail(clicked);
        },
      })
        .layoutWeight(1)
    } else {
      Column()
        .layoutWeight(1)
    }
  }

  private channelIcon(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.wand_and_stars');
    }
    if (index === 1) {
      return $r('sys.symbol.book');
    }
    if (index === 2) {
      return $r('sys.symbol.video');
    }
    if (index === 3) {
      return $r('sys.symbol.film');
    }
    if (index === 4) {
      return $r('sys.symbol.picture');
    }
    return $r('sys.symbol.headphones');
  }

  private channelIconColor(index: number): ResourceColor {
    return this.channelIndex === index ? Color.White : $r('sys.color.icon_tertiary');
  }

  private caption(): string {
    return FQ_CAPTIONS[this.channelIndex];
  }

  private rowKey(row: FqMediaItem[], index: number): string {
    const first: string = row.length > 0 ? `${row[0].kind}:${row[0].id}` : '';
    return `${index}:${row.length}:${first}`;
  }

  private selectChannel(index: number): void {
    if (this.channelIndex === index) {
      return;
    }
    this.loadToken += 1;
    this.channelIndex = index;
    FqHomeCache.saveChannelIndex(index);
    this.loading = false;
    this.loadingMore = false;
    this.refreshing = false;
    const cached: FqHomeFeed | null = this.channelFeeds[index];
    if (cached !== null && cached.totalCount() > 0) {
      this.feed = cached;
      this.errorMsg = '';
      this.applyFeed();
      this.scroller.scrollEdge(Edge.Top);
      this.searchBarHidden = false;
      return;
    }
    this.feed = new FqHomeFeed([]);
    this.spotlightItems = [];
    this.rowSource.setItems([]);
    this.itemCount = 0;
    this.errorMsg = '';
    this.hasMore = false;
    this.scroller.scrollEdge(Edge.Top);
    this.searchBarHidden = false;
    this.loadFirst();
  }

  /** 滚动时同步搜索条隐藏状态：完全收起后在标题栏菜单透出搜索入口。 */
  private updateSearchBarHidden(): void {
    const hidden: boolean = this.scroller.currentOffset().yOffset > FQ_SEARCH_HIDE_OFFSET;
    if (hidden !== this.searchBarHidden) {
      this.searchBarHidden = hidden;
    }
  }

  private openDetail(item: FqMediaItem): void {
    DetailNavParams.id = item.id;
    DetailNavParams.kind = item.kind;
    DetailNavParams.title = item.title;
    DetailNavParams.cover = item.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  private applyFeed(): void {
    const items: FqMediaItem[] = this.feed.items();
    this.spotlightItems = items.slice(0, 3);
    this.rowSource.setItems(items);
    this.itemCount = this.feed.totalCount();
    this.hasMore = this.feed.hasMore;
  }

  /** 冷启动磁盘缓存回填：各频道复用上次列表；当前频道先展示再由 loadFirst 静默刷新。 */
  private hydrateFromDisk(): void {
    const saved: number = FqHomeCache.savedChannelIndex();
    if (saved >= 0 && saved < FQ_CHANNELS.length) {
      this.channelIndex = saved;
    }
    for (let index: number = 0; index < FQ_CHANNELS.length; index += 1) {
      const items: FqMediaItem[] = FqHomeCache.channelItems(index);
      if (items.length === 0) {
        continue;
      }
      const feed: FqHomeFeed = new FqHomeFeed(FQ_CHANNELS[index].buildSources());
      feed.restore(items);
      this.channelFeeds[index] = feed;
    }
    const current: FqHomeFeed | null = this.channelFeeds[this.channelIndex];
    if (current !== null) {
      this.feed = current;
      this.applyFeed();
    }
  }

  /** 首屏 0 条且仍有游标时自动补拉一页。 */
  private maybeAutoLoadMore(token: number): void {
    if (this.feed.totalCount() === 0 && this.feed.hasMore) {
      setTimeout((): void => {
        if (token !== this.loadToken) {
          return;
        }
        this.loadMore();
      }, 500);
    }
  }

  private async loadFirst(): Promise<void> {
    const token: number = ++this.loadToken;
    const channel: number = this.channelIndex;
    this.loading = true;
    this.loadingMore = false;
    this.errorMsg = '';
    this.feed = new FqHomeFeed(FQ_CHANNELS[channel].buildSources());
    try {
      await FqBackend.get().start(getContext(this));
      await this.feed.loadFirst();
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = '';
      this.channelFeeds[channel] = this.feed;
      FqHomeCache.saveChannelItems(channel, this.feed.items());
      this.applyFeed();
      this.maybeAutoLoadMore(token);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    const token: number = ++this.loadToken;
    const channel: number = this.channelIndex;
    this.loadingMore = true;
    try {
      await this.feed.loadMore();
      if (token !== this.loadToken) {
        return;
      }
      FqHomeCache.saveChannelItems(channel, this.feed.items());
      this.applyFeed();
      this.maybeAutoLoadMore(token);
    } finally {
      if (token === this.loadToken) {
        this.loadingMore = false;
      }
    }
  }
}

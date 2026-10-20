/**
 * 首页：fqapp 原版 6 频道多源推荐流
 * （推荐 = 首页流多 tab 交错 + 漫画搜索分页；单频道 = 单源）。
 * 布局：标题栏 bottomBuilder 搜索框 + 药丸频道条 + 今日焦点轮播 + 分区头 + 3 列封面网格。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqHomeFeed, FqHomeRowDataSource, FqHomeSource } from '../core/FqHomeFeed';
import { FqMediaItem } from '../model/FqModels';
import { FqMediaCard } from '../component/FqMediaCard';
import { FqSpotlight } from '../component/FqSpotlight';
import { CommonSearch } from '../view/CommonCom';
import { DetailNavParams, ROUTE_DETAIL, ROUTE_SEARCH, FqTitleBarOptions } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { HideMode, HdsNavDestination } from '@kit.UIDesignKit';
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
const FQ_HOME_TOP_INSET: number = 108;

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
  private feed: FqHomeFeed = new FqHomeFeed([]);
  private rowSource: FqHomeRowDataSource = new FqHomeRowDataSource(3, 3);
  private scroller: Scroller = new Scroller();
  private loadToken: number = 0;

  aboutToAppear(): void {
    this.loadFirst();
  }

  build() {
    HdsNavDestination() {
      Refresh({ refreshing: this.refreshing!! }) {
        List({ space: 0, scroller: this.scroller }) {
          this.ChannelStrip()
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
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .color('#FF7A3D')
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
        .onReachEnd(() => this.loadMore())
      }
      .width('100%')
      .height('100%')
      .onRefreshing(() => this.loadFirst())
    }
    .titleBar(FqTitleBarOptions($r('app.string.app_name'), true, {
      builder: (): void => {
        this.SearchBar();
      },
    }))
    .dynamicHideTitleBar({
      hideBottomBuilder: true,
      mode: HideMode.SCROLL_UP_TO,
    })
    .bindToScrollable([this.scroller])
    .hideBackButton(true)
    .width('100%')
    .height('100%')
  }

  /** 标题栏 bottomBuilder：搜索框（点击进搜索页，不可聚焦）。 */
  @Builder
  private SearchBar() {
    Column() {
      CommonSearch({
        searchValue: '',
        placeholderValue: '搜索你想看的故事',
        isFocusable: false,
        click: (): void => {
          NavPathUtils.push(ROUTE_SEARCH);
        },
      })
    }
    .padding({ left: 16, right: 16, top: 2, bottom: 10 })
  }

  /** fqapp 药丸频道条（随内容滚动）。 */
  @Builder
  private ChannelStrip() {
    ListItem() {
      Column() {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(FQ_CHANNELS, (channel: FqChannelDef, index: number) => {
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
            }, (channel: FqChannelDef): string => channel.label)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Center)
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))
      }
      .width('100%')
      .height(54)
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 首屏加载占位。 */
  @Builder
  private FeedLoading() {
    ListItem() {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color('#FF7A3D')
        Text('正在寻找好故事')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height(270)
      .borderRadius(24)
      .backgroundColor($r('sys.color.comp_background_secondary'))
      .justifyContent(FlexAlign.Center)
      .margin({ left: 20, right: 20, top: 12 })
    }
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
    this.channelIndex = index;
    this.feed = new FqHomeFeed([]);
    this.spotlightItems = [];
    this.rowSource.setItems([]);
    this.itemCount = 0;
    this.errorMsg = '';
    this.hasMore = false;
    this.scroller.scrollEdge(Edge.Top);
    this.loadFirst();
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
    this.loading = true;
    this.loadingMore = false;
    this.errorMsg = '';
    this.feed = new FqHomeFeed(FQ_CHANNELS[this.channelIndex].buildSources());
    try {
      await FqBackend.get().start(getContext(this));
      await this.feed.loadFirst();
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = '';
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
    this.loadingMore = true;
    try {
      await this.feed.loadMore();
      if (token !== this.loadToken) {
        return;
      }
      this.applyFeed();
      this.maybeAutoLoadMore(token);
    } finally {
      if (token === this.loadToken) {
        this.loadingMore = false;
      }
    }
  }
}

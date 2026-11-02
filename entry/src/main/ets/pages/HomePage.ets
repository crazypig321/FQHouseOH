/**
 * 首页：fqapp 原版 6 频道多源推荐流
 * （推荐 = 首页流多 tab 交错 + 漫画搜索分页；单频道 = 单源）。
 * 各 homepage 源推荐游标停走后转入 search 兜底续页
 * （小说/短剧/听书 = 旧版 /api/search 页码；漫剧 = v1 搜索游标，
 * 对齐 fqapp home_provider.dart `_loadInitial`/`_loadNext`）。
 * 频道分类：每频道硬编码分类关键词，频道条下方横向分类条（排行榜同款文本样式）；
 * 点「全部」回频道默认推荐流（缓存/持久化复用），点分类用关键词直搜该频道内容
 * （小说/短剧/听书 = 页码搜索；漫剧/漫画 = v1 搜索游标；推荐 = 五类同词聚合搜索）。
 * 布局：标题栏 bottomBuilder 搜索框 + 药丸频道条 + 分类条 + 今日焦点轮播 + 分区头 + 3 列封面网格。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqHomeFeed, FqHomeRowDataSource, FqHomeSource, FQ_SOURCE_SEARCH, FQ_SOURCE_SEARCH_PAGED } from '../core/FqHomeFeed';
import { FqHomeCache } from '../core/FqHomeCache';
import { FqMediaItem } from '../model/FqModels';
import { FqMediaCard } from '../view/FqMediaCard';
import { FqSpotlight } from '../view/FqSpotlight';
import { CommonSearch, CommonLoading, RefreshOverlay } from '../view/CommonCom';
import { fqPushBookOrDetail, ROUTE_SEARCH, FqTitleBarOptions } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { CommonNav } from '../view/CommonNav';
import { appState } from '../entryability/AppState';
import { FqLog } from '../core/FqLogStore';
import { rowImmersiveModifier, selectImmersiveModifier } from '../utils/ModifierUtils';
import { feedColumns } from '../utils/BreakpointUtils';
import { LengthMetrics } from '@kit.ArkUI';

/** 频道大分类（分类条 Select 项）：一组细分词表。 */
class FqCategoryGroup {
  readonly label: string;
  readonly categories: string[];

  constructor(label: string, categories: string[]) {
    this.label = label;
    this.categories = categories;
  }
}

class FqChannelDef {
  readonly label: string;
  readonly buildSources: () => FqHomeSource[];
  /** 大分类组：首组为混合词表（Select「全部」），其余为男频/女频等细分组。 */
  readonly groups: FqCategoryGroup[];
  /** 分类搜索源构建（分类关键词直搜该频道内容）。 */
  readonly buildCategorySources: (category: string) => FqHomeSource[];

  constructor(label: string, buildSources: () => FqHomeSource[],
    groups: FqCategoryGroup[], buildCategorySources: (category: string) => FqHomeSource[]) {
    this.label = label;
    this.buildSources = buildSources;
    this.groups = groups;
    this.buildCategorySources = buildCategorySources;
  }
}

const FQ_CHANNELS: FqChannelDef[] = [
  new FqChannelDef('推荐', (): FqHomeSource[] => [
    FqHomeSource.homepageFallback(2, 'book', FQ_SOURCE_SEARCH_PAGED, '小说', 0),
    FqHomeSource.homepageFallback(8, 'video', FQ_SOURCE_SEARCH_PAGED, '短剧', 0),
    FqHomeSource.homepageFallback(24, 'manju', FQ_SOURCE_SEARCH, '漫剧', 11),
    FqHomeSource.search('漫画', 8, 'manga'),
    FqHomeSource.homepageFallback(5, 'audio', FQ_SOURCE_SEARCH_PAGED, '听书', 0),
  ],
    [
      new FqCategoryGroup('全部', ['热门', '高分', '完结', '新书', '连载', '免费', '经典', '爆款']),
      new FqCategoryGroup('热门', ['热门', '爆款', '新书']),
      new FqCategoryGroup('口碑', ['高分', '经典']),
      new FqCategoryGroup('完结', ['完结', '连载', '免费']),
    ],
    (category: string): FqHomeSource[] => [
      FqHomeSource.pagedSearch(category, 'book'),
      FqHomeSource.search(category, 11, 'video'),
      FqHomeSource.pagedSearch(category, 'audio'),
      FqHomeSource.search(category, 8, 'manga'),
      FqHomeSource.search(category, 11, 'manju'),
    ]),
  new FqChannelDef('小说', (): FqHomeSource[] => [
    FqHomeSource.homepageFallback(2, 'book', FQ_SOURCE_SEARCH_PAGED, '小说', 0),
  ],
    [
      new FqCategoryGroup('全部', ['都市', '玄幻', '仙侠', '奇幻', '武侠', '历史', '科幻', '悬疑', '轻小说', '古言', '现言']),
      new FqCategoryGroup('男频', ['都市', '玄幻', '仙侠', '奇幻', '武侠', '历史', '军事', '游戏', '科幻', '灵异', '脑洞', '悬疑', '轻小说']),
      new FqCategoryGroup('女频', ['古言', '现言', '幻言', '甜宠', '萌宝', '宫斗', '宅斗', '虐恋', '短篇', '悬疑']),
    ],
    (category: string): FqHomeSource[] => [FqHomeSource.pagedSearch(category, 'book')]),
  new FqChannelDef('短剧', (): FqHomeSource[] => [
    FqHomeSource.homepageFallback(8, 'video', FQ_SOURCE_SEARCH_PAGED, '短剧', 0),
  ],
    [
      new FqCategoryGroup('全部', ['甜宠', '逆袭', '战神', '豪门', '萌宝', '复仇', '穿越', '重生', '神豪', '打脸']),
      new FqCategoryGroup('男频', ['战神', '逆袭', '重生', '神豪', '打脸', '赘婿', '都市', '玄幻']),
      new FqCategoryGroup('女频', ['甜宠', '豪门', '萌宝', '复仇', '穿越', '虐恋', '总裁', '古言']),
    ],
    (category: string): FqHomeSource[] => [FqHomeSource.search(category, 11, 'video')]),
  new FqChannelDef('漫剧', (): FqHomeSource[] => [
    FqHomeSource.homepageFallback(24, 'manju', FQ_SOURCE_SEARCH, '漫剧', 11),
  ],
    [
      new FqCategoryGroup('全部', ['古风', '恋爱', '玄幻', '都市', '搞笑', '热血', '悬疑', '奇幻', '治愈', '冒险']),
      new FqCategoryGroup('男频', ['玄幻', '热血', '都市', '冒险', '搞笑', '奇幻']),
      new FqCategoryGroup('女频', ['古风', '恋爱', '治愈', '悬疑', '甜宠', '萌宝']),
    ],
    // 检索词带「漫剧」后缀：裸分类词的 t11 结果全是短剧，无 manju 条目（探针实证）。
    (category: string): FqHomeSource[] => [FqHomeSource.search(`${category}漫剧`, 11, 'manju')]),
  new FqChannelDef('漫画', (): FqHomeSource[] => [FqHomeSource.search('漫画', 8, 'manga')],
    [
      new FqCategoryGroup('全部', ['恋爱', '搞笑', '热血', '玄幻', '都市', '古风', '科幻', '冒险', '悬疑', '治愈']),
      new FqCategoryGroup('男频', ['热血', '玄幻', '搞笑', '都市', '科幻', '冒险']),
      new FqCategoryGroup('女频', ['恋爱', '古风', '治愈', '悬疑', '甜宠', '萌宝']),
    ],
    (category: string): FqHomeSource[] => [FqHomeSource.search(category, 8, 'manga')]),
  new FqChannelDef('听书', (): FqHomeSource[] => [
    FqHomeSource.homepageFallback(5, 'audio', FQ_SOURCE_SEARCH_PAGED, '听书', 0),
  ],
    [
      new FqCategoryGroup('全部', ['都市', '玄幻', '仙侠', '悬疑', '历史', '官场', '相声', '评书', '文学', '儿童']),
      new FqCategoryGroup('男频', ['都市', '玄幻', '仙侠', '历史', '官场', '军事', '悬疑']),
      new FqCategoryGroup('女频', ['古言', '现言', '甜宠', '萌宝', '悬疑']),
      new FqCategoryGroup('出版', ['相声', '评书', '文学', '儿童']),
    ],
    (category: string): FqHomeSource[] => [FqHomeSource.pagedSearch(category, 'audio')]),
];

const FQ_CAPTIONS: string[] = [
  '换个故事，换一种心情',
  '翻开之后，就舍不得合上',
  '好戏开场，下一集更精彩',
  '画中的故事，正在上演',
  '每一格，都藏着一个新世界',
  '让好故事，陪你走过日常',
];

/** 列表内容起始偏移：标题栏 56 + bottomBuilder 插槽（搜索行 + 频道条 + 分类条）。 */
const FQ_HOME_TOP_INSET: number = 200;

/** bottomBuilder（140vp 插槽）完全收起所需滚动距离（hideRatio 默认 2）。 */
const FQ_SEARCH_HIDE_OFFSET: number = 256;

@ComponentV2
export struct HomePage {
  @Local channelIndex: number = 0;
  /** 频道分类下标：0 = 全部（频道默认推荐流），>0 = categories 下标 + 1。 */
  @Local categoryIndex: number = 0;
  /** 大分类组下标（分类条 Select）：0 = 全部（混合词表）。 */
  @Local groupIndex: number = 0;
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
  private rowSource: FqHomeRowDataSource = new FqHomeRowDataSource(3);
  private scroller: Scroller = new Scroller();
  private loadToken: number = 0;
  /** 各频道流实例缓存（含翻页游标）；切回频道直接复用，不重新加载。 */
  private channelFeeds: (FqHomeFeed | null)[] = [null, null, null, null, null, null];

  aboutToAppear(): void {
    FqHomeCache.init(getContext(this));
    const saved: number = FqHomeCache.savedChannelIndex();
    if (saved >= 0 && saved < FQ_CHANNELS.length) {
      this.channelIndex = saved;
    }
    // 冷启动：有持久化列表直接展示（不自动刷新）；触底翻页按源续拉、去重追加。
    const cachedItems: FqMediaItem[] = FqHomeCache.loadFeedItems(this.channelIndex);
    if (cachedItems.length > 0) {
      this.feed = new FqHomeFeed(FQ_CHANNELS[this.channelIndex].buildSources());
      this.feed.continueFrom(cachedItems);
      this.channelFeeds[this.channelIndex] = this.feed;
      this.applyFeed();
    } else {
      this.loadFirst();
    }
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions($r('app.string.app_name'), this.searchBarHidden, {
        builder: (): void => {
          this.SearchBar();
        },
        height: 125
      }, (): void => {
        this.startRefresh();
      }, true),
      embedded: true,
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
                  .backgroundColor(appState.accentColor)
                Column({ space: 2 }) {
                  Text('发现更多好故事')
                    .fontSize(20)
                    .fontWeight(800)
                    .fontColor($r('sys.color.font_primary'))
                  Text(this.sectionSubtitle())
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

            ListItem() {
              List({ space: 14 }) {
                LazyForEach(this.rowSource, (row: FqMediaItem, i: number) => {
                  ListItem() {
                    this.GridSlot(row, i)
                  }//.transition(TransitionEffect.scale({ x: 0.8, y: 0.8 }).animation({ duration: 300, curve: Curve.Smooth }))
                }, (row: FqMediaItem, index: number): string => this.rowKey(row, index))
              }
              .width('100%')
              .lanes(feedColumns(appState.WidthBp), 20)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.None)
              .padding({ left: 20, right: 20 })
              .cachedCount(3)
            }

            if (this.loadingMore) {
              ListItem() {
                Row({ space: 8 }) {
                  CommonLoading({ sizeValue: 18, loadColor: appState.accentColor })
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

  /** 右上角刷新入口：展示全屏覆盖 loading 并按当前模式重载。 */
  private startRefresh(): void {
    if (this.loading || this.refreshing) {
      return;
    }
    this.refreshing = true;
    if (this.categoryIndex > 0) {
      this.loadCategoryFirst();
    } else {
      this.loadFirst();
    }
  }

  /** 标题栏 bottomBuilder：搜索框（点击进搜索页，不可聚焦）。 */
  @Builder
  private SearchBar() {
    Column({ space: 10 }){
      CommonSearch({
        searchValue: '',
        placeholderValue: '搜索你想看的故事',
        isFocusable: false,
        click: (): void => {
          NavPathUtils.push(ROUTE_SEARCH);
        },
      }).height(30)
      Stack({alignContent: Alignment.Center}){
        this.ChannelStrip()
        this.CategoryStrip()
      }
    }.padding({ left: 16, right: 16 })
  }

  /** fqapp 药丸频道条（随内容滚动，横向 List）。 */
  @Builder
  private ChannelStrip() {
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
          .backgroundColor(this.channelIndex === index ? appState.accentColor : Color.Transparent)
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.selectChannel(index))
          .attributeModifier(this.channelIndex === index ? undefined : rowImmersiveModifier)
        }
      }, (channel: FqChannelDef): string => channel.label)
    }
    .listDirection(Axis.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .height(85)
    .alignListItem(ListItemAlign.Center)
    .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(30) })
  }

  /** 频道分类条：首位大分类 Select（全部=频道默认推荐流，男频/女频…=细分组，选中即加载组内首个分类）。 */
  @Builder
  private CategoryStrip() {
    Row({ space: 4 }) {
      Select(this.categoryGroupOptions())
        .value(this.currentGroup().label)
        .selected(this.groupIndex)
        .font({ size: 12, weight: FontWeight.Medium })
        .fontColor($r('sys.color.font_secondary'))
        .selectedOptionFont({ size: 13, weight: FontWeight.Medium })
        .selectedOptionFontColor(appState.accentColor)
        .optionFont({ size: 13 })
        .optionFontColor($r('sys.color.font_primary'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .height(30)
        .attributeModifier(selectImmersiveModifier)
        .onSelect((index: number, text: string) => this.selectGroup(index))
      List({ space: 4 }) {
        ForEach(this.currentGroup().categories, (category: string, index: number) => {
          ListItem() {
            Text(category)
              .fontSize(12)
              .fontWeight(this.categoryIndex === index + 1 ? 700 : 400)
              .fontColor(this.categoryIndex === index + 1 ? appState.accentColor : $r('sys.color.font_tertiary'))
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .onClick(() => this.selectCategory(index + 1))
          }
        }, (category: string): string => category)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .layoutWeight(1)
      .height(30)
      .alignListItem(ListItemAlign.Center)
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(24) })
    }
    .width('100%')
    .height(30)
    .offset({ y: 45 })
  }

  /** 首屏加载占位。 */
  @Builder
  private FeedLoading() {
    ListItem() {
      Column({ space: 12 }) {
        CommonLoading({ sizeValue: 24, loadColor: appState.accentColor })
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
          .backgroundColor(appState.accentColor)
          .onClick(() => this.retryLoadFirst())
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
            .fontColor([appState.accentColor])
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
          .fontColor(appState.accentColor)
          .borderRadius(18)
          .border({ width: 1, color: appState.accentColor })
          .margin({ top: 6 })
          .onClick(() => this.retryLoadFirst())
      }
      .width('100%')
      .padding({ top: 40 })
      .alignItems(HorizontalAlign.Center)
    }
  }

  /** 网格行：整行渲染 3 列，不足 3 个时用空占位保持等宽。 */
  @Builder
  private GridSlot(row: FqMediaItem, i: number) {
    if (i < this.rowSource.totalCount()) {
      FqMediaCard({
        item: row,
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

  /** 分区头副标题：分类态带上分类词。 */
  private sectionSubtitle(): string {
    const channel: FqChannelDef = FQ_CHANNELS[this.channelIndex];
    const categories: string[] = this.currentGroup().categories;
    if (this.categoryIndex > 0 && this.categoryIndex <= categories.length) {
      return `值得一看的${categories[this.categoryIndex - 1]}${channel.label}`;
    }
    return `值得一看的${channel.label}`;
  }

  /** 失败/空态重试：按当前模式分派首屏加载。 */
  private retryLoadFirst(): void {
    if (this.categoryIndex > 0) {
      this.loadCategoryFirst();
    } else {
      this.loadFirst();
    }
  }

  private rowKey(row: FqMediaItem, index: number): string {
    return `${index}:${row.kind}:${row.id}`;
  }

  private selectChannel(index: number): void {
    if (this.channelIndex === index && this.categoryIndex === 0) {
      return;
    }
    this.loadToken += 1;
    this.channelIndex = index;
    this.categoryIndex = 0;
    this.groupIndex = 0;
    FqHomeCache.saveChannelIndex(index);
    this.activateDefaultFeed();
  }

  /** 当前大分类组（越界回退首组「全部」）。 */
  private currentGroup(): FqCategoryGroup {
    const groups: FqCategoryGroup[] = FQ_CHANNELS[this.channelIndex].groups;
    if (this.groupIndex > 0 && this.groupIndex < groups.length) {
      return groups[this.groupIndex];
    }
    return groups[0];
  }

  /** 分类条 Select 的选项列表（各组标签）。 */
  private categoryGroupOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const group of FQ_CHANNELS[this.channelIndex].groups) {
      const option: SelectOption = { value: group.label };
      options.push(option);
    }
    return options;
  }

  /** 大分类切换：换细分词表；若正处于分类态则回默认推荐流。 */
  private selectGroup(index: number): void {
    if (this.groupIndex === index) {
      return;
    }
    this.groupIndex = index;
    if (this.categoryIndex > 0) {
      this.loadToken += 1;
      this.categoryIndex = 0;
      this.activateDefaultFeed();
    }
  }

  /** 激活当前频道默认推荐流：内存缓存 → 磁盘持久化 → 网络重载。 */
  private activateDefaultFeed(): void {
    const index: number = this.channelIndex;
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
    // 本次会话未访问过：回退磁盘持久化列表（触底续拉/手动刷新拉新）。
    const diskItems: FqMediaItem[] = FqHomeCache.loadFeedItems(index);
    if (diskItems.length > 0) {
      const diskFeed: FqHomeFeed = new FqHomeFeed(FQ_CHANNELS[index].buildSources());
      diskFeed.continueFrom(diskItems);
      this.channelFeeds[index] = diskFeed;
      this.feed = diskFeed;
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

  /** 分类条点击：>0 = 当前组第 index 个分类词直搜该频道（同词点击不重载）。 */
  private selectCategory(index: number): void {
    if (this.categoryIndex === index) {
      return;
    }
    this.enterCategory(index);
  }

  /** 切换分类展示：0 = 频道默认推荐流；>0 = 当前组第 index 个分类词（跨组强制重载）。 */
  private enterCategory(index: number): void {
    this.loadToken += 1;
    this.categoryIndex = index;
    if (index === 0) {
      this.activateDefaultFeed();
      return;
    }
    // 分类搜索流：清空展示后加载；不写内存/磁盘频道缓存。
    this.loading = false;
    this.loadingMore = false;
    this.refreshing = false;
    this.feed = new FqHomeFeed([]);
    this.spotlightItems = [];
    this.rowSource.setItems([]);
    this.itemCount = 0;
    this.errorMsg = '';
    this.hasMore = false;
    this.scroller.scrollEdge(Edge.Top);
    this.searchBarHidden = false;
    this.loadCategoryFirst();
  }

  /** 分类流首屏：分类关键词直搜当前频道；不写 channelFeeds 与磁盘缓存。 */
  private async loadCategoryFirst(): Promise<void> {
    const token: number = ++this.loadToken;
    const channel: number = this.channelIndex;
    const categories: string[] = this.currentGroup().categories;
    if (this.categoryIndex < 1 || this.categoryIndex > categories.length) {
      return;
    }
    const category: string = categories[this.categoryIndex - 1];
    this.loading = true;
    this.loadingMore = false;
    this.errorMsg = '';
    this.feed = new FqHomeFeed(FQ_CHANNELS[channel].buildCategorySources(category));
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
      FqLog.w('home', `频道「${FQ_CHANNELS[channel].label}·${category}」分类加载失败: ${fqErrorMessage(error)}`);
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
      }
    }
  }

  /** 滚动时同步搜索条隐藏状态：完全收起后在标题栏菜单透出搜索入口。 */
  private updateSearchBarHidden(): void {
    const hidden: boolean = this.scroller.currentOffset().yOffset > FQ_SEARCH_HIDE_OFFSET;
    if (hidden !== this.searchBarHidden) {
      this.searchBarHidden = hidden;
    }
  }

  private openDetail(item: FqMediaItem): void {
    fqPushBookOrDetail(item.id, item.kind, item.title, item.cover);
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
      FqHomeCache.saveFeedItems(channel, this.feed.items());
      this.applyFeed();
      this.maybeAutoLoadMore(token);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      FqLog.w('home', `频道「${FQ_CHANNELS[channel].label}」加载失败: ${fqErrorMessage(error)}`);
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
      // 冷启动缓存态首次触底时 loadFirst 未跑过，需先确保后端就绪。
      await FqBackend.get().start(getContext(this));
      const added: number = await this.feed.loadMore();
      if (token !== this.loadToken) {
        return;
      }
      this.applyFeed();
      if (added > 0 && this.categoryIndex === 0) {
        FqHomeCache.saveFeedItems(channel, this.feed.items());
      }
      this.maybeAutoLoadMore(token);
      // 整页被去重（缓存已覆盖该页）且仍有源可拉：短延迟后自动续拉下一页。
      if (added === 0 && this.feed.hasMore) {
        setTimeout((): void => {
          if (token !== this.loadToken) {
            return;
          }
          this.loadMore();
        }, 100);
      }
    } finally {
      if (token === this.loadToken) {
        this.loadingMore = false;
      }
    }
  }
}

/**
 * 搜索页（CommonNav/HdsNavDestination）：bottomBuilder 搜索框 + 分类条 +
 * 单 List 装载历史/结果流。端点语义对齐 fqapp search_page.dart 的 _SearchCategory 与
 * ApiClient.searchTabs（/api/v1/search）。
 * 长列表使用 LazyForEach + FqMediaDataSource 懒加载。
 */

import { preferences } from '@kit.ArkData';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions, TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqHotSearchEntry, FqMediaItem, FqSearchTab } from '../../model/FqModels';
import { fqMediaIdFromSearch } from '../../core/FqParser';
import { FqMediaDataSource } from '../../core/FqMediaDataSource';
import { FqItemCard } from '../../view/FqItemCard';
import { DetailNavParams, fqPushBookOrDetail, ROUTE_DETAIL, SearchNavParams } from '../../model/FqNavModels';
import { FqShuqiBook, fqIsShuqiItem, fqShuqiIdFromSearch } from '../../model/FqShuqiModels';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { CommonSearch, CommonLoading } from '../../view/CommonCom';
import { CommonNav, titleBarOf } from '../../view/CommonNav';
import { FqMenu, FqMenuItem } from '../../view/CommonMenu';
import { selectImmersiveModifier } from '../../utils/ModifierUtils';
import { appState } from '../../entryability/AppState';
import { FqLog } from '../../core/FqLogStore';

interface FqSearchCategoryDef {
  readonly title: string;
  readonly sourceTitle: string;
  readonly tabType: number;
  readonly kind: string;
}

const FQ_SEARCH_CATEGORIES: FqSearchCategoryDef[] = [
  { title: '综合', sourceTitle: '综合', tabType: 1, kind: '' },
  { title: '小说', sourceTitle: '书籍', tabType: 3, kind: 'book' },
  { title: '短剧', sourceTitle: '短剧', tabType: 11, kind: 'video' },
  { title: '漫剧', sourceTitle: '短剧', tabType: 11, kind: 'manju' },
  { title: '漫画', sourceTitle: '漫画', tabType: 8, kind: 'manga' },
  { title: '听书', sourceTitle: '听书', tabType: 2, kind: 'audio' },
];

/** 完结状态筛选选项（0 默认 / 1 未完结 / 2 已完结）。 */
const FQ_STATUS_FILTER_LABELS: string[] = ['默认', '未完结', '已完结'];

/** 高分选项（0 默认 / 1 高分排序 / 2 8分以上 / 3 9分以上）。 */
const FQ_SCORE_FILTER_LABELS: string[] = ['默认', '高分排序', '8分以上', '9分以上'];

const HISTORY_STORE_NAME: string = 'fq_search_history';
const HISTORY_KEY: string = 'history';
const HISTORY_MAX: number = 10;

/** 标题栏 bottomBuilder 插槽高：搜索框 40 + 间距 10 + 筛选/类目行 36 + 上下 padding */
const FQ_SEARCH_BOTTOM_BUILDER_HEIGHT: number = 110;

/** 列表内容起始偏移：标题栏 56 + bottomBuilder 100 */
const FQ_SEARCH_TOP_INSET: number = 160;

/** 高分排序自动拉取上限（防极端情况无限翻页；超限后只对已加载部分排序）。 */
const FQ_SCORE_SORT_MAX_ITEMS: number = 300;

/** 「来源」菜单锚点 id（对齐书架页更多菜单模式）。 */
const FQ_SEARCH_SOURCE_ANCHOR_ID: string = 'search_source_anchor';

@ComponentV2
export struct SearchPage {
  @Local keyword: string = '';
  @Local submittedQuery: string = '';
  @Local categoryIndex: number = 0;
  @Local itemCount: number = 0;
  @Local loadingState: boolean = false;
  @Local loadingMore: boolean = false;
  @Local errorMsg: string = '';
  @Local historyChips: string[] = [];
  /** 热搜榜词条（官方 472 榜单，展示前 10 条；fqapp SearchPage._hot）。 */
  @Local hotEntries: FqHotSearchEntry[] = [];
  /** ID 精确查找模式（fqapp _idQuery）：非空表示按作品 ID 查找。 */
  @Local idQuery: string = '';
  /** 搜索来源：false 番茄 / true 书旗（fqapp _shuqiSource；只读第三方源）。 */
  @Local shuqiSource: boolean = false;
  /** 完结状态筛选下标（FQ_STATUS_FILTER_LABELS；fqapp 评分筛选的新增姊妹筛选项）。 */
  @Local statusFilterIndex: number = 0;
  /** 高分选项下标（FQ_SCORE_FILTER_LABELS；fqapp SearchScoreFilter 阈值 0/8/9 + 高分排序）。 */
  @Local scoreFilterIndex: number = 0;
  /** 切入书旗前记住的番茄分类，切回「番茄」时恢复（fqapp _fanqieTab）。 */
  private fanqieCategoryIndex: number = 0;
  private dataSource: FqMediaDataSource = new FqMediaDataSource();
  /** 已加载的原始结果（去重后原顺序），筛选/排序在视图层重投影（fqapp 筛选只作用于已加载结果）。 */
  private allItems: FqMediaItem[] = [];
  /** ID 模式查得的单条结果（切分类时本地过滤，不重新请求）。 */
  private idItem: FqMediaItem | null = null;
  private hasMore: boolean = false;
  private nextOffset: number = 0;
  private seen: Set<string> = new Set<string>();
  private loadToken: number = 0;
  /** 高分排序链式拉取进行中（防重入；切筛选/分类/来源时每轮重校验自然中断）。 */
  private scoreChainRunning: boolean = false;
  private historyStore: preferences.Preferences | null = null;
  private scroller: Scroller = new Scroller();
  /** 标题栏配置缓存：引用稳定避免每次渲染重建 HdsTitleBar 底部插槽（导致输入焦点丢失/分类条滚动复位） */
  private titleBarOp: TitleBarContentOptions = titleBarOf('搜索');

  aboutToAppear(): void {
    this.titleBarOp = titleBarOf('搜索', undefined, this.sourceMenus(), {
      builder: (): void => {
        this.SearchBar();
      },
      height: FQ_SEARCH_BOTTOM_BUILDER_HEIGHT,
    });
    // 短剧页搜索入口带入的初始类目（消费后复位；fqapp 按频道语境搜）
    if (SearchNavParams.initialCategoryIndex >= 0
      && SearchNavParams.initialCategoryIndex < FQ_SEARCH_CATEGORIES.length) {
      this.categoryIndex = SearchNavParams.initialCategoryIndex;
    }
    SearchNavParams.initialCategoryIndex = -1;
    this.initHistory();
    this.loadHotSearch();
  }

  build() {
    CommonNav({
      titleBarOp: this.titleBarOp,
      scroller: this.scroller,
      doubleTapToTop: true,
      isSearchBarScroller: false,
    }) {
      Stack({ alignContent: Alignment.Top }) {
        List({ space: 0, scroller: this.scroller }) {
        if (this.idQuery.length > 0 && this.submittedQuery.length > 0) {
          ListItem() {
            Row() {
              Text('按作品 ID 查找')
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
              Blank()
              Text('按关键词搜索')
                .fontSize(13)
                .fontColor(appState.accentColor)
                .onClick(() => this.searchAsKeyword())
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 4 })
            .alignItems(VerticalAlign.Center)
          }
        }
        if (this.submittedQuery.length === 0) {
          ListItem() {
            this.HistoryView()
          }
          ListItem() {
            this.HotSearchView()
          }
        } else if (this.errorMsg.length > 0 && this.itemCount === 0) {
          ListItem() {
            Column({ space: 12 }) {
              Text(this.errorMsg)
                .fontSize(14)
                .fontColor($r('sys.color.font_tertiary'))
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Button('重试')
                .backgroundColor(appState.accentColor)
                .onClick(() => this.submit())
            }
            .width('100%')
            .padding({ top: 48 })
            .alignItems(HorizontalAlign.Center)
          }
        } else if (this.itemCount === 0 && this.loadingState) {
          ListItem() {
            Column() {
              CommonLoading({ sizeValue: 36, loadColor: appState.accentColor })
            }
            .width('100%')
            .padding({ top: 64 })
            .alignItems(HorizontalAlign.Center)
          }
        } else if (this.itemCount === 0 && !this.loadingState) {
          ListItem() {
            Column({ space: 12 }) {
              Text(this.idQuery.length > 0 ? '未找到该 ID 对应的作品'
                : this.filtersActive() && this.allItems.length > 0 ? '已加载结果中暂无符合筛选的作品'
                : '没有找到相关内容')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              if (this.filtersActive() && this.allItems.length > 0) {
                Row({ space: 10 }) {
                  if (this.hasMore) {
                    Button('加载更多')
                      .fontSize(13)
                      .backgroundColor($r('sys.color.comp_background_tertiary'))
                      .fontColor($r('sys.color.font_primary'))
                      .onClick(() => this.loadMore())
                  }
                  Button('清除筛选')
                    .fontSize(13)
                    .backgroundColor(appState.accentColor)
                    .onClick(() => this.clearFilters())
                }
                .alignItems(VerticalAlign.Center)
              }
            }
            .width('100%')
            .padding({ top: 48 })
            .alignItems(HorizontalAlign.Center)
          }
        } else {
          LazyForEach(this.dataSource, (item: FqMediaItem) => {
            ListItem() {
              FqItemCard({
                item: item,
                onItemClick: (clicked: FqMediaItem): void => {
                  this.openDetail(clicked);
                },
              })
            }
          }, (item: FqMediaItem): string => `${item.kind}:${item.id}`)
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
    /*  .divider({
        strokeWidth: 0.5,
        color: $r('sys.color.comp_divider'),
        startMargin: 103,
        endMargin: 16,
      })*/
      .contentStartOffset(appState.topRect + FQ_SEARCH_TOP_INSET)
      .contentEndOffset(appState.bottomRect + 60)
      .onReachEnd(() => this.loadMore())

        // 「来源」菜单锚点（对齐书架页更多按钮：右缘 16、垂直居中于 56 高标题栏）
        Row() {
          Column()
            .id(FQ_SEARCH_SOURCE_ANCHOR_ID)
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

  /** 标题栏 bottomBuilder：搜索输入（可聚焦）+ 分类条。 */
  @Builder
  private SearchBar() {
    Column({ space: 10 }) {
      CommonSearch({
        searchValue: this.keyword,
        placeholderValue: '搜索书名 / 作者 / ID',
        isFocusable: true,
        focusId: 'search_page_input',
        submit: (content: string, event: SubmitEvent): void => {
          this.keyword = content;
          this.submit();
        },
        change: (value: string): void => {
          this.keyword = value;
          // 输入清空回到发现区（fqapp _onQueryChanged 空词 → _showHistory）
          if (value.trim().length === 0 && this.submittedQuery.length > 0) {
            this.backToDiscovery();
          }
        },
        didDelete: (): void => {
          this.keyword = '';
          if (this.submittedQuery.length > 0) {
            this.backToDiscovery();
          }
        },
        click: (): void => {
        },
      })
      this.CategoryStrip()
    }
    .padding({ left: 16, right: 16, top: 2, bottom: 10 })
  }

  /** 完结状态筛选 Select（样式对齐分类弹窗类目 Select；ID 直查模式禁用；未选择显示「状态」）。 */
  @Builder
  private StatusFilterSelect() {
    Select(this.statusFilterOptions())
      .value(this.statusFilterIndex === 0 ? '状态' : FQ_STATUS_FILTER_LABELS[this.statusFilterIndex])
      .selected(this.statusFilterIndex)
      .font({ size: 15, weight: FontWeight.Medium })
      .fontColor($r('sys.color.font_primary'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Medium })
      .selectedOptionFontColor(appState.accentColor)
      .optionFont({ size: 15 })
      .optionFontColor($r('sys.color.font_primary'))
      .backgroundColor(Color.Transparent)
      .height(36)
      .padding({ left: 0, right: 0 })
      .onSelect((index: number, text: string) => {
        this.selectStatusFilter(index);
      })
      .attributeModifier(selectImmersiveModifier)
      .enabled(this.idQuery.length === 0)
      .opacity(this.idQuery.length > 0 ? 0.4 : 1)
  }

  /** 高分选项 Select（高分排序 + 8/9 分阈值；ID 直查模式禁用；未选择显示「评分」）。 */
  @Builder
  private ScoreFilterSelect() {
    Select(this.scoreFilterOptions())
      .value(this.scoreFilterIndex === 0 ? '评分' : FQ_SCORE_FILTER_LABELS[this.scoreFilterIndex])
      .selected(this.scoreFilterIndex)
      .font({ size: 15, weight: FontWeight.Medium })
      .fontColor($r('sys.color.font_primary'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Medium })
      .selectedOptionFontColor(appState.accentColor)
      .optionFont({ size: 15 })
      .optionFontColor($r('sys.color.font_primary'))
      .backgroundColor(Color.Transparent)
      .height(36)
      .padding({ left: 0, right: 0 })
      .onSelect((index: number, text: string) => {
        this.selectScoreFilter(index);
      })
      .attributeModifier(selectImmersiveModifier)
      .enabled(this.idQuery.length === 0)
      .opacity(this.idQuery.length > 0 ? 0.4 : 1)
  }

  /** 完结状态筛选选项。 */
  private statusFilterOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const label of FQ_STATUS_FILTER_LABELS) {
      const option: SelectOption = { value: label };
      options.push(option);
    }
    return options;
  }

  /** 高分选项。 */
  private scoreFilterOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const label of FQ_SCORE_FILTER_LABELS) {
      const option: SelectOption = { value: label };
      options.push(option);
    }
    return options;
  }

  /** 筛选/类目行：状态 + 评分两个 Select 在前，类目 List 其后（放不下时横向滚动）。
   *  高分 Select 书旗源隐藏（书旗无评分，fqapp「不提供评分」）；书旗下类目置灰不可点。 */
  @Builder
  private CategoryStrip() {
    Row({ space: 6 }) {
      this.StatusFilterSelect()
      if (!this.shuqiSource) {
        this.ScoreFilterSelect()
      }
      List({ space: 22 }) {
        ForEach(FQ_SEARCH_CATEGORIES, (category: FqSearchCategoryDef, index: number) => {
          ListItem() {
            Text(category.title)
              .fontSize(15)
              .fontWeight(this.categoryWeight(index))
              .fontColor(this.categoryColor(index))
              .padding({ top: 6, bottom: 6 })
              .onClick(() => this.selectCategory(index))
          }
        }, (category: FqSearchCategoryDef): string => category.title)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .layoutWeight(1)
      .height(36)
      .alignListItem(ListItemAlign.Center)
      .padding({ left: 8, right: 8 })
      .opacity(this.shuqiSource ? 0.4 : 1)
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(30) })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 标题栏「来源」菜单按钮（对齐书架页更多按钮模式）。 */
  private sourceMenus(): Array<HdsNavigationMenuItemOptions> {
    const menu: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.dot_grid_2x2'),
        label: '来源',
        action: (): void => {
          this.openSourceMenu();
        },
      },
    };
    return [menu];
  }

  /** 搜索来源菜单（书架页 FqMenu 模式）：番茄/书旗两档，当前档尾勾标识。 */
  private openSourceMenu(): void {
    const items: Array<FqMenuItem> = [];

    const fanqieItem = new FqMenuItem();
    fanqieItem.label = '番茄小说';
    fanqieItem.endIcon = !this.shuqiSource ? $r('sys.symbol.checkmark') : '';
    fanqieItem.onAction = (): void => {
      FqMenu.dismiss();
      this.selectSource(false);
    };
    items.push(fanqieItem);

    const shuqiItem = new FqMenuItem();
    shuqiItem.label = '书旗小说';
    shuqiItem.endIcon = this.shuqiSource ? $r('sys.symbol.checkmark') : '';
    shuqiItem.onAction = (): void => {
      FqMenu.dismiss();
      this.selectSource(true);
    };
    items.push(shuqiItem);

    FqMenu.open(this.getUIContext(), FQ_SEARCH_SOURCE_ANCHOR_ID, items);
  }

  @Builder
  private HistoryView() {
    if (this.historyChips.length > 0) {
      Column({ space: 12 }) {
        Row() {
          Text('搜索历史')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_tertiary'))
          Blank()
          Text('清空')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .onClick(() => this.clearHistory())
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.historyChips, (entry: string) => {
            Text(entry)
              .fontSize(13)
              .fontColor($r('sys.color.font_primary'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.keyword = entry;
                this.submit();
              })
          }, (entry: string): string => entry)
        }
        .width('100%')
      }
      .padding(16)
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 热搜榜（fqapp SearchDiscoveryView）：历史记录下方，行高 44，前三名强调色，点击即搜；书旗来源无番茄热搜，隐藏。 */
  @Builder
  private HotSearchView() {
    if (this.hotEntries.length > 0 && !this.shuqiSource) {
      Column() {
        Row() {
          Text('热搜榜')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')

        ForEach(this.hotEntries, (entry: FqHotSearchEntry, index: number) => {
          Row() {
            Text(`${index + 1}`)
              .fontSize(index < 3 ? 16 : 14)
              .fontWeight(index < 3 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(index < 3 ? appState.accentColor : $r('sys.color.font_secondary'))
              .width(28)
              .textAlign(TextAlign.Center)
            Text(entry.title)
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (entry.badge.length > 0) {
              Text(entry.badge)
                .fontSize(10)
                .fontColor($r('sys.color.font_secondary'))
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .margin({ left: 6, right: 6 })
            }
            if (entry.hotValue.length > 0) {
              Text(entry.hotValue)
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'))
            }
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.keyword = entry.title;
            this.submit();
          })
        }, (entry: FqHotSearchEntry): string => `${entry.title}:${entry.badge}`)
      }
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 热搜榜加载：页面出现时一次，失败静默（fqapp _loadHotSearch 返回 HotSearch.empty）。 */
  private async loadHotSearch(): Promise<void> {
    try {
      await FqBackend.get().start(getContext(this));
      const entries: FqHotSearchEntry[] = await FqBackend.get().hotSearch();
      this.hotEntries = entries.slice(0, 10);
    } catch (error) {
      FqLog.w('search', `热搜榜加载失败: ${fqErrorMessage(error)}`);
    }
  }

  private categoryWeight(index: number): FontWeight {
    return this.categoryIndex === index ? FontWeight.Bold : FontWeight.Normal;
  }

  private categoryColor(index: number): ResourceColor {
    return this.categoryIndex === index ? appState.accentColor : $r('sys.color.font_secondary');
  }

  private selectCategory(index: number): void {
    // 书旗来源下分类条置灰不可点，退出书旗只能点「番茄」（fqapp _selectTab）
    if (this.shuqiSource) {
      return;
    }
    if (this.categoryIndex === index) {
      return;
    }
    this.categoryIndex = index;
    this.resetFeed();
    if (this.idQuery.length > 0) {
      this.applyIdItem();
      return;
    }
    this.load();
  }

  /**
   * 切换搜索来源（fqapp _selectSource）。进入书旗时记住当前番茄分类并清掉
   * 作品 ID 状态；点回「番茄」恢复那个分类，避免用户被悄悄重置到综合。
   */
  private selectSource(shuqi: boolean): void {
    if (shuqi === this.shuqiSource) {
      return;
    }
    if (shuqi) {
      this.fanqieCategoryIndex = this.categoryIndex;
      // 书旗源无评分：高分 Select 隐藏，选项同步回「评分」，避免隐形过滤清空结果
      this.scoreFilterIndex = 0;
    }
    this.shuqiSource = shuqi;
    this.categoryIndex = shuqi ? 0 : this.fanqieCategoryIndex;
    // 书旗 id 是另一套命名空间，切来源后 ID 提示与 ID 结果都失效
    this.idQuery = '';
    this.idItem = null;
    this.resetFeed();
    if (this.submittedQuery.length === 0) {
      return;
    }
    if (shuqi) {
      this.loadShuqi();
    } else {
      this.load();
    }
  }

  private resetFeed(): void {
    this.dataSource.reset();
    this.allItems = [];
    this.itemCount = 0;
    this.errorMsg = '';
    this.seen.clear();
    this.nextOffset = 0;
    this.hasMore = false;
    this.loadToken += 1;
  }

  // ----- 筛选/排序（视图层重投影，fqapp 筛选只作用于已加载结果） -----

  /** 完结状态筛选是否生效。 */
  private filtersActive(): boolean {
    return this.statusFilterIndex > 0 || (this.scoreFilterIndex > 0 && !this.shuqiSource);
  }

  /** 完结状态筛选：未完结/已完结均要求已知状态，未知（-1）不计入。 */
  private matchesStatusFilter(item: FqMediaItem): boolean {
    if (this.statusFilterIndex === 1) {
      return item.creationStatus === 1;
    }
    if (this.statusFilterIndex === 2) {
      return item.creationStatus === 0;
    }
    return true;
  }

  /** 高分筛选：8/9 分阈值不计未评分（score 0；fqapp「未评分作品不计入」）。 */
  private matchesScoreFilter(item: FqMediaItem): boolean {
    if (this.scoreFilterIndex === 2) {
      return item.score >= 8;
    }
    if (this.scoreFilterIndex === 3) {
      return item.score >= 9;
    }
    return true;
  }

  /** allItems 按当前筛选/排序重投影进 dataSource；ID 直查模式不过滤（fqapp 评分筛选 ID 模式禁用）。 */
  private applyFilters(): void {
    const view: FqMediaItem[] = [];
    if (this.idQuery.length > 0) {
      for (const item of this.allItems) {
        view.push(item);
      }
    } else {
      for (const item of this.allItems) {
        if (!this.matchesStatusFilter(item)) {
          continue;
        }
        if (!this.matchesScoreFilter(item)) {
          continue;
        }
        view.push(item);
      }
      if (this.scoreFilterIndex === 1 && !this.shuqiSource) {
        // 高分排序：分数降序，同分保持原顺序（稳定排序）
        view.sort((left: FqMediaItem, right: FqMediaItem): number => right.score - left.score);
      }
    }
    this.dataSource.reset();
    this.dataSource.append(view);
    this.itemCount = this.dataSource.totalCount();
  }

  private selectStatusFilter(index: number): void {
    if (this.statusFilterIndex === index) {
      return;
    }
    this.statusFilterIndex = index;
    this.applyFilters();
  }

  private selectScoreFilter(index: number): void {
    if (this.scoreFilterIndex === index) {
      return;
    }
    this.scoreFilterIndex = index;
    this.applyFilters();
    // 高分排序要求全量结果：已加载的可能只是前几页，自动链式拉完剩余分页（加载中有指示）
    if (index === 1 && this.hasMore && !this.loadingState && !this.scoreChainRunning) {
      this.loadAllForScoreSort();
    }
  }

  /** 清空筛选（空态「清除筛选」按钮）。 */
  private clearFilters(): void {
    this.statusFilterIndex = 0;
    this.scoreFilterIndex = 0;
    this.applyFilters();
  }

  private submit(): void {
    const query: string = this.keyword.trim();
    if (query.length === 0) {
      return;
    }
    this.submittedQuery = query;
    // ID 识别（fqapp mediaIdFromSearch）：番茄 `id:` 前缀显式或 15~20 位纯数字；
    // 书旗仅认 `id:` 前缀（bookId 短、无长度特征，纯数字由 loadShuqi 做「直查置顶+关键词」合并）
    const mediaId: string | null = this.shuqiSource ? fqShuqiIdFromSearch(query) : fqMediaIdFromSearch(query);
    this.idQuery = mediaId !== null ? mediaId : '';
    this.idItem = null;
    this.resetFeed();
    if (this.idQuery.length > 0) {
      this.loadId();
    } else if (this.shuqiSource) {
      this.loadShuqi();
    } else {
      this.load();
    }
    this.recordHistory(query);
  }

  /** ID 模式切回关键词搜索（fqapp asKeyword）。 */
  private searchAsKeyword(): void {
    this.idQuery = '';
    this.idItem = null;
    this.resetFeed();
    if (this.shuqiSource) {
      this.loadShuqi();
    } else {
      this.load();
    }
  }

  /** 输入清空回到发现区（fqapp _showHistory）：重置查询态，恢复历史+热搜榜。 */
  private backToDiscovery(): void {
    this.submittedQuery = '';
    this.idQuery = '';
    this.idItem = null;
    this.resetFeed();
  }

  /** ID 精确查找（fqapp _loadId/lookupMediaById）：单条结果，无分页；书旗走详情端点直查。 */
  private async loadId(): Promise<void> {
    const id: string = this.idQuery;
    if (id.length === 0) {
      return;
    }
    const token: number = ++this.loadToken;
    const category: FqSearchCategoryDef = FQ_SEARCH_CATEGORIES[this.categoryIndex];
    this.loadingState = true;
    this.loadingMore = false;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const item: FqMediaItem | null = this.shuqiSource
        ? await this.lookupShuqiById(id)
        : await FqBackend.get().lookupMediaById(id);
      if (token !== this.loadToken) {
        return;
      }
      this.idItem = item;
      const fresh: FqMediaItem[] = [];
      if (item !== null && item.id.length > 0
        && (category.kind.length === 0 || item.kind === category.kind)) {
        fresh.push(item);
      }
      this.allItems = this.allItems.concat(fresh);
      this.applyFilters();
      this.hasMore = false;
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loadingState = false;
        this.loadingMore = false;
      }
    }
  }

  /** ID 模式切分类：仅按类型过滤已查得的单条结果（不重新请求）。 */
  private applyIdItem(): void {
    const category: FqSearchCategoryDef = FQ_SEARCH_CATEGORIES[this.categoryIndex];
    const item: FqMediaItem | null = this.idItem;
    const fresh: FqMediaItem[] = [];
    if (item !== null && (category.kind.length === 0 || item.kind === category.kind)) {
      fresh.push(item);
    }
    this.allItems = fresh;
    this.applyFilters();
  }

  /** 书旗搜索（fqapp _searchShuqi）：单次返回全量、无分页，结果全量落当前 feed。
   *  纯数字查询并行做 ID 直查命中置顶（书旗 bookId 短、无长度特征，数字书名仍可关键词搜到）。 */
  private async loadShuqi(): Promise<void> {
    const query: string = this.submittedQuery;
    if (query.length === 0) {
      return;
    }
    const token: number = ++this.loadToken;
    this.loadingState = true;
    this.loadingMore = false;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const searchTask: Promise<FqMediaItem[]> = FqBackend.get().shuqiSearch(query);
      const directTask: Promise<FqMediaItem | null> = /^[0-9]+$/.test(query) && /[1-9]/.test(query)
        ? this.lookupShuqiById(query).catch((): FqMediaItem | null => null)
        : Promise.resolve<FqMediaItem | null>(null);
      const direct: FqMediaItem | null = await directTask;
      const items: FqMediaItem[] = await searchTask;
      if (token !== this.loadToken) {
        return;
      }
      const fresh: FqMediaItem[] = [];
      if (direct !== null && direct.id.length > 0) {
        this.seen.add(`${direct.kind}:${direct.id}`);
        fresh.push(direct);
      }
      for (const item of items) {
        if (item.id.length === 0) {
          continue;
        }
        const key: string = `${item.kind}:${item.id}`;
        if (this.seen.has(key)) {
          continue;
        }
        this.seen.add(key);
        fresh.push(item);
      }
      this.allItems = this.allItems.concat(fresh);
      this.applyFilters();
      this.hasMore = false;
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      FqLog.w('search', `书旗搜索「${query}」加载失败: ${fqErrorMessage(error)}`);
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loadingState = false;
        this.loadingMore = false;
      }
    }
  }

  /** 书旗 ID 直查：纯数字 bookId 走详情端点转搜索卡片；格式无效或不命中返回 null，网络错误照抛。 */
  private async lookupShuqiById(id: string): Promise<FqMediaItem | null> {
    if (!/^[0-9]+$/.test(id) || !/[1-9]/.test(id)) {
      return null;
    }
    const book: FqShuqiBook = await FqBackend.get().shuqiBook(id);
    return book.bookId.length > 0 ? book.toMediaItem() : null;
  }

  private loadMore(): void {
    if (this.idQuery.length > 0 || !this.hasMore || this.loadingMore || this.loadingState) {
      return;
    }
    this.load();
  }

  private async load(): Promise<void> {
    const query: string = this.submittedQuery;
    if (query.length === 0) {
      return;
    }
    const token: number = ++this.loadToken;
    const category: FqSearchCategoryDef = FQ_SEARCH_CATEGORIES[this.categoryIndex];
    const offset: number = this.nextOffset;
    this.loadingState = true;
    this.loadingMore = offset > 0;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const tabs: FqSearchTab[] = await FqBackend.get().searchTabs(query, category.tabType, offset);
      if (token !== this.loadToken) {
        return;
      }
      let page: FqSearchTab | null = null;
      for (const tab of tabs) {
        if (tab.title === category.title) {
          page = tab;
          break;
        }
      }
      if (page === null) {
        for (const tab of tabs) {
          if (tab.title === category.sourceTitle) {
            page = tab;
            break;
          }
        }
      }
      if (page === null) {
        page = new FqSearchTab(category.title, [], false, offset);
      }
      const fresh: FqMediaItem[] = [];
      for (const item of page.items) {
        if (item.id.length === 0) {
          continue;
        }
        if (category.kind.length > 0 && item.kind !== category.kind) {
          continue;
        }
        const key: string = `${item.kind}:${item.id}`;
        if (this.seen.has(key)) {
          continue;
        }
        this.seen.add(key);
        fresh.push(item);
      }
      this.allItems = this.allItems.concat(fresh);
      this.applyFilters();
      const next: number = page.nextOffset;
      this.hasMore = page.hasMore && next > offset;
      if (this.hasMore) {
        this.nextOffset = next;
      }
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      FqLog.w('search', `搜索「${query}」(${category.title})加载失败: ${fqErrorMessage(error)}`);
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loadingState = false;
        this.loadingMore = false;
      }
    }
    // 高分排序激活且还有下一页：自动链式拉完全部分页再全局排序（首搜/加载更多后兜底触发）
    if (token === this.loadToken && this.scoreFilterIndex === 1 && !this.shuqiSource
      && this.idQuery.length === 0 && this.hasMore && this.errorMsg.length === 0
      && this.allItems.length < FQ_SCORE_SORT_MAX_ITEMS) {
      this.loadAllForScoreSort();
    }
  }

  /** 高分排序链式拉取：逐页 load() 直到拉完（或达上限/出错/被切换中断），每轮重校验状态；
   *  复用 load() 的 loadingMore 指示与 loadToken 并发保护。 */
  private async loadAllForScoreSort(): Promise<void> {
    if (this.scoreChainRunning || this.idQuery.length > 0 || this.shuqiSource
      || this.scoreFilterIndex !== 1) {
      return;
    }
    this.scoreChainRunning = true;
    try {
      while (this.scoreFilterIndex === 1 && this.hasMore && this.errorMsg.length === 0
        && this.allItems.length < FQ_SCORE_SORT_MAX_ITEMS) {
        const before: number = this.allItems.length;
        await this.load();
        if (this.allItems.length === before) {
          break;
        }
      }
    } finally {
      this.scoreChainRunning = false;
    }
  }

  private openDetail(item: FqMediaItem): void {
    // 书旗条目复用详情页（shuqi 标记走只读加载链路）；番茄条目照旧分流
    if (fqIsShuqiItem(item)) {
      DetailNavParams.id = item.id;
      DetailNavParams.kind = 'book';
      DetailNavParams.title = item.title;
      DetailNavParams.cover = item.cover;
      DetailNavParams.shuqi = true;
      NavPathUtils.push(ROUTE_DETAIL);
      return;
    }
    fqPushBookOrDetail(item.id, item.kind, item.title, item.cover);
  }

  // ----- 搜索历史（preferences） -----

  private async initHistory(): Promise<void> {
    try {
      this.historyStore = await preferences.getPreferences(getContext(this), HISTORY_STORE_NAME);
      const raw: preferences.ValueType = await this.historyStore.get(HISTORY_KEY, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: Object = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          const entries: string[] = [];
          for (const value of parsed as Object[]) {
            if (typeof value === 'string' && value.length > 0) {
              entries.push(value);
            }
          }
          this.historyChips = entries;
        }
      }
    } catch (error) {
      this.historyChips = [];
    }
  }

  private recordHistory(query: string): void {
    const entries: string[] = [];
    entries.push(query);
    for (const entry of this.historyChips) {
      if (entry !== query && entries.length < HISTORY_MAX) {
        entries.push(entry);
      }
    }
    this.historyChips = entries;
    const store: preferences.Preferences | null = this.historyStore;
    if (store !== null) {
      store.put(HISTORY_KEY, JSON.stringify(entries));
      store.flush();
    }
  }

  private clearHistory(): void {
    this.historyChips = [];
    const store: preferences.Preferences | null = this.historyStore;
    if (store !== null) {
      store.delete(HISTORY_KEY);
      store.flush();
    }
  }
}

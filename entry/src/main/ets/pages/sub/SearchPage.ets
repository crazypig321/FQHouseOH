/**
 * 搜索页（CommonNav/HdsNavDestination）：bottomBuilder 搜索框 + 分类条 +
 * 单 List 装载历史/结果流。端点语义对齐 fqapp search_page.dart 的 _SearchCategory 与
 * ApiClient.searchTabs（/api/v1/search）。
 * 长列表使用 LazyForEach + FqMediaDataSource 懒加载。
 */

import { preferences } from '@kit.ArkData';
import { HdsNavigationMenuItemOptions, TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqHotSearchEntry, FqMediaItem, FqSearchTab } from '../../model/FqModels';
import { fqMediaIdFromSearch } from '../../core/FqParser';
import { FqMediaDataSource } from '../../core/FqMediaDataSource';
import { FqItemCard } from '../../view/FqItemCard';
import { DetailNavParams, fqPushBookOrDetail, ROUTE_DETAIL } from '../../model/FqNavModels';
import { fqIsShuqiItem } from '../../model/FqShuqiModels';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { CommonSearch, CommonLoading } from '../../view/CommonCom';
import { CommonNav, titleBarOf } from '../../view/CommonNav';
import { FqMenu, FqMenuItem } from '../../view/CommonMenu';
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

const HISTORY_STORE_NAME: string = 'fq_search_history';
const HISTORY_KEY: string = 'history';
const HISTORY_MAX: number = 10;

/** 标题栏 bottomBuilder 插槽高：搜索框 40 + 间距 10 + 分类条 33 + 上下 padding 12 */
const FQ_SEARCH_BOTTOM_BUILDER_HEIGHT: number = 110;

/** 列表内容起始偏移：标题栏 56 + bottomBuilder 96 */
const FQ_SEARCH_TOP_INSET: number = 160;

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
  /** 切入书旗前记住的番茄分类，切回「番茄」时恢复（fqapp _fanqieTab）。 */
  private fanqieCategoryIndex: number = 0;
  private dataSource: FqMediaDataSource = new FqMediaDataSource();
  /** ID 模式查得的单条结果（切分类时本地过滤，不重新请求）。 */
  private idItem: FqMediaItem | null = null;
  private hasMore: boolean = false;
  private nextOffset: number = 0;
  private seen: Set<string> = new Set<string>();
  private loadToken: number = 0;
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
            Column() {
              Text(this.idQuery.length > 0 ? '未找到该 ID 对应的作品' : '没有找到相关内容')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
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

  @Builder
  private CategoryStrip() {
    Scroll() {
      Row({ space: 2 }) {
        ForEach(FQ_SEARCH_CATEGORIES, (category: FqSearchCategoryDef, index: number) => {
          Text(category.title)
            .fontSize(15)
            .fontWeight(this.categoryWeight(index))
            .fontColor(this.categoryColor(index))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => this.selectCategory(index))
        }, (category: FqSearchCategoryDef): string => category.title)
      }
      .padding({ left: 8, right: 8 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .opacity(this.shuqiSource ? 0.4 : 1)
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
    this.itemCount = 0;
    this.errorMsg = '';
    this.seen.clear();
    this.nextOffset = 0;
    this.hasMore = false;
    this.loadToken += 1;
  }

  private submit(): void {
    const query: string = this.keyword.trim();
    if (query.length === 0) {
      return;
    }
    this.submittedQuery = query;
    // ID 识别（fqapp mediaIdFromSearch）：`id:` 前缀显式或 15~20 位纯数字；
    // 书旗 id 是另一套命名空间，按 id 直查不适用（fqapp _search）
    const mediaId: string | null = this.shuqiSource ? null : fqMediaIdFromSearch(query);
    this.idQuery = mediaId !== null ? mediaId : '';
    this.idItem = null;
    this.resetFeed();
    if (this.shuqiSource) {
      this.loadShuqi();
    } else if (this.idQuery.length > 0) {
      this.loadId();
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
    this.load();
  }

  /** 输入清空回到发现区（fqapp _showHistory）：重置查询态，恢复历史+热搜榜。 */
  private backToDiscovery(): void {
    this.submittedQuery = '';
    this.idQuery = '';
    this.idItem = null;
    this.resetFeed();
  }

  /** ID 精确查找（fqapp _loadId/lookupMediaById）：单条结果，无分页。 */
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
      const item: FqMediaItem | null = await FqBackend.get().lookupMediaById(id);
      if (token !== this.loadToken) {
        return;
      }
      this.idItem = item;
      const fresh: FqMediaItem[] = [];
      if (item !== null && item.id.length > 0
        && (category.kind.length === 0 || item.kind === category.kind)) {
        fresh.push(item);
      }
      this.dataSource.append(fresh);
      this.itemCount = this.dataSource.totalCount();
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
    this.dataSource.append(fresh);
    this.itemCount = this.dataSource.totalCount();
  }

  /** 书旗搜索（fqapp _searchShuqi）：单次返回全量、无分页，结果全量落当前 feed。 */
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
      const items: FqMediaItem[] = await FqBackend.get().shuqiSearch(query);
      if (token !== this.loadToken) {
        return;
      }
      const fresh: FqMediaItem[] = [];
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
      this.dataSource.append(fresh);
      this.itemCount = this.dataSource.totalCount();
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
      this.dataSource.append(fresh);
      this.itemCount = this.dataSource.totalCount();
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

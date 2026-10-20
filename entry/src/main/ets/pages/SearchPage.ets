/**
 * 搜索页（CommonNav/HdsNavDestination）：bottomBuilder 搜索框 + 分类条 +
 * 单 List 装载历史/结果流。端点语义对齐 fqapp search_page.dart 的 _SearchCategory 与
 * ApiClient.searchTabs（/api/v1/search）。
 * 长列表使用 LazyForEach + FqMediaDataSource 懒加载。
 */

import { preferences } from '@kit.ArkData';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqMediaItem, FqSearchTab } from '../model/FqModels';
import { FqMediaDataSource } from '../core/FqMediaDataSource';
import { FqItemCard } from '../component/FqItemCard';
import { DetailNavParams, FqTitleBarOptions, ROUTE_DETAIL } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { CommonSearch, FQ_ACCENT, CommonLoading } from '../view/CommonCom';
import { CommonNav } from '../view/CommonNav';
import { appState } from '../entryability/AppState';

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
const FQ_SEARCH_BOTTOM_BUILDER_HEIGHT: number = 96;

/** 列表内容起始偏移：标题栏 56 + bottomBuilder 96 */
const FQ_SEARCH_TOP_INSET: number = 152;

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
  private dataSource: FqMediaDataSource = new FqMediaDataSource();
  private hasMore: boolean = false;
  private nextOffset: number = 0;
  private seen: Set<string> = new Set<string>();
  private loadToken: number = 0;
  private historyStore: preferences.Preferences | null = null;
  private scroller: Scroller = new Scroller();
  /** 标题栏配置缓存：引用稳定避免每次渲染重建 HdsTitleBar 底部插槽（导致输入焦点丢失/分类条滚动复位） */
  private titleBarOp: TitleBarContentOptions = FqTitleBarOptions('搜索', false, {
    builder: (): void => {
      this.SearchBar();
    },
    height: FQ_SEARCH_BOTTOM_BUILDER_HEIGHT,
  });

  aboutToAppear(): void {
    this.initHistory();
  }

  build() {
    CommonNav({
      titleBarOp: this.titleBarOp,
      scroller: this.scroller,
      doubleTapToTop: true,
      isSearchBarScroller: false,
    }) {
      List({ space: 0, scroller: this.scroller }) {
        if (this.submittedQuery.length === 0) {
          ListItem() {
            this.HistoryView()
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
                .backgroundColor('#FF7A3D')
                .onClick(() => this.submit())
            }
            .width('100%')
            .padding({ top: 48 })
            .alignItems(HorizontalAlign.Center)
          }
        } else if (this.itemCount === 0 && !this.loadingState) {
          ListItem() {
            Column() {
              Text('没有找到相关内容')
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
                CommonLoading({ sizeValue: 20, loadColor: FQ_ACCENT })
                Text('加载中…')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding(12)
            }
          }
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 0.5,
        color: $r('sys.color.comp_divider'),
        startMargin: 16,
        endMargin: 16,
      })
      .contentStartOffset(appState.topRect + FQ_SEARCH_TOP_INSET)
      .contentEndOffset(appState.bottomRect + 60)
      .onReachEnd(() => this.loadMore())
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
        },
        didDelete: (): void => {
          this.keyword = '';
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

  private categoryWeight(index: number): FontWeight {
    return this.categoryIndex === index ? FontWeight.Bold : FontWeight.Normal;
  }

  private categoryColor(index: number): ResourceColor {
    return this.categoryIndex === index ? '#FF7A3D' : $r('sys.color.font_secondary');
  }

  private selectCategory(index: number): void {
    if (this.categoryIndex === index) {
      return;
    }
    this.categoryIndex = index;
    this.resetFeed();
    this.load();
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
    this.resetFeed();
    this.load();
    this.recordHistory(query);
  }

  private loadMore(): void {
    if (!this.hasMore || this.loadingMore || this.loadingState) {
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
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const tabs: FqSearchTab[] = await FqBackend.get().searchTabs(query, category.tabType, offset);
      if (token !== this.loadToken) {
        return;
      }
      let page: FqSearchTab | null = null;
      for (const tab of tabs) {
        if (tab.title === category.sourceTitle || tab.title === category.title) {
          page = tab;
          break;
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
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loadingState = false;
        this.loadingMore = false;
      }
    }
  }

  private openDetail(item: FqMediaItem): void {
    DetailNavParams.id = item.id;
    DetailNavParams.kind = item.kind;
    DetailNavParams.title = item.title;
    DetailNavParams.cover = item.cover;
    NavPathUtils.push(ROUTE_DETAIL);
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

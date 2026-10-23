/**
 * 公共页面装配（对齐 musicfreeOH AppPages 模式）：
 * - MainTabPagesBuilder：主 TabContent（首页/书架/我的）
 * - PageMapBuilder：二级路由页（Navigation.navDestination 单 builder 页表）
 */

import { MENU_CONFIG, MenuItem, tabBarSymbolOf } from '../model/FqTabsModels';
import { ROUTE_DETAIL, ROUTE_RANK, ROUTE_READER2, ROUTE_SEARCH, ROUTE_AUTHOR, ROUTE_LISTEN, FqTitleBarOptions, DetailNavParams } from '../model/FqNavModels';
import { HomePage } from '../pages/HomePage';
import { SearchPage } from '../pages/SearchPage';
import { DetailPage } from '../pages/DetailPage';
import { RankPage } from '../pages/RankPage';
import { AuthorPage } from '../pages/AuthorPage';
import { ReaderPage } from '../reader/ReaderPage'
import { ListenPage } from '../pages/ListenPage';
import { CommonNav, titleBarOf } from './CommonNav';
import { FQ_ACCENT, CommonSearch } from './CommonCom';
import { FqMenu, FqMenuItem } from './CommonMenu';
import { FqShelfStore, FqShelfItem } from '../core/FqShelfStore';
import { FqBrowseStore, FqBrowseItem } from '../core/FqBrowseStore';
import { FqMediaItem } from '../model/FqModels';
import { FqMediaCard } from '../component/FqMediaCard';
import { NavPathUtils } from '../utils/NavPathUtils';
import { appState } from '../entryability/AppState';
import { rowImmersiveModifier, stackImmersiveModifier } from '../utils/ModifierUtils';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';

const TAB_ACCENT: string = '#FF7A3D';

/** 书架页「更多」菜单锚点 id */
const SHELF_MORE_ANCHOR_ID: string = 'shelf_more_anchor';
/** 书架页搜索框焦点 id（须与 SearchBar 中 CommonSearch focusId 一致） */
const SHELF_SEARCH_FOCUS_ID: string = 'shelf_page_search';

function tabBarOf(item: MenuItem): BottomTabBarStyle {
  const style: BottomTabBarStyle = new BottomTabBarStyle(tabBarSymbolOf(item), item.label);
  style.labelStyle({ selectedColor: TAB_ACCENT });
  return style;
}

/** 主页面 TabContent 装配 */
@Builder
export function MainTabPagesBuilder() {
  ForEach(MENU_CONFIG, (item: MenuItem, i: number) => {
    TabContent() {
      if (i === 0) {
        HomePage()
      } else if (i === 1) {
        ShelfPage()
      } else {
        ProfilePlaceholderPage()
      }
    }
    .tabBar(tabBarOf(item))

  }, (item: MenuItem, i: number) => `tab_${i}`)
}

/** 二级路由页装配（由 Navigation.navDestination 调用） */
@Builder
export function PageMapBuilder(name: string) {
  if (name === ROUTE_SEARCH) {
    SearchPage()
  } else if (name === ROUTE_DETAIL) {
    DetailPage()
  } else if (name === ROUTE_RANK) {
    RankPage()
  } else if (name === ROUTE_AUTHOR) {
    AuthorPage()
  } else if (name === ROUTE_READER2) {
    ReaderPage()
  } else if (name === ROUTE_LISTEN) {
    ListenPage()
  }
}

/**
 * 书架页（对齐 musicfreeOH MySheetsPage 形态）：
 * 标题栏 bottomBuilder「书架/浏览历史」胶囊切换 + 搜索/更多菜单 +
 * 3 列封面网格（数据源 FqShelfStore / FqBrowseStore）。
 */
@ComponentV2
struct ShelfPage {
  /** 0=书架 1=浏览历史 */
  @Local currentTab: number = 0;
  @Local showSearchBox: boolean = false;
  @Local searchInput: string = '';
  @Local searchKeyword: string = '';
  @Local shelfItems: FqShelfItem[] = [];
  @Local historyItems: FqBrowseItem[] = [];
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    FqShelfStore.init(getContext(this));
    FqBrowseStore.init(getContext(this));
    this.refreshData();
  }

  build() {
    CommonNav({
      titleBarOp: titleBarOf('书架', undefined, this.titleMenus(),
        {
          builder: (): void => {
            this.TitleExtraBuilder();
          },
          height: this.showSearchBox ? 110 : 40
        }),
      isHideBackButton: true,
      scroller: this.scroller,
      // 胶囊常驻标题栏下方，不随滚动隐藏
      isSearchBarScroller: false,
      doubleTapToTop: true,
      scrollToTopYOffset: -this.listTopInset(),
      onShown: (): void => {
        this.refreshData();
      },
    }) {
      Stack({ alignContent: Alignment.Top }) {
        List({ space: 14, scroller: this.scroller }) {
          ForEach(this.visibleItems(), (item: FqMediaItem, index: number) => {
            ListItem() {
              FqMediaCard({
                item: item,
                onItemClick: (clicked: FqMediaItem): void => {
                  this.openDetail(clicked);
                },
              })
            }
          }, (item: FqMediaItem, index: number): string => `${index}:${item.kind}:${item.id}`)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .lanes(3, 20)
        .padding({ left: 20, right: 20 })
        .contentStartOffset(this.listTopInset())
        .contentEndOffset(appState.bottomRect + 60)

        if (this.visibleItems().length === 0) {
          this.EmptyHint()
        }

        // 「更多」菜单锚点（对齐标题栏更多按钮：右缘 16、垂直居中于 56 高标题栏）
        Row() {
          Column()
            .id(SHELF_MORE_ANCHOR_ID)
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

  /** 列表顶部避让：标题栏 56 + 胶囊 54（+ 搜索行 56）。 */
  private listTopInset(): number {
    return appState.topRect + 110 + (this.showSearchBox ? 56 : 0);
  }

  private refreshData(): void {
    this.shelfItems = FqShelfStore.all().slice();
    this.historyItems = FqBrowseStore.all().slice();
  }

  /** 当前 tab 应用搜索关键词后的展示条目。 */
  private visibleItems(): FqMediaItem[] {
    const keyword: string = this.searchKeyword;
    const out: FqMediaItem[] = [];
    if (this.currentTab === 0) {
      for (const entry of this.shelfItems) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          out.push(new FqMediaItem(entry.id, entry.title, entry.cover,
            '', '', '', entry.kind, 0, '', '', '', 0));
        }
      }
    } else {
      for (const entry of this.historyItems) {
        if (keyword.length === 0 || entry.title.includes(keyword)) {
          out.push(new FqMediaItem(entry.id, entry.title, entry.cover,
            '', '', '', entry.kind, 0, '', '', '', 0));
        }
      }
    }
    return out;
  }

  /** titleBar 菜单按钮：搜索（展开/收起标题栏搜索框）+ 更多（清空浏览历史）。 */
  private titleMenus(): Array<HdsNavigationMenuItemOptions> {
    const search: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.magnifyingglass'),
        label: '搜索',
        action: (): void => {
          this.toggleSearchBox();
        }
      }
    };
    const menu: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.dot_grid_2x2'),
        label: '更多',
        action: (): void => {
          this.openMoreMenu();
        }
      }
    };
    return [search, menu];
  }

  /** 展开/收起标题栏搜索框（收起时清空关键词恢复全部）。 */
  private toggleSearchBox(): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.showSearchBox = !this.showSearchBox;
    });
    if (!this.showSearchBox) {
      this.searchKeyword = '';
      this.searchInput = '';
      return;
    }
    // 展开后请求焦点呼出软键盘（延时等待插槽挂载与展开过渡完成）
    const focusController = this.getUIContext().getFocusController();
    setTimeout((): void => {
      try {
        focusController.requestFocus(SHELF_SEARCH_FOCUS_ID);
      } catch (e) {
        // 组件未挂载时忽略
      }
    }, 320);
    if (this.scroller.currentOffset().yOffset !== 0) {
      this.scroller.scrollTo({
        xOffset: 0,
        yOffset: -this.listTopInset(),
        animation: { duration: 250, curve: Curve.EaseOut }
      });
    }
  }

  /** 切换「书架/浏览历史」胶囊（滑块位移动画 + 列表回顶）。 */
  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.currentTab = index;
    });
    this.scroller.scrollEdge(Edge.Top);
  }

  /** 更多菜单：清空浏览历史（不可恢复，保留确认）。 */
  private openMoreMenu(): void {
    const clearItem = new FqMenuItem();
    clearItem.icon = $r('sys.symbol.trash');
    clearItem.label = '清空浏览历史';
    clearItem.onAction = (): void => {
      FqMenu.dismiss();
      AlertDialog.show({
        title: '清空浏览历史',
        message: '确定要清空全部浏览历史吗？此操作不可恢复。',
        primaryButton: {
          value: '取消',
          action: (): void => {
          }
        },
        secondaryButton: {
          value: '清空',
          fontColor: FQ_ACCENT,
          action: (): void => {
            FqBrowseStore.clear();
            this.refreshData();
          }
        },
        alignment: DialogAlignment.Center,
      });
    };
    FqMenu.open(this.getUIContext(), SHELF_MORE_ANCHOR_ID, [clearItem]);
  }

  private openDetail(item: FqMediaItem): void {
    DetailNavParams.id = item.id;
    DetailNavParams.kind = item.kind;
    DetailNavParams.title = item.title;
    DetailNavParams.cover = item.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 标题栏下方扩展区：「书架/浏览历史」胶囊滑块 + 可展开搜索框。 */
  @Builder
  private TitleExtraBuilder() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('50%')
          .height(26)
          .borderRadius(13)
          // 位移必须用绝对值：81 = 滑轨内宽 162 的一半
          .offset({ x: this.currentTab === 1 ? 81 : 0 })
          .attributeModifier(rowImmersiveModifier)

        Row() {
          Text('书架')
            .fontSize(12)
            .fontWeight(this.currentTab === 0 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.currentTab === 0 ? FQ_ACCENT : $r('sys.color.font_tertiary'))
            .height(26)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.switchTab(0);
            })
          Text('浏览历史')
            .fontSize(12)
            .fontWeight(this.currentTab === 1 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.currentTab === 1 ? FQ_ACCENT : $r('sys.color.font_tertiary'))
            .height(26)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.switchTab(1);
            })
        }
        .width('100%')
      }
      .width(168)
      .height(30)
      .borderRadius(15)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .padding(3)
      .margin({ top: 4, bottom: 10 })
      .attributeModifier(stackImmersiveModifier)

      if (this.showSearchBox) {
        this.SearchBar()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 搜索框（固定于标题栏下方；输入不即时过滤，
   * 点搜索按钮/软键盘回车后才应用关键词）。
   */
  @Builder
  private SearchBar() {
    CommonSearch({
      searchValue: this.searchInput,
      placeholderValue: this.currentTab === 0 ? '搜索书架作品' : '搜索浏览记录',
      focusId: SHELF_SEARCH_FOCUS_ID,
      submit: (_value: string, _event: SubmitEvent): void => {
        this.searchKeyword = this.searchInput.trim();
      },
      change: (v: string): void => {
        this.searchInput = v;
      },
      didDelete: (): void => {
        this.searchInput = '';
        this.searchKeyword = '';
      },
    })
      .width('100%')
      .padding({ left: 16, right: 16 })
      .transition(TransitionEffect.move(TransitionEdge.TOP))
  }

  /** 空态：按 tab 与关键词区分文案（覆盖层居中，避开 lanes 三列挤压）。 */
  @Builder
  private EmptyHint() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(64)
          .height(64)
          .borderRadius(32)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
        SymbolGlyph(this.currentTab === 0 ? $r('sys.symbol.book') : $r('sys.symbol.clock'))
          .fontSize(32)
          .fontColor([FQ_ACCENT])
      }
      Text(this.emptyTitle())
        .fontSize(16)
        .fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
      Text(this.emptySub())
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private emptyTitle(): string {
    if (this.searchKeyword.length > 0) {
      return '未找到相关内容';
    }
    if (this.currentTab === 0) {
      return '书架还是空的';
    }
    return '暂无浏览记录';
  }

  private emptySub(): string {
    if (this.searchKeyword.length > 0) {
      return '换个关键词试试';
    }
    if (this.currentTab === 0) {
      return '去首页发现好故事，加入书架吧';
    }
    return '看过的作品会出现在这里';
  }
}

@ComponentV2
struct ProfilePlaceholderPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('我的', false),
      isHideBackButton: true,
    }) {
      Column({ space: 10 }) {
        Text('设置与账号将在后续版本提供')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}

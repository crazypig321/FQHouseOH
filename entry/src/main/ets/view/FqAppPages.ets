/**
 * 公共页面装配（对齐 musicfreeOH AppPages 模式）：
 * - MainTabPagesBuilder：主 TabContent（首页/书架/我的/设置）
 * - PageMapBuilder：二级路由页（Navigation.navDestination 单 builder 页表）
 */

import { ROUTE_DETAIL, ROUTE_RANK, ROUTE_READER2, ROUTE_SEARCH, ROUTE_AUTHOR, ROUTE_LISTEN, ROUTE_PLAYER, ROUTE_COMIC, ROUTE_LISTEN_VIDEO, ROUTE_SETTINGS, ROUTE_ABOUT, ROUTE_CACHED_BOOKS, ROUTE_CACHED_DRAMAS } from '../model/FqNavModels';
import { MENU_CONFIG, MenuItem, tabBarSymbolOf } from '../model/FqTabsModels';
import { HomePage } from '../pages/HomePage';
import { ShelfPage } from '../pages/ShelfPage';
import { ProfilePage } from '../pages/ProfilePage';
import { SearchPage } from '../pages/sub/SearchPage';
import { DetailPage } from '../pages/sub/DetailPage';
import { RankPage } from '../pages/sub/RankPage';
import { AuthorPage } from '../pages/sub/AuthorPage';
import { ReaderPage } from '../pages/sub/ReaderPage';
import { ComicPage } from '../pages/sub/ComicPage';
import { ListenPage } from '../pages/sub/ListenPage';
import { ListenVideoPage } from '../pages/sub/ListenVideoPage';
import { PlayerPage } from '../pages/sub/PlayerPage';
import { SettingsPage } from '../pages/SettingsPage';
import { AboutPage } from '../pages/sub/AboutPage';
import { CachedBooksPage } from '../pages/sub/CachedBooksPage';
import { CachedDramasPage } from '../pages/sub/CachedDramasPage';

const TAB_ACCENT: string = '#FF7A3D';

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
      } else if (i === 2) {
        ProfilePage()
      } else {
        SettingsPage({ isTab: true })
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
  } else if (name === ROUTE_COMIC) {
    ComicPage()
  } else if (name === ROUTE_LISTEN) {
    ListenPage()
  } else if (name === ROUTE_PLAYER) {
    PlayerPage()
  } else if (name === ROUTE_LISTEN_VIDEO) {
    ListenVideoPage()
  } else if (name === ROUTE_SETTINGS) {
    SettingsPage()
  } else if (name === ROUTE_ABOUT) {
    AboutPage()
  } else if (name === ROUTE_CACHED_BOOKS) {
    CachedBooksPage()
  } else if (name === ROUTE_CACHED_DRAMAS) {
    CachedDramasPage()
  }
}

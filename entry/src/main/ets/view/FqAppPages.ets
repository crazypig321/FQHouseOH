/**
 * 公共页面装配（对齐 musicfreeOH AppPages 模式）：
 * - MainTabPagesBuilder：主 TabContent（首页/书架/我的）
 * - PageMapBuilder：二级路由页（Navigation.navDestination 单 builder 页表）
 */

import { MENU_CONFIG, MenuItem, tabBarSymbolOf } from '../model/FqTabsModels';
import { ROUTE_DETAIL, ROUTE_RANK, ROUTE_READER2, ROUTE_SEARCH, ROUTE_AUTHOR, ROUTE_LISTEN } from '../model/FqNavModels';
import { HomePage } from '../pages/HomePage';
import { ShelfPage } from '../pages/ShelfPage';
import { ProfilePlaceholderPage } from '../pages/ProfilePage';
import { SearchPage } from '../pages/sub/SearchPage';
import { DetailPage } from '../pages/sub/DetailPage';
import { RankPage } from '../pages/sub/RankPage';
import { AuthorPage } from '../pages/sub/AuthorPage';
import { ReaderPage } from '../pages/sub/ReaderPage';
import { ListenPage } from '../pages/sub/ListenPage';

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

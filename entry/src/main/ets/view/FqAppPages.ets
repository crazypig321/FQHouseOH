/**
 * 公共页面装配（对齐 musicfreeOH AppPages 模式）：
 * - MainTabPagesBuilder：主 TabContent（首页/书架/我的）
 * - PageMapBuilder：二级路由页（Navigation.navDestination 单 builder 页表）
 */

import { MENU_CONFIG, MenuItem, tabBarSymbolOf } from '../model/FqTabsModels';
import { ROUTE_DETAIL, ROUTE_RANK, ROUTE_READER2, ROUTE_SEARCH, FqTitleBarOptions } from '../model/FqNavModels';
import { HomePage } from '../pages/HomePage';
import { SearchPage } from '../pages/SearchPage';
import { DetailPage } from '../pages/DetailPage';
import { RankPage } from '../pages/RankPage';
import { ReaderPage } from '../reader/ReaderPage'
import { CommonNav } from './CommonNav';

const TAB_ACCENT: string = '#FF7A3D';

/** 底部 tab 样式：文本选中色适配主题橙 */
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
        ShelfPlaceholderPage()
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
  } else if (name === ROUTE_READER2) {
    ReaderPage()
  }
}

@ComponentV2
struct ShelfPlaceholderPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('书架', false),
      isHideBackButton: true,
    }) {
      Column({ space: 10 }) {
        Text('收藏与浏览记录将在后续版本提供')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
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

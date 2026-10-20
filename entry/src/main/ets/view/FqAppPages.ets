/**
 * 公共页面装配（对齐 musicfreeOH AppPages 模式）：
 * - MainTabPagesBuilder：主 TabContent（首页/书架/我的）
 * - PageMapBuilder：二级路由页（Navigation.navDestination 单 builder 页表）
 */

import { MENU_CONFIG, MenuItem, tabBarSymbolOf } from '../model/FqTabsModels';
import { ROUTE_DETAIL, ROUTE_SEARCH, FqTitleBarOptions } from '../model/FqNavModels';
import { HomePage } from '../pages/HomePage';
import { SearchPage } from '../pages/SearchPage';
import { DetailPage } from '../pages/DetailPage';
import { HdsNavDestination } from '@kit.UIDesignKit';

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
  }
}

@ComponentV2
struct ShelfPlaceholderPage {
  build() {
    HdsNavDestination() {
      Column({ space: 10 }) {
        Text('收藏与浏览记录将在后续版本提供')
          .fontSize(13)
          .fontColor('#66000000')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#FFFFFF')
    }
    .titleBar(FqTitleBarOptions('书架', false))
    .hideBackButton(true)
    .width('100%')
    .height('100%')
  }
}

@ComponentV2
struct ProfilePlaceholderPage {
  build() {
    HdsNavDestination() {
      Column({ space: 10 }) {
        Text('设置与账号将在后续版本提供')
          .fontSize(13)
          .fontColor('#66000000')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#FFFFFF')
    }
    .titleBar(FqTitleBarOptions('我的', false))
    .hideBackButton(true)
    .width('100%')
    .height('100%')
  }
}

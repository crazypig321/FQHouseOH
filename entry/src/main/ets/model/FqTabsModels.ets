/**
 * 底部 Tab 菜单配置（对齐 musicfreeOH TabsModels 模式：
 * SymbolGlyph 图标 + BottomTabBarStyle，选中色为主题橙）。
 */

import { SymbolGlyphModifier } from '@kit.ArkUI';

export interface MenuItem {
  icon: Resource;
  label: string;
}

/** 选中态强调色 */
const ACCENT_COLOR: string = '#FF7A3D';

export function tabBarSymbolOf(item: MenuItem): TabBarSymbol {
  const normal: SymbolGlyphModifier = new SymbolGlyphModifier(item.icon)
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    .fontColor([$r('sys.color.icon_primary')]);
  const selected: SymbolGlyphModifier = new SymbolGlyphModifier(item.icon)
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    .fontColor([ACCENT_COLOR]);
  const symbol: TabBarSymbol = {
    normal: normal,
    selected: selected,
  };
  return symbol;
}

export const MENU_CONFIG: MenuItem[] = [
  { icon: $r('sys.symbol.house'), label: '首页' },
  { icon: $r('sys.symbol.bookshelf'), label: '书架' },
  { icon: $r('sys.symbol.person'), label: '我的' },
];

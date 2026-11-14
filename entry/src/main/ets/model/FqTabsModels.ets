/**
 * 底部 Tab 菜单配置（对齐 musicfreeOH TabsModels 模式：
 *  SymbolGlyph 图标 + BottomTabBarStyle，选中色为主题色）。
 */

import { SymbolGlyphModifier } from '@kit.ArkUI';
import { appState } from '../entryability/AppState';

export interface MenuItem {
  icon: Resource;
  label: string;
}

export function tabBarSymbolOf(item: MenuItem): TabBarSymbol {
  const normal: SymbolGlyphModifier = new SymbolGlyphModifier(item.icon)
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    .fontColor([$r('sys.color.icon_primary')]);
  const selected: SymbolGlyphModifier = new SymbolGlyphModifier(item.icon)
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    .fontColor([appState.accentColor]);
  const symbol: TabBarSymbol = {
    normal: normal,
    selected: selected,
  };
  return symbol;
}

export const MENU_CONFIG: MenuItem[] = [
  { icon: $r('sys.symbol.house_fill_1'), label: '首页' },
  { icon: $r('sys.symbol.video_fill'), label: '短剧' },
  { icon: $r('sys.symbol.bookshelf'), label: '书架' },
  { icon: $r('sys.symbol.person_fill'), label: '我的' },
  { icon: $r('sys.symbol.gearshape_fill'), label: '设置' },
];

/** 设置 Tab 下标（MENU_CONFIG 第 5 项；我的-应用设置经主 Tab 切换进入）。 */
export const SETTINGS_TAB_INDEX: number = 4;

/**
 * 我的、设置页面显示样式下的可见主 Tab 逻辑下标列表：
 * 0 我的含设置入口 → [首页, 短剧, 书架, 我的]；1 设置含我的入口 → [首页, 短剧, 书架, 设置]；
 * 其余 → 全部 5 Tab。
 */
export function fqVisibleTabIndexes(style: number): number[] {
  if (style === 0) {
    return [0, 1, 2, 3];
  }
  if (style === 1) {
    return [0, 1, 2, 4];
  }
  return [0, 1, 2, 3, 4];
}

/** 逻辑下标 → Tabs 实际（物理）下标；样式下不可见时回退 0（首页）。 */
export function fqPhysicalIndexOf(logicalIndex: number, style: number): number {
  const visible: number[] = fqVisibleTabIndexes(style);
  const pos: number = visible.indexOf(logicalIndex);
  return pos >= 0 ? pos : 0;
}

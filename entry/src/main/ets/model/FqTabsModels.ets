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
  // 短剧页（沉浸黑底、底栏渐变遮罩透明）未选中图标固定用深色模式的浅色，
  // 其余 Tab 跟随系统深浅色
  const normalColor: ResourceColor = fqIsDramaTabActive()
    ? '#E6FFFFFF' : $r('sys.color.icon_primary');
  const normal: SymbolGlyphModifier = new SymbolGlyphModifier(item.icon)
    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    .fontColor([normalColor]);
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
  { icon: $r('sys.symbol.template_fill'), label: '短剧' },
  { icon: $r('sys.symbol.bookshelf'), label: '书架' },
  { icon: $r('sys.symbol.person_fill'), label: '我的' },
  { icon: $r('sys.symbol.gearshape_fill'), label: '设置' },
];

/** 设置 Tab 下标（MENU_CONFIG 第 5 项；我的-应用设置经主 Tab 切换进入）。 */
export const SETTINGS_TAB_INDEX: number = 4;

/**
 * 我的、设置页面显示样式下的主 Tab 逻辑下标全量列表（短剧页开关未过滤）：
 * 0 我的含设置入口 → [首页, 短剧, 书架, 我的]；1 设置含我的入口 → [首页, 短剧, 书架, 设置]；
 * 其余 → 全部 5 Tab。
 */
function fqStyleTabIndexes(style: number): number[] {
  if (style === 0) {
    return [0, 1, 2, 3];
  }
  if (style === 1) {
    return [0, 1, 2, 4];
  }
  return [0, 1, 2, 3, 4];
}

/**
 * 当前可见主 Tab 逻辑下标列表：显示样式过滤 + 「启用短剧页」关闭时剔除短剧页（逻辑下标 1）。
 */
export function fqVisibleTabIndexes(style: number): number[] {
  const base: number[] = fqStyleTabIndexes(style);
  if (appState.dramaPageEnabled) {
    return base;
  }
  const visible: number[] = [];
  for (let index: number = 0; index < base.length; index++) {
    if (base[index] !== 1) {
      visible.push(base[index]);
    }
  }
  return visible;
}

/** 逻辑下标 → Tabs 实际（物理）下标；样式下不可见时回退 0（首页）。 */
export function fqPhysicalIndexOf(logicalIndex: number, style: number): number {
  const visible: number[] = fqVisibleTabIndexes(style);
  const pos: number = visible.indexOf(logicalIndex);
  return pos >= 0 ? pos : 0;
}

/** 物理（可见列表内位置）→ 逻辑下标；越界回退 0（首页）。 */
export function fqLogicalIndexOf(physicalIndex: number, style: number): number {
  const visible: number[] = fqVisibleTabIndexes(style);
  return visible[physicalIndex] ?? 0;
}

/** 当前主 Tab 是否停在短剧页（短剧页关闭时恒 false；底栏配色/渐变遮罩判断用）。 */
export function fqIsDramaTabActive(): boolean {
  if (!appState.dramaPageEnabled) {
    return false;
  }
  return fqLogicalIndexOf(appState.currTabsIndex, appState.mineSettingsStyle) === 1;
}

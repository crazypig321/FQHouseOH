/**
 * 断点适配工具（对齐 musicfreeOH BreakpointUtils 模式）：
 * 基于 appState.WidthBp / HeightBp（0=sm，1=md，2=lg）输出设备布局参数。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { appState } from '../entryability/AppState';

/**
 * 是否为 PC 风格侧边栏布局：
 * - 2in1/PC、平板设备恒为侧边栏布局（大屏常驻左侧导航）
 * - 手机设备（phone）不启用：分屏/自由窗口下仍保持手机布局
 * - 其余设备仅在以自由窗口方式运行时启用（窗口宽度与物理屏宽差值判定）
 */
export function useSidebarLayout(widthBp: number, windowWidthVp: number,
  displayWidthVp: number): boolean {
  if (deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'tablet') {
    return true;
  }
  if (deviceInfo.deviceType === 'phone') {
    return false;
  }
  return widthBp >= 1 && windowWidthVp > 0 && displayWidthVp > 0 &&
    displayWidthVp - windowWidthVp > 4;
}

/**
 * 首页「发现更多好故事」/ 书架网格列数：
 * 断点 <= 1（sm/md，手机与半宽窗口）保持原 3 列，lg 起铺满 6 列。
 */
export function feedColumns(widthBp: number): number {
  if (widthBp >= 2) {
    return 6;
  }
  return 3;
}

/**
 * 书架列数（layout = 0 网格 / 1 双列大卡 / 2 列表行）：
 * - 断点 <= 1 一律保持手机原布局（3 / 2 / 1 列）
 * - layout 0/1：lg 起 6 / 4 列
 * - layout 2（列表行）：仅 PC 侧边栏布局且 lg 时一排两列（窄窗口仍是单列长行）
 */
export function shelfColumns(widthBp: number, windowWidthVp: number,
  displayWidthVp: number, layout: number): number {
  if (layout === 2) {
    return useSidebarLayout(widthBp, windowWidthVp, displayWidthVp) && widthBp >= 2 ? 2 : 1;
  }
  if (layout === 1) {
    return widthBp >= 2 ? 4 : 2;
  }
  return feedColumns(widthBp);
}

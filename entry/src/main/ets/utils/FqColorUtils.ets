/**
 * 颜色工具：给任意 ResourceColor（hex 字符串 / Color 枚举 / 数字 / $r 资源）
 * 叠加 0-1 透明度，统一输出 '#AARRGGBB' 字符串颜色。
 * - $r 资源经 appState.abilityContext.resourceManager.getColorSync 同步取值；
 *   上下文未就绪或解析失败时原样返回，不打断调用方。
 * 用法：FqColorUtils.withOpacity(FQ_ACCENT, 0.4)
 */

import { appState } from '../entryability/AppState';

export class FqColorUtils {
  /** 主入口：color 叠加 opacity（0-1）透明度，返回 '#AARRGGBB' 字符串颜色。 */
  static withOpacity(color: ResourceColor, opacity: number): ResourceColor {
    const alpha: number = FqColorUtils.alphaFromOpacity(opacity);
    if (typeof color === 'number') {
      // Color 枚举 / 数字颜色：取低 24 位 RGB，替换 alpha
      return FqColorUtils.toArgbString(alpha, color & 0xFFFFFF);
    }
    if (typeof color === 'string') {
      const rgb: number = FqColorUtils.rgbFromString(color);
      if (rgb >= 0) {
        return FqColorUtils.toArgbString(alpha, rgb);
      }
      return color;
    }
    // Resource（$r）：同步解析 color 资源数值
    const context = appState.abilityContext;
    if (context === null) {
      return color;
    }
    try {
      const value: number = context.resourceManager.getColorSync(color.id);
      return FqColorUtils.toArgbString(alpha, value & 0xFFFFFF);
    } catch (error) {
      return color;
    }
  }

  /** 0-1 透明度 → 0-255 alpha（越界收敛）。 */
  private static alphaFromOpacity(opacity: number): number {
    if (opacity <= 0) {
      return 0;
    }
    if (opacity >= 1) {
      return 255;
    }
    return Math.round(opacity * 255);
  }

  /** 解析 '#RGB'/'#RRGGBB'/'#AARRGGBB' → 0xRRGGBB；无法解析返回 -1。 */
  private static rgbFromString(color: string): number {
    let hex: string = color.startsWith('#') ? color.substring(1) : color;
    if (hex.length === 3) {
      hex = hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1)
        + hex.charAt(2) + hex.charAt(2);
    }
    if (hex.length === 6) {
      const value: number = parseInt(hex, 16);
      return Number.isNaN(value) ? -1 : value;
    }
    if (hex.length === 8) {
      const value: number = parseInt(hex.substring(2), 16);
      return Number.isNaN(value) ? -1 : value;
    }
    return -1;
  }

  /** alpha + rgb → '#AARRGGBB'（大写，自动补零）。 */
  private static toArgbString(alpha: number, rgb: number): string {
    const alphaText: string = alpha.toString(16).toUpperCase();
    const rgbText: string = rgb.toString(16).toUpperCase();
    const alphaHex: string = alphaText.length < 2 ? `0${alphaText}` : alphaText;
    return `#${alphaHex}${'000000'.substring(rgbText.length)}${rgbText}`;
  }
}

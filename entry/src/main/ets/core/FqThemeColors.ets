/**
 * 主题色预设（设置页-外观-主题色，参考 musicfreeOH 主题色功能）：
 * - 颜色定义于资源文件 base/dark element/color.json（theme_color_*），
 *   同一主题色深浅模式自动切换明暗（跟随应用 setColorMode 生效配置）；
 * - key 持久化于 FqAppSettingsStore（themeColor，默认 'orange' 番茄橙）；
 * - '' = 跟随系统强调色（sys.color.icon_emphasize，同样深浅自适应）；
 * - 全项目高亮色统一引用 appState.accentColor（@Trace，切换即时刷新），
 *   半透明变体经 FqColorUtils.withOpacity(appState.accentColor, x) 派生。
 */

export class FqThemeColorOption {
  /** 持久化 key（'' = 跟随系统）。 */
  readonly key: string;
  /** 展示名。 */
  readonly name: string;

  constructor(key: string, name: string) {
    this.key = key;
    this.name = name;
  }
}

/** 主题色预设列表（设置菜单展示顺序；custom = 自定义颜色，经三方 HSB 取色器取色）。 */
export const FQ_THEME_COLOR_OPTIONS: FqThemeColorOption[] = [
  new FqThemeColorOption('', '跟随系统'),
  new FqThemeColorOption('orange', '番茄橙'),
  new FqThemeColorOption('gold', '琥珀金'),
  new FqThemeColorOption('green', '松石绿'),
  new FqThemeColorOption('teal', '青碧'),
  new FqThemeColorOption('blue', '蔚蓝'),
  new FqThemeColorOption('violet', '紫罗兰'),
  new FqThemeColorOption('pink', '樱花粉'),
  new FqThemeColorOption('red', '绯红'),
  new FqThemeColorOption('custom', '自定义颜色'),
];

/** key → 主题色（'' = 系统强调色；'custom' 不经此函数，由 FqAppSettingsStore 直取 themeCustomColor hex；未知 key 回落番茄橙）。 */
export function fqThemeColorOf(key: string): ResourceColor {
  if (key === '') {
    return $r('sys.color.icon_emphasize');
  }
  if (key === 'orange') {
    return $r('app.color.theme_color_orange');
  }
  if (key === 'gold') {
    return $r('app.color.theme_color_gold');
  }
  if (key === 'green') {
    return $r('app.color.theme_color_green');
  }
  if (key === 'teal') {
    return $r('app.color.theme_color_teal');
  }
  if (key === 'blue') {
    return $r('app.color.theme_color_blue');
  }
  if (key === 'violet') {
    return $r('app.color.theme_color_violet');
  }
  if (key === 'pink') {
    return $r('app.color.theme_color_pink');
  }
  if (key === 'red') {
    return $r('app.color.theme_color_red');
  }
  return $r('app.color.theme_color_orange');
}

/** key → 预设展示名（设置页右侧文案；未知 key 回落番茄橙）。 */
export function fqThemeColorNameOf(key: string): string {
  for (const option of FQ_THEME_COLOR_OPTIONS) {
    if (option.key === key) {
      return option.name;
    }
  }
  return '番茄橙';
}

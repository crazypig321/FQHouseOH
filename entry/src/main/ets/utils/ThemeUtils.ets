import { ConfigurationConstant } from "@kit.AbilityKit";


/**
 * 深浅模式主题工具（参考 ting_read 的 resourceTheme）：
 * HDS 组件（HdsNavDestination titleBar 等）的系统色不会随深浅模式自动刷新，
 * 需在 Ability onConfigurationUpdate 时重赋值 @Trace 颜色字段触发重渲染，
 * 使组件按当前模式重新解析系统色
 */
@ObservedV2
export class ThemeUtils {
  /** 主文本色（标题 / 图标） */
  @Trace textColor: ResourceColor = $r('sys.color.font');
  /** 三级文本色（副标题） */
  @Trace terTextColor: ResourceColor = $r('sys.color.font_tertiary');

  /**
   * 深浅模式变化时调用（EntryAbility.onConfigurationUpdate）
   * @param color 变化后的颜色模式
   */
  public colorModeChange(color: ConfigurationConstant.ColorMode): void {
    if (color === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      this.textColor = $r('sys.color.font');
      this.terTextColor = $r('sys.color.font_tertiary');
    } else {
      this.textColor = $r('sys.color.font');
      this.terTextColor = $r('sys.color.font_tertiary');
    }
  }
}


export const themeUtils: ThemeUtils = new ThemeUtils();

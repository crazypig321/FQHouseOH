/**
 * 公共下拉菜单（对齐 CommonSheet 模式，页面直接调用 FqMenu.open）：
 * THICK 沉浸式光感材质 + 锚点下方 12vp 间距 + 条目分割线。
 * 页面仅需组装 FqMenuItem 列表并在锚点（id）处打开。
 */

import { ComponentContent, LengthMetrics, UIContext, uiMaterial } from '@kit.ArkUI';
import { IsApiVersion_26 } from '../utils/ModifierUtils';

/** 公共菜单项参数（icon 为空字符串时不显示图标；endIcon 用于选中态勾选等尾部图标）。 */
export class FqMenuItem {
  icon: ResourceStr = '';
  label: string = '';
  endIcon: ResourceStr = '';
  onAction: () => void = (): void => {};
}

/** 公共菜单内容参数。 */
export class FqMenuParams {
  items: Array<FqMenuItem> = [];
}

/** 菜单光感材质（THICK 沉浸式；API<26 无材质返回 undefined）。 */
export function fqMenuMaterial(): uiMaterial.Material | undefined {
  return IsApiVersion_26()
    ? new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK })
    : undefined;
}

/** 公共菜单内容：条目间带分割线。 */
@Builder
export function fqMenuBuilder(params: FqMenuParams) {
  Menu() {
    ForEach(params.items, (item: FqMenuItem) => {
      if (typeof item.icon === 'string') {
        MenuItem({ content: item.label, endIcon: item.endIcon === '' ? undefined : item.endIcon })
          .onClick(() => {
            item.onAction();
          })
      } else {
        MenuItem({ startIcon: item.icon, content: item.label, endIcon: item.endIcon === '' ? undefined : item.endIcon })
          .onClick(() => {
            item.onAction();
          })
      }
    }, (item: FqMenuItem) => item.label)
  }
  .menuItemDivider({
    strokeWidth: LengthMetrics.vp(0.6),
    color: $r('sys.color.comp_divider'),
    startMargin: LengthMetrics.vp(12),
    endMargin: LengthMetrics.vp(12)
  })
}

/** 供 ComponentContent 使用的包装 builder。 */
const fqMenuWrapped: WrappedBuilder<[FqMenuParams]> = wrapBuilder(fqMenuBuilder);

/** 公共菜单打开/关闭工具（同一时刻只允许一个菜单）。 */
export class FqMenu {
  private static content: ComponentContent<FqMenuParams> | null = null;
  private static uiContext: UIContext | null = null;

  /**
   * 在锚点组件下方打开菜单（右对齐、间距 12vp、THICK 光感材质）。
   * @param uiContext 页面 UIContext
   * @param anchorId 锚点组件 id（须与触发按钮位置对齐）
   * @param items 菜单项列表
   */
  public static open(uiContext: UIContext, anchorId: string, items: Array<FqMenuItem>): void {
    FqMenu.dismiss();
    const params = new FqMenuParams();
    params.items = items;
    const content = new ComponentContent<FqMenuParams>(uiContext, fqMenuWrapped, params);
    FqMenu.content = content;
    FqMenu.uiContext = uiContext;
    uiContext.getPromptAction().openMenu(content, { id: anchorId }, {
      placement: Placement.BottomRight,
      targetSpace: LengthMetrics.vp(12),
      systemMaterial: fqMenuMaterial(),
    })
      .then((): void => {
        if (FqMenu.content === content) {
          FqMenu.content = null;
          FqMenu.uiContext = null;
        }
      })
      .catch((_e: Object): void => {
        if (FqMenu.content === content) {
          FqMenu.content = null;
          FqMenu.uiContext = null;
        }
      });
  }

  /** 关闭当前打开的菜单。 */
  public static dismiss(): void {
    const content = FqMenu.content;
    FqMenu.content = null;
    const uiContext = FqMenu.uiContext;
    FqMenu.uiContext = null;
    if (content !== null && uiContext !== null) {
      uiContext.getPromptAction().closeMenu(content).catch((_e: Object): void => {
      });
    }
  }
}

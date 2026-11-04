/**
 * 公共下拉菜单（对齐 CommonSheet 模式，页面直接调用 FqMenu.open）：
 * THICK 沉浸式光感材质 + 锚点下方 12vp 间距 + 条目分割线。
 * 页面仅需组装 FqMenuItem 列表并在锚点（id）处打开。
 */

import { ComponentContent, LengthMetrics, SymbolGlyphModifier, UIContext, uiMaterial } from '@kit.ArkUI';
import { IsApiVersion_26 } from '../utils/ModifierUtils';
import { appState } from '../entryability/AppState';

/** 公共菜单项参数（icon 为空字符串时不显示图标；endIcon 仅支持 sys.symbol 资源，
 *  经 SymbolGlyphModifier 渲染——MenuItem.endIcon 不支持 Symbol 图标，直接赋值不显示；
 *  swatch 非 null 时以自绘色板行渲染（主题色等颜色选择菜单）；
 *  selected 为 true 时高亮（MenuItem.selected，默认无对勾）；
 *  subItems 非空时为级联父项：点击侧滑展开子菜单（SIDE_EXPAND），此时
 *  onAction/icon/swatch/endIcon 不生效，仅 label 与 subItems 参与。 */
export class FqMenuItem {
  icon: ResourceStr = '';
  label: string = '';
  endIcon: ResourceStr = '';
  swatch: ResourceColor | null = null;
  selected: boolean = false;
  onAction: () => void = (): void => {};
  subItems: FqMenuItem[] = [];
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

/** 菜单内容宿主组件：@Builder 全部收进 struct（官方 FAQ faqs-arkui-1159 方案）。
 *  全局 helper @Builder 在 ComponentContent 场景下丢失观察上下文——真机表现为
 *  MenuItem content 未落节点（"content or label is empty" 文字不可见），子菜单
 *  惰性箭头内 this=undefined 直接闪退（observeComponentCreation2 of undefined）。
 *  struct 成员 @Builder 恒以组件实例为 this，两条路径均修复。 */
@Component
struct FqMenuContent {
  items: Array<FqMenuItem> = [];

  /** 叶子菜单项（无子菜单，点击触发 onAction）。 */
  @Builder
  EntryItem(item: FqMenuItem) {
    if (item.swatch !== null) {
      MenuItem({
        content: item.label,
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.circle_fill'))
          .fontSize(16)
          .fontColor([item.swatch ?? Color.Transparent]),
        symbolEndIcon: typeof item.endIcon === 'string'
          ? undefined : new SymbolGlyphModifier(item.endIcon).fontColor([appState.accentColor])
      })
        .selected(item.selected)
        .onClick(() => {
          item.onAction();
        })
    } else if (typeof item.icon === 'string') {
      MenuItem({
        content: item.label,
        symbolEndIcon: typeof item.endIcon === 'string'
          ? undefined : new SymbolGlyphModifier(item.endIcon).fontColor([$r('sys.color.icon_primary')])
      })
        .selected(item.selected)
        .onClick(() => {
          item.onAction();
        })
    } else {
      MenuItem({
        startIcon: item.icon,
        content: item.label,
        symbolEndIcon: typeof item.endIcon === 'string'
          ? undefined : new SymbolGlyphModifier(item.endIcon).fontColor([$r('sys.color.icon_primary')])
      })
        .selected(item.selected)
        .onClick(() => {
          item.onAction();
        })
    }
  }

  /** 级联父菜单项：MenuItemOptions.builder 挂侧滑子菜单（SIDE_EXPAND，API 9+）。 */
  @Builder
  ParentItem(item: FqMenuItem) {
    MenuItem({
      content: item.label,
      builder: (): void => {
        this.SubMenu(item.subItems)
      }
    })
  }

  /** 级联子菜单（递归支持任意层级）。 */
  @Builder
  SubMenu(subItems: Array<FqMenuItem>) {
    Menu() {
      ForEach(subItems, (sub: FqMenuItem) => {
        if (sub.subItems.length > 0) {
          this.ParentItem(sub)
        } else {
          this.EntryItem(sub)
        }
      }, (sub: FqMenuItem): string => sub.label)
    }
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.6),
      color: $r('sys.color.comp_divider'),
      startMargin: LengthMetrics.vp(12),
      endMargin: LengthMetrics.vp(12)
    })
  }

  build() {
    Menu() {
      ForEach(this.items, (item: FqMenuItem) => {
        if (item.subItems.length > 0) {
          this.ParentItem(item)
        } else {
          this.EntryItem(item)
        }
      }, (item: FqMenuItem): string => item.label)
    }
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.6),
      color: $r('sys.color.comp_divider'),
      startMargin: LengthMetrics.vp(12),
      endMargin: LengthMetrics.vp(12)
    })
  }
}

/** 公共菜单内容入口（wrapBuilder + ComponentContent 用）：全部渲染收进 FqMenuContent。 */
@Builder
export function fqMenuBuilder(params: FqMenuParams) {
  FqMenuContent({ items: params.items })
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
   * @param onClose 菜单关闭回调（选中条目/点击菜单外关闭/openMenu 异常时触发）
   */
  public static open(uiContext: UIContext, anchorId: string, items: Array<FqMenuItem>,
    onClose?: () => void): void {
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
          if (onClose !== undefined) {
            onClose();
          }
        }
      })
      .catch((_e: Object): void => {
        if (FqMenu.content === content) {
          FqMenu.content = null;
          FqMenu.uiContext = null;
          if (onClose !== undefined) {
            onClose();
          }
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

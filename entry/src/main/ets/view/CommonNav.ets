/**
 * 通用 HdsNavDestination 封装（对齐 musicfreeOH CommonNav 模式）：
 * 统一标题栏（滚动渐变模糊 + 避让安全区）、bottomBuilder 上滑隐藏、
 * 双击标题栏回顶、返回键拦截；页面仅传 titleBarOp 与内容。
 */

import { BlurStrategy,
  HdsNavDestination,
  HdsNavigationTitle,
  HdsNavigationMenuItemOptions,
  ScrollEffectType,
  TitleBarContentOptions,
  BottomBuilderParams,
  HideMode } from '@kit.UIDesignKit';
import { appState } from '../entryability/AppState';
import { LengthMetrics } from '@kit.ArkUI';
import { themeUtils } from '../utils/ThemeUtils';

export function titleBarOf(mainTitle: ResourceStr, subTitle?: ResourceStr,
  menus?: Array<HdsNavigationMenuItemOptions>, bottomBuilder?: BottomBuilderParams): TitleBarContentOptions {
  const title: HdsNavigationTitle = {
    mainTitle: mainTitle,
    subTitle: subTitle
  };
  const options: TitleBarContentOptions = {
    title: title
  };
  if (menus !== undefined && menus.length > 0) {
    options.menu = {
      value: menus
    };
  }
  options.bottomBuilder = bottomBuilder
  return options;
}

@ComponentV2
export struct CommonNav {
  @Param titleBarOp?: TitleBarContentOptions = undefined
  @Param isHideBackButton: boolean = false
  /** 标题栏背景延伸至状态栏，内容区从标题栏下方起排 */
  @Param avoidLayoutSafeArea: boolean = true
  /** 绑定页面滚动器（驱动标题栏滚动模糊与上滑隐藏） */
  @Param scroller: Scroller | undefined = undefined
  /** 上滑时随标题栏隐藏 bottomBuilder（搜索行） */
  @Param isSearchBarScroller: boolean = true
  /** 双击标题栏区域时列表回滚到顶部 */
  @Param doubleTapToTop: boolean = false
  @Param scrollToTopYOffset: number = 0
  /** 返回 true 拦截系统返回 */
  @Event backPressed: () => boolean = (): boolean => false

  @BuilderParam content: () => void;

  /** 上一次标题栏单击时间（300ms 内两次单击视为双击） */
  private lastTitleTapTime: number = 0;
  /** 页面宽度（vp，用于排除右侧菜单按钮区域） */
  private pageWidthVp: number = 0;

  /** 标题栏区域触摸：双击回滚到顶部 */
  private handleTouch(event: TouchEvent): void {
    if (!this.doubleTapToTop || this.scroller === undefined) {
      return;
    }
    if (event.type !== TouchType.Down) {
      return;
    }
    const t: TouchObject = event.touches[0];
    // 仅响应标题栏带（状态栏下方 56vp 内）
    if (t.windowY < appState.topRect || t.windowY > appState.topRect + 56) {
      return;
    }
    // 避开左侧返回键与右侧菜单按钮
    if (!this.isHideBackButton && t.windowX < 72) {
      return;
    }
    if (this.pageWidthVp > 0 && t.windowX > this.pageWidthVp - 130) {
      return;
    }
    const now: number = Date.now();
    if (this.lastTitleTapTime > 0 && now - this.lastTitleTapTime <= 300) {
      this.lastTitleTapTime = 0;
      this.scroller.scrollTo({ xOffset: 0, yOffset: this.scrollToTopYOffset, animation: { duration: 250, curve: Curve.EaseOut } });
    } else {
      this.lastTitleTapTime = now;
    }
  }

  build() {
    HdsNavDestination() {
      this.content()
    }
    .titleBar({
      content: this.titleBarOp,
      style: {
        originalStyle: {
          backgroundStyle: { backgroundColor: '#00ffffff', maskExtraHeight: 0, blurRadius: 30 },
          contentStyle: {
            // 深浅模式切换时由 themeUtils 触发重渲染（HDS 不会自动刷新系统色）
            titleStyle: { mainTitleColor: themeUtils.textColor, subTitleColor: themeUtils.terTextColor },
            backIconStyle: { iconColor: themeUtils.textColor },
            menuStyle: {
              iconColor: themeUtils.textColor
            },
            subIconStyle: {
              iconColor: themeUtils.textColor
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR, // 设置模糊类型
          blurEffectiveStartOffset: LengthMetrics.vp(0), // 动态样式线性过渡的起始位置
          blurEffectiveEndOffset: LengthMetrics.vp(80), // 动态样式线性过渡的终点位置
        },
        blurStrategy: BlurStrategy.ADAPTIVE,
        systemMaterialEffect: {
          materialType: appState.materialType,
          materialLevel: appState.materialLevel
        },
      },
      avoidLayoutSafeArea: this.avoidLayoutSafeArea,
    })
    .bindToScrollable(this.scroller ? [this.scroller] : [])
    .hideBackButton(this.isHideBackButton)
    .onTouch((event: TouchEvent): void => {
      this.handleTouch(event);
    })
    .onAreaChange((_old: Area, newArea: Area): void => {
      if (typeof newArea.width === 'number') {
        this.pageWidthVp = newArea.width;
      }
    })
    .backgroundColor($r('sys.color.background_secondary'))
    .width('100%')
    .height('100%')
    .onBackPressed(() => {
      return this.backPressed()
    })
    .dynamicHideTitleBar({
      hideBottomBuilder: this.isSearchBarScroller,
      mode: HideMode.SCROLL_UP_TO
    })
  }
}

/**
 * 双击回顶部 y 轴偏移值（标题栏 56）
 */
export function ScrollToTopYOffset(yOffset?: number): number {
  if (yOffset) {
    return -(appState.topRect + 56 + yOffset)
  } else {
    return -(appState.topRect + 56)
  }
}

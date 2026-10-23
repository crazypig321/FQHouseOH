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
  HideMode,
  HdsTabs,
  HdsTabsController,
  HdsNavDestinationTitleMode,
  HdsAnimationMode} from '@kit.UIDesignKit';
import { appState } from '../entryability/AppState';
import { LengthMetrics } from '@kit.ArkUI';
import { themeUtils } from '../utils/ThemeUtils';
import { FQ_ACCENT } from './CommonCom';

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
  private tabsController: HdsTabsController = new HdsTabsController();
  @Param titleBarOp?: TitleBarContentOptions = undefined
  @Param isHideBackButton: boolean = false
  /** 标题栏背景延伸至状态栏，内容区从标题栏下方起排 */
  @Param avoidLayoutSafeArea: boolean = true
  /** 绑定页面滚动器（驱动标题栏滚动模糊与上滑隐藏） */
  @Param scroller: Scroller | undefined = undefined
  /** 上滑时随标题栏隐藏 bottomBuilder（搜索行） */
  @Param isSearchBarScroller: boolean = true
  /** 是否显示底部栏 */
  @Param isShowBar: boolean = false
  /** 是否显示底部栏 */
  @Param isShowBarController: boolean = false
  /** 底部栏内容类型：book 显示听书/下载，其余仅主按钮；主按钮文案/图标按类型区分 */
  @Param readBarKind: string = 'book'
  /** 双击标题栏区域时列表回滚到顶部 */
  @Param doubleTapToTop: boolean = false
  @Param scrollToTopYOffset: number = 0
  @Param scrollMaskExtraHeight?: number = 0
  /** 隐藏标题栏（带动画）；阅读页阅读态传 true */
  @Param hideTitleBar: boolean = false
  /** 页面背景色；undefined 用 sys.color.background_secondary */
  @Param pageBackgroundColor: ResourceColor | undefined = undefined
  /** 是否保留品牌橙渐变背景 */
  @Param showBrandGradient: boolean = true
  /** nav标题栏模糊度 */
  @Param navBlurRadius: number = 30
  /** tab遮罩高度 */
  @Param tabMaskHeight: number = 56

  /** 返回 true 拦截系统返回 */
  @Event backPressed: () => boolean = (): boolean => false

  /** readerBar点击回调 */
  @Event readerBarClick: (key: string) => void

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
      this.scroller.scrollTo({ xOffset: 0, yOffset: this.scrollToTopYOffset, animation: { duration: 300, curve: Curve.EaseOut } });
    } else {
      this.lastTitleTapTime = now;
    }
  }
  
  @Monitor('isShowBarController')
  private isShowTabBar(){
    if (this.isShowBarController) {
      // 触发显示动效，恢复页签栏和迷你栏。
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION);
    }else{
      // 触发隐藏动效，页签栏和迷你栏一起隐藏。
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION);
    }
  }

  build() {
    HdsNavDestination() {
      // PC 侧边栏布局下不渲染页面级迷你条（Index 全局悬浮 PlayBar 常驻覆盖所有页面）
      if (this.isShowBar){
        HdsTabs({ controller: this.tabsController }) {
          TabContent(){
            this.content()
          }.tabBar(this.ReadBar())//.align(Alignment.Top)
        }
        .barOverlap(true)
        .vertical(false)
        .scrollable(false)
        .barPosition(BarPosition.End)
        .barHeight(56)
        .barFloatingStyle({
          barWidth: { smallWidth: 330, mediumWidth: 480, largeWidth: 560 },
          barBottomMargin: 28,
          systemMaterialEffect: {
            materialType: appState.materialType,
            materialLevel: appState.materialLevel
          },
          gradientMask: {
            maskHeight: !this.isShowBarController ? 0 : this.tabMaskHeight,
          },
          adaptToHandedness: true,
        })
      }else{
        this.content()
      }
    }
    .titleBar({
      content: this.titleBarOp,
      style: {
        originalStyle: {
          backgroundStyle: { maskExtraHeight: 0, blurRadius: this.navBlurRadius },
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
        scrollEffectStyle: { backgroundStyle: { maskExtraHeight: this.scrollMaskExtraHeight, blurRadius: this.navBlurRadius } },
        blurStrategy: BlurStrategy.ADAPTIVE,
        systemMaterialEffect: {
          materialType: appState.materialType,
          materialLevel: appState.materialLevel
        },
      },
      avoidLayoutSafeArea: this.avoidLayoutSafeArea,
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideTitleBar(this.hideTitleBar, true)
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
    .backgroundColor(this.pageBackgroundColor ?? $r('sys.color.background_secondary'))
    .width('100%')
    .height('100%')
    .onBackPressed(() => {
      return this.backPressed()
    })
    .dynamicHideTitleBar({
      hideBottomBuilder: this.isSearchBarScroller,
      mode: HideMode.SCROLL_UP_TO
    })
    .linearGradient(this.brandGradient())
  }

  /** 品牌橙渐变背景；showBrandGradient 为 false（阅读页）时返回 undefined。 */
  private brandGradient(): LinearGradient | undefined {
    if (!this.showBrandGradient) {
      return undefined;
    }
    const options: LinearGradientOptions = {
      angle: 180,
      colors: [['#1AFF7A3D', 0], ['#00FF7A3D', 1]],
    };
    return options;
  }

  /** 底部悬浮操作栏：小说带听书/下载，其余类型仅主按钮（开始观看/收听/阅读）；reader 为阅读工具条。 */
  @Builder
  private ReadBar() {
    if (this.readBarKind === 'reader') {
      Row() {
        this.ReaderTool($r('sys.symbol.list_bullet'), '目录')
        this.ReaderBarDivider()
        this.ReaderTool($r('sys.symbol.chevron_left'), '上一章')
        this.ReaderBarDivider()
        this.ReaderTool($r('sys.symbol.chevron_right'), '下一章')
        this.ReaderBarDivider()
        this.ReaderTool($r('sys.symbol.textformat'), '设置')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .transition(TransitionEffect.OPACITY.animation({duration: 300}))
    } else {
      Row() {
        if (this.readBarKind === 'book') {
        Row() {
          ForEach([$r('sys.symbol.headphones'), $r('sys.symbol.download')], (v: Resource, i: number) => {
            Column({ space: 3 }) {
              SymbolGlyph(v)
                .fontSize(19)
                .fontColor([$r('sys.color.icon_primary')])
              Text(i === 0 ? '听书' : '下载')
                .fontSize(10.5)
                .fontColor($r('sys.color.font_primary'))
            }
            .alignItems(HorizontalAlign.Center)
            .onClick(() => this.readerBarClick(i === 0 ? '听书' : '下载'))

            if (i === 0) {
              Divider()
                .vertical(true)
                .strokeWidth(0.5)
                .height(22)
                .color($r('sys.color.comp_divider'))
                .margin({ left: 14, right: 14 })
            }
          })
        }

        Divider()
          .vertical(true)
          .strokeWidth(0.5)
          .height(22)
          .color($r('sys.color.comp_divider'))
          .margin({ left: 14, right: 14 })
      }

      Row({ space: 8 }) {
        SymbolGlyph(this.readBarIcon())
          .fontSize(19)
          .fontColor([$r('sys.color.icon')])
        Text(this.readBarLabel())
          .fontSize(15.5)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font'))
      }
      .layoutWeight(1)
      .height(48)
      .borderRadius(24)
      .justifyContent(FlexAlign.Center)
      /*.linearGradient(this.readBarKind === 'book' ? {
        angle: 90,
        colors: [[FQ_ACCENT, 0], ['#E4432E', 1]],
      } : undefined)*/
      .onClick(() => this.readerBarClick(this.readBarActionLabel()))
    }
    .width('100%')
      .padding({ left: this.readBarKind != 'book' ? 0 : 10 })
      .borderRadius(24)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween)
    }
  }

  /** 阅读页悬浮条工具键（对齐听书/下载小键样式），点击按文案分发 readerBarClick。 */
  @Builder
  private ReaderTool(icon: Resource, label: string) {
    Column({ space: 3 }) {
      SymbolGlyph(icon)
        .fontSize(19)
        .fontColor([$r('sys.color.icon_primary')])
      Text(label)
        .fontSize(10.5)
        .fontColor($r('sys.color.font_primary'))
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .onClick(() => {
      this.readerBarClick(label);
    })
  }

  /** 阅读页悬浮条键间分隔线。 */
  @Builder
  private ReaderBarDivider() {
    Divider()
      .vertical(true)
      .strokeWidth(0.5)
      .height(22)
      .color($r('sys.color.comp_divider'))
  }

  /** 主按钮文案：观看 / 收听 / 阅读（对齐 fqapp _readLabel）。 */
  private readBarLabel(): string {
    if (this.readBarKind === 'video' || this.readBarKind === 'manju') {
      return '开始观看';
    }
    if (this.readBarKind === 'audio') {
      return '开始收听';
    }
    return '开始阅读';
  }

  /** 主按钮点击回调标识（页面据此区分动作）。 */
  private readBarActionLabel(): string {
    if (this.readBarKind === 'video' || this.readBarKind === 'manju') {
      return '观看';
    }
    if (this.readBarKind === 'audio') {
      return '收听';
    }
    return '阅读';
  }

  /** 主按钮图标：按内容类型区分（对齐 fqapp homeKindIcon）。 */
  private readBarIcon(): Resource {
    if (this.readBarKind === 'video' || this.readBarKind === 'manju') {
      return $r('sys.symbol.film');
    }
    if (this.readBarKind === 'audio') {
      return $r('sys.symbol.headphones');
    }
    if (this.readBarKind === 'manga') {
      return $r('sys.symbol.book_pages');
    }
    return $r('sys.symbol.book');
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

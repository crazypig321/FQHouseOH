/**
 * 全局悬浮播控球（听书 / 听视频）：
 * - 圆形态：封面 + 封面外缘一圈环形进度（当前章节播放比例）
 * - 点击球体展开控制排：播放/暂停、下一章/下一集、停止、收起
 * - 展开/收回动画：单容器宽度属性动画（64 ↔ 胶囊宽），封面常驻容器靠屏幕侧一端，
 *   随布局动画平滑移动缩小（同节点在树，天然一镜到底）；按钮组随宽度展开淡入
 * - 左侧停靠（智感握姿左手握持）时展开态整体镜像：
 *   封面在最左，按钮组反序（关闭 + 停止 + 下一曲 + 播放），向右展开
 * - 展开态 7s 无操作自动收回
 * - 会话关闭（fqAudioSession.close / hasSession=false）后整体消失
 * - 悬于底部悬浮栏（tabbar/工具栏）上方；左右侧由「智感握姿」决定——
 *   Index 传入 ballAtRight（appState.holdingHand !== 'left'），左手握持时换到左下角；
 *   换侧经 @Monitor 包 animateTo 驱动水平 margin 过渡，球体平滑滑至另一侧。
 */

import { fqAudioSession } from '../core/FqAudioSession';
import { appState } from '../entryability/AppState';
import { ListenNavParams, ROUTE_LISTEN } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { FqColorUtils } from '../utils/FqColorUtils';
import { hdsEffect } from '@kit.UIDesignKit';
import { rowImmersiveModifier } from '../utils/ModifierUtils';

/** 球直径（vp）。 */
const FQ_BALL_SIZE: number = 64;
/** 展开态封面环径（vp）。 */
const FQ_PANEL_COVER_SIZE: number = 48;
/** 展开态封面距容器右缘（vp）。 */
const FQ_PANEL_COVER_INSET: number = 4;
/** 展开态容器总宽（vp）：控制组 196 + 封面 48 + 右距 4。 */
const FQ_PANEL_WIDTH: number = 252;
/** 展开/收回动画时长（ms）。 */
const FQ_TOGGLE_MS: number = 250;
/** 展开态无操作自动收回时长（ms）。 */
const FQ_AUTO_COLLAPSE_MS: number = 7000;
/** 球体距底栏上沿的间隙（vp）。 */
const FQ_BALL_BOTTOM_GAP: number = 12;
/** 底部悬浮栏占位：悬浮边距 28 + 栏高 56（对齐 Index HdsTabs / 工具栏悬浮参数）。 */
const FQ_BOTTOM_BAR_INSET: number = 84;
/** 球体距屏幕左右边缘（vp）。 */
const FQ_BALL_SIDE_MARGIN: number = 16;
/** 智感握姿换侧滑动动画时长（ms）。 */
const FQ_SIDE_SWITCH_MS: number = 250;

@ComponentV2
export struct FqPlaybackBall {
  /** 智感握姿左右侧（Index 传 holdingHand !== 'left'）：true 右侧（默认），false 左侧。 */
  @Param ballAtRight: boolean = true;
  /** 换侧动画镜像值：@Param 变化经 @Monitor 包 animateTo 驱动水平 margin 过渡。 */
  @Local atRightAnim: boolean = true;
  /** 展开态（宽度动画在圆/胶囊之间切换）。 */
  @Local expanded: boolean = false;
  /** 展开态无操作自动收回的定时器句柄。 */
  private autoCollapseId: number = -1;

  aboutToAppear(): void {
    this.atRightAnim = this.ballAtRight;
  }

  aboutToDisappear(): void {
    this.cancelAutoCollapse();
  }

  /** 智感握姿换侧：包裹镜像值变化驱动水平 margin 过渡（球体平滑滑到另一侧）。 */
  @Monitor('ballAtRight')
  onBallSideChange(): void {
    this.getUIContext().animateTo({ duration: FQ_SIDE_SWITCH_MS, curve: Curve.Smooth }, (): void => {
      this.atRightAnim = this.ballAtRight;
    });
  }

  build() {
    // 全屏触控透传层（HitTestMode.None），球体自身正常响应点击；
    // 恒以 BottomStart 锚定，水平位置由 BallPanel 的 margin left 驱动（可动画）
    Stack({ alignContent: Alignment.BottomStart }) {
      if (fqAudioSession.hasSession) {
        this.BallPanel()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 单容器：圆 ↔ 胶囊宽度属性动画；封面常驻靠屏幕侧一端，按钮组展开淡入；
   *  左侧停靠（atRightAnim=false）时镜像：封面在最左，按钮组反序。 */
  @Builder
  private BallPanel() {
    Row() {
      if (this.atRightAnim) {
        if (this.expanded) {
          this.ControlGroup(false)
        }
        this.CoverTapArea()
      } else {
        this.CoverTapArea()
        if (this.expanded) {
          this.ControlGroup(true)
        }
      }
    }
    .width(this.ballPanelWidth())
    .height(FQ_BALL_SIZE)
    .borderRadius(FQ_BALL_SIZE / 2)
    .clip(true)
    .backdropBlur(60, { grayscale: [0,1] })
    .backgroundColor(this.expanded ? '#1affffff' : Color.Transparent)
    .border({ width: 1, color: $r('sys.color.comp_background_list_card') })
    .shadow({ radius: 12, color: '#40000000', offsetY: 2 })
    .margin(this.ballMargin())
    .visualEffect(new hdsEffect.HdsEffectBuilder().pointLight({
     // sourceType: hdsEffect.PointLightSourceType.SOFT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER,
    }).buildEffect())
    .attributeModifier(rowImmersiveModifier)
  }

  /** 控制排（展开态）：右侧停靠顺序 播放/下一曲/停止/关闭；左侧停靠整体反序。 */
  @Builder
  private ControlGroup(atLeft: boolean) {
    Row({ space: 2 }) {
      if (atLeft) {
        this.PanelButton($r('sys.symbol.xmark'), (): void => {
          this.collapse();
        })
        this.PanelButton($r('sys.symbol.stop_circle'), (): void => {
          fqAudioSession.close();
          this.collapse();
        }, true, '#FFE84026')
        this.NextButton()
        this.PlayPauseButton()
      } else {
        this.PlayPauseButton()
        this.NextButton()
        this.PanelButton($r('sys.symbol.stop_circle'), (): void => {
          fqAudioSession.close();
          this.collapse();
        }, true, '#FFE84026')
        this.PanelButton($r('sys.symbol.xmark'), (): void => {
          this.collapse();
        })
      }
    }
    .margin(this.controlGroupMargin(atLeft))
    .transition(TransitionEffect.OPACITY
      .animation({ duration: 150, curve: Curve.EaseOut }))
  }

  /** 播放/暂停按钮（顺序随停靠侧由 ControlGroup 决定）。 */
  @Builder
  private PlayPauseButton() {
    Stack() {
      SymbolGlyph(fqAudioSession.wantPlay && !fqAudioSession.completed
        ? $r('sys.symbol.pause_fill')
        : $r('sys.symbol.play_fill'))
        .fontSize(28)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .onClick(() => {
      fqAudioSession.togglePlayPause();
      this.armAutoCollapse();
    })
  }

  /** 下一章/下一集按钮（末章置灰不可点）。 */
  @Builder
  private NextButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.forward_end_fill'))
        .fontSize(20)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .opacity(fqAudioSession.hasNextChapter ? 1 : 0.35)
    .onClick(() => {
      if (fqAudioSession.hasNextChapter) {
        fqAudioSession.next();
        this.armAutoCollapse();
      }
    })
  }

  /** 封面点击区：圆态点击展开，展开态点击进听书页；贴容器靠屏幕侧一端。 */
  @Builder
  private CoverTapArea() {
    Row() {
      this.CoverWithProgress()
    }
    .margin(this.coverWrapMargin())
    .onClick(() => {
      if (this.expanded) {
        this.openPlayingPage();
      } else {
        this.setExpanded(true);
        this.armAutoCollapse();
      }
    })
  }

  /** 封面 + 外缘环形进度（圆/展开态共用）：
   * 进度环与封面固定尺寸，展开/收回仅做 scale 视觉缩放（纯渲染变换不触发组件重测），
   * 避免 width/height 动画引起 Ring 进度弧重播（展开/收回时进度条跳一下）。 */
  @Builder
  private CoverWithProgress() {
    Stack() {
      Stack() {
        Progress({
          value: this.progressValue(),
          total: this.progressTotal(),
          type: ProgressType.Ring,
        })
          .style({ strokeWidth: this.expanded ? 4 : 6 })
          .color(appState.accentColor)
          .backgroundColor(Color.Transparent)
          .width(FQ_BALL_SIZE - 1)
          .height(FQ_BALL_SIZE - 1)
        if (fqAudioSession.cover.length > 0) {
          Image(fqAudioSession.cover)
            .width(FQ_BALL_SIZE - 12)
            .height(FQ_BALL_SIZE - 12)
            .borderRadius((FQ_BALL_SIZE - 12) / 2)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            SymbolGlyph($r('sys.symbol.headphones'))
              .fontSize(24)
              .fontColor([$r('sys.color.icon_primary')])
          }
          .width(FQ_BALL_SIZE - 12)
          .height(FQ_BALL_SIZE - 12)
          .borderRadius((FQ_BALL_SIZE - 12) / 2)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
        }
      }
      .width(FQ_BALL_SIZE)
      .height(FQ_BALL_SIZE)
      .scale({ x: this.coverScale(), y: this.coverScale() })
    }
    .width(this.ballCoverSize())
    .height(FQ_BALL_SIZE)
  }

  /** 控制排圆钮；enabled false 置灰不可点（末章隐藏下一章入口）。 */
  @Builder
  private PanelButton(icon: Resource, onTap: () => void, enabled: boolean = true,
    tint: ResourceColor = $r('sys.color.icon_primary')) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([tint])
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .opacity(enabled ? 1 : 0.35)
    .onClick(() => {
      if (enabled) {
        onTap();
      }
    })
  }

  /** 展开态点击封面：进入听书页（同书 open 早退，保持现场）。 */
  private openPlayingPage(): void {
    this.collapse();
    ListenNavParams.bookId = fqAudioSession.bookId;
    ListenNavParams.tab = fqAudioSession.tab;
    ListenNavParams.title = fqAudioSession.title;
    ListenNavParams.cover = fqAudioSession.cover;
    ListenNavParams.chapters = fqAudioSession.chapters;
    ListenNavParams.chapterIndex = -1;
    NavPathUtils.push(ROUTE_LISTEN);
  }

  /** 收回展开态并取消自动收回定时器。 */
  private collapse(): void {
    this.cancelAutoCollapse();
    this.setExpanded(false);
  }

  /** 展开/收回切换：animateTo 驱动宽度等属性动画（封面随布局一镜到底）。 */
  private setExpanded(value: boolean): void {
    this.getUIContext().animateTo({ duration: FQ_TOGGLE_MS, curve: Curve.EaseOut }, () => {
      this.expanded = value;
    });
  }

  /** 展开/交互后续接 7s 无操作自动收回。 */
  private armAutoCollapse(): void {
    this.cancelAutoCollapse();
    if (this.expanded) {
      this.autoCollapseId = setTimeout(() => {
        this.autoCollapseId = -1;
        this.setExpanded(false);
      }, FQ_AUTO_COLLAPSE_MS);
    }
  }

  private cancelAutoCollapse(): void {
    if (this.autoCollapseId >= 0) {
      clearTimeout(this.autoCollapseId);
      this.autoCollapseId = -1;
    }
  }

  /** 容器宽：圆 64 ↔ 胶囊 248（宽度属性动画主体）。 */
  private ballPanelWidth(): number {
    return this.expanded ? FQ_PANEL_WIDTH : FQ_BALL_SIZE;
  }

  /** 封面环径：圆态铺满球体，展开态缩小为 48。 */
  private ballCoverSize(): number {
    return this.expanded ? FQ_PANEL_COVER_SIZE : FQ_BALL_SIZE;
  }

  /** 封面视觉缩放比：展开 48/64=0.75，圆态 1（scale 渲染变换，进度环不重测不重播）。 */
  private coverScale(): number {
    return this.ballCoverSize() / FQ_BALL_SIZE;
  }

  /** 封面右距：圆态贴边 0，展开态缩进 4。 */
  private ballCoverRightInset(): number {
    return this.expanded ? FQ_PANEL_COVER_INSET : 0;
  }

  /** 封面贴容器靠屏幕侧：右侧停靠右缩进，左侧停靠（镜像）左缩进。 */
  private coverWrapMargin(): Margin {
    const inset: number = this.ballCoverRightInset();
    return this.atRightAnim ? { right: inset } : { left: inset };
  }

  /** 控制组与封面/容器边缘间距：左侧停靠镜像（8/6 反转）。 */
  private controlGroupMargin(atLeft: boolean): Margin {
    return atLeft ? { left: 6, right: 8 } : { left: 8, right: 6 };
  }

  /** 悬浮位置：底栏上沿再抬高；水平恒用 margin left 定位——
   *  右侧 = 窗口宽 - 球宽 - 边距（右缘贴边），左侧 = 边距；
   *  换侧与展开/收起时 left 随 atRightAnim/expanded 在 animateTo 内重算，平滑过渡。 */
  private ballMargin(): Margin {
    const bottom: number = appState.bottomRect + FQ_BOTTOM_BAR_INSET + FQ_BALL_BOTTOM_GAP;
    const width: number = appState.windowWidthVp > 0 ? appState.windowWidthVp : appState.displayWidthVp;
    const left: number = this.atRightAnim
      ? Math.max(width - FQ_BALL_SIDE_MARGIN - this.ballPanelWidth(), FQ_BALL_SIDE_MARGIN)
      : FQ_BALL_SIDE_MARGIN;
    return { bottom: bottom, left: left };
  }

  private progressTotal(): number {
    return fqAudioSession.durationSec > 0 ? fqAudioSession.durationSec : 1;
  }

  private progressValue(): number {
    const total: number = this.progressTotal();
    const position: number = fqAudioSession.positionSec;
    if (position < 0) {
      return 0;
    }
    return position > total ? total : position;
  }
}

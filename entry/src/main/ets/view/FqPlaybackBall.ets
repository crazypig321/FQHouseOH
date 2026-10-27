/**
 * 全局悬浮播控球（听书 / 听视频）：
 * - 圆形态：封面 + 封面外缘一圈环形进度（当前章节播放比例）
 * - 点击球体展开控制排：播放/暂停、下一章/下一集、停止、收起
 * - 展开/收回动画：单容器宽度属性动画（64 ↔ 胶囊宽），封面常驻容器右端，
 *   随布局动画平滑左移缩小（同节点在树，天然一镜到底）；按钮组随宽度展开淡入
 * - 展开态 7s 无操作自动收回
 * - 会话关闭（fqAudioSession.close / hasSession=false）后整体消失
 * - 悬于底部悬浮栏（tabbar/工具栏）上方；左右侧由「智感握姿」决定——
 *   该能力未实现，预埋 ballAtRight 参数（默认右侧），后续接入时改传值即可。
 */

import { fqAudioSession } from '../core/FqAudioSession';
import { appState } from '../entryability/AppState';
import { ListenNavParams, ROUTE_LISTEN } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { FqColorUtils } from '../utils/FqColorUtils';
import { hdsEffect } from '@kit.UIDesignKit';

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

@ComponentV2
export struct FqPlaybackBall {
  /** 智感握姿左右侧预埋：true 右侧（默认），false 左侧。 */
  @Param ballAtRight: boolean = true;
  /** 展开态（宽度动画在圆/胶囊之间切换）。 */
  @Local expanded: boolean = false;
  /** 展开态无操作自动收回的定时器句柄。 */
  private autoCollapseId: number = -1;

  aboutToDisappear(): void {
    this.cancelAutoCollapse();
  }

  build() {
    // 全屏触控透传层（HitTestMode.None），球体自身正常响应点击
    Stack({ alignContent: this.ballAtRight ? Alignment.BottomEnd : Alignment.BottomStart }) {
      if (fqAudioSession.hasSession) {
        this.BallPanel()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 单容器：圆 ↔ 胶囊宽度属性动画；封面常驻右端随布局移动，按钮组展开淡入。 */
  @Builder
  private BallPanel() {
    Row() {
      if (this.expanded) {
        Row({ space: 2 }) {
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
          this.PanelButton($r('sys.symbol.stop_circle'), (): void => {
            fqAudioSession.close();
            this.collapse();
          }, true, '#FFE84026')
          this.PanelButton($r('sys.symbol.xmark'), (): void => {
            this.collapse();
          })
        }
        .margin({ left: 8, right: 6 })
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 150, curve: Curve.EaseOut }))
      }
      Row() {
        this.CoverWithProgress()
      }
      .margin({ right: this.ballCoverRightInset() })
      .onClick(() => {
        if (this.expanded) {
          this.openPlayingPage();
        } else {
          this.setExpanded(true);
          this.armAutoCollapse();
        }
      })
    }
    .width(this.ballPanelWidth())
    .height(FQ_BALL_SIZE)
    .borderRadius(FQ_BALL_SIZE / 2)
    .clip(true)
    .backdropBlur(45, { grayscale: [0,1] })
    .backgroundColor(this.expanded ? '#12ffffff' : Color.Transparent)
    .border({ width: 1, color: $r('sys.color.comp_background_list_card') })
    .shadow({ radius: 12, color: '#40000000', offsetY: 2 })
    .margin(this.ballMargin())
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

  /** 悬浮位置：底栏上沿再抬高，左右随智感握姿侧位。 */
  private ballMargin(): Margin {
    const bottom: number = appState.bottomRect + FQ_BOTTOM_BAR_INSET + FQ_BALL_BOTTOM_GAP;
    if (this.ballAtRight) {
      return { bottom: bottom, right: FQ_BALL_SIDE_MARGIN };
    }
    return { bottom: bottom, left: FQ_BALL_SIDE_MARGIN };
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

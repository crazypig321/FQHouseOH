/**
 * 评论配图查看（公共组件）：
 * - FqImageViewer：全屏图片查看器（黑底 + 双指缩放 1~4 倍 + 放大后单指平移 +
 *   双击 1x/2.5x + 单击关闭），经 bindContentCover 全屏承载；
 * - FqCommentImages：配图九宫行（76x76 缩略，最多 3 张），点击缩略图
 *   geometryTransition 一镜到底展开 FqImageViewer（缩略图与全屏图同 id 配对，
 *   ModalTransition.NONE 由共享元素转场接管动画），关闭时反向飞回。
 *   官方模态范式约束：cover builder 内容不做显隐 if 守卫（显隐完全由
 *   bindContentCover 显示态驱动），否则关闭时内容先于模态层摘除，
 *   模态层残留不可见遮罩吞掉全部触摸。
 */

import { display } from '@kit.ArkUI';
import { appState } from '../entryability/AppState';

/** 图片查看器内容组件（宿主经 bindContentCover 全屏承载）。 */
@ComponentV2
export struct FqImageViewer {
  /** 图片地址（CDN 签名 URL 原样透传）。 */
  @Param imageUrl: string = '';
  /** 共享元素转场 id（与缩略图配对，一镜到底）。 */
  @Param geometryId: string = '';
  /** 关闭请求（宿主翻转 bindContentCover 显示态）。 */
  @Event requestClose: () => void = (): void => {};
  @Local zoomScale: number = 1;
  @Local panOffsetX: number = 0;
  @Local panOffsetY: number = 0;
  private pinchActive: boolean = false;
  private pinchBaseScale: number = 1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  private halfScreenW: number = 0;
  private halfScreenH: number = 0;

  aboutToAppear(): void {
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const w: number = appState.screenWidth > 0 ? appState.screenWidth : displayData.width;
    const h: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
    this.halfScreenW = w / density / 2;
    this.halfScreenH = h / density / 2;
  }

  private resetTransform(): void {
    this.pinchActive = false;
    this.zoomScale = 1;
    this.panOffsetX = 0;
    this.panOffsetY = 0;
  }

  private clampScale(value: number): number {
    return value < 1 ? 1 : (value > 4 ? 4 : value);
  }

  /** 平移钳制屏幕边界内（缩放余量 × 半屏），避免图片被拖出屏幕看着像卡死。 */
  private clampPanX(x: number): number {
    const limit: number = (this.zoomScale - 1) * this.halfScreenW;
    return x < -limit ? -limit : (x > limit ? limit : x);
  }

  private clampPanY(y: number): number {
    const limit: number = (this.zoomScale - 1) * this.halfScreenH;
    return y < -limit ? -limit : (y > limit ? limit : y);
  }

  build() {
    Stack() {
      Image(this.imageUrl)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .draggable(false)
        .geometryTransition(this.geometryId)
        .transition(TransitionEffect.opacity(0.99))
        .scale({ x: this.zoomScale, y: this.zoomScale })
        .translate({ x: this.panOffsetX, y: this.panOffsetY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2, distance: 3 })
              .onActionStart((): void => {
                this.pinchActive = true;
                this.pinchBaseScale = this.zoomScale;
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.zoomScale = this.clampScale(this.pinchBaseScale * event.scale);
                if (this.zoomScale === 1) {
                  this.panOffsetX = 0;
                  this.panOffsetY = 0;
                }
              })
              .onActionEnd((): void => {
                this.pinchActive = false;
                if (this.zoomScale <= 1) {
                  this.resetTransform();
                }
              }),
            PanGesture({ fingers: 1, distance: 5 })
              .onActionStart((): void => {
                this.panBaseX = this.panOffsetX;
                this.panBaseY = this.panOffsetY;
              })
              .onActionUpdate((event: GestureEvent): void => {
                // 双指缩放期间单指 pan 并行触发会带着图片乱飞，跳过；
                // 仅放大态平移，且钳制在屏幕内。
                if (this.zoomScale > 1 && !this.pinchActive) {
                  this.panOffsetX = this.clampPanX(this.panBaseX + event.offsetX);
                  this.panOffsetY = this.clampPanY(this.panBaseY + event.offsetY);
                }
              }),
          ),
        )
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0.99),
      TransitionEffect.OPACITY,
    ))
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 })
          .onAction((): void => {
            if (this.zoomScale > 1) {
              this.resetTransform();
            } else {
              this.zoomScale = 2.5;
            }
          }),
        TapGesture({ count: 1 })
          .onAction((): void => {
            this.resetTransform();
            this.requestClose();
          }),
      ),
    )
  }
}

/** 评论配图行：缩略图 + 点击一镜到底全屏放大（书评/章评/漫评/段评/回复共用）。 */
/** 评论配图行：缩略图 + 点击一镜到底全屏放大（书评/章评/漫评/段评/回复共用）。 */
@ComponentV2
export struct FqCommentImages {
  /** 配图 URL（最多展示 3 张）。 */
  @Param imageUrls: string[] = [];
  /** 共享元素转场唯一前缀（宿主传瓦片实例唯一值，如 `r12_<回复id>`）。 */
  @Param geometryPrefix: string = '';
  /** 全屏查看层显示态（与 zoomIndex 解耦：关闭动画期间内容仍保留，飞回途中不变空白）。 */
  @Local coverVisible: boolean = false;
  /** 当前放大配图下标（onDisappear 归 -1，过渡期间保持有效供飞回配对）。 */
  @Local zoomIndex: number = -1;

  private openZoom(index: number): void {
    this.getUIContext().animateTo({ duration: 350, curve: Curve.Friction }, (): void => {
      this.zoomIndex = index;
      this.coverVisible = true;
    });
  }

  private closeZoom(): void {
    this.getUIContext().animateTo({ duration: 350, curve: Curve.Friction }, (): void => {
      this.coverVisible = false;
    });
  }

  /** 当前放大图下标（无效时取 0 兜底，避免空配对）。 */
  private zoomedIndex(): number {
    return this.zoomIndex >= 0 && this.zoomIndex < this.imageUrls.length ? this.zoomIndex : 0;
  }

  build() {
    Row({ space: 6 }) {
      ForEach(this.imageUrls.slice(0, 3), (url: string, index: number) => {
        Image(url)
          .width(76)
          .height(76)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .geometryTransition(`${this.geometryPrefix}_${index}`, { follow: true })
          .transition(TransitionEffect.opacity(0.99))
          .onClick((): void => {
            this.openZoom(index);
          })
      }, (url: string, index: number): string => `${index}-${url}`)
    }
    .alignItems(VerticalAlign.Top)
    .bindContentCover(this.coverVisible, this.ZoomCover(), {
      modalTransition: ModalTransition.NONE,
      onWillDismiss: (action: DismissContentCoverAction): void => {
        if (!this.coverVisible) {
          // 兜底：状态已关闭但模态层残留时强制关掉，避免不可见遮罩吞触摸
          action.dismiss();
          return;
        }
        // 返回手势关闭走同一关闭路径（animateTo 翻转），保留一镜到底缩小动画
        this.closeZoom();
      },
      onDisappear: (): void => {
        this.coverVisible = false;
        this.zoomIndex = -1;
      },
    })
  }

  /** 全屏放大内容（官方模态范式：builder 不做显隐守卫，显隐完全由显示态驱动，
   *  关闭转场期间内容保留，几何配对不中断）。 */
  @Builder
  private ZoomCover() {
    FqImageViewer({
      imageUrl: this.imageUrls.length > 0 ? this.imageUrls[this.zoomedIndex()] : '',
      geometryId: `${this.geometryPrefix}_${this.zoomedIndex()}`,
      requestClose: (): void => {
        this.closeZoom();
      },
    })
  }
}

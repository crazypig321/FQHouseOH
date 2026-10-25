/**
 * 漫画分页画布（ComicPage 仿真/覆盖模式专用，架构对齐小说页固定绑定——不做层轮换）：
 * - PixelMap 源：NodeContainer + RenderNode 同帧 Contain 绘制。提交翻页换源即换绘
 *   （@Monitor → invalidate → 下一 vsync 出新图），不经 Image 组件跨实例换源上传，
 *   杜绝提交帧黑底透出的“闪一下”；
 * - 字符串源（预解码未就绪/失败的 URL 回退）：退回 Image 异步加载（降级路径）；
 * - 空串：空白（无图槽位，由调用方 if 守卫保证不进来）。
 */

import { common2D, drawing } from '@kit.ArkGraphics2D';
import { display, DrawContext, FrameNode, NodeController, RenderNode, UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';

/** 画布渲染节点：按宿主控制器状态 Contain 适配绘制位图。 */
class FqComicCanvasRenderNode extends RenderNode {
  private readonly host: FqComicCanvasController;

  constructor(host: FqComicCanvasController) {
    super();
    this.host = host;
  }

  draw(context: DrawContext): void {
    const pm: image.PixelMap | null = this.host.pixelMap;
    const cw: number = this.host.widthPx;
    const ch: number = this.host.heightPx;
    if (pm === null || cw <= 0 || ch <= 0) {
      return;
    }
    const info: image.ImageInfo = pm.getImageInfoSync();
    const iw: number = info.size.width;
    const ih: number = info.size.height;
    if (iw <= 0 || ih <= 0) {
      return;
    }
    // Contain：等比缩放居中，短边贴合
    const scale: number = Math.min(cw / iw, ch / ih);
    const dw: number = iw * scale;
    const dh: number = ih * scale;
    const dx: number = (cw - dw) / 2;
    const dy: number = (ch - dh) / 2;
    const dst: common2D.Rect = { left: dx, top: dy, right: dx + dw, bottom: dy + dh };
    context.canvas.drawImageRect(pm, dst,
      new drawing.SamplingOptions(drawing.FilterMode.FILTER_MODE_LINEAR));
  }
}

/** 画布宿主控制器：持绘制区尺寸与当前位图，invalidate 换渲染节点驱动重绘。 */
export class FqComicCanvasController extends NodeController {
  private rootNode: FrameNode | null = null;
  private ui: UIContext | null = null;
  /** 绘制区尺寸（px）。 */
  public widthPx: number = 0;
  public heightPx: number = 0;
  /** 待绘位图（null = 空白）。 */
  public pixelMap: image.PixelMap | null = null;

  makeNode(uiContext: UIContext): FrameNode {
    this.ui = uiContext;
    this.rootNode = new FrameNode(uiContext);
    this.applyRootFrame();
    this.mountRenderNode();
    return this.rootNode;
  }

  /** 尺寸/位图变化后重绘（根 frame 同步 + 清子节点挂新渲染节点）。 */
  public invalidate(): void {
    this.applyRootFrame();
    this.mountRenderNode();
  }

  private applyRootFrame(): void {
    const root: FrameNode | null = this.rootNode;
    const ui: UIContext | null = this.ui;
    if (root === null || ui === null) {
      return;
    }
    const renderNode = root.getRenderNode();
    if (renderNode !== null) {
      renderNode.frame = {
        x: 0,
        y: 0,
        width: ui.px2vp(this.widthPx),
        height: ui.px2vp(this.heightPx),
      };
    }
  }

  private mountRenderNode(): void {
    const root: FrameNode | null = this.rootNode;
    if (root === null) {
      return;
    }
    const renderNode = root.getRenderNode();
    if (renderNode !== null) {
      renderNode.clearChildren();
      renderNode.appendChild(new FqComicCanvasRenderNode(this));
    }
  }
}

@ComponentV2
export struct FqComicCanvas {
  /** 图源：PixelMap（同帧绘制）/ URL 字符串（Image 异步回退）。 */
  @Param source: image.PixelMap | string = '';
  /** 绘制区高（vp，与分页图片定高一致）。 */
  @Param heightVp: number = 0;

  private controller: FqComicCanvasController = new FqComicCanvasController();
  /** 上次同步进控制器的源（引用比较去重，免重复 invalidate）。 */
  private lastSource: image.PixelMap | string = '';

  aboutToAppear(): void {
    this.syncSource();
  }

  @Monitor('source')
  onSourceChange(): void {
    this.syncSource();
  }

  /** 源同步：PixelMap 入控制器换绘；字符串清空位图（Image 分支接管显示）。 */
  private syncSource(): void {
    const src: image.PixelMap | string = this.source;
    if (src === this.lastSource) {
      return;
    }
    this.lastSource = src;
    this.controller.pixelMap = typeof src !== 'string' ? src : null;
    this.controller.invalidate();
  }

  build() {
    if (typeof this.source === 'string') {
      Image(this.source)
        .width('100%')
        .height(this.heightVp)
        .objectFit(ImageFit.Contain)
        .draggable(false)
    } else {
      NodeContainer(this.controller)
        .width('100%')
        .height(this.heightVp)
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.onCanvasAreaChange(newArea);
        })
    }
  }

  /** 首布局/定高变化：px 尺寸入控制器并重绘。 */
  private onCanvasAreaChange(area: Area): void {
    const wVp: number = typeof area.width === 'number' ? area.width : 0;
    const hVp: number = typeof area.height === 'number' ? area.height : 0;
    const density: number = this.densityPx();
    const widthPx: number = Math.round(wVp * density);
    const heightPx: number = Math.round(hVp * density);
    if (widthPx !== this.controller.widthPx || heightPx !== this.controller.heightPx) {
      this.controller.widthPx = widthPx;
      this.controller.heightPx = heightPx;
      this.controller.invalidate();
    }
  }

  /** 密度（px/vp）。 */
  private densityPx(): number {
    const displayData: display.Display = display.getDefaultDisplaySync();
    return displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  }
}

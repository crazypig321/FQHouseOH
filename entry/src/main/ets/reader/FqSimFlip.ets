/**
 * 仿真翻页绘制核心（ReaderPage2 专用，移植自 PageFlip-master 官方示例）：
 * - FqSimFlipController：折页几何（A~K 点）/路径/阴影/镜像绘制，全 px 坐标系；
 *   修复示例两处问题：drawShadow 内嵌 restore 导致的 save/restore 不平衡
 *   （本模块 drawShadowCore 不 restore，各阴影方法对称 save/restore），
 *   以及空路径 lineTo 隐式起点（buildPathA 显式 moveTo(0,0) 等价替换）；
 * - FqSimFlipRenderNode：自绘制渲染节点，draw 委托控制器；
 * - FqSimFlipNodeController：NodeContainer 宿主，根节点尺寸由 px 宽高换算 vp。
 * 状态（zone/phase/dir/positionX/Y/pixelMap）由 FqReaderFlip 驱动，本模块只负责画。
 */

import { common2D, drawing } from '@kit.ArkGraphics2D';
import { DrawContext, FrameNode, NodeController, RenderNode, UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';

/** 触摸起始区域。 */
export enum FqFlipZone {
  NONE = 0,
  TOP = 1,
  BOTTOM = 2,
  MIDDLE = 3,
}

/** 绘制阶段：拖动跟手 / 松手自动。 */
export enum FqFlipPhase {
  NONE = 0,
  MOVING = 1,
  RELEASE = 2,
}

/** 翻页方向：FORWARD = 前翻上一页（右滑）/ BACKWARD = 后翻下一页（左滑）。 */
export enum FqFlipDir {
  NONE = 0,
  FORWARD = 1,
  BACKWARD = 2,
}

/** 折角圆弧半径（页宽比例，对齐示例 SIXTY_PERCENT）。 */
const FQ_SIM_SIXTY: number = 0.6;

/** 坐标点。 */
class FqSimPoint {
  x: number = 0;
  y: number = 0;
}

/** NodeContainer 宿主：根节点 frame 随控制器 px 宽高换算（vp）。 */
export class FqSimFlipNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private uiContext: UIContext | null = null;
  /** 根节点尺寸（px）。 */
  public widthPx: number = 0;
  public heightPx: number = 0;

  makeNode(uiContext: UIContext): FrameNode {
    this.uiContext = uiContext;
    this.rootNode = new FrameNode(uiContext);
    this.applyRootFrame();
    return this.rootNode;
  }

  /** 挂载自绘制渲染节点。 */
  public addNode(node: RenderNode): void {
    const root: FrameNode | null = this.rootNode;
    if (root === null) {
      return;
    }
    const renderNode = root.getRenderNode();
    if (renderNode !== null) {
      renderNode.appendChild(node);
    }
  }

  /** 清空子节点。 */
  public clearNodes(): void {
    const root: FrameNode | null = this.rootNode;
    if (root === null) {
      return;
    }
    const renderNode = root.getRenderNode();
    if (renderNode !== null) {
      renderNode.clearChildren();
    }
  }

  /** 尺寸变化后刷新根节点 frame（makeNode 前调用则首次挂载即生效）。 */
  public refreshRootFrame(): void {
    this.applyRootFrame();
  }

  private applyRootFrame(): void {
    const root: FrameNode | null = this.rootNode;
    const ui: UIContext | null = this.uiContext;
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
      renderNode.pivot = { x: 50, y: 50 };
    }
  }
}

/** 仿真翻页控制器：持有全部绘制状态与几何计算（全 px）。 */
export class FqSimFlipController {
  /** 页宽/高（px）。 */
  public widthPx: number = 0;
  public heightPx: number = 0;
  /** 折点位置（px；positionX < 0 表示无绘制）。 */
  public positionX: number = -1;
  public positionY: number = -1;
  /** 触摸起始区域 / 绘制阶段 / 翻页方向。 */
  public zone: FqFlipZone = FqFlipZone.NONE;
  public phase: FqFlipPhase = FqFlipPhase.NONE;
  public dir: FqFlipDir = FqFlipDir.NONE;
  /** 折叠页截图。 */
  public pixelMap: image.PixelMap | null = null;
  /** 折点 A 的 y 存档（松手自动翻页沿该高度滑出）。 */
  public flipPositionY: number = 0;
  /** 折叠区域是否已滑出窗口（后退式自动翻页终止条件）。 */
  public isFinished: boolean = false;
  /** NodeContainer 宿主。 */
  public readonly nodeController: FqSimFlipNodeController = new FqSimFlipNodeController();

  private pointA: FqSimPoint = new FqSimPoint();
  private pointB: FqSimPoint = new FqSimPoint();
  private pointC: FqSimPoint = new FqSimPoint();
  private pointD: FqSimPoint = new FqSimPoint();
  private pointE: FqSimPoint = new FqSimPoint();
  private pointF: FqSimPoint = new FqSimPoint();
  private pointG: FqSimPoint = new FqSimPoint();
  private pointH: FqSimPoint = new FqSimPoint();
  private pointI: FqSimPoint = new FqSimPoint();
  private pointJ: FqSimPoint = new FqSimPoint();
  private pointK: FqSimPoint = new FqSimPoint();
  /** A 侧阴影宽度。 */
  private lShadowDis: number = 0;
  private rShadowDis: number = 0;
  private brushA: drawing.Brush = new drawing.Brush();
  private brushC: drawing.Brush = new drawing.Brush();
  private pathA: drawing.Path = new drawing.Path();
  private pathC: drawing.Path = new drawing.Path();
  /** 底页投影渐变深色端（随页底色明暗适配，亮色示例默认近黑）。 */
  private bShadowDeep: number = 0xff111111;

  constructor() {
    this.brushA.setColor({ alpha: 255, red: 255, green: 235, blue: 195 });
    this.brushC.setColor({ alpha: 120, red: 186, green: 172, blue: 145 });
  }

  /** 主题适配：折叠背面底色 / 背面蒙层 / 底页投影深色端。
   * 深色主题页底色为深色时，须传深色背面避免翻页过程亮色闪屏。 */
  public setFoldColors(back: common2D.Color, tint: common2D.Color, bShadowDeep: number): void {
    this.brushA.setColor(back);
    this.brushC.setColor(tint);
    this.bShadowDeep = bShadowDeep;
  }

  /** 重置状态（不触碰 NodeContainer 可见性，由宿主管理）。 */
  public reset(): void {
    this.positionX = -1;
    this.positionY = -1;
    this.zone = FqFlipZone.NONE;
    this.phase = FqFlipPhase.NONE;
    this.dir = FqFlipDir.NONE;
    this.isFinished = false;
    this.flipPositionY = 0;
    this.releasePixelMap();
  }

  /** 释放截图。 */
  public releasePixelMap(): void {
    if (this.pixelMap !== null) {
      this.pixelMap.release();
      this.pixelMap = null;
    }
  }

  /** 设置页尺寸（px），同步刷新 NodeContainer 根节点 frame。 */
  public setSize(widthPx: number, heightPx: number): void {
    this.widthPx = widthPx;
    this.heightPx = heightPx;
    this.nodeController.widthPx = widthPx;
    this.nodeController.heightPx = heightPx;
    this.nodeController.refreshRootFrame();
  }

  /** 帧绘制入口：底页阴影 → 背面 → 正面裁切内容 → 阴影。 */
  public draw(canvas: drawing.Canvas): void {
    const pm: image.PixelMap | null = this.pixelMap;
    // 仅 -1 为「无绘制」哨兵：后退式自动翻页中折点会滑入负 x 区，
    // 期间仍需继续算几何以触发 isFinished，不能用 < 0 拦截。
    if (pm === null || this.positionX === -1 || this.widthPx <= 0 || this.heightPx <= 0) {
      return;
    }
    this.initGeom();
    this.drawPathBShadow(canvas);
    this.drawPathC(canvas, pm);
    this.buildPathA();
    this.drawPathAContent(canvas, pm);
  }

  /** 几何初始化：按触摸区域定 F 点、约束 A 点，再算全部路径点。 */
  private initGeom(): void {
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    this.pointA.x = this.positionX;
    this.pointA.y = this.positionY;
    if (this.zone === FqFlipZone.TOP) {
      this.pointF.x = w;
      this.pointF.y = 0;
      if (this.phase !== FqFlipPhase.RELEASE) {
        this.calcPointAByTouchPoint();
      }
    } else if (this.zone === FqFlipZone.BOTTOM) {
      this.pointF.x = w;
      this.pointF.y = h;
      if (this.phase !== FqFlipPhase.RELEASE) {
        this.calcPointAByTouchPoint();
      }
    } else {
      // 中部：折线恒在 A.y = 页高-1；A.x 收敛防 F.x-G.x 为 0
      this.pointA.y = h - 1;
      this.pointA.x = Math.min(this.pointA.x, w - 1);
      this.pointF.x = w;
      this.pointF.y = h;
    }
    this.flipPositionY = this.pointA.y;
    this.calcPointsXY();
  }

  /** 按圆弧约束重算 A 点（上/下区域）；含边界与 NaN 防护。 */
  private calcPointAByTouchPoint(): void {
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    const r: number = FQ_SIM_SIXTY * w;
    const tx: number = Math.max(0, Math.min(w - 1, this.pointA.x));
    this.pointA.x = tx;
    const inner: number = r * r - (tx - (w - r)) * (tx - (w - r));
    if (this.pointF.y === h) {
      const tmpY: number = inner > 0 ? h - Math.sqrt(inner) : h;
      this.pointA.y = Math.max(this.positionY, tmpY);
      this.pointA.y = Math.min(this.pointA.y, h - 1);
    } else {
      const tmpY: number = inner > 0 ? Math.sqrt(inner) : 0;
      this.pointA.y = Math.min(this.positionY, tmpY);
      this.pointA.y = Math.max(this.pointA.y, 1);
    }
  }

  /** 计算全部路径点（B~K）与阴影宽度，并检测折叠区是否滑出窗口。 */
  private calcPointsXY(): void {
    const a: FqSimPoint = this.pointA;
    const f: FqSimPoint = this.pointF;
    const g: FqSimPoint = this.pointG;
    g.x = (a.x + f.x) / 2;
    g.y = (a.y + f.y) / 2;
    const e: FqSimPoint = this.pointE;
    e.x = g.x - (f.y - g.y) * (f.y - g.y) / (f.x - g.x);
    e.y = f.y;
    const hp: FqSimPoint = this.pointH;
    hp.x = f.x;
    hp.y = g.y - (f.x - g.x) * (f.x - g.x) / (f.y - g.y);
    const c: FqSimPoint = this.pointC;
    c.x = e.x - (f.x - e.x) / 2;
    c.y = f.y;
    const j: FqSimPoint = this.pointJ;
    j.x = f.x;
    j.y = hp.y - (f.y - hp.y) / 2;
    FqSimFlipController.intersectTo(a, e, c, j, this.pointB);
    FqSimFlipController.intersectTo(a, hp, c, j, this.pointK);
    const b: FqSimPoint = this.pointB;
    const k: FqSimPoint = this.pointK;
    const d: FqSimPoint = this.pointD;
    d.x = (c.x + 2 * e.x + b.x) / 4;
    d.y = (2 * e.y + c.y + b.y) / 4;
    const i: FqSimPoint = this.pointI;
    i.x = (j.x + 2 * hp.x + k.x) / 4;
    i.y = (2 * hp.y + j.y + k.y) / 4;
    const lA: number = a.y - e.y;
    const lB: number = e.x - a.x;
    const lC: number = a.x * e.y - e.x * a.y;
    this.lShadowDis = Math.abs((lA * d.x + lB * d.y + lC) / Math.hypot(lA, lB));
    const rA: number = a.y - hp.y;
    const rB: number = hp.x - a.x;
    const rC: number = a.x * hp.y - hp.x * a.y;
    this.rShadowDis = Math.abs((rA * i.x + rB * i.y + rC) / Math.hypot(rA, rB));
    if (!this.checkDrawingAreaInWindow()) {
      this.isFinished = true;
    }
  }

  /** 两线段交点（结果写入 out）。 */
  private static intersectTo(p1: FqSimPoint, p2: FqSimPoint, p3: FqSimPoint, p4: FqSimPoint,
    out: FqSimPoint): void {
    const x1: number = p1.x;
    const y1: number = p1.y;
    const x2: number = p2.x;
    const y2: number = p2.y;
    const x3: number = p3.x;
    const y3: number = p3.y;
    const x4: number = p4.x;
    const y4: number = p4.y;
    out.x = ((x1 - x2) * (x3 * y4 - x4 * y3) - (x3 - x4) * (x1 * y2 - x2 * y1))
      / ((x3 - x4) * (y1 - y2) - (x1 - x2) * (y3 - y4));
    out.y = ((y1 - y2) * (x3 * y4 - x4 * y3) - (x1 * y2 - x2 * y1) * (y3 - y4))
      / ((y1 - y2) * (x3 - x4) - (x1 - x2) * (y3 - y4));
  }

  /** 折叠区是否仍在窗口内（DI 连线截距判断）。 */
  private checkDrawingAreaInWindow(): boolean {
    const h: number = this.heightPx;
    if (this.pointD.x === this.pointI.x) {
      return true;
    }
    const k: number = (this.pointD.y - this.pointI.y) / (this.pointD.x - this.pointI.x);
    const b: number = this.pointD.y - k * this.pointD.x;
    if ((this.pointF.y === 0 && b > h) || (this.pointF.y !== 0 && b < 0)) {
      return false;
    }
    return true;
  }

  /** 正面裁切路径（显式 moveTo(0,0)，等价示例空路径 lineTo 且无歧义）。 */
  private buildPathA(): void {
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    this.pathA.reset();
    if (this.pointF.x === w && this.pointF.y === 0) {
      this.pathA.moveTo(0, 0);
      this.pathA.lineTo(this.pointC.x, this.pointC.y);
      this.pathA.quadTo(this.pointE.x, this.pointE.y, this.pointB.x, this.pointB.y);
      this.pathA.lineTo(this.pointA.x, this.pointA.y);
      this.pathA.lineTo(this.pointK.x, this.pointK.y);
      this.pathA.quadTo(this.pointH.x, this.pointH.y, this.pointJ.x, this.pointJ.y);
      this.pathA.lineTo(w, h);
      this.pathA.lineTo(0, h);
      this.pathA.close();
    } else if (this.pointF.x === w && this.pointF.y === h) {
      this.pathA.moveTo(0, 0);
      this.pathA.lineTo(0, h);
      this.pathA.lineTo(this.pointC.x, this.pointC.y);
      this.pathA.quadTo(this.pointE.x, this.pointE.y, this.pointB.x, this.pointB.y);
      this.pathA.lineTo(this.pointA.x, this.pointA.y);
      this.pathA.lineTo(this.pointK.x, this.pointK.y);
      this.pathA.quadTo(this.pointH.x, this.pointH.y, this.pointJ.x, this.pointJ.y);
      this.pathA.lineTo(w, 0);
      this.pathA.close();
    }
  }

  /** 底页（折叠后方页）投影。 */
  private drawPathBShadow(canvas: drawing.Canvas): void {
    canvas.save();
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    const deepColor: number = this.bShadowDeep;
    const lightColor: number = 0x00111111;
    const gradientColors: number[] = [deepColor, lightColor];
    const aToF: number = Math.hypot(this.pointA.x - this.pointF.x, this.pointA.y - this.pointF.y);
    const viewDiagonalLength: number = Math.hypot(w, h);
    let left: number = 0;
    let right: number = 0;
    const top: number = this.pointC.y;
    const bottom: number = viewDiagonalLength + this.pointC.y;
    if (this.pointF.x === w && this.pointF.y === 0) {
      left = this.pointC.x;
      right = this.pointC.x + aToF / 4;
    } else {
      left = this.pointC.x - aToF / 4;
      right = this.pointC.x;
    }
    const deltaX: number = this.pointH.y - this.pointF.y;
    const deltaY: number = this.pointE.x - this.pointF.x;
    const radians: number = Math.atan2(deltaY, deltaX);
    const rotateDegrees: number = radians * 180 / Math.PI;
    const startPt: common2D.Point = { x: this.pointF.y === 0 ? right : left, y: top };
    const endPt: common2D.Point = { x: this.pointF.y === 0 ? left : right, y: top };
    const shaderEffect: drawing.ShaderEffect =
      drawing.ShaderEffect.createLinearGradient(endPt, startPt, gradientColors, drawing.TileMode.MIRROR);
    canvas.rotate(rotateDegrees, this.pointC.x, this.pointC.y);
    const rect: common2D.Rect = { left: left, top: top, right: right, bottom: bottom };
    this.drawShadowCore(canvas, shaderEffect, rect);
    canvas.restore();
  }

  /** 背面（折叠页反面）投影。 */
  private drawPathCShadow(canvas: drawing.Canvas): void {
    canvas.save();
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    const deepColor: number = 0x88111111;
    const lightColor: number = 0x00111111;
    const gradientColors: number[] = [lightColor, deepColor];
    const deepOffset: number = 1;
    const viewDiagonalLength: number = Math.hypot(w, h);
    const midPointCE: number = (this.pointC.x + this.pointE.x) / 2;
    const midPointJH: number = (this.pointJ.y + this.pointH.y) / 2;
    const minDisToControlPoint: number =
      Math.min(Math.abs(midPointCE - this.pointE.x), Math.abs(midPointJH - this.pointH.y));
    let left: number = 0;
    let right: number = 0;
    const top: number = this.pointC.y;
    const bottom: number = viewDiagonalLength + this.pointC.y;
    if (this.pointF.x === w && this.pointF.y === 0) {
      left = this.pointC.x - deepOffset;
      right = this.pointC.x + minDisToControlPoint;
    } else {
      left = this.pointC.x - minDisToControlPoint;
      right = this.pointC.x + deepOffset;
    }
    const deltaX: number = this.pointH.y - this.pointF.y;
    const deltaY: number = this.pointE.x - this.pointF.x;
    const radians: number = Math.atan2(deltaY, deltaX);
    const rotateDegrees: number = radians * 180 / Math.PI;
    const startPt: common2D.Point = { x: this.pointF.y === 0 ? right : left, y: top };
    const endPt: common2D.Point = { x: this.pointF.y === 0 ? left : right, y: top };
    const shaderEffect: drawing.ShaderEffect =
      drawing.ShaderEffect.createLinearGradient(endPt, startPt, gradientColors, drawing.TileMode.MIRROR);
    canvas.rotate(rotateDegrees, this.pointC.x, this.pointC.y);
    const rect: common2D.Rect = { left: left, top: top, right: right, bottom: bottom };
    this.drawShadowCore(canvas, shaderEffect, rect);
    canvas.restore();
  }

  /** 折叠页背面：镜像矩阵绘制截图 + 背面色 + 背面投影。 */
  private drawPathC(canvas: drawing.Canvas, pm: image.PixelMap): void {
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    canvas.attachBrush(this.brushA);
    this.pathC.reset();
    this.pathC.moveTo(this.pointI.x, this.pointI.y);
    this.pathC.lineTo(this.pointD.x, this.pointD.y);
    this.pathC.lineTo(this.pointB.x, this.pointB.y);
    this.pathC.lineTo(this.pointA.x, this.pointA.y);
    this.pathC.lineTo(this.pointK.x, this.pointK.y);
    this.pathC.close();
    canvas.drawPath(this.pathC);
    canvas.save();
    canvas.clipPath(this.pathC);
    const eh: number = Math.hypot(this.pointF.x - this.pointE.x, this.pointH.y - this.pointF.y);
    const sin0: number = (this.pointF.x - this.pointE.x) / eh;
    const cos0: number = (this.pointH.y - this.pointF.y) / eh;
    const value: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 1];
    value[0] = -(1 - 2 * sin0 * sin0);
    value[1] = 2 * sin0 * cos0;
    value[3] = 2 * sin0 * cos0;
    value[4] = 1 - 2 * sin0 * sin0;
    const matrix: drawing.Matrix = new drawing.Matrix();
    matrix.reset();
    matrix.setMatrix(value);
    matrix.preTranslate(-this.pointE.x, -this.pointE.y);
    matrix.postTranslate(this.pointE.x, this.pointE.y);
    canvas.concatMatrix(matrix);
    const verts: number[] = [0, 0, w, 0, 0, h, w, h];
    canvas.drawPixelMapMesh(pm, 1, 1, verts, 0, null, 0);
    canvas.restore();
    canvas.detachBrush();
    canvas.attachBrush(this.brushC);
    canvas.drawPath(this.pathC);
    canvas.detachBrush();
    canvas.save();
    canvas.clipPath(this.pathC);
    this.drawPathCShadow(canvas);
    canvas.restore();
  }

  /** 正面：pathA 内绘制截图 + 折线阴影（中部横向 / 上下双侧）。 */
  private drawPathAContent(canvas: drawing.Canvas, pm: image.PixelMap): void {
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    canvas.attachBrush(this.brushA);
    canvas.save();
    canvas.clipPath(this.pathA);
    const verts: number[] = [0, 0, w, 0, 0, h, w, h];
    canvas.drawPixelMapMesh(pm, 1, 1, verts, 0, null, 0);
    canvas.restore();
    if (this.zone === FqFlipZone.MIDDLE) {
      this.drawPathAHorizontalShadow(canvas);
    } else {
      this.drawPathALeftShadow(canvas);
      this.drawPathARightShadow(canvas);
    }
  }

  /** 正面左侧阴影。 */
  private drawPathALeftShadow(canvas: drawing.Canvas): void {
    canvas.save();
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    const deepColor: number = 0x88111111;
    const lightColor: number = 0x00111111;
    const gradientColors: number[] = [lightColor, deepColor];
    let left: number = 0;
    let right: number = 0;
    const top: number = this.pointE.y;
    const bottom: number = this.pointE.y + h;
    if (this.pointF.x === w && this.pointF.y === 0) {
      left = this.pointE.x - this.lShadowDis / 2;
      right = this.pointE.x;
    } else {
      left = this.pointE.x;
      right = this.pointE.x + this.lShadowDis / 2;
    }
    const deltaX: number = this.pointA.y - this.pointE.y;
    const deltaY: number = this.pointE.x - this.pointA.x;
    const radians: number = Math.atan2(deltaY, deltaX);
    const rotateDegrees: number = radians * 180 / Math.PI;
    const startPt: common2D.Point = { x: this.pointF.y === h ? left : right, y: top };
    const endPt: common2D.Point = { x: this.pointF.y === h ? right : left, y: top };
    const shaderEffect: drawing.ShaderEffect =
      drawing.ShaderEffect.createLinearGradient(endPt, startPt, gradientColors, drawing.TileMode.MIRROR);
    const tmpPath: drawing.Path = new drawing.Path();
    tmpPath.moveTo(this.pointA.x - Math.max(this.rShadowDis, this.lShadowDis) / 2, this.pointA.y);
    tmpPath.lineTo(this.pointD.x, this.pointD.y);
    tmpPath.lineTo(this.pointE.x, this.pointE.y);
    tmpPath.lineTo(this.pointA.x, this.pointA.y);
    tmpPath.close();
    canvas.clipPath(this.pathA);
    canvas.clipPath(tmpPath, drawing.ClipOp.INTERSECT);
    canvas.rotate(rotateDegrees, this.pointE.x, this.pointE.y);
    const rect: common2D.Rect = { left: left, top: top, right: right, bottom: bottom };
    this.drawShadowCore(canvas, shaderEffect, rect);
    canvas.restore();
  }

  /** 正面右侧阴影。 */
  private drawPathARightShadow(canvas: drawing.Canvas): void {
    canvas.save();
    canvas.clipPath(this.pathA);
    const w: number = this.widthPx;
    const h: number = this.heightPx;
    const deepColor: number = 0x88111111;
    const lightColor: number = 0x00111111;
    const gradientColors: number[] = [deepColor, lightColor, lightColor, lightColor];
    const viewDiagonalLength: number = Math.hypot(w, h);
    const left: number = this.pointH.x;
    const right: number = this.pointH.x + viewDiagonalLength * 10;
    let top: number = 0;
    let bottom: number = 0;
    if (this.pointF.x === w && this.pointF.y === 0) {
      top = this.pointH.y - this.rShadowDis / 2;
      bottom = this.pointH.y;
    } else {
      top = this.pointH.y;
      bottom = this.pointH.y + this.rShadowDis / 2;
    }
    const deltaX: number = this.pointA.x - this.pointH.x;
    const deltaY: number = this.pointA.y - this.pointH.y;
    const radians: number = Math.atan2(deltaY, deltaX);
    const rotateDegrees: number = radians * 180 / Math.PI;
    const startPt: common2D.Point = { x: left, y: this.pointF.y === h ? bottom : top };
    const endPt: common2D.Point = { x: left, y: this.pointF.y === h ? top : bottom };
    const shaderEffect: drawing.ShaderEffect =
      drawing.ShaderEffect.createLinearGradient(endPt, startPt, gradientColors, drawing.TileMode.MIRROR);
    const tmpPath: drawing.Path = new drawing.Path();
    tmpPath.moveTo(this.pointA.x - Math.max(this.rShadowDis, this.lShadowDis) / 2, this.pointA.y);
    tmpPath.lineTo(this.pointH.x, this.pointH.y);
    tmpPath.lineTo(this.pointA.x, this.pointA.y);
    tmpPath.close();
    canvas.clipPath(tmpPath, drawing.ClipOp.INTERSECT);
    canvas.rotate(rotateDegrees, this.pointH.x, this.pointH.y);
    const rect: common2D.Rect = { left: left, top: top, right: right, bottom: bottom };
    this.drawShadowCore(canvas, shaderEffect, rect);
    canvas.restore();
  }

  /** 中部横向滑动阴影。 */
  private drawPathAHorizontalShadow(canvas: drawing.Canvas): void {
    canvas.save();
    const h: number = this.heightPx;
    const deepColor: number = 0x88111111;
    const lightColor: number = 0x00111111;
    const gradientColors: number[] = [lightColor, deepColor];
    const maxShadowWidth: number = 30;
    const left: number = this.pointA.x - Math.min(maxShadowWidth, this.rShadowDis / 2);
    const right: number = this.pointA.x + 70;
    const top: number = 0;
    const bottom: number = h;
    canvas.clipPath(this.pathA);
    const startPt: common2D.Point = { x: right, y: top };
    const endPt: common2D.Point = { x: left, y: top };
    const shaderEffect: drawing.ShaderEffect =
      drawing.ShaderEffect.createLinearGradient(endPt, startPt, gradientColors, drawing.TileMode.MIRROR);
    const rect: common2D.Rect = { left: left, top: top, right: right, bottom: bottom };
    this.drawShadowCore(canvas, shaderEffect, rect);
    canvas.restore();
  }

  /** 渐变矩形阴影（不 restore，调用方对称包裹 save/restore）。 */
  private drawShadowCore(canvas: drawing.Canvas, shaderEffect: drawing.ShaderEffect,
    rect: common2D.Rect): void {
    const tmpBrush: drawing.Brush = new drawing.Brush();
    tmpBrush.setShaderEffect(shaderEffect);
    canvas.attachBrush(tmpBrush);
    canvas.drawRect(rect.left, rect.top, rect.right, rect.bottom);
    canvas.detachBrush();
  }
}

/** 自绘制渲染节点：draw 委托控制器。 */
export class FqSimFlipRenderNode extends RenderNode {
  private readonly flip: FqSimFlipController;

  constructor(flip: FqSimFlipController) {
    super();
    this.flip = flip;
  }

  draw(context: DrawContext): void {
    this.flip.draw(context.canvas);
  }
}

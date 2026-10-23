/**
 * 自定义阅读页翻页容器（ReaderPage2 专用）：
 * - 仿真模式（flipMode=0）：移植 PageFlip-master 折角仿真——槽位页截图 + FqSimFlip
 *   自绘折叠层跟手卷曲，松手按位移/速度阈值完成翻页或回弹取消；
 * - 平移模式（flipMode=1）：三层 Stack（prev / cur / next）两页联动横滑。
 * 槽位三区：眉页 / 正文 / 眉脚（headerRenderer / pageRenderer / footerRenderer），
 * 仿真截图随页卷曲。顶层三列触区：左=上一页 / 中=呼出菜单 / 右=下一页；
 * 触区点击先按引擎输出的气泡 rect 仲裁段评气泡命中（页面级坐标含眉页区）。
 * 翻页完成回调 onTurn 由父级同步切换页数据（预载就绪后无缝衔接，无二次加载）。
 */

import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appState } from '../entryability/AppState';
import { FqPageBubble } from './ReaderTypes';
import { FqFlipDir, FqFlipPhase, FqFlipZone, FqSimFlipController, FqSimFlipRenderNode } from './FqSimFlip';

/** 平移模式：松手完成动画时长（ms）。 */
const FQ_FLIP_SETTLE_DURATION: number = 260;
/** 平移模式：回弹时长（ms）。 */
const FQ_FLIP_BACK_DURATION: number = 220;
/** 松手翻页判定：位移超过页宽比例。 */
const FQ_FLIP_DISTANCE_RATIO: number = 1 / 3;
/** 松手翻页判定：横向速度阈值（vp/s）。 */
const FQ_FLIP_VELOCITY_VPS: number = 600;
/** 仿真自动翻页定时器周期（ms，对齐示例 TIMER_DURATION）。 */
const FQ_SIM_TIMER_MS: number = 8.3;
/** 仿真后退式每 tick 折点横移步长（px，对齐示例 FLIP_X_DIFF）。 */
const FQ_SIM_BACK_STEP_PX: number = 100;
/** 仿真前进式收敛份数（对齐示例 DISTANCE_FRACTION）。 */
const FQ_SIM_SETTLE_DIV: number = 20;

@ComponentV2
export struct FqReaderFlip {
  /** 翻页模式：0 仿真 / 1 平移。 */
  @Param flipMode: number = 0;
  /** 上一页/下一页可用（章内邻页或已预载邻章）。 */
  @Param hasPrev: boolean = false;
  @Param hasNext: boolean = false;
  /** 当前页段评气泡命中区（触区点击仲裁，页面级坐标）。 */
  @Param bubbles: FqPageBubble[] = [];
  /** 眉页 / 眉脚区高（vp，槽位三区布局）。 */
  @Param headerZoneVp: number = 54;
  @Param footerZoneVp: number = 40;
  /** 页底色（槽位三区背景，与仿真截图底色一致）。 */
  @Param pageBgColor: string = '#F6F4EF';
  /** 正文渲染回调：slot -1 = 上一页 / 0 = 当前页 / 1 = 下一页。 */
  @BuilderParam pageRenderer: (slot: number) => void;
  /** 眉页 / 眉脚渲染回调（随槽位三区渲染，仿真截图含眉页眉脚）。 */
  @BuilderParam headerRenderer: (slot: number) => void;
  @BuilderParam footerRenderer: (slot: number) => void;
  /** 翻页完成（isNext=true 向后翻页）。 */
  @Event onTurn: (isNext: boolean) => void = (isNext: boolean): void => {};
  /** 中区点击呼出菜单。 */
  @Event onMenuTap: () => void = (): void => {};
  /** 气泡命中段评（paraIndex）。 */
  @Event onBubbleTap: (paraIndex: number) => void = (paraIndex: number): void => {};

  /** 平移模式：拖拽/动画偏移（vp，+向右；0 = 静止）。 */
  @Local dragVp: number = 0;
  @Local animating: boolean = false;
  /** 仿真折叠层显隐 / 当前页槽位隐藏（截图顶替）。 */
  @Local simNodeShow: boolean = false;
  @Local simCurHidden: boolean = false;
  /** 实际占用区（vp，onAreaChange 捕获；0 = 未测量回退窗口尺寸）。 */
  @Local areaWidthVp: number = 0;
  @Local areaHeightVp: number = 0;

  /** 仿真控制器（全 px 状态）。 */
  private sim: FqSimFlipController = new FqSimFlipController();
  /** 仿真自动翻页定时器句柄（-1 = 无）。 */
  private simTimer: number = -1;
  /** 仿真拖拽中 / 起点已记录。 */
  private simDrawing: boolean = false;
  private panStarted: boolean = false;
  private panStartXVp: number = 0;
  /** 仿真松手判定结果：false = 回弹取消。 */
  private simCancelled: boolean = false;

  aboutToAppear(): void {
    this.applySimFoldColors();
    // 预设尺寸：NodeContainer 首次 makeNode 即有正确 frame
    this.sim.setSize(this.pageWidthPx(), this.pageHeightPx());
  }

  /** 页底色（主题）切换 → 同步仿真折叠层配色。 */
  @Monitor('pageBgColor')
  onPageBgColorChange(): void {
    this.applySimFoldColors();
  }

  aboutToDisappear(): void {
    this.clearSimTimer();
    this.sim.releasePixelMap();
  }

  /** 密度（px/vp）。 */
  private density(): number {
    const displayData: display.Display = display.getDefaultDisplaySync();
    return displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  }

  private vp2px(v: number): number {
    return v * this.density();
  }

  /** 页宽（vp）。 */
  private pageWidthVp(): number {
    if (this.areaWidthVp > 0) {
      return this.areaWidthVp;
    }
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    return (appState.screenWidth > 0 ? appState.screenWidth : displayData.width) / density;
  }

  /** 页高（vp）。 */
  private pageHeightVp(): number {
    if (this.areaHeightVp > 0) {
      return this.areaHeightVp;
    }
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    return (appState.screenHeight > 0 ? appState.screenHeight : displayData.height) / density;
  }

  private pageWidthPx(): number {
    return this.pageWidthVp() * this.density();
  }

  private pageHeightPx(): number {
    return this.pageHeightVp() * this.density();
  }

  /** 槽位横移（vp）。 */
  private slotX(slot: number): number {
    const w: number = this.pageWidthVp();
    if (this.flipMode === 1) {
      // 平移：三页联动
      return this.dragVp + slot * w;
    }
    // 仿真：prev 常驻屏外左侧（截图源），cur/next 静止
    return slot === -1 ? -w : 0;
  }

  /** 槽位层级。 */
  private slotZ(slot: number): number {
    if (this.flipMode === 1) {
      return 1;
    }
    return slot === 1 ? 1 : (slot === 0 ? 2 : 3);
  }

  /** 触区点击的气泡命中仲裁：返回命中的段落下标（-1 未命中）。 */
  private bubbleHit(event: ClickEvent, xBaseVp: number): number {
    const x: number = xBaseVp + event.x;
    for (let index: number = 0; index < this.bubbles.length; index++) {
      const bubble: FqPageBubble = this.bubbles[index];
      if (x >= bubble.xVp - 6 && x <= bubble.xVp + bubble.widthVp + 6
        && event.y >= bubble.topVp - 6 && event.y <= bubble.topVp + bubble.heightVp + 6) {
        return bubble.paraIndex;
      }
    }
    return -1;
  }

  /** 截图指定槽位页（先释放旧图）。 */
  private snapshotPage(id: string): boolean {
    this.sim.releasePixelMap();
    try {
      this.sim.pixelMap = this.getUIContext().getComponentSnapshot().getSync(id);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0001, 'FqReaderFlip', `snapshot ${id} failed. code=${err.code} message=${err.message}`);
      return false;
    }
  }

  /** 重建仿真渲染节点（每帧新节点驱动重绘）。 */
  private newSimNode(): void {
    const node: FqSimFlipRenderNode = new FqSimFlipRenderNode(this.sim);
    node.frame = {
      x: 0,
      y: 0,
      width: this.pageWidthVp(),
      height: this.pageHeightVp(),
    };
    node.pivot = { x: 1, y: 1 };
    node.scale = { x: 1, y: 1 };
    this.sim.nodeController.clearNodes();
    this.sim.nodeController.addNode(node);
  }

  private clearSimTimer(): void {
    if (this.simTimer !== -1) {
      clearInterval(this.simTimer);
      this.simTimer = -1;
    }
  }

  /** 开始拖拽仿真：定方向、截图、显示仿真层。 */
  private beginSimFlip(forward: boolean): void {
    this.sim.setSize(this.pageWidthPx(), this.pageHeightPx());
    this.sim.isFinished = false;
    if (forward) {
      // 前翻上一页：截图 prev（屏外左侧），对齐示例强制中部折角
      this.sim.dir = FqFlipDir.FORWARD;
      this.sim.zone = FqFlipZone.MIDDLE;
      if (!this.snapshotPage('fq_reader2_prev')) {
        return;
      }
    } else {
      // 后翻下一页：截图 cur 并隐藏（截图顶替原页）
      this.sim.dir = FqFlipDir.BACKWARD;
      if (!this.snapshotPage('fq_reader2_cur')) {
        return;
      }
      this.simCurHidden = true;
    }
    this.simDrawing = true;
    this.simNodeShow = true;
  }

  /** 松手自动翻页（complete=false 回弹取消）。 */
  private startSimAuto(complete: boolean): void {
    this.clearSimTimer();
    this.sim.phase = FqFlipPhase.RELEASE;
    this.sim.positionY = this.sim.flipPositionY;
    this.simCancelled = !complete;
    // 前进式：折点向远角收敛（前翻完成 / 后翻回弹闭合）；
    // 后退式：折叠区逐 tick 左移直至滑出窗口（后翻完成 / 前翻回弹退出）。
    const forwardStyle: boolean = this.sim.dir === FqFlipDir.BACKWARD ? !complete : complete;
    if (forwardStyle) {
      const xDiff: number = (this.sim.widthPx - this.sim.positionX) / FQ_SIM_SETTLE_DIV;
      const yDiff: number = this.sim.zone === FqFlipZone.BOTTOM
        ? (this.sim.heightPx - this.sim.positionY) / FQ_SIM_SETTLE_DIV
        : (0 - this.sim.positionY) / FQ_SIM_SETTLE_DIV;
      this.simTimer = setInterval((): void => {
        this.sim.positionX += xDiff;
        this.sim.positionY += yDiff;
        if (this.sim.positionX >= this.sim.widthPx - 1
          || this.sim.positionY >= this.sim.heightPx || this.sim.positionY <= 0) {
          this.finishSimFlip();
          return;
        }
        this.newSimNode();
      }, FQ_SIM_TIMER_MS);
    } else {
      this.simTimer = setInterval((): void => {
        this.sim.positionX -= FQ_SIM_BACK_STEP_PX;
        if (this.sim.isFinished) {
          this.finishSimFlip();
          return;
        }
        this.newSimNode();
      }, FQ_SIM_TIMER_MS);
    }
  }

  /** 结束仿真翻页：清理状态，按松手判定结果提交翻页。 */
  private finishSimFlip(): void {
    this.clearSimTimer();
    const dir: FqFlipDir = this.sim.dir;
    const cancelled: boolean = this.simCancelled;
    this.simNodeShow = false;
    this.simCurHidden = false;
    this.sim.reset();
    this.simDrawing = false;
    this.panStarted = false;
    this.simCancelled = false;
    if (cancelled) {
      return;
    }
    if (dir === FqFlipDir.BACKWARD) {
      this.onTurn(true);
    } else if (dir === FqFlipDir.FORWARD) {
      this.onTurn(false);
    }
  }

  /** '#RRGGBB' / '#AARRGGBB' → RGB 数值（解析失败返回 -1）。 */
  private parseHexColor(hex: string): number {
    let raw: string = hex.trim();
    if (raw.startsWith('#')) {
      raw = raw.substring(1);
    }
    if (raw.length === 8) {
      raw = raw.substring(2);
    }
    if (raw.length !== 6) {
      return -1;
    }
    const value: number = parseInt(raw, 16);
    return Number.isNaN(value) ? -1 : value;
  }

  /** 仿真折叠层配色：随页底色明暗适配——深色主题传深色背面/蒙层与柔和投影，
   *  避免翻页过程出现亮色纸面闪屏；亮色纸面沿用示例配色。 */
  private applySimFoldColors(): void {
    const rgb: number = this.parseHexColor(this.pageBgColor);
    if (rgb < 0) {
      return;
    }
    const red: number = (rgb >> 16) & 0xff;
    const green: number = (rgb >> 8) & 0xff;
    const blue: number = rgb & 0xff;
    const lum: number = (0.299 * red + 0.587 * green + 0.114 * blue) / 255;
    if (lum >= 0.5) {
      this.sim.setFoldColors(
        { alpha: 255, red: 255, green: 235, blue: 195 },
        { alpha: 120, red: 186, green: 172, blue: 145 },
        0xff111111);
      return;
    }
    const backR: number = Math.min(255, Math.round(red * 1.3) + 8);
    const backG: number = Math.min(255, Math.round(green * 1.3) + 9);
    const backB: number = Math.min(255, Math.round(blue * 1.3) + 12);
    this.sim.setFoldColors(
      { alpha: 255, red: backR, green: backG, blue: backB },
      { alpha: 70, red: 14, green: 16, blue: 22 },
      0x88111111);
  }

  /** 触区点击仿真翻页（模拟底部折角自动翻页）。 */
  private tapFlipSim(event: ClickEvent, xBaseVp: number, isNext: boolean): void {
    if (this.simTimer !== -1 || this.simDrawing) {
      return;
    }
    if (isNext && !this.hasNext) {
      return;
    }
    if (!isNext && !this.hasPrev) {
      return;
    }
    const heightPx: number = this.pageHeightPx();
    this.sim.setSize(this.pageWidthPx(), heightPx);
    this.sim.isFinished = false;
    this.sim.zone = FqFlipZone.MIDDLE;
    this.sim.phase = FqFlipPhase.RELEASE;
    this.sim.dir = isNext ? FqFlipDir.BACKWARD : FqFlipDir.FORWARD;
    this.sim.positionX = this.vp2px(xBaseVp + event.x);
    // 折点置于底边：前进式 y 条件立即参与终止判定（对齐示例 MIDDLE 初始化结果）
    this.sim.positionY = heightPx - 1;
    this.sim.flipPositionY = heightPx - 1;
    if (isNext) {
      if (!this.snapshotPage('fq_reader2_cur')) {
        this.sim.reset();
        return;
      }
      this.simCurHidden = true;
    } else {
      if (!this.snapshotPage('fq_reader2_prev')) {
        this.sim.reset();
        return;
      }
    }
    this.simNodeShow = true;
    this.newSimNode();
    this.startSimAuto(true);
  }

  /** 仿真拖拽更新：首次记录起点与触区，其后定方向开折并跟手。 */
  private onSimPanUpdate(event: GestureEvent): void {
    if (this.simTimer !== -1) {
      return;
    }
    const finger: FingerInfo = event.fingerList[0];
    if (!this.panStarted) {
      this.panStarted = true;
      this.panStartXVp = finger.localX;
      const heightPx: number = this.pageHeightPx();
      const yPx: number = this.vp2px(finger.localY);
      this.sim.zone = yPx < heightPx / 3 ? FqFlipZone.TOP
        : (yPx > heightPx * 2 / 3 ? FqFlipZone.BOTTOM : FqFlipZone.MIDDLE);
      return;
    }
    if (!this.simDrawing) {
      const forward: boolean = finger.localX > this.panStartXVp;
      if (forward && !this.hasPrev) {
        return;
      }
      if (!forward && !this.hasNext) {
        return;
      }
      this.beginSimFlip(forward);
      if (!this.simDrawing) {
        return;
      }
    }
    this.sim.phase = FqFlipPhase.MOVING;
    this.sim.positionX = this.vp2px(finger.localX);
    this.sim.positionY = this.vp2px(finger.localY);
    this.newSimNode();
  }

  /** 仿真松手：按位移/定向速度阈值决定完成或回弹。 */
  private onSimPanEnd(event: GestureEvent): void {
    if (this.simTimer !== -1 || !this.simDrawing) {
      return;
    }
    const dragPx: number = this.sim.positionX - this.vp2px(this.panStartXVp);
    const passDistance: boolean = Math.abs(dragPx) > this.pageWidthPx() * FQ_FLIP_DISTANCE_RATIO;
    const passVelocity: boolean = this.sim.dir === FqFlipDir.FORWARD
      ? event.velocityX > FQ_FLIP_VELOCITY_VPS
      : event.velocityX < -FQ_FLIP_VELOCITY_VPS;
    this.startSimAuto(passDistance || passVelocity);
  }

  /** 占用区变化（菜单栏弹出等）：同步仿真页尺寸。 */
  private onAreaChanged(newArea: Area): void {
    // Area.width/height 类型为 Length，运行时为 vp 数值，先归一化
    const widthVp: number = typeof newArea.width === 'number' ? newArea.width : 0;
    const heightVp: number = typeof newArea.height === 'number' ? newArea.height : 0;
    if (widthVp <= 0 || heightVp <= 0) {
      return;
    }
    this.areaWidthVp = widthVp;
    this.areaHeightVp = heightVp;
    if (this.simTimer === -1 && !this.simDrawing) {
      this.sim.setSize(this.pageWidthPx(), this.pageHeightPx());
    }
  }

  /** 平移模式：点击翻页。 */
  private tapFlip(isNext: boolean): void {
    if (this.animating || this.dragVp !== 0) {
      return;
    }
    if (isNext && !this.hasNext) {
      return;
    }
    if (!isNext && !this.hasPrev) {
      return;
    }
    this.settle(isNext);
  }

  /** 平移模式：翻页完成动画（两页联动到位）。 */
  private settle(isNext: boolean): void {
    if (this.animating) {
      return;
    }
    this.animating = true;
    const w: number = this.pageWidthVp();
    const target: number = isNext ? -w : w;
    this.getUIContext().animateTo({
      duration: FQ_FLIP_SETTLE_DURATION,
      curve: Curve.Friction,
      onFinish: (): void => {
        this.animating = false;
        // 与父级同帧完成：dragVp 归零 + 父切换页数据，视觉上旧“下一页”原位成为当前页
        this.dragVp = 0;
        this.onTurn(isNext);
      },
    }, (): void => {
      this.dragVp = target;
    });
  }

  /** 平移模式：未过阈值回弹。 */
  private springBack(): void {
    if (this.animating || this.dragVp === 0) {
      return;
    }
    this.animating = true;
    this.getUIContext().animateTo({
      duration: FQ_FLIP_BACK_DURATION,
      curve: Curve.Friction,
      onFinish: (): void => {
        this.animating = false;
        this.dragVp = 0;
      },
    }, (): void => {
      this.dragVp = 0;
    });
  }

  /** 槽位三区：眉页 / 正文 / 眉脚（仿真截图随页卷曲）。 */
  @Builder
  private slotContent(slot: number) {
    Column() {
      Column() {
        this.headerRenderer(slot)
      }
      .width('100%')
      .height(this.headerZoneVp)
      .justifyContent(FlexAlign.End)

      Column() {
        this.pageRenderer(slot)
      }
      .width('100%')
      .layoutWeight(1)

      Column() {
        this.footerRenderer(slot)
      }
      .width('100%')
      .height(this.footerZoneVp)
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBgColor)
  }

  build() {
    Stack() {
      // 下一页层（仿真后翻时的底页）
      Column() {
        this.slotContent(1)
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.slotX(1) })
      .zIndex(this.slotZ(1))

      // 当前页层（仿真后翻截图源）
      Column() {
        this.slotContent(0)
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.slotX(0) })
      .zIndex(this.slotZ(0))
      .visibility(this.flipMode === 0 && this.simCurHidden ? Visibility.None : Visibility.Visible)
      .id('fq_reader2_cur')

      // 上一页层（仿真前翻截图源，常驻屏外左侧）
      Column() {
        this.slotContent(-1)
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.slotX(-1) })
      .zIndex(this.slotZ(-1))
      .id('fq_reader2_prev')

      if (this.flipMode === 0) {
        // 仿真折叠层（常驻挂载，makeNode 仅首帧执行；显隐由 simNodeShow 控制）
        NodeContainer(this.sim.nodeController)
          .width(this.pageWidthVp())
          .height(this.pageHeightVp())
          .visibility(this.simNodeShow ? Visibility.Visible : Visibility.Hidden)
          .zIndex(5)
          .hitTestBehavior(HitTestMode.None)
      }

      // 顶层三列触区（点击含气泡仲裁；滑动由 PanGesture 处理）
      Row() {
        Column()
          .layoutWeight(1)
          .height('100%')
          .onClick((event: ClickEvent) => {
            const para: number = this.bubbleHit(event, 0);
            if (para >= 0) {
              this.onBubbleTap(para);
              return;
            }
            if (this.flipMode === 0) {
              this.tapFlipSim(event, 0, false);
            } else {
              this.tapFlip(false);
            }
          })
        Column()
          .layoutWeight(1)
          .height('100%')
          .onClick((event: ClickEvent) => {
            const para: number = this.bubbleHit(event, this.pageWidthVp() / 3);
            if (para >= 0) {
              this.onBubbleTap(para);
              return;
            }
            if (!this.animating && !this.simDrawing && this.simTimer === -1) {
              this.onMenuTap();
            }
          })
        Column()
          .layoutWeight(1)
          .height('100%')
          .onClick((event: ClickEvent) => {
            const para: number = this.bubbleHit(event, this.pageWidthVp() * 2 / 3);
            if (para >= 0) {
              this.onBubbleTap(para);
              return;
            }
            if (this.flipMode === 0) {
              this.tapFlipSim(event, this.pageWidthVp() * 2 / 3, true);
            } else {
              this.tapFlip(true);
            }
          })
      }
      .width('100%')
      .height('100%')
      .zIndex(10)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.onAreaChanged(newArea);
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
        .onActionStart((event: GestureEvent) => {
          if (this.flipMode === 1) {
            if (this.animating) {
              return;
            }
            this.dragVp = 0;
          } else {
            if (this.simTimer !== -1) {
              // 提交在途自动翻页后，新手势基于新页数据
              this.finishSimFlip();
            } else if (this.simNodeShow) {
              // 残留折叠层清理（异常中断兜底）
              this.simNodeShow = false;
              this.simCurHidden = false;
              this.sim.reset();
            }
            this.panStarted = false;
            this.simDrawing = false;
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.flipMode === 1) {
            if (this.animating) {
              return;
            }
            let offset: number = event.offsetX;
            if (offset > 0 && !this.hasPrev) {
              offset = 0;
            }
            if (offset < 0 && !this.hasNext) {
              offset = 0;
            }
            const w: number = this.pageWidthVp();
            this.dragVp = Math.max(-w, Math.min(w, offset));
          } else {
            this.onSimPanUpdate(event);
          }
        })
        .onActionEnd((event: GestureEvent) => {
          if (this.flipMode === 1) {
            if (this.animating) {
              return;
            }
            const w: number = this.pageWidthVp();
            const drag: number = this.dragVp;
            if (drag === 0) {
              return;
            }
            const velocityVps: number = Math.abs(event.velocityX);
            const passDistance: boolean = Math.abs(drag) > w * FQ_FLIP_DISTANCE_RATIO;
            const passVelocity: boolean = velocityVps > FQ_FLIP_VELOCITY_VPS;
            if (drag < 0 && this.hasNext && (passDistance || passVelocity)) {
              this.settle(true);
            } else if (drag > 0 && this.hasPrev && (passDistance || passVelocity)) {
              this.settle(false);
            } else {
              this.springBack();
            }
          } else {
            this.onSimPanEnd(event);
          }
        })
        .onActionCancel(() => {
          if (this.flipMode === 1) {
            this.springBack();
          } else if (this.simDrawing) {
            this.startSimAuto(false);
          }
        })
    )
  }
}

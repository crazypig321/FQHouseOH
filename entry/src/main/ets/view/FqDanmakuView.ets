/**
 * 弹幕层（对齐 fqapp playlet_danmaku_layer 语义的轻量实现）：
 * - 右→左匀速飞行（animateTo 线性动画驱动 @Trace x）；
 * - 车道避让：每条车道记录下一次可复用的墙钟时刻，满道丢弃（官方同语义）；
 * - 车道数按层实际高度自适应（层只占屏上约 20%，少遮挡画面）；
 * - 播放位置喂入驱动出现时机，超过追补窗口的旧弹幕静默跳过；
 * - 暂停时全体冻结在当前像素位置，恢复播放后按剩余时长续飞；
 * - resetToken 变化（seek/切集）清空已飞/在飞状态；
 * - 整棵子树不参与触摸测试，不影响任何交互。
 */

import { FqDanmaku } from '../model/FqModels';

/** 弹幕字号（官方 15sp 档）。 */
const FQ_DANMAKU_FONT_SIZE: number = 15;
/** 车道高（含行距）。 */
const FQ_DANMAKU_LANE_HEIGHT: number = 30;
/** 最大车道数（实际按层高度自适应向下收敛）。 */
const FQ_DANMAKU_MAX_LANES: number = 9;
/** 飞行速度（vp/s）。 */
const FQ_DANMAKU_SPEED_VP: number = 90;
/** 追补窗口：位置跳变后多久内的弹幕仍允许起飞（毫秒）。 */
const FQ_DANMAKU_CATCHUP_MS: number = 1500;

/** 飞行中的弹幕（@Trace x 驱动 translate 动画；墙钟起点支持暂停冻结）。 */
@ObservedV2
class FqFlyingDanmaku {
  readonly key: string;
  readonly text: string;
  readonly lane: number;
  /** 入场 x（层宽，右缘外）。 */
  readonly startX: number;
  /** 终点 x（-文本宽，全出左缘）。 */
  readonly endX: number;
  /** 本次动画的墙钟起点（暂停时前移，剔除冻结时长）。 */
  startWallMs: number;
  /** 本次动画的剩余时长（暂停续飞时收窄）。 */
  durationMs: number;
  /** 暂停时刻已飞行时长（未暂停为 -1）。 */
  pausedElapsedMs: number;
  @Trace x: number;

  constructor(key: string, text: string, lane: number, startX: number, endX: number,
    startWallMs: number, durationMs: number) {
    this.key = key;
    this.text = text;
    this.lane = lane;
    this.startX = startX;
    this.endX = endX;
    this.startWallMs = startWallMs;
    this.durationMs = durationMs;
    this.pausedElapsedMs = -1;
    this.x = startX;
  }
}

@ComponentV2
export struct FqDanmakuView {
  /** 已加载弹幕（offsetMs 升序；由宿主按集加载/续拉/去重）。 */
  @Param items: FqDanmaku[] = [];
  /** 当前播放位置（毫秒）。 */
  @Param positionMs: number = 0;
  /** 重置令牌：seek/切集时 +1，清空已飞/在飞状态。 */
  @Param resetToken: number = 0;
  /** 是否正在播放：暂停冻结全体飞行，恢复后续飞。 */
  @Param playing: boolean = true;
  @Local flying: FqFlyingDanmaku[] = [];
  private spawned: Set<string> = new Set<string>();
  private laneFreeAt: number[] = [];
  private viewWidth: number = 0;
  private viewHeight: number = 0;
  private paused: boolean = false;

  @Monitor('positionMs')
  private onPositionChange(): void {
    this.feed(this.positionMs);
  }

  @Monitor('resetToken')
  private onReset(): void {
    this.flying = [];
    this.spawned.clear();
    this.releaseAllLanes();
  }

  @Monitor('playing')
  private onPlayingChange(): void {
    if (this.playing) {
      this.resumeAll();
    } else {
      this.pauseAll();
    }
  }

  /** 位置推进：把 [0, pos] 内未起飞的弹幕依次起飞（追补窗口内的才真正飞行）。 */
  private feed(posMs: number): void {
    if (this.items.length === 0) {
      return;
    }
    for (let i: number = 0; i < this.items.length; i++) {
      const item: FqDanmaku = this.items[i];
      if (item.offsetMs > posMs) {
        break;
      }
      if (this.spawned.has(item.id)) {
        continue;
      }
      this.spawned.add(item.id);
      if (posMs - item.offsetMs <= FQ_DANMAKU_CATCHUP_MS) {
        this.launch(item);
      }
    }
  }

  /** 起飞：挑空闲车道，按文本宽度定时长，右缘外入场 → 全出左缘后回收。 */
  private launch(item: FqDanmaku): void {
    this.rebuildLanes();
    if (this.laneFreeAt.length === 0) {
      return;
    }
    const now: number = Date.now();
    let lane: number = -1;
    for (let i: number = 0; i < this.laneFreeAt.length; i++) {
      if (this.laneFreeAt[i] <= now) {
        lane = i;
        break;
      }
    }
    if (lane < 0) {
      return;
    }
    const textWidth: number = this.estimateTextWidth(item.text);
    const width: number = this.viewWidth > 0 ? this.viewWidth : 360;
    const durationMs: number = Math.round((width + textWidth) / FQ_DANMAKU_SPEED_VP * 1000);
    this.laneFreeAt[lane] = now + durationMs;
    const flyer: FqFlyingDanmaku = new FqFlyingDanmaku(
      item.id, item.text, lane, width, -textWidth, now, durationMs);
    this.flying.push(flyer);
    // 下一拍再启动动画，确保初始位置先完成一次渲染；已暂停则等恢复续飞
    setTimeout((): void => {
      if (this.paused || !this.flying.includes(flyer)) {
        return;
      }
      this.fly(flyer);
    }, 0);
  }

  /** 启动（或续飞）单条线性动画。 */
  private fly(flyer: FqFlyingDanmaku): void {
    this.getUIContext().animateTo({
      duration: flyer.durationMs,
      curve: Curve.Linear,
      onFinish: (): void => {
        this.retire(flyer);
      },
    }, (): void => {
      flyer.x = flyer.endX;
    });
  }

  /** 暂停：全体按已飞行进度冻结在当前像素位置（0 时长动画顶掉在飞动画）。 */
  private pauseAll(): void {
    if (this.paused) {
      return;
    }
    this.paused = true;
    if (this.flying.length === 0) {
      return;
    }
    const now: number = Date.now();
    const finished: FqFlyingDanmaku[] = [];
    for (const flyer of this.flying) {
      const elapsed: number = now - flyer.startWallMs;
      if (elapsed >= flyer.durationMs) {
        finished.push(flyer);
        continue;
      }
      const progress: number = elapsed / flyer.durationMs;
      flyer.pausedElapsedMs = elapsed;
      const frozenX: number = flyer.startX + (flyer.endX - flyer.startX) * progress;
      this.getUIContext().animateTo({ duration: 0 }, (): void => {
        flyer.x = frozenX;
      });
    }
    if (finished.length > 0) {
      const done: Set<FqFlyingDanmaku> = new Set<FqFlyingDanmaku>(finished);
      this.flying = this.flying.filter((item: FqFlyingDanmaku): boolean => !done.has(item));
    }
  }

  /** 恢复：墙钟起点前移剔除冻结时长，按剩余时长续飞。 */
  private resumeAll(): void {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    const now: number = Date.now();
    for (const flyer of this.flying) {
      if (flyer.pausedElapsedMs < 0) {
        // 冻结期间才起飞、还没动过的：从起点正常起飞
        this.fly(flyer);
        continue;
      }
      const elapsed: number = flyer.pausedElapsedMs;
      flyer.pausedElapsedMs = -1;
      const remaining: number = flyer.durationMs - elapsed;
      if (remaining <= 0) {
        this.retire(flyer);
        continue;
      }
      flyer.startWallMs = now - elapsed;
      flyer.durationMs = remaining;
      this.fly(flyer);
    }
  }

  private retire(flyer: FqFlyingDanmaku): void {
    this.flying = this.flying.filter((item: FqFlyingDanmaku): boolean => item !== flyer);
  }

  /** 车道数按层高度自适应（层只占屏上约 20%）。 */
  private rebuildLanes(): void {
    let count: number = FQ_DANMAKU_MAX_LANES;
    if (this.viewHeight > 0) {
      count = Math.floor(this.viewHeight / FQ_DANMAKU_LANE_HEIGHT);
    }
    count = Math.max(1, Math.min(FQ_DANMAKU_MAX_LANES, count));
    if (count !== this.laneFreeAt.length) {
      const lanes: number[] = [];
      for (let i: number = 0; i < count; i++) {
        lanes.push(0);
      }
      this.laneFreeAt = lanes;
    }
  }

  private releaseAllLanes(): void {
    for (let i: number = 0; i < this.laneFreeAt.length; i++) {
      this.laneFreeAt[i] = 0;
    }
  }

  /** 文本宽度估算：CJK 全宽、其余约 0.55 倍字号。 */
  private estimateTextWidth(text: string): number {
    let units: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      units += text.charCodeAt(i) > 0x2E7F ? 1 : 0.55;
    }
    return Math.max(FQ_DANMAKU_FONT_SIZE, Math.ceil(units * FQ_DANMAKU_FONT_SIZE));
  }

  build() {
    Stack() {
      ForEach(this.flying, (flyer: FqFlyingDanmaku) => {
        Text(flyer.text)
          .fontSize(FQ_DANMAKU_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textShadow({ radius: 2, color: '#CC000000', offsetX: 0, offsetY: 0 })
          .maxLines(1)
          .position({ x: 0, y: flyer.lane * FQ_DANMAKU_LANE_HEIGHT })
          .translate({ x: flyer.x })
      }, (flyer: FqFlyingDanmaku) => flyer.key)
    }
    .width('100%')
    .height('100%')
    // 纯展示层：整棵子树不参与触摸测试，不拦截画面单击/双击与底部控件
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.viewWidth = Number(newArea.width);
      this.viewHeight = Number(newArea.height);
    })
  }
}

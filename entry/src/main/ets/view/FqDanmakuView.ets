/**
 * 弹幕层（对齐 fqapp playlet_danmaku_layer 语义的轻量实现）：
 * - 右→左匀速飞行（animateTo 线性动画驱动 @Trace x）；官方时长制：
 *   竖屏 10000ms / 横屏 12000ms 基准 ÷（弹幕速度档 × 播放倍速），
 *   时长恒定、文本越长像素速度越快（container/l.java:782-784,1371-1373）；
 * - 车道避让：每条车道记录下一次可复用的墙钟时刻，满道丢弃（官方同语义）；
 * - 车道数 = maxLanes 与层实际高度按行高自适应的较小者；
 * - 播放位置喂入驱动出现时机，超过追补窗口的旧弹幕静默跳过；
 * - 暂停时全体冻结在当前像素位置，恢复播放后按剩余时长续飞；
 * - resetToken 变化（seek/切集）清空已飞/在飞状态；
 * - 样式经 config 可调（fqapp danmaku_config：字号/不透明度/速度倍率/背景透明气泡）；
 * - 正文官方括号表情（`[微笑]` 等）复用评论表情切段渲染为内联图（与段评同款）；
 * - 整棵子树不参与触摸测试，不影响任何交互。
 */

import { FqDanmaku } from '../model/FqModels';
import { FqEmojiSegment, fqCommentEmojiSegments, fqHasCommentEmoji } from './FqCommentEmoji';

/** 官方飞行时长基准（毫秒）：竖屏 10000、横屏 12000（container/l.java）。 */
const FQ_DANMAKU_FLIGHT_MS: number = 10000;
const FQ_DANMAKU_FLIGHT_MS_LANDSCAPE: number = 12000;
/** 追补窗口：位置跳变后多久内的弹幕仍允许起飞（毫秒）。 */
const FQ_DANMAKU_CATCHUP_MS: number = 1500;
/** 弹幕气泡底色（官方 40% 黑底圆角气泡；transparentBg 时不画）。 */
const FQ_DANMAKU_BUBBLE_BG: string = '#66000000';

/** 弹幕样式配置（fqapp danmaku_config 五项 + 本地背景透明开关的视图投影）。 */
export class FqDanmakuViewConfig {
  /** 字号（fp；fqapp DanmakuTextSize 5 档 12/14/16/18/20，默认 16）。 */
  readonly fontSize: number;
  /** 不透明度（%，20-100）。 */
  readonly alphaPercent: number;
  /** 速度倍率（fqapp DanmakuSpeed 5 档 0.5-1.5，默认 1.0）。 */
  readonly speedMultiplier: number;
  /** 背景透明：不画黑底气泡，只留文字与阴影。 */
  readonly transparentBg: boolean;

  constructor(fontSize: number = 16, alphaPercent: number = 100,
    speedMultiplier: number = 1.0, transparentBg: boolean = false) {
    this.fontSize = fontSize;
    this.alphaPercent = alphaPercent;
    this.speedMultiplier = speedMultiplier;
    this.transparentBg = transparentBg;
  }
}

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
  /** 样式配置（字号/不透明度/速度倍率/背景透明；整实例替换生效）。 */
  @Param config: FqDanmakuViewConfig = new FqDanmakuViewConfig();
  /** 最大车道数（竖屏=设置行数 1-4；横屏=显示区域高度折算，宿主计算）。 */
  @Param maxLanes: number = 4;
  /** 横屏片源（官方横屏飞行 12000ms、竖屏 10000ms）。 */
  @Param landscape: boolean = false;
  /** 播放倍速：飞行墙钟时长 = 基准 ÷（速度档倍率 × 倍速）。 */
  @Param playbackRate: number = 1;
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

  /** 行高（含行距）：随字号缩放（16sp → 28vp，对齐 fqapp trackPitch 28）。 */
  private laneHeight(): number {
    return this.config.fontSize + 12;
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
    // 官方时长制：基准 ÷（速度档 × 倍速），时长恒定、长文本像素速度更快
    const speed: number = Math.max(0.1, this.config.speedMultiplier);
    const rate: number = Math.max(0.1, this.playbackRate);
    const durationMs: number = Math.round(
      (this.landscape ? FQ_DANMAKU_FLIGHT_MS_LANDSCAPE : FQ_DANMAKU_FLIGHT_MS) / (speed * rate));
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

  /** 车道数：maxLanes 与层高度自适应（行高随字号）取较小者，至少 1 条。 */
  private rebuildLanes(): void {
    let count: number = this.maxLanes >= 1 ? Math.floor(this.maxLanes) : 1;
    if (this.viewHeight > 0) {
      count = Math.min(count, Math.floor(this.viewHeight / this.laneHeight()));
    }
    count = Math.max(1, count);
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

  /** 文本宽度估算：CJK 全宽、其余约 0.55 倍字号；
   *  官方括号表情按内联图实际宽度（1.4 倍字号）计，不按 token 原文。 */
  private estimateTextWidth(text: string): number {
    if (fqHasCommentEmoji(text)) {
      let width: number = 0;
      for (const segment of fqCommentEmojiSegments(text)) {
        width += segment.emoji !== null
          ? this.config.fontSize * 1.4
          : this.estimatePlainWidth(segment.plain);
      }
      return Math.max(this.config.fontSize, Math.ceil(width));
    }
    return this.estimatePlainWidth(text);
  }

  /** 纯文本宽度估算（CJK 全宽、其余约 0.55 倍字号）。 */
  private estimatePlainWidth(text: string): number {
    let units: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      units += text.charCodeAt(i) > 0x2E7F ? 1 : 0.55;
    }
    return Math.max(this.config.fontSize, Math.ceil(units * this.config.fontSize));
  }

  /** 弹幕文字色（白色 + 不透明度档；气泡底色恒定不受透明度影响）。 */
  private textColor(): string {
    const alpha: number = Math.round(this.config.alphaPercent) / 100;
    return `rgba(255,255,255,${alpha})`;
  }

  build() {
    Stack() {
      ForEach(this.flying, (flyer: FqFlyingDanmaku) => {
        if (fqHasCommentEmoji(flyer.text)) {
          // 官方括号表情弹幕：切段横排（文本段纯 Text + 表情段 Image，1.4 倍字号）。
          // 不用 Text 富文本（Span/ImageSpan）：实测在该动画场景下静默不渲染，整条弹幕消失
          Row({ space: 0 }) {
            ForEach(fqCommentEmojiSegments(flyer.text), (segment: FqEmojiSegment, index: number) => {
              if (segment.emoji !== null) {
                Image(segment.emoji)
                  .width(this.config.fontSize * 1.4)
                  .height(this.config.fontSize * 1.4)
                  .objectFit(ImageFit.Contain)
                  .draggable(false)
                  // 表情与文字同等受弹幕不透明度设置影响
                  .opacity(this.config.alphaPercent / 100)
              } else {
                Text(segment.plain)
                  .fontSize(this.config.fontSize)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.textColor())
                  .textShadow({ radius: 2, color: '#CC000000', offsetX: 0, offsetY: 0 })
                  .maxLines(1)
              }
            }, (segment: FqEmojiSegment, index: number): string => `${flyer.key}_${index}_${segment.plain.length}`)
          }
          .alignItems(VerticalAlign.Center)
          .position({ x: 0, y: flyer.lane * this.laneHeight() })
          .translate({ x: flyer.x })
          .padding({
            left: this.config.transparentBg ? 0 : 6,
            right: this.config.transparentBg ? 0 : 6,
            top: this.config.transparentBg ? 0 : 2,
            bottom: this.config.transparentBg ? 0 : 2,
          })
          .borderRadius(this.config.transparentBg ? 0 : 4)
          .backgroundColor(this.config.transparentBg ? Color.Transparent : FQ_DANMAKU_BUBBLE_BG)
        } else {
          Text(flyer.text)
            .fontSize(this.config.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
            .textShadow({ radius: 2, color: '#CC000000', offsetX: 0, offsetY: 0 })
            .maxLines(1)
            .position({ x: 0, y: flyer.lane * this.laneHeight() })
            .translate({ x: flyer.x })
            .padding({
              left: this.config.transparentBg ? 0 : 6,
              right: this.config.transparentBg ? 0 : 6,
              top: this.config.transparentBg ? 0 : 2,
              bottom: this.config.transparentBg ? 0 : 2,
            })
            .borderRadius(this.config.transparentBg ? 0 : 4)
            .backgroundColor(this.config.transparentBg ? Color.Transparent : FQ_DANMAKU_BUBBLE_BG)
        }
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

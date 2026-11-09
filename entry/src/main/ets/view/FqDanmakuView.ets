/**
 * 弹幕层（对齐 fqapp playlet_danmaku_layer 语义的轻量实现）：
 * - 右→左匀速飞行（帧时钟 16ms 步进推进 @Trace x，同 fqapp Ticker 模型，不用
 *   animateTo——暂停顶帧依赖动画打断语义，onFinish 误触发会连回收一起出错）；
 *   官方时长制：竖屏 10000ms / 横屏 12000ms 基准 ÷（弹幕速度档 × 播放倍速），
 *   时长恒定、文本越长像素速度越快（container/l.java:782-784,1371-1373）；
 * - 车道避让：每条车道记录下一次可复用的墙钟时刻，满道丢弃（官方同语义）；
 *   暂停期间车道占用计时同步冻结顺延，长暂停后不串道；
 * - 车道数 = maxLanes 与层实际高度按行高自适应的较小者；
 * - 播放位置喂入驱动出现时机，超过追补窗口的旧弹幕静默跳过；
 * - 暂停时停帧冻结在当前像素位置，恢复播放后按剩余时长续飞；
 * - resetToken 变化（seek/切集）清空已飞/在飞状态；
 * - 片尾收尾：飞行终点超出本集时长时压缩飞行时长，赶在片尾前完整飞出，
 *   不随切集截断（保底最短时长，剩得太少时最多在最后 2 秒内被截）；
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
/** 片尾压缩飞行的最短墙钟时长（毫秒）：再短就看不清，宁可在最后 2 秒内被切集截断。 */
const FQ_DANMAKU_TAIL_MIN_MS: number = 2000;
/** 帧时钟步进间隔（毫秒）：约 60fps，弹幕低速匀移足够顺滑。 */
const FQ_DANMAKU_FRAME_MS: number = 16;
/** 单帧最大步进（毫秒）：后台/卡顿的长帧按上限折算，防止恢复瞬间弹幕瞬移。 */
const FQ_DANMAKU_MAX_FRAME_MS: number = 100;
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

/** 飞行中的弹幕（@Trace x 由帧时钟推进；墙钟已飞时长支持暂停冻结）。 */
@ObservedV2
class FqFlyingDanmaku {
  readonly key: string;
  readonly text: string;
  readonly lane: number;
  /** 入场 x（层宽，右缘外）。 */
  readonly startX: number;
  /** 终点 x（-文本宽，全出左缘）。 */
  readonly endX: number;
  /** 飞行总时长（墙钟毫秒）。 */
  readonly totalMs: number;
  /** 已飞行时长（墙钟毫秒；暂停时停帧自然冻结）。 */
  elapsedMs: number;
  @Trace x: number;

  constructor(key: string, text: string, lane: number, startX: number, endX: number,
    totalMs: number) {
    this.key = key;
    this.text = text;
    this.lane = lane;
    this.startX = startX;
    this.endX = endX;
    this.totalMs = totalMs;
    this.elapsedMs = 0;
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
  /** 本集媒体总时长（毫秒）：>0 时片尾弹幕压缩飞行，赶在片尾前完整飞出。 */
  @Param durationMs: number = 0;
  @Local flying: FqFlyingDanmaku[] = [];
  private spawned: Set<string> = new Set<string>();
  private laneFreeAt: number[] = [];
  private viewWidth: number = 0;
  private viewHeight: number = 0;
  /** 帧时钟定时器 id（-1 未运行）。 */
  private tickerId: number = -1;
  private lastTickAt: number = 0;
  /** 暂停时刻（0 表示未暂停）：恢复时车道占用计时按暂停时长顺延。 */
  private pausedAt: number = 0;

  aboutToAppear(): void {
    if (this.playing) {
      this.startTicker();
    }
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

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
      this.startTicker();
    } else {
      this.stopTicker();
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
    let durationMs: number = Math.round(
      (this.landscape ? FQ_DANMAKU_FLIGHT_MS_LANDSCAPE : FQ_DANMAKU_FLIGHT_MS) / (speed * rate));
    // 片尾收尾（fqapp/官方未处理的原生缺陷）：飞行终点超出本集时长时压缩到「片尾前飞完」，
    // 避免切集时弹幕飘到一半被截；剩得太少则保底最短时长，最多在最后 2 秒内被截
    if (this.durationMs > 0 && this.positionMs < this.durationMs) {
      const remainWallMs: number = (this.durationMs - this.positionMs) / rate;
      if (remainWallMs < durationMs) {
        durationMs = Math.max(FQ_DANMAKU_TAIL_MIN_MS, Math.round(remainWallMs));
      }
    }
    this.laneFreeAt[lane] = now + durationMs;
    this.flying.push(new FqFlyingDanmaku(
      item.id, item.text, lane, width, -textWidth, durationMs));
  }

  /** 启动帧时钟（幂等）：恢复时先按暂停时长顺延仍在占用的车道释放时刻。 */
  private startTicker(): void {
    if (this.tickerId >= 0) {
      return;
    }
    const now: number = Date.now();
    if (this.pausedAt > 0) {
      const pausedMs: number = now - this.pausedAt;
      for (let i: number = 0; i < this.laneFreeAt.length; i++) {
        // 只顺延暂停时仍被冻结弹幕占用的车道，空闲车道保持原状
        if (this.laneFreeAt[i] > this.pausedAt) {
          this.laneFreeAt[i] += pausedMs;
        }
      }
      this.pausedAt = 0;
    }
    this.lastTickAt = now;
    this.tickerId = setInterval((): void => this.tickFrame(), FQ_DANMAKU_FRAME_MS);
  }

  /** 停帧（幂等）：冻结全体弹幕在当前像素位置，记录暂停时刻。 */
  private stopTicker(): void {
    if (this.tickerId >= 0) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
    if (this.pausedAt === 0) {
      this.pausedAt = Date.now();
    }
  }

  /** 帧步进：全体按墙钟推进剩余飞行，飞完的出列回收。 */
  private tickFrame(): void {
    if (this.flying.length === 0) {
      return;
    }
    const now: number = Date.now();
    let dt: number = now - this.lastTickAt;
    this.lastTickAt = now;
    if (dt <= 0) {
      return;
    }
    if (dt > FQ_DANMAKU_MAX_FRAME_MS) {
      dt = FQ_DANMAKU_MAX_FRAME_MS;
    }
    let retired = false;
    for (const flyer of this.flying) {
      flyer.elapsedMs += dt;
      if (flyer.elapsedMs >= flyer.totalMs) {
        flyer.x = flyer.endX;
        retired = true;
        continue;
      }
      const progress: number = flyer.elapsedMs / flyer.totalMs;
      flyer.x = flyer.startX + (flyer.endX - flyer.startX) * progress;
    }
    if (retired) {
      this.flying = this.flying.filter(
        (item: FqFlyingDanmaku): boolean => item.elapsedMs < item.totalMs);
    }
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

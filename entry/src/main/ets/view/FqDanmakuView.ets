/**
 * 弹幕层（对齐 fqapp playlet_danmaku_layer 语义的轻量实现）：
 * - 右→左匀速飞行（帧时钟 16ms 步进推进 @Trace x，同 fqapp Ticker 模型，不用
 *   animateTo——暂停顶帧依赖动画打断语义，onFinish 误触发会连回收一起出错）；
 *   官方时长制：竖屏 10000ms / 横屏 12000ms 基准 ÷（弹幕速度档 × 播放倍速），
 *   时长恒定、文本越长像素速度越快（container/l.java:782-784,1371-1373）；
 * - 车道密集调度：弹道不整程独占——上一条尾部入屏即可复用，新弹幕像素更快时
 *   按追尾校验补足安全间距，同弹道并行多条错开飞行；显示区域只决定弹道数、
 *   不削减吞吐（区域调小后弹幕改在剩余弹道内加密，而非大量丢弃）；
 *   全弹道安全间距内都满时才丢弃；
 *   暂停期间车道占用计时同步冻结顺延，长暂停后不串道；
 * - 相同弹幕合并（hongguoTV DanmakuLayout group-start 语义）：items 变化时按
 *   「距组首 5 秒内同文本」离线预合成，组首起飞即带「文字 ×N」计数，被并成员
 *   不再单独起飞；组首被丢弃时成员接力起飞（不丢弹幕）；续拉使计数增长时
 *   原位刷新在飞组文本，不打断飞行；
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
/** 弹道复用安全间距之外的固定余量（毫秒）：避免相邻弹幕贴字。 */
const FQ_DANMAKU_LANE_GAP_MS: number = 150;
/** 相同弹幕合并窗口（毫秒）：同文本距其组首条 ≤ 该值时并组「 ×N」，超窗另起一组。 */
const FQ_DANMAKU_MERGE_WINDOW_MS: number = 5000;
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

/** 飞行中的弹幕（@Trace x/text 驱动飞行与合并计数重渲染；墙钟已飞时长支持暂停冻结）。 */
@ObservedV2
class FqFlyingDanmaku {
  readonly key: string;
  /** 文本（并组合并时更新为「文字 ×N」）。 */
  @Trace text: string;
  readonly lane: number;
  /** 入场 x（层宽，右缘外）。 */
  readonly startX: number;
  /** 终点 x（-文本宽，全出左缘；合并加宽时同步更新，保证完整飞出）。 */
  endX: number;
  /** 飞行总时长（墙钟毫秒）。 */
  readonly totalMs: number;
  /** 已并入条数（含首条；>1 时文本拼「 ×N」）。 */
  count: number;
  /** 本组首条弹幕的播放位置（毫秒）：后续同文本与其比较合并窗口。 */
  groupOffsetMs: number;
  /** 已飞行时长（墙钟毫秒；暂停时停帧自然冻结）。 */
  elapsedMs: number;
  @Trace x: number;

  constructor(key: string, text: string, lane: number, startX: number, endX: number,
    totalMs: number, count: number, groupOffsetMs: number) {
    this.key = key;
    this.text = text;
    this.lane = lane;
    this.startX = startX;
    this.endX = endX;
    this.totalMs = totalMs;
    this.count = count;
    this.groupOffsetMs = groupOffsetMs;
    this.elapsedMs = 0;
    this.x = startX;
  }
}

/** 弹道占用（密集调度）：记录最近一次起飞信息，按需计算安全复用间距。 */
class FqDanmakuLane {
  /** 最近一次起飞墙钟时刻（0 = 未使用/已重置）。 */
  launchAt: number = 0;
  /** 最近一次弹幕文本宽（px）。 */
  width: number = 0;
  /** 最近一次飞行墙钟时长（毫秒）。 */
  durationMs: number = 0;
}

/** 相同弹幕合并组（items 变化时离线重算的预合成计划）：组首起飞即显示 composedText。 */
class FqDanmakuMergeGroup {
  /** 组首弹幕 id。 */
  readonly headId: string;
  /** 组内原文（同文本）。 */
  readonly text: string;
  /** 组首播放位置（毫秒）：并组窗口基准。 */
  readonly startOffsetMs: number;
  /** 已并入条数（含组首）。 */
  count: number;
  /** 合成显示文本（count > 1 时「原文 ×N」）。 */
  composedText: string;

  constructor(headId: string, text: string, startOffsetMs: number) {
    this.headId = headId;
    this.text = text;
    this.startOffsetMs = startOffsetMs;
    this.count = 1;
    this.composedText = text;
  }

  /** 并入一条：计数 +1，重合成显示文本。 */
  absorb(): void {
    this.count += 1;
    this.composedText = `${this.text} ×${this.count}`;
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
  /** 在飞合并组：文本 → 组引用（运行时兜底并组用；超窗或飞完的下一条同文本另起）。 */
  private mergeGroups: Map<string, FqFlyingDanmaku> = new Map();
  /** 合并计划（items 变化时重算）：组首 id → 合并组。 */
  private mergePlanById: Map<string, FqDanmakuMergeGroup> = new Map();
  /** 被并成员 id → 组首 id：组首起飞后成员不再单独起飞。 */
  private absorbedMemberHead: Map<string, string> = new Map();
  /** 已真正起飞的组首 id：丢弃的组首不入内，成员据此接力兜底。 */
  private launchedHeads: Set<string> = new Set();
  private lanes: FqDanmakuLane[] = [];
  private viewWidth: number = 0;
  private viewHeight: number = 0;
  /** 帧时钟定时器 id（-1 未运行）。 */
  private tickerId: number = -1;
  private lastTickAt: number = 0;
  /** 暂停时刻（0 表示未暂停）：恢复时车道占用计时按暂停时长顺延。 */
  private pausedAt: number = 0;

  aboutToAppear(): void {
    this.rebuildMergePlan();
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

  @Monitor('items')
  private onItemsChange(): void {
    this.rebuildMergePlan();
  }

  @Monitor('resetToken')
  private onReset(): void {
    this.flying = [];
    this.spawned.clear();
    this.mergeGroups.clear();
    this.launchedHeads.clear();
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
      const headId: string | undefined = this.absorbedMemberHead.get(item.id);
      if (headId !== undefined && this.launchedHeads.has(headId)) {
        // 已并入在飞合并组（组首起飞即带「 ×N」），不再单独起飞；
        // 组首被丢弃时落到下方照常接力起飞，不丢弹幕
        continue;
      }
      if (posMs - item.offsetMs <= FQ_DANMAKU_CATCHUP_MS) {
        this.launch(item);
      }
    }
  }

  /** 起飞：预合成「文字 ×N」整组起飞；兜底并组见方法内运行时分支。 */
  private launch(item: FqDanmaku): void {
    // 运行时兜底并组：组首被丢弃、成员接力起飞后，后续同文本成员并入接力的在飞组
    // （距接力组首 ≤ 5 秒且未飞完，只改文本与终点，不打断飞行）
    const group: FqFlyingDanmaku | undefined = this.mergeGroups.get(item.text);
    if (group !== undefined && group.elapsedMs < group.totalMs &&
      item.offsetMs - group.groupOffsetMs <= FQ_DANMAKU_MERGE_WINDOW_MS) {
      group.count += 1;
      group.text = `${item.text} ×${group.count}`;
      group.endX = -this.estimateTextWidth(group.text);
      return;
    }
    this.rebuildLanes();
    if (this.lanes.length === 0) {
      return;
    }
    const now: number = Date.now();
    // 预合成：组首起飞即显示整组「文字 ×N」（计划在 rebuildMergePlan 里离线算好）
    const plan: FqDanmakuMergeGroup | undefined = this.mergePlanById.get(item.id);
    const text: string = plan !== undefined ? plan.composedText : item.text;
    const count: number = plan !== undefined ? plan.count : 1;
    const textWidth: number = this.estimateTextWidth(text);
    const width: number = this.viewWidth > 0 ? this.viewWidth : 360;
    const durationMs: number = this.flightDurationMs();
    // 密集调度：上一条尾部入屏即复用（+追尾校验），同弹道并行多条错开飞行；
    // 全弹道安全间距内都满才丢弃（超密兜底，避免叠字）
    let lane: number = -1;
    let bestGap: number = -1;
    for (let i: number = 0; i < this.lanes.length; i++) {
      const gap: number = now - this.lanes[i].launchAt;
      if (gap >= this.requiredHeadway(this.lanes[i], textWidth, durationMs, width) && gap > bestGap) {
        lane = i;
        bestGap = gap;
      }
    }
    if (lane < 0) {
      return;
    }
    this.lanes[lane].launchAt = now;
    this.lanes[lane].width = textWidth;
    this.lanes[lane].durationMs = durationMs;
    const flyer: FqFlyingDanmaku = new FqFlyingDanmaku(
      item.id, text, lane, width, -textWidth, durationMs, count, item.offsetMs);
    this.flying.push(flyer);
    this.mergeGroups.set(item.text, flyer);
    this.launchedHeads.add(item.id);
  }

  /**
   * 重算合并计划（初载/续拉）：距组首 5 秒内的同文本并组（group-start 链），
   * 组首起飞即带整组「文字 ×N」；续拉使在飞组计数增长时原位刷新其文本与终点。
   */
  private rebuildMergePlan(): void {
    this.mergePlanById.clear();
    this.absorbedMemberHead.clear();
    const groupByText: Map<string, FqDanmakuMergeGroup> = new Map();
    for (const item of this.items) {
      const group: FqDanmakuMergeGroup | undefined = groupByText.get(item.text);
      if (group !== undefined && item.offsetMs - group.startOffsetMs <= FQ_DANMAKU_MERGE_WINDOW_MS) {
        group.absorb();
        this.absorbedMemberHead.set(item.id, group.headId);
      } else {
        const head: FqDanmakuMergeGroup =
          new FqDanmakuMergeGroup(item.id, item.text, item.offsetMs);
        this.mergePlanById.set(item.id, head);
        groupByText.set(item.text, head);
      }
    }
    // 续拉边界：组首已按旧计数起飞、新页又并入成员 → 原位刷新在飞组，不打断飞行
    for (const flyer of this.flying) {
      const plan: FqDanmakuMergeGroup | undefined = this.mergePlanById.get(flyer.key);
      if (plan !== undefined && plan.count > flyer.count && flyer.elapsedMs < flyer.totalMs) {
        flyer.count = plan.count;
        flyer.text = plan.composedText;
        flyer.endX = -this.estimateTextWidth(plan.composedText);
      }
    }
  }

  /** 飞行墙钟时长：官方基准 ÷（速度档 × 倍速），片尾压缩赶在片尾前完整飞出。 */
  private flightDurationMs(): number {
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
    return durationMs;
  }

  /**
   * 弹道安全复用间距（毫秒）：上一条尾部入屏（尾巴离开右缘）即可复用；
   * 新弹幕像素更快时按追尾校验补足（保证全程追不上前一条），外加固定贴字余量。
   * 等价于 bilibili 式车道复用：间距只看两条中较长者，与后续弹幕无关。
   */
  private requiredHeadway(lane: FqDanmakuLane, nextWidth: number,
    nextDurationMs: number, width: number): number {
    if (lane.launchAt === 0 || lane.durationMs <= 0) {
      return 0;
    }
    const prevSpeed: number = (width + lane.width) / lane.durationMs;
    const nextSpeed: number = (width + nextWidth) / nextDurationMs;
    // 尾部入屏：上一条尾巴飞过右缘的时刻
    let headway: number = lane.width * lane.durationMs / (width + lane.width);
    if (nextSpeed > prevSpeed) {
      // 追尾校验：新弹幕更快，须等上一条在被追上前先飞出屏幕
      headway = Math.max(headway, lane.durationMs - width / nextSpeed);
    }
    return headway + FQ_DANMAKU_LANE_GAP_MS;
  }

  /** 启动帧时钟（幂等）：恢复时先按暂停时长顺延仍在占用的车道释放时刻。 */
  private startTicker(): void {
    if (this.tickerId >= 0) {
      return;
    }
    const now: number = Date.now();
    if (this.pausedAt > 0) {
      const pausedMs: number = now - this.pausedAt;
      for (let i: number = 0; i < this.lanes.length; i++) {
        // 只顺延暂停时仍有弹幕冻结占用的弹道，空闲弹道保持原状
        const lane: FqDanmakuLane = this.lanes[i];
        if (lane.launchAt > 0 && lane.launchAt + lane.durationMs > this.pausedAt) {
          lane.launchAt += pausedMs;
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
    if (count !== this.lanes.length) {
      const lanes: FqDanmakuLane[] = [];
      for (let i: number = 0; i < count; i++) {
        lanes.push(new FqDanmakuLane());
      }
      // 车道数变化（全屏切换/层高变化）：用仍在飞的弹幕回填新车道占用，
      // 否则新车道全「空闲」，下一条弹幕会立刻叠进还挂着字的弹道（同排叠字）
      const now: number = Date.now();
      for (const flyer of this.flying) {
        if (flyer.lane >= 0 && flyer.lane < count) {
          const lane: FqDanmakuLane = lanes[flyer.lane];
          // elapsedMs 即距起飞的墙钟时差（暂停时冻结，暂停中也不会有新起飞）
          const launchedAt: number = now - flyer.elapsedMs;
          if (lane.launchAt === 0 || launchedAt > lane.launchAt) {
            lane.launchAt = launchedAt;
            lane.width = this.estimateTextWidth(flyer.text);
            lane.durationMs = flyer.totalMs;
          }
        }
      }
      this.lanes = lanes;
    }
  }

  private releaseAllLanes(): void {
    for (let i: number = 0; i < this.lanes.length; i++) {
      this.lanes[i] = new FqDanmakuLane();
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

/**
 * 红果原生源健康熔断器（Hg = 红果）。
 *
 * 策略（计划 drama-hongguo-priority Step 3）：
 * - 稳态（红果健康）串行只发红果（Go 本地调用 <1s）；
 * - 单次失败不熔断，调用方在同一次调用内回退番茄（仅一次 8s 超时感知）；
 * - 连续失败 ≥ 阈值（默认 3）→ 熔断：冷却期内（默认 5 分钟）所有红果入口
 *   直接走番茄（不发红果请求，零额外延迟）；
 * - 冷却期满半开试探：下次请求仍走红果，成功即完全恢复；
 *   再失败立即重新熔断（失败计数已 ≥ 阈值，任一次失败都触发）。
 * 不做常驻双发竞速：两边 feed 排序/新鲜度不同，双发会致列表内容抖动、流量翻倍。
 */

/** 熔断失败计数阈值（连续失败次数）。 */
const HG_BREAK_THRESHOLD: number = 3;
/** 熔断冷却时长（ms）。 */
const HG_COOLDOWN_MS: number = 300000;

export class HgHealth {
  private static readonly instance: HgHealth = new HgHealth();

  /** 连续失败计数（任一次成功清零）。 */
  private failStreak: number = 0;
  /** 熔断截止时刻（epoch ms；0 = 未熔断）。 */
  private brokenUntilMs: number = 0;

  private constructor() {
  }

  public static get(): HgHealth {
    return HgHealth.instance;
  }

  /** 熔断期是否跳过红果（调用方直接走番茄，不发红果请求）。 */
  public shouldBypass(nowMs: number): boolean {
    return nowMs < this.brokenUntilMs;
  }

  /** 任一次成功：清零计数、解除熔断（半开试探成功即完全恢复）。 */
  public recordSuccess(): void {
    this.failStreak = 0;
    this.brokenUntilMs = 0;
  }

  /** 失败计数；达到阈值进入/刷新熔断冷却窗。 */
  public recordFailure(nowMs: number): void {
    this.failStreak += 1;
    if (this.failStreak >= HG_BREAK_THRESHOLD) {
      this.brokenUntilMs = nowMs + HG_COOLDOWN_MS;
    }
  }
}

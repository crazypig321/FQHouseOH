/**
 * 进程级 AVSession 槽位仲裁器：
 * AVSession 服务每进程（EntryAbility）仅允许同时存在一个会话，而本应用有三类持有者
 * （听书 FqListen / 视频页 FqVideo / 听视频页 FqListenVideo）。页面互相 push 叠栈时
 * （如视频页 → 相关推荐 → 详情 → 听书），底层视频页不会触发 aboutToDisappear，
 * 其会话一直占用进程唯一槽位，顶层听书 create 永远失败（session is existed），
 * 后台无通知栏播控中心/胶囊。本仲裁器以回调注册解耦 FqAudioSession 与 FqVideoMedia
 * （避免循环 import），统一让路规则：
 * - 听书 open：让路全部视频类持有者（暂停 + 释放会话/长时任务）；
 * - 视频 ensureSession（显式起播接管）：让路听书与其他视频页（顶层意图优先）；
 * - 视频 1s tick 的隐式重建：听书或其他视频页持有时跳过（埋页不回抢，防互踩风暴）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FqAvArbiter';

/** 视频类持有者（FqVideoMedia）注册项。 */
export class FqAvVideoHolder {
  /** 让路回调（暂停播放 + release 会话/长时任务；页面保持挂载）。 */
  public readonly yielder: () => void = (): void => {
  };
  /** 是否正持有 AVSession（隐式重建让路判定）。 */
  public readonly holderProbe: () => boolean = (): boolean => false;

  constructor(yielder: () => void, holderProbe: () => boolean) {
    this.yielder = yielder;
    this.holderProbe = holderProbe;
  }
}

export class FqAvArbiter {
  private static videoHolders: Array<FqAvVideoHolder> = [];
  private static listenYielder: (() => void) | null = null;
  private static listenActiveProbe: () => boolean = (): boolean => false;

  public static registerVideo(holder: FqAvVideoHolder): void {
    if (FqAvArbiter.videoHolders.indexOf(holder) < 0) {
      FqAvArbiter.videoHolders.push(holder);
    }
  }

  public static unregisterVideo(holder: FqAvVideoHolder): void {
    const idx: number = FqAvArbiter.videoHolders.indexOf(holder);
    if (idx >= 0) {
      FqAvArbiter.videoHolders.splice(idx, 1);
    }
  }

  public static registerListen(yielder: () => void, activeProbe: () => boolean): void {
    FqAvArbiter.listenYielder = yielder;
    FqAvArbiter.listenActiveProbe = activeProbe;
  }

  /** 让路听书（视频显式接管时：fqAudioSession.close 完整关闭链路）。 */
  public static yieldListen(): void {
    if (FqAvArbiter.listenYielder !== null) {
      FqAvArbiter.listenYielder();
    }
  }

  /** 让路全部视频类持有者（听书 open / Ability 销毁兜底；except 跳过自身）。 */
  public static yieldAllVideoExcept(except: FqAvVideoHolder | null): void {
    const holders: Array<FqAvVideoHolder> = FqAvArbiter.videoHolders.slice();
    for (const holder of holders) {
      if (holder !== except) {
        hilog.info(0x0001, TAG, 'yield video holder for owner takeover');
        holder.yielder();
      }
    }
  }

  /** 听书会话是否活跃（fqAudioSession.hasSession）。 */
  public static isListenActive(): boolean {
    return FqAvArbiter.listenActiveProbe();
  }

  /** 除自身外是否有视频类持有者正持有会话。 */
  public static videoHeldByOther(self: FqAvVideoHolder | null): boolean {
    for (const holder of FqAvArbiter.videoHolders) {
      if (holder !== self && holder.holderProbe()) {
        return true;
      }
    }
    return false;
  }
}

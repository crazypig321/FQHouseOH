/**
 * 应用级 audioPlayback 后台长时任务引用计数管理器。
 *
 * 听书会话（FqAudioSession）、视频播放页与听视频页（FqVideoMedia）共享同一个
 * 应用级长时任务：stopBackgroundRunning/startBackgroundRunning 为应用级全局生效，
 * 页面交替（pop 转场中旧页 aboutToDisappear 晚于新页 onShown）时各自独立停/启
 * 会互相误杀（先 apply 后 stop 把新页需要的任务停掉，后台播一会即被冻结）。
 * 统一引用计数：
 * - acquire：引用 +1；取消待执行的延迟释放；任务未申请时立即申请。
 * - release：引用 -1；归零后延迟释放（可被新 acquire 取消），期间任务不断档。
 */
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FqMediaBgTask';
/** 引用归零后延迟释放时长（ms）：覆盖页面交替窗口。 */
const FQ_BG_RELEASE_DELAY_MS: number = 1200;

export class FqMediaBgTask {
  private static refCount: number = 0;
  private static applied: boolean = false;
  private static stopTimer: number = 0;
  private static context: common.UIAbilityContext | null = null;

  /** 获取任务引用（媒体起播时调用；调用方以自身 bgStarted 去重）。 */
  public static acquire(context: common.UIAbilityContext): void {
    FqMediaBgTask.context = context;
    FqMediaBgTask.refCount += 1;
    if (FqMediaBgTask.stopTimer !== 0) {
      clearTimeout(FqMediaBgTask.stopTimer);
      FqMediaBgTask.stopTimer = 0;
    }
    if (FqMediaBgTask.applied) {
      return;
    }
    FqMediaBgTask.applied = true;
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent): void => {
        backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent)
          .then((): void => {
            hilog.info(0x0001, TAG, 'background audioPlayback task started');
          })
          .catch((error: BusinessError): void => {
            if (error.code === 9800005) {
              // 应用已有同类长时任务：视为已持有
              return;
            }
            FqMediaBgTask.applied = false;
            hilog.warn(0x0001, TAG, `startBackgroundRunning failed: ${error.message}`);
          });
      })
      .catch((error: BusinessError): void => {
        FqMediaBgTask.applied = false;
        hilog.warn(0x0001, TAG, `getWantAgent failed: ${error.message}`);
      });
  }

  /** 释放任务引用（媒体停止/让路/离页时调用；归零延迟停任务）。 */
  public static release(): void {
    if (FqMediaBgTask.refCount > 0) {
      FqMediaBgTask.refCount -= 1;
    }
    if (FqMediaBgTask.refCount > 0 || FqMediaBgTask.stopTimer !== 0) {
      return;
    }
    FqMediaBgTask.stopTimer = setTimeout((): void => {
      FqMediaBgTask.stopTimer = 0;
      if (FqMediaBgTask.refCount > 0 || !FqMediaBgTask.applied) {
        return;
      }
      FqMediaBgTask.applied = false;
      const context: common.UIAbilityContext | null = FqMediaBgTask.context;
      if (context === null) {
        return;
      }
      backgroundTaskManager.stopBackgroundRunning(context).catch((_error: BusinessError): void => {
      });
    }, FQ_BG_RELEASE_DELAY_MS);
  }
}

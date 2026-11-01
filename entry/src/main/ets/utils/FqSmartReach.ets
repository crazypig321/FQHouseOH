/**
 * 智感握姿（适人握持）：
 * 订阅系统握持手识别（motion.on('holdingHandChanged')），左手握持时
 * appState.holdingHand 置 'left'，播控球换到左下角、HdsTabs 底部栏随
 * adaptToHandedness 做 handedness 适配；其余状态一律按右手（默认）布局。
 * 需声明 ohos.permission.DETECT_GESTURE 权限；设备不支持时静默保持默认布局。
 */

import { motion } from '@kit.MultimodalAwarenessKit';
import { Callback, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appState } from '../entryability/AppState';

const DOMAIN = 0x0000;

export class FqSmartReach {
  private static active: boolean = false;

  private static readonly callback: Callback<motion.HoldingHandStatus> =
    (status: motion.HoldingHandStatus): void => {
      const next: string = status === motion.HoldingHandStatus.LEFT_HAND_HELD ? 'left' : 'right';
      if (appState.holdingHand === next) {
        return;
      }
      appState.holdingHand = next;
    };

  /** 启动时按持久化开关恢复订阅（EntryAbility.onCreate 在 FqAppSettingsStore.init 后调用）。 */
  static setup(): void {
    if (appState.smartReachEnabled) {
      FqSmartReach.start();
    }
  }

  /** 设置开关（设置页 Toggle 切换时调用）：开=订阅识别，关=退订并复位右手布局。 */
  static setEnabled(enabled: boolean): void {
    appState.smartReachEnabled = enabled;
    if (enabled) {
      FqSmartReach.start();
    } else {
      FqSmartReach.stop();
    }
  }

  private static start(): void {
    if (FqSmartReach.active) {
      return;
    }
    if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      hilog.warn(DOMAIN, 'FqSmartReach', 'device not support motion awareness');
      return;
    }
    try {
      motion.on('holdingHandChanged', FqSmartReach.callback);
      FqSmartReach.active = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, 'FqSmartReach', 'subscribe holdingHandChanged failed: %{public}s', `${err.message}`);
    }
  }

  private static stop(): void {
    if (!FqSmartReach.active) {
      return;
    }
    try {
      motion.off('holdingHandChanged', FqSmartReach.callback);
    } catch (error) {
      // 静默失败
    }
    FqSmartReach.active = false;
    appState.holdingHand = 'right';
  }
}

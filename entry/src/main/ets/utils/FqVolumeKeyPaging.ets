/**
 * 音量键翻页拦截（inputConsumer 全局快捷键，isRepeat:false 优先消费不上报系统，
 * 参考 FAQ faqs-audio-19 / fqapp volume_key）：
 * 仅阅读/漫画页在栈顶、开关开启、分页模式、无菜单/半模态遮挡时由宿主页 sync(true) 注册；
 * 页面隐藏（onHidden）、离开（aboutToDisappear）或条件不再满足时 sync(false) 注销，
 * 恢复系统音量调节。音量上 = 上一页，音量下 = 下一页。
 */
import { inputConsumer, KeyEvent, KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class FqVolumeKeyPaging {
  private static active: boolean = false;
  private static prevCallback: (event: KeyEvent) => void = (): void => {
  };
  private static nextCallback: (event: KeyEvent) => void = (): void => {
  };

  /** want=true 注册拦截（onPrev=音量上、onNext=音量下）；false 注销恢复系统音量。 */
  public static sync(want: boolean, onPrev: () => void, onNext: () => void): void {
    if (want === FqVolumeKeyPaging.active) {
      return;
    }
    if (!want) {
      FqVolumeKeyPaging.disable();
      return;
    }
    FqVolumeKeyPaging.prevCallback = (_event: KeyEvent): void => {
      onPrev();
    };
    FqVolumeKeyPaging.nextCallback = (_event: KeyEvent): void => {
      onNext();
    };
    try {
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_UP,
        action: 1,
        isRepeat: false,
      }, FqVolumeKeyPaging.prevCallback);
      inputConsumer.on('keyPressed', {
        key: KeyCode.KEYCODE_VOLUME_DOWN,
        action: 1,
        isRepeat: false,
      }, FqVolumeKeyPaging.nextCallback);
      FqVolumeKeyPaging.active = true;
    } catch (error) {
      // 注册失败（如系统限制）回退系统音量行为，下次条件变化重试
      FqVolumeKeyPaging.disable();
      hilog.warn(0x0001, 'FqVolumeKey', 'register failed: %{public}s', `${JSON.stringify(error)}`);
    }
  }

  /** 无条件注销（页面销毁兜底）。 */
  public static disable(): void {
    try {
      inputConsumer.off('keyPressed', FqVolumeKeyPaging.prevCallback);
      inputConsumer.off('keyPressed', FqVolumeKeyPaging.nextCallback);
    } catch (error) {
      hilog.warn(0x0001, 'FqVolumeKey', 'unregister failed: %{public}s', `${JSON.stringify(error)}`);
    }
    FqVolumeKeyPaging.active = false;
  }
}

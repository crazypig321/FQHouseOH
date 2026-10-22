/**
 * 公共弹窗管理（参考 musicfreeOH DialogManager，适配本项目）：
 * 宿主页（持有 CustomDialogController）aboutToAppear 时经 Register 注册
 * 打开/轻提示/关闭动作，aboutToDisappear 时经 Unregister 注销；
 * 各处经 OpenDialog(key) 打开弹窗，宿主内容构建按 dialogChangeKey 分发内容组件；
 * 弹窗消失时宿主 onWillDisappear 调 DisappearDialog 清理状态并触发一次性关闭回调。
 */

/** 公共弹窗管理器：弹窗标识/宿主动作/生命周期回调的静态集散地。 */
export class DialogManager {
  /** 当前弹窗标识（如「阅读设置」；空串表示当前无弹窗）。 */
  public static dialogChangeKey: string = '';

  /** 弹窗关闭回调（一次性，触发后自动清空）。 */
  public static onDialogClosed: (() => void) | null = null;

  // ===== 宿主注册动作（由持有 CustomDialogController 的页面注入） =====
  private static opener: (() => void) | null = null;
  private static toaster: ((message: string) => void) | null = null;
  private static closer: (() => void) | null = null;

  /** 注册弹窗宿主：opener 打开弹窗、toaster 轻提示、closer 关闭弹窗。 */
  public static Register(opener: () => void, toaster: (message: string) => void,
    closer: () => void): void {
    DialogManager.opener = opener;
    DialogManager.toaster = toaster;
    DialogManager.closer = closer;
  }

  /** 注销弹窗宿主（页面 aboutToDisappear 调用，防悬空回调与残留标识）。 */
  public static Unregister(): void {
    DialogManager.opener = null;
    DialogManager.toaster = null;
    DialogManager.closer = null;
    DialogManager.onDialogClosed = null;
    DialogManager.dialogChangeKey = '';
  }

  /** 打开弹窗：key 写入 dialogChangeKey 后交宿主打开，内容按 key 分发。 */
  public static OpenDialog(key: string): void {
    DialogManager.dialogChangeKey = key;
    if (DialogManager.opener !== null) {
      DialogManager.opener();
    }
  }

  /** 关闭弹窗（由弹窗内自定义动作完成后调用）。 */
  public static CloseDialog(): void {
    if (DialogManager.closer !== null) {
      DialogManager.closer();
    }
  }

  /** 弹窗内轻提示。 */
  public static Toast(message: string): void {
    if (DialogManager.toaster !== null) {
      DialogManager.toaster(message);
    }
  }

  /** 弹窗消失清理（宿主 onWillDisappear 调用）：清标识、触发一次性关闭回调。 */
  public static DisappearDialog(key: string): void {
    if (key !== DialogManager.dialogChangeKey) {
      return;
    }
    DialogManager.dialogChangeKey = '';
    const cb: (() => void) | null = DialogManager.onDialogClosed;
    DialogManager.onDialogClosed = null;
    if (cb !== null) {
      cb();
    }
  }
}

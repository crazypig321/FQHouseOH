/**
 * 公共弹窗管理（参考 musicfreeOH DialogManager，适配本项目）：
 * 宿主页（持有 CustomDialogController）aboutToAppear 时经 Register 注册
 * 打开/轻提示/关闭动作，aboutToDisappear 时经 Unregister 注销；
 * 各处经 OpenDialog(key) 打开弹窗，宿主内容构建按 dialogChangeKey 分发内容组件；
 * 弹窗消失时宿主 onWillDisappear 调 DisappearDialog 清理状态并触发一次性关闭回调。
 */

import { ButtonOptions } from '@kit.ArkUI';
import { appState } from '../entryability/AppState';

/** 公共弹窗管理器：弹窗标识/宿主动作/生命周期回调的静态集散地。 */
export class DialogManager {
  /** 当前弹窗标识（如「通用确认」；空串表示当前无弹窗）。 */
  public static dialogChangeKey: string = '';

  /** 弹窗关闭回调（一次性，触发后自动清空）。 */
  public static onDialogClosed: (() => void) | null = null;

  // ===== 通用确认弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 通用确认弹窗标题。 */
  public static confirmTitle: string = '';
  /** 通用确认弹窗正文。 */
  public static confirmMessage: string = '';
  /** 通用确认弹窗确认按钮文案（移出/删除/清空等）。 */
  public static confirmLabel: string = '确定';
  /** 通用确认弹窗确认回调（点击确认后执行；取消/关闭弹窗不触发）。 */
  public static confirmCallback: (() => void) | null = null;

  // ===== 自定义颜色弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 自定义颜色弹窗：取色器起始色。 */
  public static customColorInitial: string = '#FF7A3D';
  /** 自定义颜色弹窗：当前拖选色（确认后回传，取消丢弃）。 */
  public static customColorPicked: string = '#FF7A3D';
  /** 自定义颜色弹窗确认回调（确认后执行并回传所选色；取消/关闭不触发）。 */
  private static customColorConfirmCallback: ((hex: string) => void) | null = null;

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

  /** 通用确认弹窗（移出书架/删除记录/清空书架/清空浏览历史等共用）：
   *  title 标题、message 正文、confirmLabel 确认按钮文案，onConfirm 点确认后执行（取消/关闭不触发）。 */
  public static ShowConfirm(title: string, message: string, confirmLabel: string, onConfirm: () => void): void {
    DialogManager.confirmTitle = title;
    DialogManager.confirmMessage = message;
    DialogManager.confirmLabel = confirmLabel;
    DialogManager.confirmCallback = onConfirm;
    DialogManager.OpenDialog('通用确认');
  }

  /** 自定义颜色弹窗（HSB 取色器 + 确认/取消）：initial 取色器起始色，onConfirm 确认后回传所选色（取消/关闭不触发）。 */
  public static ShowCustomColorPicker(initial: string, onConfirm: (hex: string) => void): void {
    DialogManager.customColorInitial = initial;
    DialogManager.customColorPicked = initial;
    DialogManager.customColorConfirmCallback = onConfirm;
    DialogManager.OpenDialog('自定义颜色');
  }

  /** 弹窗标题（宿主渲染时读取）。 */
  public static DialogTitle(key: string): ResourceStr {
    if (key === '通用确认') {
      return DialogManager.confirmTitle;
    }
    if (key === '自定义颜色') {
      return '自定义颜色';
    }
    return '';
  }

  /** 弹窗底部按钮（宿主渲染时读取；CustomContentDialog 点击按钮后自动关闭）。 */
  public static DialogButtons(key: string): Array<ButtonOptions> {
    if (key === '通用确认' || key === '自定义颜色') {
      const cancel: ButtonOptions = {
        value: '取消',
        fontColor: appState.accentColor,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => {
        }
      };
      const confirm: ButtonOptions = {
        value: key === '通用确认' ? DialogManager.confirmLabel : '确认',
        fontColor: Color.White,
        background: appState.accentColor,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => {
          DialogManager.ConfirmButtonDialog(key);
        }
      };
      return [cancel, confirm];
    }
    return [];
  }

  /** 弹窗确认键回调（宿主按钮 action 调用）。 */
  public static ConfirmButtonDialog(key: string): void {
    if (key === '通用确认') {
      const cb: (() => void) | null = DialogManager.confirmCallback;
      if (cb !== null) {
        cb();
      }
    }
    if (key === '自定义颜色') {
      const cb: ((hex: string) => void) | null = DialogManager.customColorConfirmCallback;
      if (cb !== null) {
        cb(DialogManager.customColorPicked);
      }
    }
  }

  /** 弹窗消失清理（宿主 onWillDisappear 调用）：清标识、触发一次性关闭回调。 */
  public static DisappearDialog(key: string): void {
    if (key !== DialogManager.dialogChangeKey) {
      return;
    }
    DialogManager.dialogChangeKey = '';
    // 通用确认弹窗参数一次性，关闭后清理（取消/关闭不触发确认回调）
    if (key === '通用确认') {
      DialogManager.confirmTitle = '';
      DialogManager.confirmMessage = '';
      DialogManager.confirmLabel = '确定';
      DialogManager.confirmCallback = null;
    }
    // 自定义颜色弹窗参数一次性，关闭后清理（取消丢弃拖选色）
    if (key === '自定义颜色') {
      DialogManager.customColorInitial = '#FF7A3D';
      DialogManager.customColorPicked = '#FF7A3D';
      DialogManager.customColorConfirmCallback = null;
    }
    const cb: (() => void) | null = DialogManager.onDialogClosed;
    DialogManager.onDialogClosed = null;
    if (cb !== null) {
      cb();
    }
  }
}

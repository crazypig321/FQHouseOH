/**
 * 隔空手势（智慧手势，SmartGesture，API 26）公共封装。
 *
 * 设备侧仅三种隔空操作：划一划（OperateIntention.SLIDE_FORWARD）、翻腕
 * （OperateIntention.BACK_PRESS，系统默认开启、语义为返回）、敲一敲
 * （OperateIntention.TAP）；无公开的上下挥手方向。各页面按自身语义在
 * 监听回调里映射动作（播放页：划一划→下一集、翻腕→上一集；阅读页等
 * 复用同一封装）。枚举 GestureShortcut / SmartGestureAction /
 * OperateIntention 为全局声明，无需 import。
 *
 * 用法：
 * 1. 页面成员持有监听（箭头函数属性，可引用页面 this）：
 *    private monitor: FqSmartGestureHandler = (p) => { ... };
 * 2. aboutToAppear 创建并注册：
 *    this.sg = new FqSmartGesture(this.getUIContext().getSmartGestureController(), this.monitor);
 *    this.sg.register();
 * 3. onShown / onHidden：register() / unregister()（被覆盖页停用，防隔空误触）。
 * 4. aboutToDisappear：unregister()。
 * 回调内约定：条件不满足 return fqPassSmartGesture()（不消费，交还系统
 * 默认行为）；完成自定义动作后 return fqConsumeSmartGesture()（消费并
 * 抑制系统默认动作——注意仅 new GestureHandlingResolution(true) 不挂提案
 * 会继续走系统默认动作，必须挂 NoneActionProposal 才算消费且不执行默认）。
 */
import { SmartGestureController, BaseGestureHandlingProposal, GestureHandlingResolution, NoneActionProposal } from '@kit.ArkUI';

/** 隔空手势监听回调（参数为系统默认处理提案，返回是否消费/替换默认行为）。 */
export type FqSmartGestureHandler = (proposal: BaseGestureHandlingProposal) => GestureHandlingResolution;

/** 消费当前隔空手势并抑制系统默认行为（自定义副作用已由调用方完成）。 */
export function fqConsumeSmartGesture(): GestureHandlingResolution {
  const consumed: GestureHandlingResolution = new GestureHandlingResolution(true);
  consumed.selectedProposal = new NoneActionProposal();
  return consumed;
}

/** 不消费当前隔空手势：交还系统默认行为（边界/遮挡态透传）。 */
export function fqPassSmartGesture(): GestureHandlingResolution {
  return new GestureHandlingResolution(false);
}

/** 隔空手势注册器：register/unregister 幂等（重复注册/注销安全）。 */
export class FqSmartGesture {
  private ctrl: SmartGestureController;
  private handler: FqSmartGestureHandler;
  private registered: boolean = false;

  constructor(ctrl: SmartGestureController, handler: FqSmartGestureHandler) {
    this.ctrl = ctrl;
    this.handler = handler;
  }

  /** 注册监听并开启敲一敲/划一划识别（翻腕系统默认开启，不受此开关控制）。 */
  register(): void {
    if (this.registered) {
      return;
    }
    this.ctrl.enableSmartTapAndSlideGestures(true);
    this.ctrl.registerMonitor(this.handler);
    this.registered = true;
  }

  /** 注销监听并关闭敲一敲/划一划识别（页面隐藏/离页停用）。 */
  unregister(): void {
    if (!this.registered) {
      return;
    }
    this.ctrl.unregisterMonitor(this.handler);
    this.ctrl.enableSmartTapAndSlideGestures(false);
    this.registered = false;
  }
}

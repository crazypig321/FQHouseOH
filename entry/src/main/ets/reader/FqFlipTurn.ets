/**
 * 外部程序化翻页控制器（宿主页面持有，翻页容器挂载时注册回调）：
 * - 宿主（阅读页 / 漫画页）创建实例并传入 FqReaderFlip / FqComicFlip 的 turnController；
 * - 翻页容器 aboutToAppear 时把自身 pageTurn 挂到 turn 槽位，aboutToDisappear 时清空；
 * - 宿主外部触发（音量键翻页等）读取 turn 槽位调用，未挂载时走各自的兜底翻页路径。
 */

/** 翻页回调槽位：isNext = true 向后翻页 / false 向前翻页；null = 翻页容器未挂载。 */
export class FqFlipTurnController {
  public turn: ((isNext: boolean) => void) | null = null;
}

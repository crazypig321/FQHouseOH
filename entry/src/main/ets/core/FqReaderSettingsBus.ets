/**
 * 阅读设置弹窗数据总线：公共弹窗宿主在 Index（utils/DialogUtils 模式），
 * 阅读页存活期间镜像设置值（@Trace 驱动弹窗内容实时刷新）并注册变更处理器；
 * 变更动作（重排/持久化/换字体）仍由阅读页完成。
 */
@ObservedV2
export class FqReaderSettingsBus {
  @Trace fontSize: number = 19;
  @Trace lineHeight: number = 1.9;
  @Trace themeIndex: number = 0;
  @Trace flipIndex: number = 0;
  @Trace fontIndex: number = 0;
  /** 阅读页注册的变更处理器（aboutToAppear 注册、aboutToDisappear 注销）。 */
  public handler: FqReaderSettingsHandler | null = null;
}

/** 阅读设置变更处理器（阅读页实现：更新本地状态、持久化并按需重排，随后回写总线）。 */
export interface FqReaderSettingsHandler {
  changeFontSize: (delta: number) => void;
  changeLineHeight: (delta: number) => void;
  changeTheme: (index: number) => void;
  changeFont: (index: number) => void;
  changeFlip: (index: number) => void;
}

export const fqReaderSettingsBus: FqReaderSettingsBus = new FqReaderSettingsBus();

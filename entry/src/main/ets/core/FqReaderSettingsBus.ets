/**
 * 阅读设置弹窗数据总线：公共弹窗宿主在 Index（utils/DialogUtils 模式），
 * 阅读页存活期间镜像设置值（@Trace 驱动弹窗内容实时刷新）并注册变更处理器；
 * 变更动作（重排/持久化/换字体）仍由阅读页完成。
 */
import { FqCustomReaderTheme } from './FqReaderStore';

@ObservedV2
export class FqReaderSettingsBus {
  @Trace fontSize: number = 19;
  @Trace lineHeight: number = 1.9;
  @Trace themeIndex: number = 0;
  @Trace flipIndex: number = 0;
  @Trace fontIndex: number = 0;
  @Trace showParagraphComment: boolean = true;
  /** 自定义阅读主题列表（镜像阅读页，数组整体替换驱动刷新）。 */
  @Trace customThemes: FqCustomReaderTheme[] = [];
  /** 当前选中的自定义主题 id（themeIndex=3 时生效）。 */
  @Trace customThemeId: string = '';
  /** 阅读页注册的变更处理器（aboutToAppear 注册、aboutToDisappear 注销）。 */
  public handler: FqReaderSettingsHandler | null = null;
}

/** 阅读设置变更处理器（阅读页实现：更新本地状态、持久化并按需重排，随后回写总线）。 */
export interface FqReaderSettingsHandler {
  changeFontSize: (delta: number) => void;
  changeLineHeight: (delta: number) => void;
  /** 切换预设主题（-1 跟随系统 / 0 纸白 / 1 米黄 / 2 夜间）。 */
  changeTheme: (index: number) => void;
  changeFont: (index: number) => void;
  changeFlip: (index: number) => void;
  changeShowParagraphComment: (on: boolean) => void;
  /** 图库选图新增自定义主题并选中。 */
  pickCustomTheme: () => void;
  /** 选中指定自定义主题（themeIndex 切到 3）。 */
  selectCustomTheme: (id: string) => void;
  /** 长按自定义主题：打开编辑弹窗（名称/字色/字号/字体/行距/删除）。 */
  editCustomTheme: (id: string) => void;
}

export const fqReaderSettingsBus: FqReaderSettingsBus = new FqReaderSettingsBus();

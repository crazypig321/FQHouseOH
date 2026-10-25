/**
 * 漫画设置弹窗数据总线：公共弹窗宿主在 Index（utils/DialogUtils 模式），
 * 漫画页存活期间镜像翻页方式（@Trace 驱动弹窗内容实时刷新）并注册变更处理器；
 * 变更动作（切换渲染模式/持久化）仍由漫画页完成。
 */
@ObservedV2
export class FqComicSettingsBus {
  /** 漫画翻页方式：0 仿真 / 1 覆盖 / 2 上下滚动。 */
  @Trace comicFlipIndex: number = 0;
  /** 漫画页注册的变更处理器（aboutToAppear 注册、aboutToDisappear 注销）。 */
  public handler: FqComicSettingsHandler | null = null;
}

/** 漫画设置变更处理器（漫画页实现：切换翻页模式并持久化，随后回写总线）。 */
export interface FqComicSettingsHandler {
  changeFlip: (index: number) => void;
}

export const fqComicSettingsBus: FqComicSettingsBus = new FqComicSettingsBus();

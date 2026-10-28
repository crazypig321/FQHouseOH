/**
 * 「漫画设置」弹窗内容（经 utils/DialogUtils 的 DialogManager.OpenDialog('漫画设置') 打开，
 * 由宿主页 CustomContentDialog 装配：无标题无按钮仅内容区，悬于工具条上方居中）：
 * 翻页方式（仿真/覆盖/上下）+ 音量键翻页开关两行；当前值经 @Param 注入、变更经 @Event 回调宿主页；
 * 配色跟随系统深浅色（弹窗卡片为系统色）。
 */
import { themeUtils } from '../../utils/ThemeUtils';
import { appState } from '../../entryability/AppState';

/** 漫画翻页模式标签（下标与 comicFlipIndex 对应）。 */
export const FQ_COMIC_FLIP_LABELS: string[] = ['仿真', '覆盖', '上下'];

@ComponentV2
export struct ComicSettingsDialogContent {
  @Param comicFlipIndex: number = 0;
  /** 音量键翻页开关（与小说阅读共用 FqReaderStore 全局设置；分页模式拦截音量上/下）。 */
  @Param volumeKeyPaging: boolean = false;
  @Event flipChange: (index: number) => void = (_index: number): void => {};
  @Event volumeKeyPagingChange: (on: boolean) => void = (_on: boolean): void => {};

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('翻页')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        ForEach(FQ_COMIC_FLIP_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontColor(this.comicFlipIndex === index ? '#FFFFFF' : themeUtils.textColor)
            .backgroundColor(this.comicFlipIndex === index ? appState.accentColor : 'transparent')
            .borderRadius(13)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.flipChange(index);
            })
        }, (label: string): string => label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('翻页')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Text(this.volumeKeyPaging ? '音量上/下键代替翻页' : '音量键保持调节系统音量')
          .fontSize(12)
          .fontColor(themeUtils.terTextColor)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.volumeKeyPaging })
          .selectedColor(appState.accentColor)
          .switchPointColor(Color.White)
          .onChange((isOn: boolean): void => {
            this.volumeKeyPagingChange(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }
}

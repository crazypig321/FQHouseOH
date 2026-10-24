/**
 * 「漫画设置」弹窗内容（经 utils/DialogUtils 的 DialogManager.OpenDialog('漫画设置') 打开，
 * 由宿主页 CustomContentDialog 装配：无标题无按钮仅内容区，悬于工具条上方居中）：
 * 仅翻页方式一行（仿真/覆盖/上下）；当前值经 @Param 注入、变更经 @Event 回调宿主页；
 * 配色跟随系统深浅色（弹窗卡片为系统色）。
 */
import { FQ_ACCENT } from '../CommonCom';
import { themeUtils } from '../../utils/ThemeUtils';

/** 漫画翻页模式标签（下标与 comicFlipIndex 对应）。 */
export const FQ_COMIC_FLIP_LABELS: string[] = ['仿真', '覆盖', '上下'];

@ComponentV2
export struct ComicSettingsDialogContent {
  @Param comicFlipIndex: number = 0;
  @Event flipChange: (index: number) => void = (_index: number): void => {};

  build() {
    Row({ space: 12 }) {
      Text('翻页')
        .fontSize(14)
        .fontColor(themeUtils.textColor)
        .width(36)
      ForEach(FQ_COMIC_FLIP_LABELS, (label: string, index: number) => {
        Text(label)
          .fontSize(12)
          .fontColor(this.comicFlipIndex === index ? '#FFFFFF' : themeUtils.textColor)
          .backgroundColor(this.comicFlipIndex === index ? FQ_ACCENT : 'transparent')
          .borderRadius(13)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick((): void => {
            this.flipChange(index);
          })
      }, (label: string): string => label)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

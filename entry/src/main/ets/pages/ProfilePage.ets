/**
 * 「我的」Tab 页（占位：设置与账号后续版本提供）。
 */
import { CommonNav } from '../view/CommonNav';
import { FqTitleBarOptions } from '../model/FqNavModels';

@ComponentV2
export struct ProfilePlaceholderPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('我的', false),
      isHideBackButton: true,
    }) {
      Column({ space: 10 }) {
        Text('设置与账号将在后续版本提供')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}

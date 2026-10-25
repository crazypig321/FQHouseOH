/**
 * 应用设置页（我的-应用设置入口，占位：设置项后续版本提供）。
 */
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';

@ComponentV2
export struct SettingsPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('应用设置', false),
    }) {
      Column({ space: 10 }) {
        Text('设置项开发中，敬请期待')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}

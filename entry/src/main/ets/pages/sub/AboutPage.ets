/**
 * 关于我们页（我的-关于我们入口，占位：版本信息等后续版本提供）。
 */
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';

@ComponentV2
export struct AboutPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('关于我们', false),
    }) {
      Column({ space: 10 }) {
        Text('内容开发中，敬请期待')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}

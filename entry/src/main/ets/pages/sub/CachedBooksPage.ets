/**
 * 章节缓存页（我的-章节缓存入口，占位：缓存管理后续版本提供）。
 */
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';

@ComponentV2
export struct CachedBooksPage {
  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('章节缓存', false),
    }) {
      Column({ space: 10 }) {
        Text('缓存管理开发中，敬请期待')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
  }
}

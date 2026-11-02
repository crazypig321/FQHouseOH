/**
 * 「章节缓存限制」弹窗内容：自动缓存上限数值输入 + 单位下拉（MB / GB）。
 * 数值/单位经 DialogManager 静态参数暂存，确认后由页面回调落库并触发预算收敛。
 */

import { DialogManager } from '../../utils/DialogUtils';
import { selectImmersiveModifier } from '../../utils/ModifierUtils';

/** 单位选项（下标与 DialogManager.chapterCacheLimitUnitIndex 对应）。 */
const FQ_CACHE_LIMIT_UNITS: string[] = ['MB', 'GB'];

@ComponentV2
export struct ChapterCacheLimitDialogContent {
  build() {
    Row({ space: 10 }) {
      TextInput({ text: DialogManager.chapterCacheLimitValue, placeholder: '1-100' })
        .type(InputType.NUMBER_DECIMAL)
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius(10)
        .onChange((value: string): void => {
          DialogManager.chapterCacheLimitValue = value;
        })

      Select([
        { value: FQ_CACHE_LIMIT_UNITS[0] },
        { value: FQ_CACHE_LIMIT_UNITS[1] },
      ])
        .selected(DialogManager.chapterCacheLimitUnitIndex)
        .value(FQ_CACHE_LIMIT_UNITS[DialogManager.chapterCacheLimitUnitIndex])
        .font({ size: 14, weight: FontWeight.Medium })
        .fontColor($r('sys.color.font_primary'))
        .selectedOptionFontColor($r('sys.color.font_primary'))
        .optionFontColor($r('sys.color.font_primary'))
        .selectedOptionBgColor($r('sys.color.comp_background_tertiary'))
        .optionBgColor(Color.Transparent)
        .attributeModifier(selectImmersiveModifier)
        .controlSize(ControlSize.NORMAL)
        .height(44)
        .width(96)
        .borderRadius(10)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onSelect((index: number, _value: string): void => {
          DialogManager.chapterCacheLimitUnitIndex = index;
        })
    }
    .width('100%')
  }
}

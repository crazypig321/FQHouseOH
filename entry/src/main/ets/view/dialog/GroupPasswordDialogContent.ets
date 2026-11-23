/** 「分组密码」弹窗内容：分组加锁应用内密码输入框（4-8 位数字）。 */

import { DialogManager } from '../../utils/DialogUtils';

@ComponentV2
export struct GroupPasswordDialogContent {
  build() {
    TextInput({ text: DialogManager.groupPasswordValue, placeholder: '4-8 位数字' })
      .type(InputType.NUMBER_PASSWORD)
      .width('100%')
      .height(44)
      .fontSize(16)
      .fontColor($r('sys.color.font_primary'))
      .placeholderColor($r('sys.color.font_tertiary'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(10)
      .maxLength(8)
      .onChange((value: string): void => {
        DialogManager.groupPasswordValue = value;
      })
  }
}

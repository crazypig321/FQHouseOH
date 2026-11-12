/** 「分组命名」弹窗内容：书架分组名称输入框（1~30 字）。 */

import { DialogManager } from '../../utils/DialogUtils';

@ComponentV2
export struct GroupNameDialogContent {
  build() {
    TextInput({ text: DialogManager.shelfGroupNameValue, placeholder: '1-30 个字' })
      .width('100%')
      .height(44)
      .fontSize(14)
      .fontColor($r('sys.color.font_primary'))
      .placeholderColor($r('sys.color.font_tertiary'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(10)
      .maxLength(30)
      .onChange((value: string): void => {
        DialogManager.shelfGroupNameValue = value;
      })
  }
}

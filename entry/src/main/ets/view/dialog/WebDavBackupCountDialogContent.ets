/** 「备份保留数量」弹窗内容：WebDAV 备份保留数量输入框（1-50 整数）。 */

import { DialogManager } from '../../utils/DialogUtils';

@ComponentV2
export struct WebDavBackupCountDialogContent {
  build() {
    TextInput({ text: DialogManager.webdavCountValue, placeholder: '1-50' })
      .type(InputType.Number)
      .width('100%')
      .height(44)
      .fontSize(14)
      .fontColor($r('sys.color.font_primary'))
      .placeholderColor($r('sys.color.font_tertiary'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(10)
      .onChange((value: string): void => {
        DialogManager.webdavCountValue = value;
      })
  }
}

/** 「分组命名」弹窗内容：书架分组名称输入框（1~30 字）+ 加锁开关（仅新建分组）。 */

import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';

@ComponentV2
export struct GroupNameDialogContent {
  build() {
    Column({ space: 12 }) {
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

      if (DialogManager.shelfGroupNameShowLock) {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('加锁')
              .fontSize(14.5)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text('进入分组需验证身份，组内作品隐藏')
              .fontSize(11.5)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: DialogManager.shelfGroupNameLock })
            .selectedColor(appState.accentColor)
            .onChange((isOn: boolean): void => {
              DialogManager.shelfGroupNameLock = isOn;
            })
        }
        .width('100%')
      }
    }
  }
}

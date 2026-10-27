/**
 * 「选择备份文件」弹窗内容：WebDAV 远端备份列表（新备份在前），
 * 每条列出时间/设备/大小，右侧 Radio 单选；先选中条目，点「恢复」后拉取并合并恢复。
 */

import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqWebDav, FqWebDavBackupEntry } from '../../core/FqWebDav';

@ComponentV2
export struct WebDavBackupListDialogContent {
  @Local selectedIndex: number = 0;

  build() {
    List({ space: 8 }) {
      ForEach(DialogManager.webdavBackupEntries, (entry: FqWebDavBackupEntry, index: number) => {
        ListItem() {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.archivebox'))
              .fontSize(20)
              .fontColor([$r('sys.color.icon_secondary')])
            Column({ space: 2 }) {
              Text(FqWebDav.displayTitle(entry.fileName))
                .fontSize(14)
                .fontColor($r('sys.color.font_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (entry.size > 0) {
                Text(FqWebDav.formatSize(entry.size))
                  .fontSize(11)
                  .fontColor($r('sys.color.font_tertiary'))
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Radio({ value: entry.fileName, group: 'webdavBackup' })
              .checked(index === this.selectedIndex)
              .radioStyle({ checkedBackgroundColor: appState.accentColor })
              .onChange((isChecked: boolean): void => {
                if (isChecked) {
                  this.selectedIndex = index;
                  DialogManager.webdavBackupIndex = index;
                }
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(10)
        .borderRadius(12)
        .backgroundColor(this.selectedIndex === index
          ? $r('sys.color.comp_background_tertiary')
          : Color.Transparent)
        .onClick((): void => {
          this.selectedIndex = index;
          DialogManager.webdavBackupIndex = index;
        })
      }, (entry: FqWebDavBackupEntry, index: number): string => `${entry.fileName}_${index}`)
    }
    .constraintSize({ maxHeight: 320 })
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

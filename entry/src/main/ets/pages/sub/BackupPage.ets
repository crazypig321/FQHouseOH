/**
 * 备份与恢复页（设置-数据-备份与恢复，对齐 fqapp LibraryBackupPage 流程）：
 * - 导出备份：弹窗确认 → 采集本机书架/浏览/收听/阅读进度/已看剧集 → 白名单校验 →
 *   写入 Download/FQHouseOH/fqhouse-backup-时间戳.json（复用缓存导出目录体系）；
 * - 从备份恢复：系统文件选择器选 json → 读取 + 全量校验 → 预览统计 →
 *   「确认恢复到本机」合并写入（只补缺失，绝不覆盖本机已有记录，可重复导入）；
 * - busy 期间禁用全部操作；结果/错误就地展示（fqapp 同款文案风格）。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions, ROUTE_WEBDAV, ROUTE_FANQIE_IMPORT } from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { DialogManager } from '../../utils/DialogUtils';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';
import { fqExportTextFile } from '../../core/FqCacheExport';
import {
  FQ_BACKUP_MAX_BYTES,
  FqLibraryBackup,
  FqLibraryBackupData,
  FqLibraryBackupRestoreResult,
} from '../../core/FqLibraryBackup';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_BACKUP_TOP_INSET: number = 56;
/** 滚动内容末尾偏移。 */
const FQ_BACKUP_BOTTOM_INSET: number = 40;
/** 行内分割线左右避让（与设置页行一致）。 */
const FQ_BACKUP_ROW_DIVIDER_INSET: number = 60;
/** 备份保存目录（展示文案）。 */
const FQ_BACKUP_DIR_TEXT: string = 'Download/FQHouseOH';

/** 两位补零。 */
function fqBackupPad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 备份文件名时间戳（yyyyMMdd_HHmmss）。 */
function fqBackupFileStamp(now: Date): string {
  return `${now.getFullYear()}${fqBackupPad(now.getMonth() + 1)}${fqBackupPad(now.getDate())}` +
    `_${fqBackupPad(now.getHours())}${fqBackupPad(now.getMinutes())}${fqBackupPad(now.getSeconds())}`;
}

/** 毫秒时间戳 → 'yyyy-MM-dd HH:mm'。 */
function fqBackupDateTime(ms: number): string {
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${fqBackupPad(date.getMonth() + 1)}-${fqBackupPad(date.getDate())}` +
    ` ${fqBackupPad(date.getHours())}:${fqBackupPad(date.getMinutes())}`;
}

@Builder
function fqBackupEmptyContent() {
}

/** 卡片壳（与设置页 FqSettingsCard 同体系：comp_background_list_card + 深色描边）。 */
@ComponentV2
struct FqBackupCard {
  @BuilderParam content: () => void = fqBackupEmptyContent;

  build() {
    Column() {
      this.content()
    }
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }
}

@ComponentV2
export struct BackupPage {
  private scroller: Scroller = new Scroller();
  /** 非空 = 进行中（导出/选择/恢复），期间禁用全部操作。 */
  @Local busy: string = '';
  /** 就地结果/错误消息。 */
  @Local message: string = '';
  @Local messageIsError: boolean = false;
  /** 选中并解析通过的备份（待确认恢复）。 */
  @Local preview: FqLibraryBackupData | null = null;

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('备份与恢复', false),
      scroller: this.scroller,
    }) {
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
          this.SectionHeader('本机数据')
        }
        ListItem() {
          FqBackupCard() {
            this.ActionRow($r('sys.symbol.download'), '#FF3B82F6', '导出备份',
              `备份将保存到 ${FQ_BACKUP_DIR_TEXT} 目录`, (): void => {
                this.confirmExport();
              })
            this.RowDivider()
            this.ActionRow($r('sys.symbol.doc_plaintext'), '#FF10B981', '从备份恢复',
              this.preview === null ? '选择备份文件，预览后再合并' : '重新选择其他备份', (): void => {
                this.runImport();
              })
            this.RowDivider()
            this.ActionRow($r('sys.symbol.cloud'), '#FF8B5CF6', 'WebDAV 备份与恢复',
              '通过 WebDAV 服务器云端备份与恢复', (): void => {
                NavPathUtils.push(ROUTE_WEBDAV);
              })
          }
        }

        ListItem() {
          this.SectionHeader('其他来源')
        }
        ListItem() {
          FqBackupCard() {
            this.ActionRow($r('sys.symbol.book_pages'), '#FFF97316', '导入番茄书架',
              '从番茄账号读取书架与阅读进度，合并到本机', (): void => {
                NavPathUtils.push(ROUTE_FANQIE_IMPORT);
              })
          }
        }

        if (this.preview !== null) {
          ListItem() {
            this.SectionHeader('恢复预览')
          }
          ListItem() {
            FqBackupCard() {
              this.PreviewContent(this.preview)
            }
          }
        }

        if (this.message.length > 0) {
          ListItem() {
            FqBackupCard() {
              Text(this.message)
                .fontSize(13)
                .lineHeight(20)
                .fontColor(this.messageIsError
                  ? '#FFF43F5E'
                  : $r('sys.color.font_secondary'))
                .padding(16)
                .width('100%')
            }
          }
        }

        if (this.busy.length > 0) {
          ListItem() {
            Row({ space: 10 }) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(appState.accentColor)
              Text(this.busy)
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
          }
        }

        ListItem() {
          this.SectionHeader('说明')
        }
        ListItem() {
          FqBackupCard() {
            Column({ space: 8 }) {
              Text('备份包含哪些内容？')
                .fontSize(14.5)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
              Text(`包含书架收藏、浏览记录、收听进度、阅读进度、已看剧集（含续播进度）与外观、阅读设置。\n\n` +
                '不含本地 TXT 书籍、下载缓存、阅读时长统计与搜索历史，这些需要另行保留。\n\n' +
                `导出的备份保存在 ${FQ_BACKUP_DIR_TEXT} 目录，可跨设备传输；` +
                '恢复采用合并方式，只补充缺失记录，不会覆盖本机已有数据，可重复导入。')
                .fontSize(13)
                .lineHeight(21)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
            }
            .padding(16)
            .width('100%')
          }
        }
      }
      .padding({ left: 16, right: 16, top: 10, bottom: appState.bottomRect + FQ_BACKUP_BOTTOM_INSET })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_BACKUP_TOP_INSET)
      .width('100%')
      .height('100%')
    }
  }

  /** 导出前弹窗确认（DialogManager 公共确认弹窗）。 */
  private confirmExport(): void {
    if (this.busy.length > 0) {
      return;
    }
    DialogManager.ShowConfirm('导出备份',
      `备份将保存到 ${FQ_BACKUP_DIR_TEXT} 目录，包含书架收藏、浏览记录、收听进度、` +
      '阅读进度、已看剧集与外观、阅读设置。将文件传到新设备，在本页选择导入即可恢复。',
      '导出', (): void => {
        this.runExport();
      });
  }

  /** 导出：采集 → 校验 → 写入下载目录，结果就地提示。 */
  private async runExport(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = '正在导出备份…';
    this.message = '';
    this.messageIsError = false;
    try {
      const data: FqLibraryBackupData = FqLibraryBackup.capture();
      const text: string = FqLibraryBackup.encode(data);
      const name: string = `fqhouse-backup-${fqBackupFileStamp(new Date())}.json`;
      await fqExportTextFile(getContext(this), name, text);
      let summary: string = `备份已保存到 ${FQ_BACKUP_DIR_TEXT}/${name}\n` +
        `收录收藏 ${data.shelf.length} 条、浏览 ${data.browse.length} 条、收听 ${data.listen.length} 条、` +
        `阅读进度 ${data.reader.length} 本、已看剧集 ${data.episodeCount()} 集。\n` +
        '将文件传到新设备，在本页选择导入即可。';
      if (data.excludedLocalRecords > 0) {
        summary += `\n已排除 ${data.excludedLocalRecords} 条本地书籍相关记录。`;
      }
      this.message = summary;
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '导出失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 选择备份文件：系统选择器 → 读取校验 → 预览。 */
  private async runImport(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = '请选择备份文件…';
    this.message = '';
    this.messageIsError = false;
    this.preview = null;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['json'],
      });
      if (uris.length === 0) {
        this.message = '已取消选择';
        return;
      }
      this.busy = '正在读取备份…';
      const text: string = this.readBackupFile(uris[0]);
      this.preview = FqLibraryBackup.decode(text);
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '读取备份失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 确认恢复：合并写入（只补缺失），结果统计就地提示。 */
  private async runRestore(): Promise<void> {
    const data: FqLibraryBackupData | null = this.preview;
    if (data === null || this.busy.length > 0) {
      return;
    }
    this.busy = '正在恢复，请稍候…';
    this.message = '';
    this.messageIsError = false;
    try {
      const result: FqLibraryBackupRestoreResult = FqLibraryBackup.restore(data);
      this.preview = null;
      let summary: string = `恢复完成：新增收藏 ${result.shelfAdded} 条、浏览 ${result.browseAdded} 条、` +
        `收听 ${result.listenAdded} 条、阅读进度 ${result.readerAdded} 本、` +
        `已看剧集 ${result.episodesAdded} 集。\n本机已有记录保持不变，可重复导入。`;
      if (result.settingsApplied) {
        summary += '\n外观与阅读设置已同步。';
      }
      this.message = summary;
    } catch (error) {
      this.messageIsError = true;
      this.message = '恢复未完成，部分记录可能已写入。可重试同一文件，已存在的数据会保留。';
    } finally {
      this.busy = '';
    }
  }

  /** 读取备份文件（≤16MB），UTF-8 解码为文本。 */
  private readBackupFile(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > FQ_BACKUP_MAX_BYTES) {
        throw new Error('备份文件超过 16 MB 或不可读');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
      return decoder.decodeWithStream(new Uint8Array(buffer), { stream: false });
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        // 关闭失败忽略
      }
    }
  }

  @Builder
  private SectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(3.5)
        .height(15)
        .borderRadius(2)
        .backgroundColor(appState.accentColor)
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
    }
    .width('100%')
  }

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: FQ_BACKUP_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 操作行（彩色图标块 + 标题/副标题 + 箭头；busy 期间禁用）。 */
  @Builder
  private ActionRow(icon: Resource, tint: string, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([tint])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(tint, 0.12))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .enabled(this.busy.length === 0)
    .onClick(onTap)
  }

  /** 恢复预览卡内容：备份时间 + 统计 + 说明 + 确认按钮。 */
  @Builder
  private PreviewContent(data: FqLibraryBackupData) {
    Column({ space: 14 }) {
      Text(`备份于 ${fqBackupDateTime(data.createdAt)}`)
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        this.StatCell(`${data.shelf.length}`, '收藏')
        this.StatCell(`${data.browse.length}`, '浏览')
        this.StatCell(`${data.listen.length}`, '收听')
        this.StatCell(`${data.reader.length}`, '阅读进度')
        this.StatCell(`${data.episodeCount()}`, '已看剧集')
      }
      .width('100%')

      Text('恢复只补充缺失的记录，本机已有的收藏、进度与已看标记保持不变，可重复导入。')
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')

      if (data.excludedLocalRecords > 0) {
        Text(`此备份不含 ${data.excludedLocalRecords} 条本地书籍记录。`)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }

      Button('确认恢复到本机')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(appState.accentColor)
        .height(42)
        .borderRadius(12)
        .width('100%')
        .enabled(this.busy.length === 0)
        .onClick((): void => {
          this.runRestore();
        })
    }
    .padding(16)
    .width('100%')
  }

  /** 预览统计单元（数值 + 标签）。 */
  @Builder
  private StatCell(countText: string, label: string) {
    Column({ space: 3 }) {
      Text(countText)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(label)
        .fontSize(11.5)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('33.3%')
    .padding({ top: 4, bottom: 4 })
  }
}

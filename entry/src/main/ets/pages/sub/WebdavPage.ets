/**
 * WebDAV 备份与恢复页（备份与恢复-WebDAV，写法对齐 musicfreeOH WebDavSettingPage）：
 * - 服务器配置卡：服务器地址 / 备份路径 / 用户名 / 密码（输入即保存）；
 * - 操作卡：备份到 WebDAV（独立时间戳文件）/ 从 WebDAV 恢复（远端列表弹窗选择后合并恢复）/
 *   退出时自动备份开关 / 备份保留数量（超限自动删除最老备份）；
 * - 备份内容复用本机备份（FqLibraryBackup 白名单 JSON），恢复为合并语义（只补缺失，可重复恢复）；
 * - busy 期间禁用操作；结果/错误就地展示。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqWebDavConfigStore } from '../../core/FqWebDavConfigStore';
import {
  FqWebDav,
  FqWebDavBackupEntry,
} from '../../core/FqWebDav';
import {
  FqLibraryBackup,
  FqLibraryBackupData,
  FqLibraryBackupRestoreResult,
} from '../../core/FqLibraryBackup';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_WEBDAV_TOP_INSET: number = 56;
/** 滚动内容末尾偏移。 */
const FQ_WEBDAV_BOTTOM_INSET: number = 40;

@Builder
function fqWebDavEmptyContent() {
}

/** 卡片壳（与备份页 FqBackupCard 同体系）。 */
@ComponentV2
struct FqWebDavCard {
  @BuilderParam content: () => void = fqWebDavEmptyContent;

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
export struct WebdavPage {
  private scroller: Scroller = new Scroller();
  @Local url: string = FqWebDavConfigStore.getUrl();
  @Local path: string = FqWebDavConfigStore.getPath();
  @Local username: string = FqWebDavConfigStore.getUsername();
  @Local password: string = FqWebDavConfigStore.getPassword();
  @Local autoBackupOnExit: boolean = FqWebDavConfigStore.isAutoBackupOnExit();
  /** 备份保留数量展示文本。 */
  @Local maxBackupCountText: string = `${FqWebDavConfigStore.getMaxBackupCount()} 个`;
  /** 非空 = 进行中（备份/列表/恢复），期间禁用全部操作。 */
  @Local busy: string = '';
  /** 就地结果/错误消息。 */
  @Local message: string = '';
  @Local messageIsError: boolean = false;

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('WebDAV 备份与恢复', false),
      scroller: this.scroller,
    }) {
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
          this.SectionHeader('服务器配置')
        }
        ListItem() {
          FqWebDavCard() {
            this.ConfigRow('服务器地址', this.url, 'https://dav.example.com/dav/', false,
              (value: string): void => {
                this.url = value;
                FqWebDavConfigStore.setUrl(value);
              })
            this.RowDivider()
            this.ConfigRow('备份路径', this.path, '可选，如 /backups', false,
              (value: string): void => {
                this.path = value;
                FqWebDavConfigStore.setPath(value);
              })
            this.RowDivider()
            this.ConfigRow('用户名', this.username, '可选', false,
              (value: string): void => {
                this.username = value;
                FqWebDavConfigStore.setUsername(value);
              })
            this.RowDivider()
            this.ConfigRow('密码', this.password, '可选', true,
              (value: string): void => {
                this.password = value;
                FqWebDavConfigStore.setPassword(value);
              })
          }
        }

        ListItem() {
          this.SectionHeader('操作')
        }
        ListItem() {
          FqWebDavCard() {
            this.ActionRow($r('sys.symbol.arrow_up_circle'), '#FF3B82F6', '备份到 WebDAV',
              '生成独立备份文件，不覆盖历史备份', (): void => {
                this.runBackup();
              })
            this.RowDivider()
            this.ActionRow($r('sys.symbol.arrow_down_circle'), '#FF10B981', '从 WebDAV 恢复',
              '选择远端备份文件，合并恢复到本机', (): void => {
                this.runRestoreSelect();
              })
            this.RowDivider()
            this.ToggleRow('退出时自动备份',
              '彻底退出应用时自动上传一次备份（需服务器可达）')
            this.RowDivider()
            this.CountRow()
          }
        }

        if (this.message.length > 0) {
          ListItem() {
            FqWebDavCard() {
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
          FqWebDavCard() {
            Column({ space: 8 }) {
              Text('WebDAV 备份怎么工作？')
                .fontSize(14.5)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
              Text('备份内容与本机导出一致：书架收藏、浏览记录、收听进度、阅读进度、已看剧集与外观、阅读设置，' +
                '不含本地 TXT 书籍与缓存。\n\n' +
                `每次备份在服务器的 ${FqWebDav.BACKUP_DIRNAME}/ 目录生成独立文件（文件名含时间与设备名），` +
                '超出保留数量时自动删除最老备份；恢复采用合并方式，只补充缺失记录，' +
                '不会覆盖本机已有数据，可重复恢复。\n\n' +
                '认证方式为 Basic Auth（用户名/密码可留空），请确保服务器地址支持 WebDAV。')
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
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_WEBDAV_TOP_INSET)
      .contentEndOffset(appState.bottomRect)
      .width('100%')
      .height('100%')
    }
  }

  /** 备份到 WebDAV。 */
  private async runBackup(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    if (!FqWebDav.isConfigured()) {
      this.messageIsError = true;
      this.message = '请先填写 WebDAV 服务器地址';
      return;
    }
    this.busy = '正在备份到 WebDAV…';
    this.message = '';
    this.messageIsError = false;
    try {
      const ok: boolean = await FqWebDav.backup();
      this.messageIsError = !ok;
      this.message = ok
        ? '备份成功，已上传到 WebDAV。'
        : '备份失败，请检查服务器地址与账号。';
    } catch (error) {
      this.messageIsError = true;
      this.message = error instanceof Error && error.message.length > 0
        ? error.message
        : '备份失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 从 WebDAV 恢复：拉取远端备份列表 → 弹窗选择文件 → 下载合并恢复。 */
  private async runRestoreSelect(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    if (!FqWebDav.isConfigured()) {
      this.messageIsError = true;
      this.message = '请先填写 WebDAV 服务器地址';
      return;
    }
    this.busy = '正在获取备份列表…';
    this.message = '';
    this.messageIsError = false;
    try {
      const entries: FqWebDavBackupEntry[] | null = await FqWebDav.listBackups();
      this.busy = '';
      if (entries === null) {
        this.messageIsError = true;
        this.message = '获取备份列表失败，请检查服务器地址与账号。';
        return;
      }
      if (entries.length === 0) {
        this.messageIsError = true;
        this.message = 'WebDAV 上没有备份文件。';
        return;
      }
      DialogManager.SelectWebDavBackup(entries, (fileName: string): void => {
        this.restoreFrom(fileName);
      });
    } catch (error) {
      this.busy = '';
      this.messageIsError = true;
      this.message = '获取备份列表失败，请重试';
    }
  }

  /** 拉取选中的备份文件并合并恢复。 */
  private async restoreFrom(fileName: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = '正在从 WebDAV 恢复…';
    this.message = '';
    this.messageIsError = false;
    try {
      const result = await FqWebDav.fetchBackup(fileName);
      if (result.notFound) {
        this.messageIsError = true;
        this.message = '备份文件不存在，可能已被清理。';
        return;
      }
      if (!result.ok) {
        this.messageIsError = true;
        this.message = '恢复失败，请检查服务器地址与账号。';
        return;
      }
      const data: FqLibraryBackupData = FqLibraryBackup.decode(result.data);
      const restoreResult: FqLibraryBackupRestoreResult = FqLibraryBackup.restore(data);
      let summary: string = `恢复完成：新增收藏 ${restoreResult.shelfAdded} 条、浏览 ${restoreResult.browseAdded} 条、` +
        `收听 ${restoreResult.listenAdded} 条、阅读进度 ${restoreResult.readerAdded} 本、` +
        `已看剧集 ${restoreResult.episodesAdded} 集。\n本机已有记录保持不变，可重复恢复。`;
      if (restoreResult.settingsApplied) {
        summary += '\n外观与阅读设置已同步。';
      }
      this.message = summary;
    } catch (error) {
      this.messageIsError = true;
      this.message = error instanceof Error && error.message.length > 0
        ? error.message
        : '恢复失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 备份保留数量：弹窗输入 1-50 整数。 */
  private showBackupCountDialog(): void {
    DialogManager.InputWebDavBackupCount(FqWebDavConfigStore.getMaxBackupCount(),
      (count: number): void => {
        FqWebDavConfigStore.setMaxBackupCount(count);
        this.maxBackupCountText = `${count} 个`;
      });
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
      .margin({ left: 14, right: 14 })
  }

  /** 配置输入行（标签 + 输入框，输入即保存）。 */
  @Builder
  private ConfigRow(label: string, value: string, placeholder: string,
    isPassword: boolean, onChange: (value: string) => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(14.5)
        .fontColor($r('sys.color.font_primary'))
        .width(80)
      TextInput({ text: value, placeholder: placeholder })
        .layoutWeight(1)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .type(isPassword ? InputType.Password : InputType.Normal)
        .onChange(onChange)
    }
    .padding({ left: 14, right: 14 })
    .height(56)
    .width('100%')
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

  /** 开关行（彩色图标块 + 标题/副标题 + Switch）。 */
  @Builder
  private ToggleRow(title: string, subtitle: string) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(17)
          .fontColor(['#FFF59E0B'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FFF59E0B', 0.12))

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

      Toggle({ type: ToggleType.Switch, isOn: this.autoBackupOnExit })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          this.autoBackupOnExit = isOn;
          FqWebDavConfigStore.setAutoBackupOnExit(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 备份保留数量行（点击弹窗输入）。 */
  @Builder
  private CountRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
          .fontSize(17)
          .fontColor(['#FF8B5CF6'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF8B5CF6', 0.12))

      Column({ space: 3 }) {
        Text('备份保留数量')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('超出时自动删除最老备份')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.maxBackupCountText)
        .fontSize(13)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .enabled(this.busy.length === 0)
    .onClick((): void => {
      this.showBackupCountDialog();
    })
  }
}

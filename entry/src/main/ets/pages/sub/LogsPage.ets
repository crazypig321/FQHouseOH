/**
 * 日志页（设置-服务-日志入口，对齐 fqapp log_viewer_page）：
 * - 双源切换：「应用」（FqLogStore 环形缓冲，revision 实时刷新）/
 *   「核心」（filesDir/backend/rust.log，2s 轮询解析，行格式与应用同形）；
 * - 级别筛选（FqMenu 锚点菜单）+ 标签/内容搜索；
 * - 条目卡 List + LazyForEach（最新在前，点击展开完整内容）；
 * - 操作半模态（CommonSheet）：复制筛选结果 / 导出筛选结果 / 导出全部 /
 *   清空应用日志（DialogManager 确认弹窗）；
 * - 导出复用缓存导出目录体系（Download/<包名>/）。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqCacheEmptyView } from '../../view/FqCacheCommon';
import { FqMenu, FqMenuItem } from '../../view/CommonMenu';
import { CommonSheet, FqSheetOptions } from '../../view/sheet/CommonSheet';
import { DialogManager } from '../../utils/DialogUtils';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';
import { fqExportTextFile } from '../../core/FqCacheExport';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  FqLogEntry,
  FqLogLevel,
  FqLogStore,
  fqFormatLogLines,
  fqLogClock,
  fqLogLevelLabel,
  fqLogStamp,
  fqLogStore,
  fqParseLogLines,
} from '../../core/FqLogStore';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_LOG_TOP_INSET: number = 56;
/** 级别筛选菜单锚点 id。 */
const FQ_LOG_FILTER_ANCHOR_ID: string = 'logs_level_anchor';
/** 核心日志轮询间隔（ms，对齐官方 rustRefresh 2s）。 */
const FQ_LOG_CORE_POLL_MS: number = 2000;
/** 级别徽标配色（下标 = FqLogLevel）。 */
const FQ_LOG_LEVEL_TINTS: string[] = ['#FF9CA3AF', '#FF3B82F6', '#FFF59E0B', '#FFF43F5E'];
/** 危险操作文字色。 */
const FQ_DANGER_TINT: string = '#FFF43F5E';

/** 列表行模型（条目 + 级别配色）。 */
class FqLogRow {
  public readonly entry: FqLogEntry;
  public readonly tint: string;

  constructor(entry: FqLogEntry, tint: string) {
    this.entry = entry;
    this.tint = tint;
  }
}

/** 懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class FqLogDataSource implements IDataSource {
  private rows: FqLogRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): FqLogRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reload(rows: FqLogRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 单条日志卡：级别徽标 + 标签 + 时刻 + 内容（收起 3 行 / 展开全文）。 */
@ComponentV2
struct FqLogRowItem {
  @Require @Param row: FqLogRow;
  @Local expanded: boolean = false;

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(fqLogLevelLabel(this.row.entry.level))
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.row.tint)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(FqColorUtils.withOpacity(this.row.tint, 0.12))
        Text(this.row.entry.tag)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(fqLogClock(new Date(this.row.entry.timeMs)))
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([$r('sys.color.font_tertiary')])
          .rotate({ angle: this.expanded ? 90 : 0 })
      }
      .width('100%')

      Text(this.row.entry.message)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .fontFamily('monospace')
        .maxLines(this.expanded ? 9999 : 3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .onClick((): void => {
      this.expanded = !this.expanded;
    })
  }
}

@ComponentV2
export struct LogsPage {
  private scroller: Scroller = new Scroller();
  private dataSource: FqLogDataSource = new FqLogDataSource();
  /** 应用日志单例（revision 自增实时刷新）。 */
  @Local logStore: FqLogStore = fqLogStore;
  /** 当前源：0 应用 / 1 核心。 */
  @Local source: number = 0;
  /** 级别筛选（-1 全部）。 */
  @Local level: number = -1;
  @Local query: string = '';
  @Local visibleCount: number = 0;
  @Local totalCount: number = 0;
  /** 核心日志文件缺失/不可读。 */
  @Local coreMissing: boolean = false;
  /** 操作半模态。 */
  @Local actionsVisible: boolean = false;
  /** 当前筛选后的行（复制/导出用，refresh 时更新）。 */
  private visibleRows: FqLogRow[] = [];
  private coreEntries: FqLogEntry[] = [];
  private coreLastText: string = '';
  private coreTimer: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.stopCorePolling();
  }

  /** 应用日志新增/清空（仅应用源在屏时刷新列表）。 */
  @Monitor('logStore.revision')
  onAppLogChanged(): void {
    if (this.source === 0) {
      this.refresh();
    }
  }

  /** 源切换：核心源启动 2s 轮询，应用源停止。 */
  @Monitor('source')
  onSourceChanged(): void {
    if (this.source === 1) {
      this.startCorePolling();
    } else {
      this.stopCorePolling();
    }
    this.refresh();
  }

  private currentEntries(): FqLogEntry[] {
    return this.source === 0 ? this.logStore.entries() : this.coreEntries;
  }

  /** 重算筛选结果并整体刷新列表（最新在前）。 */
  private refresh(): void {
    const all: FqLogEntry[] = this.currentEntries();
    const keyword: string = this.query.trim().toLowerCase();
    const rows: FqLogRow[] = [];
    for (let i = all.length - 1; i >= 0; i--) {
      const entry: FqLogEntry = all[i];
      if (this.level >= 0 && entry.level !== this.level) {
        continue;
      }
      if (keyword.length > 0 && !entry.tag.toLowerCase().includes(keyword) &&
        !entry.message.toLowerCase().includes(keyword)) {
        continue;
      }
      rows.push(new FqLogRow(entry, FQ_LOG_LEVEL_TINTS[entry.level]));
    }
    this.visibleRows = rows;
    this.visibleCount = rows.length;
    this.totalCount = all.length;
    this.dataSource.reload(rows);
  }

  private startCorePolling(): void {
    this.stopCorePolling();
    this.loadCoreLog();
    this.coreTimer = setInterval((): void => {
      this.loadCoreLog();
    }, FQ_LOG_CORE_POLL_MS);
  }

  private stopCorePolling(): void {
    if (this.coreTimer !== 0) {
      clearInterval(this.coreTimer);
      this.coreTimer = 0;
    }
  }

  /** 读取并解析 rust.log（内容不变跳过解析；缺失/失败置 coreMissing）。 */
  private loadCoreLog(): void {
    try {
      const path: string = `${getContext(this).filesDir}/backend/rust.log`;
      if (!fileIo.accessSync(path)) {
        this.coreMissing = true;
        this.coreEntries = [];
        this.coreLastText = '';
      } else {
        this.coreMissing = false;
        const text: string = fileIo.readTextSync(path);
        if (text !== this.coreLastText) {
          this.coreLastText = text;
          const lines: string[] = text.split('\n');
          while (lines.length > 0 && lines[lines.length - 1].trim().length === 0) {
            lines.pop();
          }
          this.coreEntries = fqParseLogLines(lines);
        }
      }
    } catch (error) {
      this.coreMissing = true;
      this.coreEntries = [];
      this.coreLastText = '';
    }
    if (this.source === 1) {
      this.refresh();
    }
  }

  /** 级别筛选菜单（FqMenu 锚点直选，当前档尾勾标识）。 */
  private openLevelMenu(): void {
    const items: FqMenuItem[] = [];
    const allItem: FqMenuItem = new FqMenuItem();
    allItem.label = '全部级别';
    if (this.level < 0) {
      allItem.endIcon = $r('sys.symbol.checkmark');
    }
    allItem.onAction = (): void => {
      this.level = -1;
      this.refresh();
    };
    items.push(allItem);
    const levels: FqLogLevel[] = [FqLogLevel.debug, FqLogLevel.info, FqLogLevel.warn, FqLogLevel.error];
    for (const level of levels) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = fqLogLevelLabel(level);
      if (this.level === level) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      const picked: FqLogLevel = level;
      item.onAction = (): void => {
        this.level = picked;
        this.refresh();
      };
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), FQ_LOG_FILTER_ANCHOR_ID, items);
  }

  /** 复制当前筛选结果到剪贴板。 */
  private copyVisible(): void {
    const entries: FqLogEntry[] = [];
    for (const row of this.visibleRows) {
      entries.push(row.entry);
    }
    if (entries.length === 0) {
      this.toast('暂无可复制的日志');
      return;
    }
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, fqFormatLogLines(entries));
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      this.toast(`已复制 ${entries.length} 条日志`);
    }).catch((): void => {
      this.toast('复制失败，请重试');
    });
  }

  /** 导出日志 TXT 到 Download/<包名>/（all = 当前来源全部，否则当前筛选结果）。 */
  private async exportEntries(all: boolean): Promise<void> {
    let entries: FqLogEntry[] = this.currentEntries();
    if (!all) {
      entries = [];
      for (const row of this.visibleRows) {
        entries.push(row.entry);
      }
    }
    if (entries.length === 0) {
      this.toast('暂无可导出的日志');
      return;
    }
    const label: string = this.source === 0 ? '应用' : '核心';
    const header: string = `FQHouseOH ${label}日志\n导出时间：${fqLogStamp(new Date())}` +
      `\n范围：${all ? '当前来源全部日志' : '当前筛选结果'}\n共 ${entries.length} 条\n\n`;
    try {
      await fqExportTextFile(getContext(this),
        `fqhouse-${this.source === 0 ? 'app' : 'core'}-logs-${Date.now()}.txt`,
        header + fqFormatLogLines(entries));
      this.toast(`已导出 ${entries.length} 条${label}日志`);
    } catch (error) {
      this.toast('导出失败，请重试');
    }
  }

  /** 清空应用日志（确认弹窗；核心日志不受影响）。 */
  private confirmClearAppLogs(): void {
    DialogManager.ShowConfirm('清空应用日志', '将清空内存中的应用运行日志，核心日志不受影响', '清空',
      (): void => {
        this.logStore.clear();
        this.toast('已清空应用日志');
      });
  }

  private closeActions(): void {
    this.actionsVisible = false;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('日志', false),
      scroller: this.scroller,
    }) {
      Column() {
        this.ControlCard()

        if (this.visibleCount === 0) {
          Column() {
            FqCacheEmptyView({
              icon: $r('sys.symbol.list_bullet'),
              tint: '#FF3B82F6',
              title: this.source === 0
                ? '暂无应用日志'
                : (this.coreMissing ? '核心日志未生成' : '暂无核心日志'),
              subtitle: this.source === 0
                ? '应用启动与后端请求异常会记录在此，仅保留最近日志'
                : '本地后端运行日志每 2 秒自动刷新（backend/rust.log）',
            })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8, scroller: this.scroller }) {
            LazyForEach(this.dataSource, (row: FqLogRow) => {
              ListItem() {
                FqLogRowItem({ row: row })
              }
            }, (row: FqLogRow) => `${row.entry.seq}-${row.entry.timeMs}`)
          }
          .padding({ left: 16, right: 16, top: 10 })
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .contentEndOffset(appState.bottomRect)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: appState.topRect + FQ_LOG_TOP_INSET, })
      .bindSheet(this.actionsVisible, this.ActionsSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeActions();
        }, 320, false))
    }
  }

  /** 控制卡：源切换胶囊 + 级别筛选 + 操作入口 + 搜索框 + 统计行。 */
  @Builder
  private ControlCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        this.SourceTab(0, '应用')
        this.SourceTab(1, '核心')

        Blank()

        Text(this.level < 0 ? '级别' : this.levelLabel())
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .id(FQ_LOG_FILTER_ANCHOR_ID)
          .onClick((): void => {
            this.openLevelMenu();
          })
        Text('操作')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .onClick((): void => {
            this.actionsVisible = true;
          })
      }
      .width('100%')

      TextInput({ text: this.query, placeholder: '搜索标签或内容' })
        .onChange((value: string) => {
          this.query = value;
          this.refresh();
        })
        .height(36)
        .fontSize(13)
        .placeholderFont({ size: 13 })
        .placeholderColor($r('sys.color.font_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .borderRadius(18)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .padding({ left: 14, right: 14 })
        .width('100%')

      Row({ space: 6 }) {
        Text(`${this.visibleCount}/${this.totalCount} 条`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
        if (this.source === 1) {
          Text(this.coreMissing ? ' · 核心日志文件未生成' : ' · 每 2 秒自动刷新')
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .margin({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 源切换胶囊（选中橙底白字）。 */
  @Builder
  private SourceTab(index: number, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.source === index ? Color.White : $r('sys.color.font_secondary'))
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.source === index ? appState.accentColor : $r('sys.color.comp_background_tertiary'))
      .onClick((): void => {
        if (this.source !== index) {
          this.source = index;
        }
      })
  }

  /** 操作半模态（CommonSheet 壳：复制/导出/清空）。 */
  @Builder
  private ActionsSheetBuilder() {
    CommonSheet({
      sheetTitle: '日志操作',
      showClose: true,
      closeClick: (): void => {
        this.closeActions();
      },
    }) {
      Column({ space: 2 }) {
        this.ActionRow($r('sys.symbol.doc_text'), '复制筛选结果', `${this.visibleCount} 条 · 当前查看的结果`,
          (): void => {
            this.closeActions();
            this.copyVisible();
          })
        this.ActionRow($r('sys.symbol.download'), '导出筛选结果', '当前筛选结果导出为 TXT',
          (): void => {
            this.closeActions();
            this.exportEntries(false);
          })
        this.ActionRow($r('sys.symbol.arrow_up_right'), '导出全部', '当前来源全部日志导出为 TXT',
          (): void => {
            this.closeActions();
            this.exportEntries(true);
          })
        this.ActionRow($r('sys.symbol.trash'), '清空应用日志', '仅清空应用运行日志，核心日志不受影响',
          (): void => {
            this.closeActions();
            this.confirmClearAppLogs();
          })
      }
      .padding({ left: 8, right: 8, bottom: 16 })
    }
  }

  /** 操作行：图标 + 标题/副标题，整行点击。 */
  @Builder
  private ActionRow(icon: Resource, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([title === '清空应用日志' ? FQ_DANGER_TINT : $r('sys.color.font_secondary')])
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor(title === '清空应用日志' ? FQ_DANGER_TINT : $r('sys.color.font_primary'))
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .onClick((): void => {
      onTap();
    })
  }

  /** 当前级别筛选的中文标签。 */
  private levelLabel(): string {
    if (this.level === FqLogLevel.debug) {
      return fqLogLevelLabel(FqLogLevel.debug);
    }
    if (this.level === FqLogLevel.info) {
      return fqLogLevelLabel(FqLogLevel.info);
    }
    if (this.level === FqLogLevel.warn) {
      return fqLogLevelLabel(FqLogLevel.warn);
    }
    if (this.level === FqLogLevel.error) {
      return fqLogLevelLabel(FqLogLevel.error);
    }
    return '级别';
  }
}

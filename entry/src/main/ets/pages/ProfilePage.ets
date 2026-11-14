/**
 * 「我的」Tab 页（对齐 fqapp MinePage + StatsPage）：
 * - 书友卡片 + 快捷入口（缓存管理/备份恢复/应用设置/关于我们，「我的含设置入口」样式显示）；
 * - 阅读与视听统计：概览、16 周热力图、最近阅读、每日记录、最近封面、
 *   阅读排行（「查看全部」半模态 sheet）。
 * 数据源：FqReadStatsStore（全局日累计 + 按书日累计）+ FqBrowseStore（浏览历史）。
 */

import { CommonNav } from '../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../view/sheet/CommonSheet';
import { RefreshOverlay } from '../view/CommonCom';
import {
  FqTitleBarOptions,
  fqPushBookOrDetail,
  DetailNavParams,
  ReaderNavParams,
  ROUTE_ABOUT,
  ROUTE_BACKUP,
  ROUTE_CACHE_MANAGE,
  ROUTE_DETAIL,
  ROUTE_READER2,
  ROUTE_SETTINGS,
} from '../model/FqNavModels';
import { SETTINGS_TAB_INDEX } from '../model/FqTabsModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqBrowseItem, FqBrowseStore } from '../core/FqBrowseStore';
import { FqLocalBookStore } from '../core/FqLocalBookStore';
import { FqShelfStore } from '../core/FqShelfStore';
import { FqChapterCacheStore } from '../core/FqChapterCacheStore';
import { DialogManager } from '../utils/DialogUtils';
import { FqColorUtils } from '../utils/FqColorUtils';
import { FqBackend } from '../core/FqBackend';
import { appState } from '../entryability/AppState';
import {
  FQ_MINE_STYLE_MINE_WITH_SETTINGS,
  FQ_MINE_STYLE_SETTINGS_WITH_MINE,
} from '../core/FqAppSettingsStore';

const FQ_DAY_MS: number = 86400000;
/** 列表内容起始偏移：标题栏 56 ） */
const FQ_HOME_TOP_INSET: number = 56;
/** 滚动内容末尾偏移：悬浮阅读栏 72 + 底部间距 24 */
const FQ_DETAIL_BOTTOM_INSET: number = 72;
/** 热力图：16 周 × 7 天。 */
const FQ_HEAT_WEEKS: number = 16;
const FQ_HEAT_GAP: number = 3;
const FQ_HEAT_COLS: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
const FQ_HEAT_ROWS: number[] = [0, 1, 2, 3, 4, 5, 6];
const FQ_HEAT_WEEKDAYS: string[] = ['一', '', '三', '', '五', '', ''];
const FQ_DAILY_DAYS: number = 14;
const FQ_RECENT_LIMIT: number = 6;
const FQ_COVER_LIMIT: number = 5;
const FQ_RANK_LIMIT: number = 5;
/** 删除操作文字色（与缓存管理页删除色一致）。 */
const FQ_DANGER_TEXT: string = '#FFF43F5E';
const FQ_WEEKDAY_LABELS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/** 统计条目（浏览历史 + 按书累计分钟；minutes < 0 表示无真实时长记录）。 */
class FqStatsEntry {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  readonly visitedAt: number;
  readonly minutes: number;

  constructor(id: string, kind: string, title: string, cover: string, visitedAt: number, minutes: number) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.visitedAt = visitedAt;
    this.minutes = minutes;
  }
}

/** 每日记录行。 */
class FqDailyRow {
  readonly dayText: string;
  readonly subtitle: string;
  readonly minutes: number;

  constructor(dayText: string, subtitle: string, minutes: number) {
    this.dayText = dayText;
    this.subtitle = subtitle;
    this.minutes = minutes;
  }
}

function fqStatsDayKey(date: Date): string {
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

function fqStatsStartOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function fqTrimZero(text: string): string {
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/** 分钟 → 紧凑展示（'37分钟' / '2.5小时' / '3天'）。 */
function fqStatsCompact(minutes: number): string {
  const total: number = Math.floor(minutes);
  if (total <= 0) {
    return '0分钟';
  }
  if (total < 60) {
    return `${total}分钟`;
  }
  if (total < 1440) {
    return `${fqTrimZero((total / 60).toFixed(1))}小时`;
  }
  return `${fqTrimZero((total / 1440).toFixed(1))}天`;
}

/** 分钟 → 完整时长（'x天x小时x分钟'）。 */
function fqStatsDuring(minutes: number): string {
  const total: number = Math.floor(minutes);
  if (total <= 0) {
    return '0分钟';
  }
  const days: number = Math.floor(total / 1440);
  const hours: number = Math.floor((total % 1440) / 60);
  const mins: number = total % 60;
  let text: string = '';
  if (days > 0) {
    text += `${days}天`;
  }
  if (hours > 0) {
    text += `${hours}小时`;
  }
  if (mins > 0) {
    text += `${mins}分钟`;
  }
  return text.length > 0 ? text : '0分钟';
}

/** 今天/昨天/周X。 */
function fqStatsDaySubtitle(date: Date): string {
  const today: Date = fqStatsStartOfDay(new Date());
  const day: Date = fqStatsStartOfDay(date);
  const diff: number = Math.round((today.getTime() - day.getTime()) / FQ_DAY_MS);
  if (diff === 0) {
    return '今天';
  }
  if (diff === 1) {
    return '昨天';
  }
  return FQ_WEEKDAY_LABELS[day.getDay()];
}

/** 相对访问时间（刚刚/x分钟前/x小时前/x天前/M月d日）。 */
function fqStatsVisitedText(visitedAt: number): string {
  if (visitedAt <= 0) {
    return '——';
  }
  const diff: number = Date.now() - visitedAt;
  if (diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return `${Math.floor(diff / 60000)}分钟前`;
  }
  if (diff < FQ_DAY_MS) {
    return `${Math.floor(diff / 3600000)}小时前`;
  }
  if (diff < 7 * FQ_DAY_MS) {
    return `${Math.floor(diff / FQ_DAY_MS)}天前`;
  }
  const date: Date = new Date(visitedAt);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

/** 按书累计分钟（无记录返回 -1）。 */
function fqProfileBookMinutes(bookDays: Map<string, Map<string, number>>, bookId: string): number {
  const days: Map<string, number> | undefined = bookDays.get(bookId);
  if (days === undefined) {
    return -1;
  }
  let seconds: number = 0;
  days.forEach((value: number): void => {
    seconds += value;
  });
  return seconds > 0 ? seconds / 60 : -1;
}

@Builder
function fqStatsEmptyContent() {
}

/** 统计卡片壳：强调条 + 标题/副标题 + 可选标题行右侧操作区 + 内容。 */
@ComponentV2
struct FqStatsCard {
  @Param title: string = '';
  @Param subtitle: string = '';
  @BuilderParam content: () => void = fqStatsEmptyContent;
  /** 标题行右侧操作区（最近阅读「编辑」/编辑态「全选/删除/完成」）。 */
  @BuilderParam trailing: () => void = fqStatsEmptyContent;

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column()
          .width(3.5)
          .height(15)
          .borderRadius(2)
          .backgroundColor(appState.accentColor)
        Column({ space: 3 }) {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(11.5)
              .fontColor($r('sys.color.font_secondary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        this.trailing()
      }
      .width('100%')
      this.content()
    }
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }
}


@ComponentV2
export struct ProfilePage {
  /** Tab 模式（主 Tab 第三页）：隐藏返回、双击回顶；「设置含我的入口」经设置页路由推入时默认 false（带返回）。 */
  @Param isTab: boolean = false;
  private scroller: Scroller = new Scroller();

  /** 选中日期（当日零点毫秒；影响热力图终点与每日记录窗口）。 */
  private selectedMs: number = fqStatsStartOfDay(new Date()).getTime();
  @Local selectedText: string = '';
  @Local hasStats: boolean = false;
  @Local todayMin: number = 0;
  @Local monthMin: number = 0;
  @Local totalMin: number = 0;
  @Local activeDays: number = 0;
  /** 热力图 112 格分钟值（列主序：week*7 + weekday）。 */
  @Local heatCells: number[] = [];
  @Local heatMonths: string[] = [];
  @Local recentItems: FqStatsEntry[] = [];
  @Local coverItems: FqStatsEntry[] = [];
  @Local rankItems: FqStatsEntry[] = [];
  @Local dailyRows: FqDailyRow[] = [];
  @Local rankSheetVisible: boolean = false;
  /** 阅读排行 sheet 编辑模式（行首勾选圈 + 标题栏全选/删除）。 */
  @Local rankEditMode: boolean = false;
  /** 编辑模式已选条目 id。 */
  @Local rankSelectedIds: string[] = [];
  /** 最近阅读卡片编辑模式（行首勾选圈 + 标题行全选/删除/完成）。 */
  @Local recentEditMode: boolean = false;
  /** 最近阅读编辑模式已选条目 id。 */
  @Local recentSelectedIds: string[] = [];
  /** 右上角刷新中（全屏覆盖 loading）。 */
  @Local refreshing: boolean = false;

  aboutToAppear(): void {
    FqReadStatsStore.init(getContext(this));
    FqBrowseStore.init(getContext(this));
    this.rebuild();
  }

  /** 汇总统计（onShown / 选日期 / 初始化时调用）。 */
  private rebuild(): void {
    const selectedDay: Date = fqStatsStartOfDay(new Date(this.selectedMs));
    this.selectedText =
      `${selectedDay.getFullYear()}年${selectedDay.getMonth() + 1}月${selectedDay.getDate()}日`;

    // 全局日分钟表 + 汇总
    const dayMinutes: Map<string, number> = new Map<string, number>();
    let totalMin: number = 0;
    let activeDays: number = 0;
    FqReadStatsStore.allDays().forEach((seconds: number, key: string): void => {
      const minutes: number = seconds / 60;
      dayMinutes.set(key, minutes);
      totalMin += minutes;
      if (seconds > 0) {
        activeDays++;
      }
    });
    this.totalMin = totalMin;
    this.activeDays = activeDays;
    this.hasStats = activeDays > 0;

    const now: Date = new Date();
    this.todayMin = dayMinutes.get(fqStatsDayKey(now)) ?? 0;
    const monthPrefix: string = `${now.getFullYear()}-${now.getMonth() + 1}-`;
    let monthMin: number = 0;
    dayMinutes.forEach((minutes: number, key: string): void => {
      if (key.startsWith(monthPrefix)) {
        monthMin += minutes;
      }
    });
    this.monthMin = monthMin;

    // 热力图：16 周网格，周一开头，选中日为最后一格（未来格 0）
    const heatCells: number[] = [];
    const dow: number = (selectedDay.getDay() + 6) % 7;
    const startMs: number = selectedDay.getTime() - (dow + (FQ_HEAT_WEEKS - 1) * 7) * FQ_DAY_MS;
    for (let index: number = 0; index < FQ_HEAT_WEEKS * 7; index++) {
      const date: Date = new Date(startMs + index * FQ_DAY_MS);
      if (date.getTime() > selectedDay.getTime()) {
        heatCells.push(0);
      } else {
        heatCells.push(dayMinutes.get(fqStatsDayKey(date)) ?? 0);
      }
    }
    this.heatCells = heatCells;

    // 月份标签（首/中/尾去重）
    const months: string[] = [];
    const picks: number[] = [0, Math.floor(FQ_HEAT_WEEKS * 7 / 2), FQ_HEAT_WEEKS * 7 - 1];
    for (const pick of picks) {
      const date: Date = new Date(startMs + pick * FQ_DAY_MS);
      const label: string = `${date.getMonth() + 1}月`;
      if (!months.includes(label)) {
        months.push(label);
      }
    }
    this.heatMonths = months;

    // 条目：浏览历史（最新在前）+ 按书时长
    const bookDays: Map<string, Map<string, number>> = FqReadStatsStore.bookDays();
    const browsed: FqBrowseItem[] = FqBrowseStore.all();
    const entries: FqStatsEntry[] = [];
    for (const item of browsed) {
      entries.push(new FqStatsEntry(item.id, item.kind, item.title, item.cover, item.visitedAt,
        fqProfileBookMinutes(bookDays, item.id)));
    }
    // 有时长但浏览记录已被淘汰的条目（本地书 / 书旗离线续读等场景）：回填元数据
    bookDays.forEach((_days: Map<string, number>, bookId: string): void => {
      let exists: boolean = false;
      for (const item of browsed) {
        if (item.id === bookId) {
          exists = true;
          break;
        }
      }
      if (exists) {
        return;
      }
      const minutes: number = fqProfileBookMinutes(bookDays, bookId);
      if (minutes > 0) {
        entries.push(this.resolveStatsEntry(bookId, minutes));
      }
    });

    // 最近阅读 / 最近封面（浏览历史序）
    this.recentItems = entries.slice(0, FQ_RECENT_LIMIT);
    const covers: FqStatsEntry[] = [];
    for (const item of browsed) {
      if (item.cover.length > 0) {
        covers.push(new FqStatsEntry(item.id, item.kind, item.title, item.cover, item.visitedAt,
          fqProfileBookMinutes(bookDays, item.id)));
        if (covers.length >= FQ_COVER_LIMIT) {
          break;
        }
      }
    }
    this.coverItems = covers;

    // 阅读排行：真实时长 > 0，按分钟倒序
    const ranked: FqStatsEntry[] = [];
    for (const entry of entries) {
      if (entry.minutes > 0) {
        ranked.push(entry);
      }
    }
    ranked.sort((a: FqStatsEntry, b: FqStatsEntry): number => b.minutes - a.minutes);
    this.rankItems = ranked;

    // 每日记录：选中日前 14 天
    const rows: FqDailyRow[] = [];
    for (let index: number = FQ_DAILY_DAYS - 1; index >= 0; index--) {
      const date: Date = new Date(selectedDay.getTime() - index * FQ_DAY_MS);
      rows.push(new FqDailyRow(`${date.getMonth() + 1}月${date.getDate()}日`, fqStatsDaySubtitle(date),
        dayMinutes.get(fqStatsDayKey(date)) ?? 0));
    }
    this.dailyRows = rows;
  }

  /** 右上角刷新入口：全屏覆盖 loading 并重算统计（同步重算，保留短暂时长反馈）。 */
  private startRefresh(): void {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.rebuild();
    setTimeout((): void => {
      this.refreshing = false;
    }, 500);
  }

  private pickDate(): void {
    const end: Date = fqStatsStartOfDay(new Date());
    const start: Date = new Date(end.getFullYear() - 1, end.getMonth(), end.getDate());
    this.getUIContext().showDatePickerDialog({
      start: start,
      end: end,
      selected: fqStatsStartOfDay(new Date(this.selectedMs)),
      onDateAccept: (value: Date): void => {
        this.selectedMs = value.getTime();
        this.rebuild();
      },
    });
  }

  private openEntry(entry: FqStatsEntry): void {
    if (entry.kind.length === 0) {
      return;
    }
    // 本地导入书：无详情页，直接进阅读页（对齐书架打开链路）
    if (FqLocalBookStore.isLocalBookId(entry.id)) {
      ReaderNavParams.id = entry.id;
      ReaderNavParams.kind = 'book';
      ReaderNavParams.title = entry.title;
      ReaderNavParams.cover = entry.cover;
      ReaderNavParams.chapterIndex = -1;
      ReaderNavParams.listenAlong = false;
      NavPathUtils.push(ROUTE_READER2);
      return;
    }
    // 书旗来源（shuqi: 前缀 id）：进书旗只读详情
    if (entry.id.startsWith('shuqi:')) {
      DetailNavParams.id = entry.id.substring('shuqi:'.length);
      DetailNavParams.kind = 'book';
      DetailNavParams.title = entry.title;
      DetailNavParams.cover = entry.cover;
      DetailNavParams.shuqi = true;
      NavPathUtils.push(ROUTE_DETAIL);
      return;
    }
    fqPushBookOrDetail(entry.id, entry.kind, entry.title, entry.cover);
  }

  /** 无浏览记录的按书条目回填元数据：本地书取导入元数据 + 书架封面，
   *  书旗优先书架、回退章节缓存目录；其余来源书架可查则可点，否则保持不可点。 */
  private resolveStatsEntry(bookId: string, minutes: number): FqStatsEntry {
    let kind: string = 'book';
    let title: string = '';
    let cover: string = '';
    if (FqLocalBookStore.isLocalBookId(bookId)) {
      title = FqLocalBookStore.bookTitle(bookId);
    } else if (!bookId.startsWith('shuqi:')) {
      kind = '';
    }
    for (const shelfItem of FqShelfStore.all()) {
      if (shelfItem.id === bookId) {
        if (title.length === 0) {
          title = shelfItem.title;
        }
        cover = shelfItem.cover;
        if (kind.length === 0) {
          kind = shelfItem.kind;
        }
        break;
      }
    }
    if (bookId.startsWith('shuqi:') && (title.length === 0 || cover.length === 0)) {
      const catalog = FqChapterCacheStore.catalog(bookId);
      if (catalog !== null) {
        if (title.length === 0) {
          title = catalog.title;
        }
        if (cover.length === 0) {
          cover = catalog.cover;
        }
      }
    }
    if (title.length === 0) {
      title = bookId;
    }
    return new FqStatsEntry(bookId, kind, title, cover, 0, minutes);
  }

  private heatColor(minutes: number): ResourceColor {
    if (minutes <= 0) {
      return $r('sys.color.comp_background_tertiary');
    }
    if (minutes < 10) {
      return FqColorUtils.withOpacity(appState.accentColor, 0.2);
    }
    if (minutes < 30) {
      return FqColorUtils.withOpacity(appState.accentColor, 0.45);
    }
    if (minutes < 60) {
      return FqColorUtils.withOpacity(appState.accentColor, 0.7);
    }
    return appState.accentColor;
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('我的', false, undefined, (): void => {
        this.startRefresh();
      }, false, undefined, false, undefined, undefined, false,
        // 「我的含设置入口」样式：设置 Tab 已隐藏，右上角补设置按钮路由进设置页
        appState.mineSettingsStyle === FQ_MINE_STYLE_MINE_WITH_SETTINGS
          ? (): void => {
            NavPathUtils.push(ROUTE_SETTINGS);
          } : undefined),
      embedded: this.isTab,
      isHideBackButton: this.isTab,
      scroller: this.scroller,
      doubleTapToTop: this.isTab,
      scrollToTopYOffset: - appState.topRect - FQ_HOME_TOP_INSET,
      onShown: (): void => {
        this.rebuild();
      },
    }) {
      Stack() {
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            this.ProfileCard()
            // 仅「我的含设置入口」样式显示快捷入口：其余样式入口与设置页重复，不显示
            if (appState.mineSettingsStyle === FQ_MINE_STYLE_MINE_WITH_SETTINGS) {
              this.ShortcutsRow()
            }
            this.SectionHeader('阅读与视听统计')
            this.DateOverviewCard()
            FqStatsCard({
              title: '阅读热力图',
              subtitle: '最近 16 周',
              content: (): void => {
                this.HeatmapContent()
              },
            })
            FqStatsCard({
              title: '最近阅读',
              content: (): void => {
                this.RecentContent()
              },
              trailing: (): void => {
                this.RecentEditControls()
              },
            })
            FqStatsCard({
              title: '每日记录',
              content: (): void => {
                this.DailyContent()
              },
            })
            FqStatsCard({
              title: '最近封面',
              content: (): void => {
                this.CoversContent()
              },
            })
            FqStatsCard({
              title: '阅读排行',
              content: (): void => {
                this.RankContent()
              },
            })
          }
          .padding({ left: 16, right: 16, top: 10, bottom: 40 })
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentStartOffset(appState.topRect + FQ_HOME_TOP_INSET)
        .contentEndOffset(appState.bottomRect + FQ_DETAIL_BOTTOM_INSET)
        .width('100%')
        .height('100%')
        if (this.refreshing) {
          RefreshOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .bindSheet(this.rankSheetVisible, this.RankSheetBuilder(), FqSheetOptions((): void => {
        this.rankSheetVisible = false;
        this.exitRankEditMode();
      }))
    }
  }

  /** 书友卡片（渐变头像）。 */
  @Builder
  private ProfileCard() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.person_fill'))
          .fontSize(26)
          .fontColor([Color.White])
      }
      .width(50)
      .height(50)
      .borderRadius(16)
      .linearGradient({
        angle: 180,
        colors: [[FqColorUtils.tint(appState.accentColor, 0.4), 0], [appState.accentColor, 1]],
      })

      Column({ space: 4 }) {
        Text('书友')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('沉浸阅读，记录每一个好故事')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .padding(15)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }

  /** 快捷入口四宫格（「我的含设置入口」样式）。 */
  @Builder
  private ShortcutsRow() {
    Row({ space: 9 }) {
      this.ShortcutTile($r('sys.symbol.externaldrive'), '#FF3B82F6', '缓存管理', (): void => {
        NavPathUtils.push(ROUTE_CACHE_MANAGE);
      })
      this.ShortcutTile($r('sys.symbol.archivebox'), '#FFEF5038', '备份恢复', (): void => {
        NavPathUtils.push(ROUTE_BACKUP);
      })
      this.ShortcutTile($r('sys.symbol.textformat'), '#FF10B981', '应用设置', (): void => {
        this.openSettingsTab();
      })
      this.ShortcutTile($r('sys.symbol.person_fill'), '#FF8B5CF6', '关于我们', (): void => {
        NavPathUtils.push(ROUTE_ABOUT);
      })
    }
    .width('100%')
  }

  @Builder
  private ShortcutTile(icon: Resource, tint: string, label: string, onTap: () => void) {
    Column({ space: 7 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([tint])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(tint, 0.12))

      Text(label)
        .fontSize(11.5)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
    }
    .padding({ top: 13, bottom: 13 })
    .borderRadius(14)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .layoutWeight(1)
    .onClick((): void => {
      onTap();
    })
  }

  /** 应用设置入口：「我的含设置入口」路由推入设置页；「设置含我的入口」返回设置页；其余经主 Tab 切换。 */
  private openSettingsTab(): void {
    if (appState.mineSettingsStyle === FQ_MINE_STYLE_MINE_WITH_SETTINGS) {
      NavPathUtils.push(ROUTE_SETTINGS);
      return;
    }
    if (appState.mineSettingsStyle === FQ_MINE_STYLE_SETTINGS_WITH_MINE) {
      // 本页由设置页「用户」区推入，返回即回设置页（非 nav 二级路由）
      NavPathUtils.pop();
      return;
    }
    const switchMainTab = appState.switchMainTab;
    if (switchMainTab !== null) {
      switchMainTab(SETTINGS_TAB_INDEX);
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

  /** 选中日期 + 2×2 概览（点击日期弹出日期选择器）。 */
  @Builder
  private DateOverviewCard() {
    Column({ space: 14 }) {
      Column({ space: 4 }) {
        Text(this.selectedText)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text(this.hasStats ? '每日阅读时长持续统计中' : '阅读、听书、看剧都会计入时长统计')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .onClick((): void => {
        this.pickDate();
      })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          this.OverviewCell(fqStatsCompact(this.todayMin), '今日')
          this.OverviewCell(fqStatsCompact(this.monthMin), '本月')
        }
        .width('100%')
        Row({ space: 10 }) {
          this.OverviewCell(fqStatsCompact(this.totalMin), '总计')
          this.OverviewCell(`${this.activeDays} 天`, '活跃天数')
        }
        .width('100%')
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }

  @Builder
  private OverviewCell(value: string, label: string) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(11.5)
        .fontColor($r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 13, right: 13, top: 9, bottom: 9 })
    .borderRadius(12)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .layoutWeight(1)
  }

  /** 16 周热力图（列主序：每列一周，行自周一至周日；周标签 + 16 列等宽铺满卡片）。 */
  @Builder
  private HeatmapContent() {
    Column({ space: 9 }) {
      Row() {
        ForEach(this.heatMonths, (month: string) => {
          Text(month)
            .fontSize(10)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }, (month: string) => month)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      Column({ space: FQ_HEAT_GAP }) {
        ForEach(FQ_HEAT_ROWS, (row: number) => {
          Row({ space: FQ_HEAT_GAP }) {
            Text(FQ_HEAT_WEEKDAYS[row])
              .fontSize(9)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .aspectRatio(1)
            ForEach(FQ_HEAT_COLS, (col: number) => {
              Stack()
                .layoutWeight(1)
                .aspectRatio(1)
                .borderRadius(3)
                .backgroundColor(this.heatColor(this.heatCells[col * 7 + row]))
            }, (col: number) => `heat_col_${col}`)
          }
          .width('100%')
        }, (row: number) => `heat_row_${row}`)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private RecentContent() {
    if (this.recentItems.length === 0) {
      this.EmptyHint('暂无最近阅读')
    } else {
      // Scroll 嵌套下 List 不设高度自适应全部展开（官方 FAQ）；行间分隔用独立 ListItem 承载
      List() {
        ForEach(this.recentItems, (item: FqStatsEntry, index: number) => {
          if (index > 0) {
            ListItem() {
              Divider()
                .color($r('sys.color.comp_divider'))
            }
          }
          ListItem() {
            this.RecentRow(item)
          }
        }, (item: FqStatsEntry) => `recent_${item.id}`)
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
  }

  /** 最近阅读标题行操作区：常态「编辑」；编辑态「全选 / 删除 / 完成」。 */
  @Builder
  private RecentEditControls() {
    if (this.recentEditMode) {
      Row({ space: 14 }) {
        Text('全选')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.allRecentSelected() ? appState.accentColor : $r('sys.color.font_secondary'))
          .onClick((): void => {
            this.toggleRecentSelectAll();
          })
        Text('删除')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(FQ_DANGER_TEXT)
          .onClick((): void => {
            this.confirmDeleteRecent();
          })
        Text('完成')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(appState.accentColor)
          .onClick((): void => {
            this.exitRecentEditMode();
          })
      }
    } else {
      Text('编辑')
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(appState.accentColor)
        .onClick((): void => {
          this.enterRecentEditMode();
        })
    }
  }

  /** 最近阅读单行：编辑模式行首勾选圈，点击切换选中而非打开。 */
  @Builder
  private RecentRow(item: FqStatsEntry) {
    Row({ space: 10 }) {
      if (this.recentEditMode) {
        SymbolGlyph(this.isRecentSelected(item.id)
          ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([this.isRecentSelected(item.id)
            ? appState.accentColor : $r('sys.color.icon_tertiary')])
      }
      this.EntryCover(item, 40, 54, (entry: FqStatsEntry): void => {
        this.handleRecentTap(entry);
      })
      Column({ space: 4 }) {
        Text(item.title.length > 0 ? item.title : item.id)
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`最近打开 · ${fqStatsVisitedText(item.visitedAt)}`)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(item.minutes > 0 ? fqStatsDuring(item.minutes) : '——')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .padding({ top: 9, bottom: 9 })
    .width('100%')
    .onClick((): void => {
      this.handleRecentTap(item);
    })
  }

  /** 最近阅读行/封面统一点击：编辑模式切换选中，否则打开条目。 */
  private handleRecentTap(entry: FqStatsEntry): void {
    if (this.recentEditMode) {
      this.toggleRecentSelected(entry.id);
      return;
    }
    this.openEntry(entry);
  }

  /** 排行行/封面统一点击：编辑模式切换选中，否则打开条目。 */
  private handleRankTap(entry: FqStatsEntry): void {
    if (this.rankEditMode) {
      this.toggleRankSelected(entry.id);
      return;
    }
    this.openEntry(entry);
  }

  private isRecentSelected(id: string): boolean {
    return this.recentSelectedIds.indexOf(id) !== -1;
  }

  private toggleRecentSelected(id: string): void {
    const next: string[] = this.recentSelectedIds.slice();
    const index: number = next.indexOf(id);
    if (index === -1) {
      next.push(id);
    } else {
      next.splice(index, 1);
    }
    this.recentSelectedIds = next;
  }

  private allRecentSelected(): boolean {
    return this.recentItems.length > 0 && this.recentSelectedIds.length === this.recentItems.length;
  }

  private toggleRecentSelectAll(): void {
    if (this.allRecentSelected()) {
      this.recentSelectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.recentItems) {
      ids.push(item.id);
    }
    this.recentSelectedIds = ids;
  }

  private enterRecentEditMode(): void {
    this.recentEditMode = true;
    this.recentSelectedIds = [];
  }

  private exitRecentEditMode(): void {
    this.recentEditMode = false;
    this.recentSelectedIds = [];
  }

  /** 最近阅读编辑模式批量删除确认：清浏览记录 + 按书时长（书架与阅读进度不受影响）。 */
  private confirmDeleteRecent(): void {
    if (this.recentSelectedIds.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    const ids: string[] = this.recentSelectedIds.slice();
    DialogManager.ShowConfirm('删除最近阅读',
      `确定删除选中的 ${ids.length} 条记录吗？将从最近阅读与阅读排行中移除，书架与阅读进度不受影响。`,
      '删除',
      (): void => {
        FqBrowseStore.removeByIds(ids);
        FqReadStatsStore.removeBooks(ids);
        this.recentSelectedIds = [];
        this.rebuild();
        this.showToast(`已删除 ${ids.length} 条`);
      });
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }

  @Builder
  private DailyContent() {
    if (!this.hasStats) {
      this.EmptyHint('暂无每日统计')
    } else {
      Column() {
        ForEach(this.dailyRows, (row: FqDailyRow, index: number) => {
          if (index > 0) {
            Divider()
              .color($r('sys.color.comp_divider'))
          }
          Row({ space: 10 }) {
            Text(row.dayText)
              .fontSize(13)
              .fontWeight(row.minutes > 0 ? FontWeight.Medium : FontWeight.Normal)
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Text(row.subtitle)
              .fontSize(11.5)
              .fontColor($r('sys.color.font_secondary'))
            Text(row.minutes > 0 ? fqStatsCompact(row.minutes) : '——')
              .fontSize(12.5)
              .fontColor(row.minutes > 0 ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          }
          .padding({ top: 8.5, bottom: 8.5 })
          .width('100%')
        }, (row: FqDailyRow) => `daily_${row.dayText}`)
      }
      .width('100%')
    }
  }

  @Builder
  private CoversContent() {
    if (this.coverItems.length === 0) {
      this.EmptyHint('暂无最近封面')
    } else {
      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.coverItems, (item: FqStatsEntry) => {
            this.EntryCover(item, 74, 104, (entry: FqStatsEntry): void => {
              this.openEntry(entry);
            })
          }, (item: FqStatsEntry) => `cover_${item.id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
  }

  /** 阅读排行卡片：Top5 + 查看全部（半模态）。 */
  @Builder
  private RankContent() {
    if (this.rankItems.length === 0) {
      this.EmptyHint('暂无排行数据')
    } else {
      Column() {
        ForEach(this.rankItems.slice(0, FQ_RANK_LIMIT), (item: FqStatsEntry, index: number) => {
          if (index > 0) {
            Divider()
              .padding({ left: 30 })
              .color($r('sys.color.comp_divider'))
          }
          this.RankRow(item, index)
        }, (item: FqStatsEntry) => `rank_card_${item.id}`)

        Row({ space: 4 }) {
          Text('查看全部')
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(appState.accentColor)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(11)
            .fontColor([appState.accentColor])
        }
        .padding({ top: 10 })
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.rankSheetVisible = true;
        })
      }
      .width('100%')
    }
  }

  @Builder
  private RankRow(item: FqStatsEntry, index: number) {
    Row({ space: 10 }) {
      if (this.rankEditMode) {
        SymbolGlyph(this.isRankSelected(item.id)
          ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([this.isRankSelected(item.id)
            ? appState.accentColor : $r('sys.color.icon_tertiary')])
      }
      Text(`${index + 1}`)
        .fontSize(index < 3 ? 15 : 13)
        .fontWeight(FontWeight.Bold)
        .fontColor(index < 3 ? appState.accentColor : $r('sys.color.font_secondary'))
        .width(20)
        .textAlign(TextAlign.Center)
      this.EntryCover(item, 32, 44, (entry: FqStatsEntry): void => {
        this.handleRankTap(entry);
      })
      Text(item.title.length > 0 ? item.title : item.id)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(fqStatsCompact(item.minutes))
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .padding({ top: 8, bottom: 8 })
    .width('100%')
    .onClick((): void => {
      this.handleRankTap(item);
    })
  }

  /** 阅读排行「查看全部」半模态：右上角编辑（进入/退出编辑模式），编辑模式显示全选 + 删除。 */
  @Builder
  private RankSheetBuilder() {
    CommonSheet({
      sheetTitle: '阅读排行',
      showEdit: true,
      editActive: this.rankEditMode,
      editClick: (): void => {
        this.toggleRankEditMode();
      },
      showSelectAll: this.rankEditMode,
      selectAllActive: this.allRankSelected(),
      selectAllClick: (): void => {
        this.toggleRankSelectAll();
      },
      showRemove: this.rankEditMode,
      removeClick: (): void => {
        this.confirmDeleteRanked();
      },
      closeClick: (): void => {
        this.closeRankSheet();
      },
    }) {
      if (this.rankItems.length === 0) {
        this.EmptyHint('暂无排行数据')
      } else {
        List() {
          ForEach(this.rankItems, (item: FqStatsEntry, index: number) => {
            ListItem() {
              this.RankRow(item, index)
            }
          }, (item: FqStatsEntry) => `rank_sheet_${item.id}`)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .scrollBar(BarState.Off)
      }
    }
  }

  private isRankSelected(id: string): boolean {
    return this.rankSelectedIds.indexOf(id) !== -1;
  }

  private toggleRankSelected(id: string): void {
    const next: string[] = this.rankSelectedIds.slice();
    const index: number = next.indexOf(id);
    if (index === -1) {
      next.push(id);
    } else {
      next.splice(index, 1);
    }
    this.rankSelectedIds = next;
  }

  private allRankSelected(): boolean {
    return this.rankItems.length > 0 && this.rankSelectedIds.length === this.rankItems.length;
  }

  private toggleRankSelectAll(): void {
    if (this.allRankSelected()) {
      this.rankSelectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.rankItems) {
      ids.push(item.id);
    }
    this.rankSelectedIds = ids;
  }

  private toggleRankEditMode(): void {
    this.rankEditMode = !this.rankEditMode;
    this.rankSelectedIds = [];
  }

  private exitRankEditMode(): void {
    this.rankEditMode = false;
    this.rankSelectedIds = [];
  }

  private closeRankSheet(): void {
    this.rankSheetVisible = false;
    this.exitRankEditMode();
  }

  /** 阅读排行编辑模式批量删除确认：清选中条目的按书时长（全局日累计保留）。 */
  private confirmDeleteRanked(): void {
    if (this.rankSelectedIds.length === 0) {
      this.showToast('请先选择条目');
      return;
    }
    const ids: string[] = this.rankSelectedIds.slice();
    DialogManager.ShowConfirm('删除阅读排行',
      `确定删除选中的 ${ids.length} 条记录吗？对应作品的阅读时长统计将被清除。`, '删除',
      (): void => {
        FqReadStatsStore.removeBooks(ids);
        this.rankSelectedIds = [];
        this.rebuild();
        this.showToast(`已删除 ${ids.length} 条`);
      });
  }

  /** 条目封面（无封面显示书籍图标占位）；点击行为由调用方决定（编辑模式下切换选中）。 */
  @Builder
  private EntryCover(item: FqStatsEntry, widthVp: number, heightVp: number,
    onTap: (entry: FqStatsEntry) => void) {
    if (item.cover.length > 0) {
      Image(FqBackend.get().resourceUrl(item.cover))
        .width(widthVp)
        .height(heightVp)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .draggable(false)
        .onClick((): void => {
          onTap(item);
        })
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(15)
          .fontColor([$r('sys.color.font_secondary')])
      }
      .width(widthVp)
      .height(heightVp)
      .borderRadius(8)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick((): void => {
        onTap(item);
      })
    }
  }

  @Builder
  private EmptyHint(text: string) {
    Text(text)
      .fontSize(12.5)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 18, bottom: 18 })
  }
}

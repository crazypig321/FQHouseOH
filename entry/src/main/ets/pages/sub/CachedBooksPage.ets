/**
 * 章节缓存页（我的-章节缓存入口，对齐 fqapp cached_books_page）：
 * 统计卡（N 本 · M 章 · 占用 + 清空）+ 书卡列表（LazyForEach）；
 * 点击书卡离线续读（目录/正文命中章节缓存）；行尾 trash 删单本（确认）；
 * 阅读时自动缓存 + 详情页「下载」整本缓存是数据来源；空态引导文案。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { ROUTE_READER2, ReaderNavParams } from '../../model/FqNavModels';
import { FqCacheEmptyView, FqCacheStatsCard, fqFormatCacheBytes } from '../../view/FqCacheCommon';
import { FqChapterCacheStore, FqCachedBookSummary } from '../../core/FqChapterCacheStore';
import { fqStoreBus, FqStoreBus } from '../../core/FqStoreBus';
import { DialogManager } from '../../utils/DialogUtils';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_CACHE_TOP_INSET: number = 56;
/** 行图标块配色轮换（对齐项目统计页配色）。 */
const FQ_BOOK_TINTS: string[] = ['#FF3B82F6', '#FFEF5038', '#FF10B981', '#FF8B5CF6', '#FF0EA5E9', '#FFF43F5E'];
/** 危险操作（清空/删除）文字色。 */
const FQ_DANGER_TINT: string = '#FFF43F5E';

/** 书行展示模型（缓存摘要 + 轮换配色）。 */
class CachedBookRow {
  public readonly summary: FqCachedBookSummary;
  public readonly tint: string;

  constructor(summary: FqCachedBookSummary, tint: string) {
    this.summary = summary;
    this.tint = tint;
  }
}

/** 懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class CachedBookDataSource implements IDataSource {
  private rows: CachedBookRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): CachedBookRow {
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

  reload(rows: CachedBookRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct CachedBooksPage {
  private scroller: Scroller = new Scroller();
  private dataSource: CachedBookDataSource = new CachedBookDataSource();
  /** store 版本总线（阅读自动缓存/整本下载/删除实时刷新列表）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  @Local bookCount: number = 0;
  @Local chapterCount: number = 0;
  @Local totalBytes: number = 0;

  @Monitor('storeBus.chapterCacheVersion')
  onCacheDataChange(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** 重聚合缓存书列表与统计数字。 */
  private refresh(): void {
    const summaries: FqCachedBookSummary[] = FqChapterCacheStore.books();
    const rows: CachedBookRow[] = [];
    let chapters: number = 0;
    let bytes: number = 0;
    for (let i = 0; i < summaries.length; i++) {
      const summary: FqCachedBookSummary = summaries[i];
      rows.push(new CachedBookRow(summary, FQ_BOOK_TINTS[i % FQ_BOOK_TINTS.length]));
      chapters += summary.chapterCount;
      bytes += summary.byteCount;
    }
    this.bookCount = rows.length;
    this.chapterCount = chapters;
    this.totalBytes = bytes;
    this.dataSource.reload(rows);
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('章节缓存', false),
      scroller: this.scroller,
    }) {
      if (this.bookCount === 0) {
        FqCacheEmptyView({
          icon: $r('sys.symbol.download'),
          tint: '#FF3B82F6',
          title: '暂无缓存章节',
          subtitle: '阅读小说后会自动保存，详情页“下载”会保存整本；下载的章节不会被自动清理。',
        })
      } else {
        List({ space: 10, scroller: this.scroller }) {
          ListItem() {
            FqCacheStatsCard({
              icon: $r('sys.symbol.book'),
              tint: '#FF3B82F6',
              title: `已缓存 ${this.bookCount} 本 · 共 ${this.chapterCount} 章`,
              subtitle: `占用空间：${fqFormatCacheBytes(this.totalBytes)} · 点击可离线续读`,
            }) {
              Text('清空')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(FQ_DANGER_TINT)
                .padding({ left: 10, top: 6, bottom: 6 })
                .onClick((): void => {
                  this.confirmClearAll();
                })
            }
          }

          LazyForEach(this.dataSource, (row: CachedBookRow) => {
            ListItem() {
              this.BookRow(row)
            }
          }, (row: CachedBookRow) => `${row.summary.bookId}-${row.summary.chapterCount}`)
        }
        .padding({ left: 16, right: 16 })
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentStartOffset(appState.topRect + FQ_CACHE_TOP_INSET)
        .contentEndOffset(appState.bottomRect + 16)
      }
    }
  }

  /** 单本缓存书行：图标块 + 书名 + 章数/大小 + trash 删除。 */
  @Builder
  private BookRow(row: CachedBookRow) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(19)
          .fontColor([row.tint])
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(row.tint, 0.12))

      Column({ space: 3 }) {
        Text(row.summary.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`已缓存 ${row.summary.chapterCount} 章 · ${fqFormatCacheBytes(row.summary.byteCount)}`)
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_tertiary')])
        .padding({ left: 4, top: 8, bottom: 8 })
        .onClick((): void => {
          this.confirmRemove(row);
        })
    }
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
    .onClick((): void => {
      this.openBook(row);
    })
  }

  /** 点击离线续读：阅读页目录/正文优先命中章节缓存。 */
  private openBook(row: CachedBookRow): void {
    ReaderNavParams.id = row.summary.bookId;
    ReaderNavParams.kind = row.summary.kind.length > 0 ? row.summary.kind : 'book';
    ReaderNavParams.title = row.summary.title;
    ReaderNavParams.chapterIndex = -1;
    ReaderNavParams.listenAlong = false;
    NavPathUtils.push(ROUTE_READER2);
  }

  /** 删单本确认（对齐 fqapp 文案）。 */
  private confirmRemove(row: CachedBookRow): void {
    DialogManager.ShowConfirm('删除这本书的缓存', '只清理缓存正文与目录，阅读历史和排版设置会保留。', '删除',
      (): void => {
        FqChapterCacheStore.removeBook(row.summary.bookId);
      });
  }

  /** 清空全部确认（对齐 fqapp 文案）。 */
  private confirmClearAll(): void {
    DialogManager.ShowConfirm('清空全部章节缓存', '只清理缓存正文与目录，阅读历史和排版设置会保留。', '清空',
      (): void => {
        FqChapterCacheStore.clearAll();
      });
  }
}

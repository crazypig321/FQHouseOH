/**
 * 漫画缓存页（设置-漫画缓存入口，对齐 CachedAudioPage 结构）：
 * 统计卡（N 本 · M 话 · K 图 · 占用 + 暂停全部/继续全部/清空）+ 书卡手风琴
 * （LazyForEach：头行 + 话明细 + 任务行）；任务行绑定 @ObservedV2 下载任务
 * 实时进度（按图计数 x/y 张，排队/下载/暂停/失败 + 重试）；单话/整本删除
 * 走确认；未入库任务按书分组为临时卡；空态引导文案。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqCacheEmptyView, FqCacheStatsCard, fqFormatCacheBytes } from '../../view/FqCacheCommon';
import {
  FqComicCacheStore,
  FqCachedComicBookSummary,
  FqCachedComicChapter,
} from '../../core/FqComicCacheStore';
import {
  fqComicDownloader,
  FqComicDownloader,
  FqComicDownloadTask,
  ComicDownloadStatus,
} from '../../core/FqComicDownloader';
import { fqStoreBus, FqStoreBus } from '../../core/FqStoreBus';
import { DialogManager } from '../../utils/DialogUtils';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';

const FQ_CACHE_TOP_INSET: number = 56;
/** 书卡图标块配色轮换（对齐项目统计页配色）。 */
const FQ_COMIC_TINTS: string[] = ['#FF0EA5E9', '#FF8B5CF6', '#FF10B981', '#FFEF5038', '#FF3B82F6', '#FFF43F5E'];
const FQ_COMIC_TINT: string = '#FF0EA5E9';
const FQ_DANGER_TINT: string = '#FFF43F5E';

/** 列表行种类。 */
const FQ_ROW_HEADER: number = 0;
const FQ_ROW_CHAPTER: number = 1;
const FQ_ROW_TASKS: number = 2;

/** 手风琴扁平行（LazyForEach 数据源条目）。 */
class FqComicRow {
  public readonly kind: number;
  public readonly book: FqCachedComicBookSummary;
  /** 话行条目（kind=CHAPTER 时非空）。 */
  public readonly chapter: FqCachedComicChapter | null;
  public readonly tint: string;

  constructor(kind: number, book: FqCachedComicBookSummary,
    chapter: FqCachedComicChapter | null, tint: string) {
    this.kind = kind;
    this.book = book;
    this.chapter = chapter;
    this.tint = tint;
  }
}

/** 懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class CachedComicDataSource implements IDataSource {
  private rows: FqComicRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): FqComicRow {
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

  reload(rows: FqComicRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct CachedComicsPage {
  private scroller: Scroller = new Scroller();
  private dataSource: CachedComicDataSource = new CachedComicDataSource();
  /** store 版本总线（完成入库/删除实时刷新）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 下载器单例（@Trace taskList 驱动任务行动态增删与实时进度）。 */
  @Local dl: FqComicDownloader = fqComicDownloader;
  /** 收起的书 id（默认全部展开）。 */
  @Local collapsedIds: string[] = [];
  @Local bookCount: number = 0;
  @Local chapterCount: number = 0;
  @Local imageCount: number = 0;
  @Local totalBytes: number = 0;
  @Local hasRunningTasks: boolean = false;
  @Local hasPausedTasks: boolean = false;
  @Local hasContent: boolean = false;

  @Monitor('storeBus.comicCacheVersion')
  onCacheDataChange(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** 重聚合书卡（含未入库任务临时组）与统计数字。 */
  private refresh(): void {
    const books: FqCachedComicBookSummary[] = FqComicCacheStore.books();
    const knownBooks: Set<string> = new Set<string>();
    const rows: FqComicRow[] = [];
    let chapters: number = 0;
    let images: number = 0;
    let bytes: number = 0;
    let tintIndex: number = 0;
    for (const book of books) {
      knownBooks.add(book.bookId);
      chapters += book.chapterCount;
      images += book.imageCount;
      bytes += book.byteCount;
      const tint: string = FQ_COMIC_TINTS[tintIndex % FQ_COMIC_TINTS.length];
      tintIndex++;
      rows.push(new FqComicRow(FQ_ROW_HEADER, book, null, tint));
      if (this.isExpanded(book.bookId)) {
        const cachedChapters: FqCachedComicChapter[] = FqComicCacheStore.chaptersOf(book.bookId);
        for (const chapter of cachedChapters) {
          rows.push(new FqComicRow(FQ_ROW_CHAPTER, book, chapter, tint));
        }
        rows.push(new FqComicRow(FQ_ROW_TASKS, book, null, tint));
      }
    }
    // 未入库任务临时组（正在下载/暂停/失败的书，完成后自动并入正式书卡）
    const taskBookIds: string[] = [];
    for (const task of this.dl.taskList) {
      if (task.status !== ComicDownloadStatus.Completed && !knownBooks.has(task.bookId)
        && taskBookIds.indexOf(task.bookId) === -1) {
        taskBookIds.push(task.bookId);
      }
    }
    let hasRunning: boolean = false;
    let hasPaused: boolean = false;
    for (const task of this.dl.taskList) {
      if (task.status === ComicDownloadStatus.Downloading
        || task.status === ComicDownloadStatus.Waiting) {
        hasRunning = true;
      }
      if (task.status === ComicDownloadStatus.Paused) {
        hasPaused = true;
      }
    }
    for (const bookId of taskBookIds) {
      const firstTask: FqComicDownloadTask | null = this.firstTaskOf(bookId);
      if (firstTask === null) {
        continue;
      }
      const pseudo: FqCachedComicBookSummary = new FqCachedComicBookSummary(bookId,
        firstTask.bookTitle.length > 0 ? firstTask.bookTitle : bookId, 0, 0, 0);
      const tint: string = FQ_COMIC_TINTS[tintIndex % FQ_COMIC_TINTS.length];
      tintIndex++;
      rows.push(new FqComicRow(FQ_ROW_HEADER, pseudo, null, tint));
      if (this.isExpanded(bookId)) {
        rows.push(new FqComicRow(FQ_ROW_TASKS, pseudo, null, tint));
      }
    }
    this.bookCount = books.length;
    this.chapterCount = chapters;
    this.imageCount = images;
    this.totalBytes = bytes;
    this.hasRunningTasks = hasRunning;
    this.hasPausedTasks = hasPaused;
    this.hasContent = books.length > 0 || this.dl.taskList.length > 0;
    this.dataSource.reload(rows);
  }

  private firstTaskOf(bookId: string): FqComicDownloadTask | null {
    for (const task of this.dl.taskList) {
      if (task.bookId === bookId) {
        return task;
      }
    }
    return null;
  }

  /** 该书未入库任务（含暂停/失败；完成即入 store 不在此列）。 */
  private tasksOf(bookId: string): FqComicDownloadTask[] {
    const result: FqComicDownloadTask[] = [];
    for (const task of this.dl.taskList) {
      if (task.bookId === bookId && task.status !== ComicDownloadStatus.Completed) {
        result.push(task);
      }
    }
    return result;
  }

  private isExpanded(bookId: string): boolean {
    return this.collapsedIds.indexOf(bookId) === -1;
  }

  private toggleExpanded(bookId: string): void {
    const index: number = this.collapsedIds.indexOf(bookId);
    if (index >= 0) {
      this.collapsedIds.splice(index, 1);
    } else {
      this.collapsedIds.push(bookId);
    }
    this.refresh();
  }

  /** 任务状态文案。 */
  private taskStatusText(task: FqComicDownloadTask): string {
    if (task.status === ComicDownloadStatus.Waiting) {
      return '排队中';
    }
    if (task.status === ComicDownloadStatus.Downloading) {
      return '下载中';
    }
    if (task.status === ComicDownloadStatus.Paused) {
      return '已暂停';
    }
    if (task.status === ComicDownloadStatus.Failed) {
      return task.errorText.length > 0 ? task.errorText : '失败';
    }
    return '已完成';
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('漫画缓存', false),
      scroller: this.scroller,
    }) {
      if (!this.hasContent) {
        FqCacheEmptyView({
          icon: $r('sys.symbol.picture'),
          tint: FQ_COMIC_TINT,
          title: '暂无离线缓存',
          subtitle: '漫画页标题栏“下载”选择想缓存的话；下载的内容不会被自动清理。',
        })
      } else {
        List({ space: 10, scroller: this.scroller }) {
          ListItem() {
            FqCacheStatsCard({
              icon: $r('sys.symbol.picture'),
              tint: FQ_COMIC_TINT,
              title: `已缓存 ${this.bookCount} 本 · 共 ${this.chapterCount} 话 · ${this.imageCount} 图`,
              subtitle: `占用空间：${fqFormatCacheBytes(this.totalBytes)}`,
            }) {
              Row({ space: 14 }) {
                if (this.hasRunningTasks) {
                  Text('暂停全部')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_secondary'))
                    .onClick((): void => {
                      this.dl.pauseAll();
                      this.refresh();
                    })
                }
                if (this.hasPausedTasks) {
                  Text('继续全部')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_secondary'))
                    .onClick((): void => {
                      this.dl.resumeAll();
                      this.refresh();
                    })
                }
                Text('清空')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(FQ_DANGER_TINT)
                  .onClick((): void => {
                    this.confirmClearAll();
                  })
              }
            }
          }

          LazyForEach(this.dataSource, (row: FqComicRow) => {
            ListItem() {
              if (row.kind === FQ_ROW_HEADER) {
                this.BookHeader(row)
              } else if (row.kind === FQ_ROW_CHAPTER) {
                this.ChapterRow(row)
              } else {
                this.TaskRows(row.book.bookId)
              }
            }
          }, (row: FqComicRow) => `${row.kind}-${row.book.bookId}-${row.chapter !== null ? row.chapter.key : ''}`)
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

  /** 书卡头行：图标块 + 书名 + 话数/图数/大小 + 删除整本 + 展开箭头。 */
  @Builder
  private BookHeader(row: FqComicRow) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.picture'))
          .fontSize(19)
          .fontColor([row.tint])
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(row.tint, 0.12))

      Column({ space: 3 }) {
        Text(row.book.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.book.chapterCount > 0
          ? `${row.book.chapterCount} 话 · ${row.book.imageCount} 图 · ${fqFormatCacheBytes(row.book.byteCount)}`
          : '缓存中')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_tertiary')])
        .padding({ left: 4, top: 8, bottom: 8 })
        .onClick((): void => {
          this.confirmRemoveBook(row.book);
        })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
        .rotate({ angle: this.isExpanded(row.book.bookId) ? 90 : 0 })
    }
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
    .onClick((): void => {
      this.toggleExpanded(row.book.bookId);
    })
  }

  /** 单话行：第 i 话 · 标题 + 图数/大小 + 单话删除。 */
  @Builder
  private ChapterRow(row: FqComicRow) {
    if (row.chapter !== null) {
      Row({ space: 10 }) {
        Text(`第 ${row.chapter.index} 话`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (row.chapter.title.length > 0) {
          Text(row.chapter.title)
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        Text(`${row.chapter.imageCount} 图 · ${fqFormatCacheBytes(row.chapter.bytes)}`)
          .fontSize(11.5)
          .fontColor($r('sys.color.font_tertiary'))
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
          .padding({ left: 4, top: 8, bottom: 8 })
          .onClick((): void => {
            this.confirmRemoveChapter(row.chapter);
          })
      }
      .padding({ left: 16, right: 14, top: 9, bottom: 9 })
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .width('100%')
    }
  }

  /** 任务行组（ForEach 绑定 @Trace taskList：进度实时、增删动态）。 */
  @Builder
  private TaskRows(bookId: string) {
    Column({ space: 8 }) {
      ForEach(this.tasksOf(bookId), (task: FqComicDownloadTask) => {
        this.TaskRow(task)
      }, (task: FqComicDownloadTask) => `${task.key}-${task.status}`)
    }
    .width('100%')
  }

  /** 单任务行：标题 + 进度条 + 状态 + 暂停/继续/重试/移除。 */
  @Builder
  private TaskRow(task: FqComicDownloadTask) {
    Column({ space: 7 }) {
      Row({ space: 10 }) {
        Text(`第 ${task.index} 话`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (task.title.length > 0) {
          Text(task.title)
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        this.TaskActionIcon(task)
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
          .padding({ left: 4, top: 4, bottom: 4 })
          .onClick((): void => {
            this.dl.removeTask(task.key);
            this.refresh();
          })
      }
      .width('100%')

      Progress({ value: task.receivedBytes, total: task.totalBytes > 0 ? task.totalBytes : 1 })
        .style({ strokeWidth: 4 })
        .color(task.status === ComicDownloadStatus.Failed ? FQ_DANGER_TINT : FQ_COMIC_TINT)
        .width('100%')

      Row({ space: 6 }) {
        Text(this.taskStatusText(task))
          .fontSize(11)
          .fontColor(task.status === ComicDownloadStatus.Failed
            ? FQ_DANGER_TINT : $r('sys.color.font_tertiary'))
        Text(task.totalBytes > 0
          ? `${task.receivedBytes}/${task.totalBytes} 张`
          : `${task.receivedBytes} 张`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .layoutWeight(1)
      }
      .width('100%')
    }
    .padding({ left: 16, right: 14, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .width('100%')
  }

  /** 状态相关操作图标：下载中/排队→暂停；暂停→继续；失败→重试。 */
  @Builder
  private TaskActionIcon(task: FqComicDownloadTask) {
    if (task.status === ComicDownloadStatus.Downloading || task.status === ComicDownloadStatus.Waiting) {
      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.pause(task.key);
          this.refresh();
        })
    } else if (task.status === ComicDownloadStatus.Paused) {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.resume(task.key);
          this.refresh();
        })
    } else if (task.status === ComicDownloadStatus.Failed) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.retry(task.key);
          this.refresh();
        })
    }
  }

  /** 删单话确认。 */
  private confirmRemoveChapter(chapter: FqCachedComicChapter | null): void {
    if (chapter === null) {
      return;
    }
    DialogManager.ShowConfirm('删除这一话', '联网后可重新缓存。', '删除',
      (): void => {
        FqComicCacheStore.removeChapter(chapter.key);
      });
  }

  /** 删整本确认。 */
  private confirmRemoveBook(book: FqCachedComicBookSummary): void {
    DialogManager.ShowConfirm(`删除《${book.title}》的缓存`,
      `已下载的 ${book.chapterCount} 话会从设备删除，联网后可重新缓存。`, '删除',
      (): void => {
        this.dl.removeTasksOf(book.bookId);
        FqComicCacheStore.removeBook(book.bookId);
      });
  }

  /** 清空全部确认。 */
  private confirmClearAll(): void {
    DialogManager.ShowConfirm('清空全部离线缓存',
      '所有已下载的漫画会从设备删除，联网后可重新缓存。', '清空',
      (): void => {
        this.dl.pauseAll();
        for (const task of this.dl.taskList) {
          this.dl.removeTask(task.key);
        }
        FqComicCacheStore.clearAll();
      });
  }
}

/**
 * 漫画缓存页（设置-漫画缓存入口）：
 * 统计数字聚合 + 公共手风琴 FqCacheAccordionList（书卡头行/话明细行/任务行
 * 由组件渲染，本页只提供分组数据与任务行 @Builder）；任务行绑定 @ObservedV2
 * 下载任务实时进度（按图计数 x/y 张，排队/下载/暂停/失败 + 重试）；单话/整本/
 * 清空删除确认与 store 操作留在本页；未入库任务按书分组为临时卡；空态引导文案。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqCacheEmptyView, FqCacheStatsCard, fqFormatCacheBytes } from '../../view/FqCacheCommon';
import {
  FqCacheAccordionList,
  FqCacheGroupItem,
  FqCacheDetailItem,
} from '../../view/FqCacheAccordion';
import {
  FqComicCacheStore,
  FqCachedComicBookSummary,
} from '../../core/FqComicCacheStore';
import {
  fqComicDownloader,
  FqComicDownloader,
  FqComicDownloadTask,
  ComicDownloadStatus,
} from '../../core/FqComicDownloader';
import { fqStoreBus, FqStoreBus } from '../../core/FqStoreBus';
import { DialogManager } from '../../utils/DialogUtils';

/** 书卡图标块配色轮换（对齐项目统计页配色）。 */
const FQ_COMIC_TINTS: string[] = ['#FF0EA5E9', '#FF8B5CF6', '#FF10B981', '#FFEF5038', '#FF3B82F6', '#FFF43F5E'];
const FQ_COMIC_TINT: string = '#FF0EA5E9';
const FQ_DANGER_TINT: string = '#FFF43F5E';

@ComponentV2
export struct CachedComicsPage {
  private scroller: Scroller = new Scroller();
  /** store 版本总线（完成入库/删除实时刷新）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 下载器单例（@Trace taskList 驱动任务行动态增删与实时进度）。 */
  @Local dl: FqComicDownloader = fqComicDownloader;
  /** 手风琴分组数据（refresh 重建，组件监听引用变化重排）。 */
  @Local groups: FqCacheGroupItem[] = [];
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

  /** 重聚合书分组（含未入库任务临时组）与统计数字。 */
  private refresh(): void {
    const books: FqCachedComicBookSummary[] = FqComicCacheStore.books();
    const knownBooks: Set<string> = new Set<string>();
    const groups: FqCacheGroupItem[] = [];
    let chapters: number = 0;
    let images: number = 0;
    let bytes: number = 0;
    let tintIndex: number = 0;
    for (const book of books) {
      knownBooks.add(book.bookId);
      chapters += book.chapterCount;
      images += book.imageCount;
      bytes += book.byteCount;
      const details: FqCacheDetailItem[] = [];
      for (const chapter of FqComicCacheStore.chaptersOf(book.bookId)) {
        details.push(new FqCacheDetailItem(chapter.key, `第 ${chapter.index} 话`,
          chapter.title, `${chapter.imageCount} 图 · ${fqFormatCacheBytes(chapter.bytes)}`));
      }
      groups.push(new FqCacheGroupItem(book.bookId, book.title,
        `${book.chapterCount} 话 · ${book.imageCount} 图 · ${fqFormatCacheBytes(book.byteCount)}`,
        FQ_COMIC_TINTS[tintIndex % FQ_COMIC_TINTS.length], true, details));
      tintIndex++;
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
      groups.push(new FqCacheGroupItem(bookId,
        firstTask.bookTitle.length > 0 ? firstTask.bookTitle : bookId,
        '缓存中', FQ_COMIC_TINTS[tintIndex % FQ_COMIC_TINTS.length], true, []));
      tintIndex++;
    }
    this.bookCount = books.length;
    this.chapterCount = chapters;
    this.imageCount = images;
    this.totalBytes = bytes;
    this.hasRunningTasks = hasRunning;
    this.hasPausedTasks = hasPaused;
    this.hasContent = books.length > 0 || this.dl.taskList.length > 0;
    this.groups = groups;
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
        FqCacheAccordionList({
          groups: this.groups,
          icon: $r('sys.symbol.picture'),
          scroller: this.scroller,
          statsBuilder: (): void => {
            this.StatsCard()
          },
          taskRowsOf: (bookId: string): void => {
            this.TaskRows(bookId)
          },
          groupDeleteClick: (group: FqCacheGroupItem): void => {
            this.confirmRemoveBook(group);
          },
          detailDeleteClick: (detail: FqCacheDetailItem): void => {
            this.confirmRemoveChapter(detail);
          },
        })
      }
    }
  }

  /** 统计卡：N 本 · M 话 · K 图 · 占用 + 暂停全部/继续全部/清空。 */
  @Builder
  private StatsCard() {
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

  /** 删单话确认（detail.id = 话复合键）。 */
  private confirmRemoveChapter(detail: FqCacheDetailItem): void {
    DialogManager.ShowConfirm('删除这一话', '联网后可重新缓存。', '删除',
      (): void => {
        FqComicCacheStore.removeChapter(detail.id);
      });
  }

  /** 删整本确认（统计数字回查 store，未入库临时组直接清任务）。 */
  private confirmRemoveBook(group: FqCacheGroupItem): void {
    let chapterCount: number = 0;
    for (const book of FqComicCacheStore.books()) {
      if (book.bookId === group.id) {
        chapterCount = book.chapterCount;
        break;
      }
    }
    DialogManager.ShowConfirm(`删除《${group.title}》的缓存`,
      `已下载的 ${chapterCount} 话会从设备删除，联网后可重新缓存。`, '删除',
      (): void => {
        this.dl.removeTasksOf(group.id);
        FqComicCacheStore.removeBook(group.id);
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

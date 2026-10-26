/**
 * 剧集缓存页（我的-剧集缓存入口，对齐 fqapp cached_dramas_page）：
 * 统计数字聚合 + 公共手风琴 FqCacheAccordionList（剧卡头行/集明细行/任务行
 * 由组件渲染，本页只提供分组数据、任务行 @Builder 与集行尾随“导出”按钮）；
 * 任务行绑定 @ObservedV2 下载任务实时进度；单集导出/单集删除/整剧删除/清空
 * 走确认；未入库任务按剧分组为临时卡；空态引导文案。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqCacheEmptyView, FqCacheStatsCard, fqFormatCacheBytes } from '../../view/FqCacheCommon';
import {
  FqCacheAccordionList,
  FqCacheGroupItem,
  FqCacheDetailItem,
} from '../../view/FqCacheAccordion';
import { FqDramaCacheStore, FqCachedDramaSummary, FqCachedEpisode } from '../../core/FqDramaCacheStore';
import { fqExportCachedEpisode } from '../../core/FqCacheExport';
import { fqDramaDownloader, FqDramaDownloader, FqDramaDownloadTask, DramaDownloadStatus } from '../../core/FqDramaDownloader';
import { fqStoreBus, FqStoreBus } from '../../core/FqStoreBus';
import { DialogManager } from '../../utils/DialogUtils';

/** 剧卡图标块配色轮换（对齐项目统计页配色）。 */
const FQ_DRAMA_TINTS: string[] = ['#FFEF5038', '#FF8B5CF6', '#FF3B82F6', '#FF10B981', '#FF0EA5E9', '#FFF43F5E'];
const FQ_DRAMA_TINT: string = '#FFEF5038';
const FQ_DANGER_TINT: string = '#FFF43F5E';

@ComponentV2
export struct CachedDramasPage {
  private scroller: Scroller = new Scroller();
  /** store 版本总线（完成入库/删除实时刷新）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 下载器单例（@Trace taskList 驱动任务行动态增删与实时进度）。 */
  @Local dl: FqDramaDownloader = fqDramaDownloader;
  /** 手风琴分组数据（refresh 重建，组件监听引用变化重排）。 */
  @Local groups: FqCacheGroupItem[] = [];
  /** 集记录快查（集行导出/删除回调由 detail.id 定位完整记录）。 */
  private episodeById: Map<string, FqCachedEpisode> = new Map<string, FqCachedEpisode>();
  @Local dramaCount: number = 0;
  @Local episodeCount: number = 0;
  @Local totalBytes: number = 0;
  @Local hasRunningTasks: boolean = false;
  @Local hasPausedTasks: boolean = false;
  @Local hasContent: boolean = false;
  /** 导出进行中（防重复点击）。 */
  @Local exporting: boolean = false;

  @Monitor('storeBus.dramaCacheVersion')
  onCacheDataChange(): void {
    this.refresh();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** 重聚合剧分组（含未入库任务临时组）与统计数字。 */
  private refresh(): void {
    const dramas: FqCachedDramaSummary[] = FqDramaCacheStore.dramas();
    const knownSeries: Set<string> = new Set<string>();
    const groups: FqCacheGroupItem[] = [];
    this.episodeById.clear();
    let episodes: number = 0;
    let bytes: number = 0;
    let tintIndex: number = 0;
    for (const drama of dramas) {
      knownSeries.add(drama.seriesId);
      episodes += drama.episodeCount;
      bytes += drama.byteCount;
      const details: FqCacheDetailItem[] = [];
      for (const episode of FqDramaCacheStore.episodesOf(drama.seriesId)) {
        this.episodeById.set(episode.itemId, episode);
        details.push(new FqCacheDetailItem(episode.itemId, `第 ${episode.index} 集`,
          episode.title, fqFormatCacheBytes(episode.bytes)));
      }
      groups.push(new FqCacheGroupItem(drama.seriesId, drama.title,
        `${drama.episodeCount} 集 · ${fqFormatCacheBytes(drama.byteCount)}`,
        FQ_DRAMA_TINTS[tintIndex % FQ_DRAMA_TINTS.length], true, details));
      tintIndex++;
    }
    // 未入库任务临时组（正在下载/暂停/失败的剧，完成后自动并入正式剧卡）
    const taskSeriesIds: string[] = [];
    for (const task of this.dl.taskList) {
      if (task.status !== DramaDownloadStatus.Completed && !knownSeries.has(task.seriesId)
        && taskSeriesIds.indexOf(task.seriesId) === -1) {
        taskSeriesIds.push(task.seriesId);
      }
    }
    let hasRunning: boolean = false;
    let hasPaused: boolean = false;
    for (const task of this.dl.taskList) {
      if (task.status === DramaDownloadStatus.Downloading
        || task.status === DramaDownloadStatus.Waiting) {
        hasRunning = true;
      }
      if (task.status === DramaDownloadStatus.Paused) {
        hasPaused = true;
      }
    }
    for (const seriesId of taskSeriesIds) {
      const firstTask: FqDramaDownloadTask | null = this.firstTaskOf(seriesId);
      if (firstTask === null) {
        continue;
      }
      groups.push(new FqCacheGroupItem(seriesId,
        firstTask.seriesTitle.length > 0 ? firstTask.seriesTitle : seriesId,
        '缓存中', FQ_DRAMA_TINTS[tintIndex % FQ_DRAMA_TINTS.length], true, []));
      tintIndex++;
    }
    this.dramaCount = dramas.length;
    this.episodeCount = episodes;
    this.totalBytes = bytes;
    this.hasRunningTasks = hasRunning;
    this.hasPausedTasks = hasPaused;
    this.hasContent = dramas.length > 0 || this.dl.taskList.length > 0;
    this.groups = groups;
  }

  private firstTaskOf(seriesId: string): FqDramaDownloadTask | null {
    for (const task of this.dl.taskList) {
      if (task.seriesId === seriesId) {
        return task;
      }
    }
    return null;
  }

  /** 该剧未入库任务（含暂停/失败；完成即入 store 不在此列）。 */
  private tasksOf(seriesId: string): FqDramaDownloadTask[] {
    const result: FqDramaDownloadTask[] = [];
    for (const task of this.dl.taskList) {
      if (task.seriesId === seriesId && task.status !== DramaDownloadStatus.Completed) {
        result.push(task);
      }
    }
    return result;
  }

  /** 任务状态文案（fqapp statusLabel 同款）。 */
  private taskStatusText(task: FqDramaDownloadTask): string {
    if (task.status === DramaDownloadStatus.Waiting) {
      return '排队中';
    }
    if (task.status === DramaDownloadStatus.Downloading) {
      return '下载中';
    }
    if (task.status === DramaDownloadStatus.Paused) {
      return '已暂停';
    }
    if (task.status === DramaDownloadStatus.Failed) {
      return task.errorText.length > 0 ? task.errorText : '失败';
    }
    return '已完成';
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('剧集缓存', false),
      scroller: this.scroller,
    }) {
      if (!this.hasContent) {
        FqCacheEmptyView({
          icon: $r('sys.symbol.download'),
          tint: FQ_DRAMA_TINT,
          title: '暂无离线缓存',
          subtitle: '播放页选集面板“缓存”选择想下载的集；下载的内容不会被自动清理。',
        })
      } else {
        FqCacheAccordionList({
          groups: this.groups,
          icon: $r('sys.symbol.film'),
          scroller: this.scroller,
          statsBuilder: (): void => {
            this.StatsCard()
          },
          taskRowsOf: (seriesId: string): void => {
            this.TaskRows(seriesId)
          },
          detailTrailingOf: (detail: FqCacheDetailItem): void => {
            this.ExportButton(detail)
          },
          groupDeleteClick: (group: FqCacheGroupItem): void => {
            this.confirmRemoveDrama(group);
          },
          detailDeleteClick: (detail: FqCacheDetailItem): void => {
            this.confirmRemoveEpisode(detail);
          },
        })
      }
    }
  }

  /** 统计卡：N 部 · M 集 · 占用 + 暂停全部/继续全部/清空。 */
  @Builder
  private StatsCard() {
    FqCacheStatsCard({
      icon: $r('sys.symbol.film'),
      tint: FQ_DRAMA_TINT,
      title: `已缓存 ${this.dramaCount} 部 · 共 ${this.episodeCount} 集`,
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

  /** 集行尾随“导出”按钮（detailTrailingOf 注入公共组件）。 */
  @Builder
  private ExportButton(detail: FqCacheDetailItem) {
    Text('导出')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(FQ_DRAMA_TINT)
      .padding({ left: 10, right: 2, top: 6, bottom: 6 })
      .onClick((): void => {
        this.confirmExportEpisode(this.episodeById.get(detail.id) ?? null);
      })
  }

  /** 任务行组（ForEach 绑定 @Trace taskList：进度实时、增删动态）。 */
  @Builder
  private TaskRows(seriesId: string) {
    Column({ space: 8 }) {
      ForEach(this.tasksOf(seriesId), (task: FqDramaDownloadTask) => {
        this.TaskRow(task)
      }, (task: FqDramaDownloadTask) => `${task.itemId}-${task.status}`)
    }
    .width('100%')
  }

  /** 单任务行：标题 + 进度条 + 状态 + 暂停/继续/重试/移除。 */
  @Builder
  private TaskRow(task: FqDramaDownloadTask) {
    Column({ space: 7 }) {
      Row({ space: 10 }) {
        Text(`第 ${task.index} 集`)
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
            this.removeTask(task);
          })
      }
      .width('100%')

      Progress({ value: task.receivedBytes, total: task.totalBytes > 0 ? task.totalBytes : 1 })
        .style({ strokeWidth: 4 })
        .color(task.status === DramaDownloadStatus.Failed ? FQ_DANGER_TINT : FQ_DRAMA_TINT)
        .width('100%')

      Row({ space: 6 }) {
        Text(this.taskStatusText(task))
          .fontSize(11)
          .fontColor(task.status === DramaDownloadStatus.Failed
            ? FQ_DANGER_TINT : $r('sys.color.font_tertiary'))
        Text(task.totalBytes > 0
          ? `${fqFormatCacheBytes(task.receivedBytes)} / ${fqFormatCacheBytes(task.totalBytes)}`
          : fqFormatCacheBytes(task.receivedBytes))
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
  private TaskActionIcon(task: FqDramaDownloadTask) {
    if (task.status === DramaDownloadStatus.Downloading || task.status === DramaDownloadStatus.Waiting) {
      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.pause(task.itemId);
          this.refresh();
        })
    } else if (task.status === DramaDownloadStatus.Paused) {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.resume(task.itemId);
          this.refresh();
        })
    } else if (task.status === DramaDownloadStatus.Failed) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(15)
        .fontColor([$r('sys.color.font_secondary')])
        .padding({ left: 4, top: 4, bottom: 4 })
        .onClick((): void => {
          this.dl.retry(task.itemId);
          this.refresh();
        })
    }
  }

  /** 移除任务（含 .part 残留与记录）。 */
  private removeTask(task: FqDramaDownloadTask): void {
    this.dl.removeTask(task.itemId);
    FqDramaCacheStore.removeEpisode(task.itemId);
    this.refresh();
  }

  /** 导出确认：提示导出路径后再执行。 */
  private confirmExportEpisode(episode: FqCachedEpisode | null): void {
    if (episode === null) {
      return;
    }
    DialogManager.ShowConfirm('导出这一集',
      `《${episode.seriesTitle}》第${episode.index}集 ${episode.title} 将导出到 Download/FQHouseOH 文件夹里。`,
      '导出',
      (): void => {
        this.exportEpisode(episode);
      });
  }

  /** 导出单集：复制 mp4 到 Download/<包名>/<剧名>/第N集 标题.mp4。 */
  private async exportEpisode(episode: FqCachedEpisode): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    this.getUIContext().getPromptAction().showToast({ message: '正在导出…', duration: 1000 });
    try {
      const path: string = await fqExportCachedEpisode(getContext(this), episode);
      const name: string = path.substring(path.lastIndexOf('/') + 1);
      this.getUIContext().getPromptAction().showToast({ message: `已导出 ${name}`, duration: 2500 });
    } catch (error) {
      const message: string = error instanceof Error && error.message.length > 0 ? error.message : '导出失败，请重试';
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } finally {
      this.exporting = false;
    }
  }

  /** 删单集确认（对齐 fqapp 文案）。 */
  private confirmRemoveEpisode(detail: FqCacheDetailItem): void {
    DialogManager.ShowConfirm('删除这一集', '联网后可重新缓存。', '删除',
      (): void => {
        FqDramaCacheStore.removeEpisode(detail.id);
      });
  }

  /** 删整剧确认（对齐 fqapp 文案；集数回查 store，未入库临时组直接清任务）。 */
  private confirmRemoveDrama(group: FqCacheGroupItem): void {
    let episodeCount: number = 0;
    for (const drama of FqDramaCacheStore.dramas()) {
      if (drama.seriesId === group.id) {
        episodeCount = drama.episodeCount;
        break;
      }
    }
    DialogManager.ShowConfirm(`删除《${group.title}》的缓存`,
      `已下载的 ${episodeCount} 集会从设备删除，联网后可重新缓存。`, '删除',
      (): void => {
        this.dl.removeTasksOf(group.id);
        FqDramaCacheStore.removeSeries(group.id);
      });
  }

  /** 清空全部确认（对齐 fqapp 文案）。 */
  private confirmClearAll(): void {
    DialogManager.ShowConfirm('清空全部离线缓存',
      '所有已下载的剧集会从设备删除，联网后可重新缓存。', '清空',
      (): void => {
        FqDramaCacheStore.clearAll();
      });
  }
}

/**
 * 剧集缓存页（我的-剧集缓存入口，对齐 fqapp cached_dramas_page）：
 * 统计卡（N 部 · M 集 · 占用 + 暂停全部/继续全部/清空）+ 剧卡手风琴
 * （LazyForEach：头行 + 集明细 + 任务行）；任务行绑定 @ObservedV2 下载任务
 * 实时进度（排队/下载/暂停/失败 + 重试）；单集/整剧删除走确认；
 * 未入库任务按剧分组为临时卡；空态引导文案。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { FqCacheEmptyView, FqCacheStatsCard, fqFormatCacheBytes } from '../../view/FqCacheCommon';
import { FqDramaCacheStore, FqCachedDramaSummary, FqCachedEpisode } from '../../core/FqDramaCacheStore';
import { fqExportCachedEpisode, fqExportDirName } from '../../core/FqCacheExport';
import { fqDramaDownloader, FqDramaDownloader, FqDramaDownloadTask, DramaDownloadStatus } from '../../core/FqDramaDownloader';
import { fqStoreBus, FqStoreBus } from '../../core/FqStoreBus';
import { DialogManager } from '../../utils/DialogUtils';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';

const FQ_CACHE_TOP_INSET: number = 56;
/** 剧卡图标块配色轮换（对齐项目统计页配色）。 */
const FQ_DRAMA_TINTS: string[] = ['#FFEF5038', '#FF8B5CF6', '#FF3B82F6', '#FF10B981', '#FF0EA5E9', '#FFF43F5E'];
const FQ_DANGER_TINT: string = '#FFF43F5E';

/** 列表行种类。 */
const FQ_ROW_HEADER: number = 0;
const FQ_ROW_EPISODE: number = 1;
const FQ_ROW_TASKS: number = 2;

/** 手风琴扁平行（LazyForEach 数据源条目）。 */
class FqDramaRow {
  public readonly kind: number;
  public readonly drama: FqCachedDramaSummary;
  /** 集行条目（kind=EPISODE 时非空）。 */
  public readonly episode: FqCachedEpisode | null;
  public readonly tint: string;

  constructor(kind: number, drama: FqCachedDramaSummary,
    episode: FqCachedEpisode | null, tint: string) {
    this.kind = kind;
    this.drama = drama;
    this.episode = episode;
    this.tint = tint;
  }
}

/** 懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class CachedDramaDataSource implements IDataSource {
  private rows: FqDramaRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): FqDramaRow {
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

  reload(rows: FqDramaRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct CachedDramasPage {
  private scroller: Scroller = new Scroller();
  private dataSource: CachedDramaDataSource = new CachedDramaDataSource();
  /** store 版本总线（完成入库/删除实时刷新）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  /** 下载器单例（@Trace taskList 驱动任务行动态增删与实时进度）。 */
  @Local dl: FqDramaDownloader = fqDramaDownloader;
  /** 收起的剧 id（默认全部展开）。 */
  @Local collapsedIds: string[] = [];
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

  /** 重聚合剧卡（含未入库任务临时组）与统计数字。 */
  private refresh(): void {
    const dramas: FqCachedDramaSummary[] = FqDramaCacheStore.dramas();
    const knownSeries: Set<string> = new Set<string>();
    const rows: FqDramaRow[] = [];
    let episodes: number = 0;
    let bytes: number = 0;
    let tintIndex: number = 0;
    for (const drama of dramas) {
      knownSeries.add(drama.seriesId);
      episodes += drama.episodeCount;
      bytes += drama.byteCount;
      const tint: string = FQ_DRAMA_TINTS[tintIndex % FQ_DRAMA_TINTS.length];
      tintIndex++;
      rows.push(new FqDramaRow(FQ_ROW_HEADER, drama, null, tint));
      if (this.isExpanded(drama.seriesId)) {
        const cachedEpisodes: FqCachedEpisode[] = FqDramaCacheStore.episodesOf(drama.seriesId);
        for (const episode of cachedEpisodes) {
          rows.push(new FqDramaRow(FQ_ROW_EPISODE, drama, episode, tint));
        }
        rows.push(new FqDramaRow(FQ_ROW_TASKS, drama, null, tint));
      }
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
      const pseudo: FqCachedDramaSummary = new FqCachedDramaSummary(seriesId,
        firstTask.seriesTitle.length > 0 ? firstTask.seriesTitle : seriesId,
        firstTask.cover, firstTask.kind, 0, 0);
      const tint: string = FQ_DRAMA_TINTS[tintIndex % FQ_DRAMA_TINTS.length];
      tintIndex++;
      rows.push(new FqDramaRow(FQ_ROW_HEADER, pseudo, null, tint));
      if (this.isExpanded(seriesId)) {
        rows.push(new FqDramaRow(FQ_ROW_TASKS, pseudo, null, tint));
      }
    }
    this.dramaCount = dramas.length;
    this.episodeCount = episodes;
    this.totalBytes = bytes;
    this.hasRunningTasks = hasRunning;
    this.hasPausedTasks = hasPaused;
    this.hasContent = dramas.length > 0 || this.dl.taskList.length > 0;
    this.dataSource.reload(rows);
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

  private isExpanded(seriesId: string): boolean {
    return this.collapsedIds.indexOf(seriesId) === -1;
  }

  private toggleExpanded(seriesId: string): void {
    const index: number = this.collapsedIds.indexOf(seriesId);
    if (index >= 0) {
      this.collapsedIds.splice(index, 1);
    } else {
      this.collapsedIds.push(seriesId);
    }
    this.refresh();
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
          tint: '#FFEF5038',
          title: '暂无离线缓存',
          subtitle: '播放页选集面板“缓存”选择想下载的集；下载的内容不会被自动清理。',
        })
      } else {
        List({ space: 10, scroller: this.scroller }) {
          ListItem() {
            FqCacheStatsCard({
              icon: $r('sys.symbol.film'),
              tint: '#FFEF5038',
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

          LazyForEach(this.dataSource, (row: FqDramaRow) => {
            ListItem() {
              if (row.kind === FQ_ROW_HEADER) {
                this.DramaHeader(row)
              } else if (row.kind === FQ_ROW_EPISODE) {
                this.EpisodeRow(row)
              } else {
                this.TaskRows(row.drama.seriesId)
              }
            }
          }, (row: FqDramaRow) => `${row.kind}-${row.drama.seriesId}-${row.episode !== null ? row.episode.itemId : ''}`)
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

  /** 剧卡头行：图标块 + 剧名 + 集数/大小 + 删除整剧 + 展开箭头。 */
  @Builder
  private DramaHeader(row: FqDramaRow) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.film'))
          .fontSize(19)
          .fontColor([row.tint])
      }
      .width(38)
      .height(38)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(row.tint, 0.12))

      Column({ space: 3 }) {
        Text(row.drama.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.drama.episodeCount > 0
          ? `${row.drama.episodeCount} 集 · ${fqFormatCacheBytes(row.drama.byteCount)}`
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
          this.confirmRemoveDrama(row.drama);
        })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
        .rotate({ angle: this.isExpanded(row.drama.seriesId) ? 90 : 0 })
    }
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
    .onClick((): void => {
      this.toggleExpanded(row.drama.seriesId);
    })
  }

  /** 单集行：第 i 集 · 标题 + 大小 + 单集删除。 */
  @Builder
  private EpisodeRow(row: FqDramaRow) {
    if (row.episode !== null) {
      Row({ space: 10 }) {
        Text(`第 ${row.episode.index} 集`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (row.episode.title.length > 0) {
          Text(row.episode.title)
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        Text(fqFormatCacheBytes(row.episode.bytes))
          .fontSize(11.5)
          .fontColor($r('sys.color.font_tertiary'))
        Text('导出')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFEF5038')
          .padding({ left: 10, right: 2, top: 6, bottom: 6 })
          .onClick((): void => {
            this.confirmExportEpisode(row.episode);
          })
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
          .padding({ left: 4, top: 8, bottom: 8 })
          .onClick((): void => {
            this.confirmRemoveEpisode(row.episode);
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
        .color(task.status === DramaDownloadStatus.Failed ? FQ_DANGER_TINT : '#FFEF5038')
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
  private async exportEpisode(episode: FqCachedEpisode | null): Promise<void> {
    if (episode === null) {
      return;
    }
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
  private confirmRemoveEpisode(episode: FqCachedEpisode | null): void {
    if (episode === null) {
      return;
    }
    DialogManager.ShowConfirm('删除这一集', '联网后可重新缓存。', '删除',
      (): void => {
        FqDramaCacheStore.removeEpisode(episode.itemId);
      });
  }

  /** 删整剧确认（对齐 fqapp 文案）。 */
  private confirmRemoveDrama(drama: FqCachedDramaSummary): void {
    DialogManager.ShowConfirm(`删除《${drama.title}》的缓存`,
      `已下载的 ${drama.episodeCount} 集会从设备删除，联网后可重新缓存。`, '删除',
      (): void => {
        this.dl.removeTasksOf(drama.seriesId);
        FqDramaCacheStore.removeSeries(drama.seriesId);
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

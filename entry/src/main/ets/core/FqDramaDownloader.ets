/**
 * 剧集缓存下载器（对齐 fqapp DramaDownloader 语义子集）：
 * - @ObservedV2 任务模型（status/receivedBytes/totalBytes @Trace），
 *   播放页与管理页直接绑定任务对象做实时进度；
 * - 并发 2，超出的任务 Waiting 排队；
 * - 断点续传：暂停/失败保留 .part，重新发起时 Range: bytes=<已收>- 续传，
 *   服务器忽略 Range（回 200）自动丢弃 .part 整段重下；
 * - 只持久化完成集（FqDramaCacheStore.addEpisode）；任务队列不跨重启，
 *   .part 残留由再次发起时的 Range 复用。
 */

import http from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqBackend } from './FqBackend';
import { FqCachedEpisode, FqDramaCacheStore } from './FqDramaCacheStore';
import { fqKindToTab } from '../model/FqModels';

const TAG: string = 'FqDramaDL';

/** 下载任务状态（对齐 fqapp DramaDownloadStatus）。 */
export enum DramaDownloadStatus {
  Waiting = 0,
  Downloading = 1,
  Paused = 2,
  Completed = 3,
  Failed = 4,
}

/** 是否暂停态（函数封装规避编译期枚举字面量收窄的「无重叠」误报：
 *  runTask 等待网络期间 pause() 可能改写 status，编译器无法感知）。 */
function fqIsPaused(status: DramaDownloadStatus): boolean {
  return status === DramaDownloadStatus.Paused;
}

@ObservedV2
export class FqDramaDownloadTask {
  public readonly seriesId: string;
  public readonly itemId: string;
  /** 集标题。 */
  public readonly title: string;
  /** 剧名（管理页分组标题兜底）。 */
  public readonly seriesTitle: string;
  public readonly cover: string;
  /** 'video' | 'manju'（episodeSource 的 tab 由 fqKindToTab 派生）。 */
  public readonly kind: string;
  /** 集序号（1 起）。 */
  public readonly index: number;
  @Trace public status: DramaDownloadStatus = DramaDownloadStatus.Waiting;
  @Trace public receivedBytes: number = 0;
  @Trace public totalBytes: number = 0;
  @Trace public errorText: string = '';

  constructor(seriesId: string, itemId: string, title: string, seriesTitle: string,
    cover: string, kind: string, index: number) {
    this.seriesId = seriesId;
    this.itemId = itemId;
    this.title = title;
    this.seriesTitle = seriesTitle;
    this.cover = cover;
    this.kind = kind;
    this.index = index;
  }
}

@ObservedV2
export class FqDramaDownloader {
  /** 下载任务列表（含等待/下载/暂停/失败；完成的保留供进度回看，重启即清）。 */
  @Trace public taskList: FqDramaDownloadTask[] = [];
  private readonly maxConcurrent: number = 2;
  private context: common.Context | null = null;
  /** itemId → 进行中的 HTTP 请求（暂停时 destroy 中断流）。 */
  private clients: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();

  public init(context: common.Context): void {
    this.context = context;
  }

  /** 入队一集下载：已完整缓存/已在队列则跳过。 */
  public enqueue(seriesId: string, itemId: string, title: string, seriesTitle: string,
    cover: string, kind: string, index: number): void {
    if (itemId.length === 0 || FqDramaCacheStore.has(itemId)) {
      return;
    }
    const existing: FqDramaDownloadTask | null = this.taskOf(itemId);
    if (existing !== null) {
      if (existing.status === DramaDownloadStatus.Failed
        || existing.status === DramaDownloadStatus.Paused) {
        existing.status = DramaDownloadStatus.Waiting;
        existing.errorText = '';
        this.pump();
      }
      return;
    }
    this.taskList.push(new FqDramaDownloadTask(seriesId, itemId, title, seriesTitle,
      cover, kind, index));
    this.pump();
  }

  public taskOf(itemId: string): FqDramaDownloadTask | null {
    for (const task of this.taskList) {
      if (task.itemId === itemId) {
        return task;
      }
    }
    return null;
  }

  /** 暂停：等待中直接置 Paused；下载中置 Paused 后 destroy 请求（.part 保留续传）。 */
  public pause(itemId: string): void {
    const task: FqDramaDownloadTask | null = this.taskOf(itemId);
    if (task === null) {
      return;
    }
    if (task.status === DramaDownloadStatus.Waiting) {
      task.status = DramaDownloadStatus.Paused;
      return;
    }
    if (task.status !== DramaDownloadStatus.Downloading) {
      return;
    }
    task.status = DramaDownloadStatus.Paused;
    const client: http.HttpRequest | undefined = this.clients.get(itemId);
    if (client !== undefined) {
      try {
        client.destroy();
      } catch (error) {
        // 已结束的请求销毁失败不影响状态
      }
    }
  }

  /** 继续暂停的任务。 */
  public resume(itemId: string): void {
    const task: FqDramaDownloadTask | null = this.taskOf(itemId);
    if (task !== null && task.status === DramaDownloadStatus.Paused) {
      task.status = DramaDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 失败重试。 */
  public retry(itemId: string): void {
    const task: FqDramaDownloadTask | null = this.taskOf(itemId);
    if (task !== null && task.status === DramaDownloadStatus.Failed) {
      task.status = DramaDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 暂停全部进行中/排队中任务。 */
  public pauseAll(): void {
    for (const task of this.taskList) {
      if (task.status === DramaDownloadStatus.Waiting
        || task.status === DramaDownloadStatus.Downloading) {
        this.pause(task.itemId);
      }
    }
  }

  /** 继续全部暂停任务。 */
  public resumeAll(): void {
    for (const task of this.taskList) {
      if (task.status === DramaDownloadStatus.Paused) {
        task.status = DramaDownloadStatus.Waiting;
      }
    }
    this.pump();
  }

  /** 摘除任务（管理页删除未完成任务；下载中的先暂停再移除）。 */
  public removeTask(itemId: string): void {
    this.pause(itemId);
    for (let i = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].itemId === itemId) {
        this.taskList.splice(i, 1);
        return;
      }
    }
  }

  /** 摘除某剧全部未完成任务。 */
  public removeTasksOf(seriesId: string): void {
    const itemIds: string[] = [];
    for (const task of this.taskList) {
      if (task.seriesId === seriesId && task.status !== DramaDownloadStatus.Completed) {
        itemIds.push(task.itemId);
      }
    }
    for (const itemId of itemIds) {
      this.removeTask(itemId);
    }
  }

  /** 调度：补齐并发额度内的 Waiting 任务。 */
  private pump(): void {
    let active: number = 0;
    for (const task of this.taskList) {
      if (task.status === DramaDownloadStatus.Downloading) {
        active++;
      }
    }
    if (active >= this.maxConcurrent) {
      return;
    }
    for (const task of this.taskList) {
      if (active >= this.maxConcurrent) {
        break;
      }
      if (task.status === DramaDownloadStatus.Waiting) {
        active++;
        this.runTask(task);
      }
    }
  }

  private async runTask(task: FqDramaDownloadTask): Promise<void> {
    const context: common.Context | null = this.context;
    if (context === null) {
      task.status = DramaDownloadStatus.Failed;
      task.errorText = '未初始化';
      return;
    }
    task.status = DramaDownloadStatus.Downloading;
    task.errorText = '';
    const partPath: string = FqDramaCacheStore.partPath(task.itemId);
    const client: http.HttpRequest = http.createHttp();
    this.clients.set(task.itemId, client);
    let file: fs.File | null = null;
    let writeFailed: boolean = false;
    try {
      await FqBackend.get().start(context);
      if (task.status !== DramaDownloadStatus.Downloading) {
        return;
      }
      if (FqDramaCacheStore.has(task.itemId)) {
        task.status = DramaDownloadStatus.Completed;
        return;
      }
      const source = await FqBackend.get().episodeSource(task.itemId, fqKindToTab(task.kind));
      if (task.status !== DramaDownloadStatus.Downloading) {
        return;
      }
      // 续传起点：已有 .part 从其大小继续；无则整段下载。
      let startByte: number = 0;
      try {
        const stat: fs.Stat = fs.statSync(partPath);
        startByte = stat.size;
      } catch (error) {
        startByte = 0;
      }
      task.receivedBytes = startByte;
      let useRange: boolean = startByte > 0;
      file = FqDramaDownloader.openPartFile(partPath, useRange);
      if (file === null) {
        task.status = DramaDownloadStatus.Failed;
        task.errorText = '缓存目录不可用';
        this.pump();
        return;
      }
      const currentFile = file;
      client.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (writeFailed || task.status !== DramaDownloadStatus.Downloading) {
          return;
        }
        try {
          fs.writeSync(currentFile.fd, chunk);
        } catch (error) {
          writeFailed = true;
        }
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo): void => {
        if (task.status !== DramaDownloadStatus.Downloading) {
          return;
        }
        task.receivedBytes = startByte + info.receiveSize;
        if (info.totalSize > 0) {
          task.totalBytes = useRange ? startByte + info.totalSize : info.totalSize;
        }
      });
      let code: number = -1;
      try {
        const header: Record<string, string> = {};
        if (useRange) {
          header['Range'] = `bytes=${startByte}-`;
        }
        code = await client.requestInStream(source.url, {
          header: header,
          connectTimeout: 15000,
          readTimeout: 600000,
        });
      } catch (error) {
        code = -1;
      }
      // 服务器忽略 Range（回 200）：旧 part + 新整段内容已混写，丢弃重下。
      if (code === 200 && useRange) {
        hilog.info(0x0001, TAG, `range ignored, restart full: ${task.itemId}`);
        this.closeFile(file);
        file = null;
        startByte = 0;
        useRange = false;
        task.receivedBytes = 0;
        try {
          fs.unlinkSync(partPath);
        } catch (error) {
          // 无残留文件
        }
        file = FqDramaDownloader.openPartFile(partPath, false);
        if (file === null) {
          task.status = DramaDownloadStatus.Failed;
          task.errorText = '缓存目录不可用';
          this.pump();
          return;
        }
        const retryFile = file;
        client.on('dataReceive', (chunk: ArrayBuffer): void => {
          if (writeFailed || task.status !== DramaDownloadStatus.Downloading) {
            return;
          }
          try {
            fs.writeSync(retryFile.fd, chunk);
          } catch (error) {
            writeFailed = true;
          }
        });
        client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo): void => {
          if (task.status !== DramaDownloadStatus.Downloading) {
            return;
          }
          task.receivedBytes = info.receiveSize;
          if (info.totalSize > 0) {
            task.totalBytes = info.totalSize;
          }
        });
        try {
          code = await client.requestInStream(source.url, {
            connectTimeout: 15000,
            readTimeout: 600000,
          });
        } catch (error) {
          code = -1;
        }
      }
      // 暂停：保留 .part，静默退出。
      if (fqIsPaused(task.status)) {
        return;
      }
      if (writeFailed || code < 200 || code >= 300) {
        task.status = DramaDownloadStatus.Failed;
        task.errorText = '下载失败，点击重试';
        this.pump();
        return;
      }
      this.closeFile(file);
      file = null;
      const finalPath: string = FqDramaCacheStore.filePath(task.itemId);
      try {
        fs.renameSync(partPath, finalPath);
      } catch (error) {
        task.status = DramaDownloadStatus.Failed;
        task.errorText = '保存缓存失败';
        this.pump();
        return;
      }
      let bytes: number = 0;
      try {
        const stat: fs.Stat = fs.statSync(finalPath);
        bytes = stat.size;
      } catch (error) {
        bytes = 0;
      }
      task.receivedBytes = bytes;
      task.totalBytes = bytes;
      task.status = DramaDownloadStatus.Completed;
      FqDramaCacheStore.addEpisode(new FqCachedEpisode(task.seriesId, task.itemId,
        task.title, task.seriesTitle, task.cover, task.kind, task.index, bytes, Date.now()));
      this.pump();
    } catch (error) {
      if (!fqIsPaused(task.status)) {
        task.status = DramaDownloadStatus.Failed;
        task.errorText = '下载失败，点击重试';
      }
      this.pump();
    } finally {
      this.closeFile(file);
      client.off('dataReceive');
      client.off('dataReceiveProgress');
      try {
        client.destroy();
      } catch (error) {
        // 忽略销毁失败
      }
      this.clients.delete(task.itemId);
    }
  }

  /** 打开 .part：续传=APPEND 复用旧内容；整段=先删旧文件再新建。 */
  private static openPartFile(partPath: string, resume: boolean): fs.File | null {
    if (!resume) {
      try {
        fs.unlinkSync(partPath);
      } catch (error) {
        // 无旧文件
      }
    }
    try {
      return fs.openSync(partPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
    } catch (error) {
      return null;
    }
  }

  private closeFile(file: fs.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (error) {
      // 句柄关闭失败不影响结果
    }
  }
}

/** 全局单例（EntryAbility.init 注入 context；页面直接绑定做实时进度）。 */
export const fqDramaDownloader: FqDramaDownloader = new FqDramaDownloader();

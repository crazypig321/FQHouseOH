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
import { FqBackend, FqRequestError } from './FqBackend';
import { fqParseObject, fqStr } from './FqJson';
import { fqHongguoQualityHeight } from './FqParser';
import { FqCachedEpisode, FqDramaCacheStore } from './FqDramaCacheStore';
import { fqKindToTab, FqCacheTaskView } from '../model/FqModels';

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

/** 从 detail 原始章节串提取 vid（后端 chapter_vid 同语义：videoUrl 的
 *  hongguo-cenc:// 标记优先，回退 id 末段「:」之后的部分）。 */
function fqHongguoChapterVid(chapterJson: string): string {
  const rec: Record<string, Object> | null = fqParseObject(chapterJson);
  if (rec === null) {
    return '';
  }
  const videoUrl: string = fqStr(rec, 'videoUrl');
  const marker: string = 'hongguo-cenc://';
  const at: number = videoUrl.indexOf(marker);
  if (at >= 0) {
    const vid: string = videoUrl.substring(at + marker.length).trim();
    if (vid.length > 0) {
      return vid;
    }
  }
  const id: string = fqStr(rec, 'id');
  if (id.length === 0) {
    return '';
  }
  const tail: number = id.lastIndexOf(':');
  return (tail >= 0 ? id.substring(tail + 1) : id).trim();
}

@ObservedV2
export class FqDramaDownloadTask implements FqCacheTaskView {
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
  /** 边看边往后缓存自动排进来的集（滚动清理只删这类，手动下载不动）。 */
  public readonly auto: boolean;
  /** 入队时快照的清晰度偏好（空 = 后端默认最高档；下载跟播放同档，fqapp 同语义）。 */
  public readonly quality: string;
  /** 红果会话：detail 原始章节串（hongguoRawChapters 快照；空 = 番茄链路）。 */
  public readonly hongguoChapterJson: string;
  /** 取流返回的实际下载档名（完成时写入缓存记录；上游不带档位时为空）。 */
  public servedQuality: string = '';
  @Trace public status: DramaDownloadStatus = DramaDownloadStatus.Waiting;
  @Trace public receivedBytes: number = 0;
  @Trace public totalBytes: number = 0;
  @Trace public errorText: string = '';

  constructor(seriesId: string, itemId: string, title: string, seriesTitle: string,
    cover: string, kind: string, index: number, auto: boolean, quality: string,
    hongguoChapterJson: string = '') {
    this.seriesId = seriesId;
    this.itemId = itemId;
    this.title = title;
    this.seriesTitle = seriesTitle;
    this.cover = cover;
    this.kind = kind;
    this.index = index;
    this.auto = auto;
    this.quality = quality;
    this.hongguoChapterJson = hongguoChapterJson;
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
  /** itemId → 最近一次预取时间（ms）：与后端 video_info 5 分钟缓存 TTL
   *  对齐，窗口内不重复预取。 */
  private prefetchWindow: Map<string, number> = new Map<string, number>();

  public init(context: common.Context): void {
    this.context = context;
  }

  /** 入队一集下载：已完整缓存/已在队列则跳过；auto = 边看边往后缓存自动排的集；
   *  quality = 入队时的清晰度偏好（空 = 后端默认最高档，与默认播放同档）；
   *  hongguoChapterJson 非空走红果代下载链路（mode=download）。 */
  public enqueue(seriesId: string, itemId: string, title: string, seriesTitle: string,
    cover: string, kind: string, index: number, auto: boolean, quality: string,
    hongguoChapterJson: string = ''): void {
    if (itemId.length === 0 || FqDramaCacheStore.has(itemId)) {
      hilog.info(0x0001, TAG, `enqueue skip (cached/empty): ${itemId}`);
      return;
    }
    const existing: FqDramaDownloadTask | null = this.findTask(itemId);
    if (existing !== null) {
      if (existing.status === DramaDownloadStatus.Completed) {
        // 完成后缓存被管理页删除（enqueue 前置 has 检查已排除已缓存）：
        // 复活该任务重新下载，复用对象避免同 itemId 双任务。
        existing.status = DramaDownloadStatus.Waiting;
        existing.errorText = '';
        existing.servedQuality = '';
        this.pump();
        return;
      }
      hilog.info(0x0001, TAG, `enqueue skip (in queue): ${itemId}`);
      if (existing.status === DramaDownloadStatus.Failed
        || existing.status === DramaDownloadStatus.Paused) {
        existing.status = DramaDownloadStatus.Waiting;
        existing.errorText = '';
        this.pump();
      }
      return;
    }
    hilog.info(0x0001, TAG,
      `enqueue: ${itemId} index=${index} auto=${auto} quality=${quality} hongguo=${hongguoChapterJson.length > 0}`);
    this.taskList.push(new FqDramaDownloadTask(seriesId, itemId, title, seriesTitle,
      cover, kind, index, auto, quality, hongguoChapterJson));
    this.pump();
  }

  /** 查找任务（含已完成，不过滤缓存有效性；enqueue 复活被删缓存的完成任务用）。 */
  private findTask(itemId: string): FqDramaDownloadTask | null {
    for (const task of this.taskList) {
      if (task.itemId === itemId) {
        return task;
      }
    }
    return null;
  }

  /** 查询任务：已完成但缓存记录已被管理页删除的视为无任务（显示与重下走
   *  enqueue 链路）。渲染期高频调用，不改动 taskList（重启清空即可，
   *  避免渲染中改 @Trace 数组触发「渲染期间状态变更」）。 */
  public taskOf(itemId: string): FqDramaDownloadTask | null {
    const task: FqDramaDownloadTask | null = this.findTask(itemId);
    if (task !== null && task.status === DramaDownloadStatus.Completed
      && !FqDramaCacheStore.has(itemId)) {
      return null;
    }
    return task;
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
        if (task.hongguoChapterJson.length > 0) {
          this.prefetchHongguoBatch(task);
        }
        this.runTask(task);
      }
    }
  }

  /** hg源批量预取（fire-and-forget，不阻塞任务启动）：pump 启动 hg 任务
   *  时，把同剧排队的 hg 集凑一批（≤8，后端批量 resolve 上限）提前暖
   *  后端 5 分钟 video_info 缓存，后续各集取流命中缓存免逐集解析。预取
   *  与任务自身请求赛跑，未命中任务照常自行解析（有会话复用兜底）。 */
  private prefetchHongguoBatch(start: FqDramaDownloadTask): void {
    const now: number = Date.now();
    const windowMs: number = 5 * 60 * 1000;
    if (this.prefetchWindow.size > 64) {
      this.prefetchWindow.forEach((ts: number, key: string): void => {
        if (now - ts >= windowMs) {
          this.prefetchWindow.delete(key);
        }
      });
    }
    const candidates: FqDramaDownloadTask[] = [start];
    for (const task of this.taskList) {
      if (candidates.length >= 8) {
        break;
      }
      if (task === start || task.hongguoChapterJson.length === 0
        || task.seriesId !== start.seriesId
        || task.status !== DramaDownloadStatus.Waiting) {
        continue;
      }
      candidates.push(task);
    }
    const vids: string[] = [];
    for (const task of candidates) {
      if (vids.length >= 8) {
        break;
      }
      const last: number | undefined = this.prefetchWindow.get(task.itemId);
      if (last !== undefined && now - last < windowMs) {
        continue;
      }
      const vid: string = fqHongguoChapterVid(task.hongguoChapterJson);
      if (vid.length === 0) {
        continue;
      }
      this.prefetchWindow.set(task.itemId, now);
      vids.push(vid);
    }
    if (vids.length === 0) {
      return;
    }
    hilog.info(0x0001, TAG, `prefetch hg vids=${vids.length}`);
    FqBackend.get().hongguoPrefetch(vids).then((count: number): void => {
      hilog.info(0x0001, TAG, `prefetch hg done prefetched=${count}`);
    });
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
      // 红果会话走代下载链路（mode=download：后端整集代下载回 /src/ 明文）；
      // 番茄会话走 /api/content 代下载链路（.part 断点续传两者共用）
      const source = task.hongguoChapterJson.length > 0
        ? await FqBackend.get().hongguoEpisodeSourceDownload(task.seriesId,
          task.hongguoChapterJson, task.index - 1, fqHongguoQualityHeight(task.quality),
          task.seriesTitle)
        : await FqBackend.get().episodeSource(task.itemId, fqKindToTab(task.kind), task.quality);
      task.servedQuality = source.quality;
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
        task.title, task.seriesTitle, task.cover, task.kind, task.index, bytes, Date.now(),
        task.auto, task.servedQuality));
      this.pump();
    } catch (error) {
      if (!fqIsPaused(task.status)) {
        task.status = DramaDownloadStatus.Failed;
        // FqRequestError 消息面向用户（如「红果源暂时不可用」「请求超时」），
        // 直接透出；其余保持通用文案。失败原因同时落 hilog 便于排查。
        const message: string = error instanceof FqRequestError ? error.message
          : (error instanceof Error ? error.message : String(error));
        hilog.error(0x0001, TAG, `task ${task.itemId} failed: ${message}`);
        task.errorText = error instanceof FqRequestError
          && message.length > 0 ? message : '下载失败，点击重试';
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

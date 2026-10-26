/**
 * 听书音频缓存下载器（对齐 FqDramaDownloader 语义）：
 * - @ObservedV2 任务模型（status/receivedBytes/totalBytes @Trace），
 *   听书页缓存 sheet 与管理页直接绑定任务对象做实时进度；
 * - 并发 2，超出的任务 Waiting 排队；
 * - 断点续传：暂停/失败保留 .part，重新发起时 Range: bytes=<已收>- 续传，
 *   服务器忽略 Range（回 200）自动丢弃 .part 整段重下；
 * - 取流：audioChapterSource(bookId, itemId, toneId)（mode=download 整章解密），
 *   音色专属（TTS 每音色一套；真人讲书 toneId '0'）；
 * - 只持久化完成章（FqAudioCacheStore.addChapter）；任务队列不跨重启，
 *   .part 残留由再次发起时的 Range 复用。
 */

import http from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqBackend } from './FqBackend';
import { FqAudioCacheStore, FqCachedAudioChapter } from './FqAudioCacheStore';
import { FqCacheTaskView } from '../model/FqModels';

const TAG: string = 'FqAudioDL';

/** 下载任务状态（取值与 FQ_CACHE_TASK_* 一致）。 */
export enum AudioDownloadStatus {
  Waiting = 0,
  Downloading = 1,
  Paused = 2,
  Completed = 3,
  Failed = 4,
}

/** 是否暂停态（函数封装规避编译期枚举字面量收窄的「无重叠」误报：
 *  runTask 等待网络期间 pause() 可能改写 status，编译器无法感知）。 */
function fqIsPaused(status: AudioDownloadStatus): boolean {
  return status === AudioDownloadStatus.Paused;
}

@ObservedV2
export class FqAudioDownloadTask implements FqCacheTaskView {
  /** 复合键（bookId__itemId__toneId）。 */
  public readonly key: string;
  public readonly bookId: string;
  public readonly itemId: string;
  public readonly toneId: string;
  /** 章标题。 */
  public readonly title: string;
  /** 书名（管理页分组标题兜底）。 */
  public readonly bookTitle: string;
  public readonly cover: string;
  /** 章序号（1 起）。 */
  public readonly index: number;
  @Trace public status: AudioDownloadStatus = AudioDownloadStatus.Waiting;
  @Trace public receivedBytes: number = 0;
  @Trace public totalBytes: number = 0;
  @Trace public errorText: string = '';

  constructor(key: string, bookId: string, itemId: string, toneId: string,
    title: string, bookTitle: string, cover: string, index: number) {
    this.key = key;
    this.bookId = bookId;
    this.itemId = itemId;
    this.toneId = toneId;
    this.title = title;
    this.bookTitle = bookTitle;
    this.cover = cover;
    this.index = index;
  }
}

@ObservedV2
export class FqAudioDownloader {
  /** 下载任务列表（含等待/下载/暂停/失败；完成的保留供进度回看，重启即清）。 */
  @Trace public taskList: FqAudioDownloadTask[] = [];
  private readonly maxConcurrent: number = 2;
  private context: common.Context | null = null;
  /** 复合键 → 进行中的 HTTP 请求（暂停时 destroy 中断流）。 */
  private clients: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();

  public init(context: common.Context): void {
    this.context = context;
  }

  /** 入队一章下载：已完整缓存/已在队列则跳过。 */
  public enqueue(bookId: string, itemId: string, toneId: string, title: string,
    bookTitle: string, cover: string, index: number): void {
    const key: string = FqAudioCacheStore.key(bookId, itemId, toneId);
    if (key.length === 0 || FqAudioCacheStore.has(key)) {
      return;
    }
    const existing: FqAudioDownloadTask | null = this.taskOf(key);
    if (existing !== null) {
      if (existing.status === AudioDownloadStatus.Failed
        || existing.status === AudioDownloadStatus.Paused) {
        existing.status = AudioDownloadStatus.Waiting;
        existing.errorText = '';
        this.pump();
      }
      return;
    }
    this.taskList.push(new FqAudioDownloadTask(key, bookId, itemId, toneId,
      title, bookTitle, cover, index));
    this.pump();
  }

  public taskOf(key: string): FqAudioDownloadTask | null {
    for (const task of this.taskList) {
      if (task.key === key) {
        return task;
      }
    }
    return null;
  }

  /** 书 + 章节 + 音色定位任务（缓存 sheet taskViewOf / taskClick 用）。 */
  public taskOfItem(bookId: string, itemId: string, toneId: string): FqAudioDownloadTask | null {
    for (const task of this.taskList) {
      if (task.bookId === bookId && task.itemId === itemId && task.toneId === toneId) {
        return task;
      }
    }
    return null;
  }

  /** 暂停：等待中直接置 Paused；下载中置 Paused 后 destroy 请求（.part 保留续传）。 */
  public pause(key: string): void {
    const task: FqAudioDownloadTask | null = this.taskOf(key);
    if (task === null) {
      return;
    }
    if (task.status === AudioDownloadStatus.Waiting) {
      task.status = AudioDownloadStatus.Paused;
      return;
    }
    if (task.status !== AudioDownloadStatus.Downloading) {
      return;
    }
    task.status = AudioDownloadStatus.Paused;
    const client: http.HttpRequest | undefined = this.clients.get(key);
    if (client !== undefined) {
      try {
        client.destroy();
      } catch (error) {
        // 已结束的请求销毁失败不影响状态
      }
    }
  }

  /** 继续暂停的任务。 */
  public resume(key: string): void {
    const task: FqAudioDownloadTask | null = this.taskOf(key);
    if (task !== null && task.status === AudioDownloadStatus.Paused) {
      task.status = AudioDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 失败重试。 */
  public retry(key: string): void {
    const task: FqAudioDownloadTask | null = this.taskOf(key);
    if (task !== null && task.status === AudioDownloadStatus.Failed) {
      task.status = AudioDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 暂停全部进行中/排队中任务。 */
  public pauseAll(): void {
    for (const task of this.taskList) {
      if (task.status === AudioDownloadStatus.Waiting
        || task.status === AudioDownloadStatus.Downloading) {
        this.pause(task.key);
      }
    }
  }

  /** 继续全部暂停任务。 */
  public resumeAll(): void {
    for (const task of this.taskList) {
      if (task.status === AudioDownloadStatus.Paused) {
        task.status = AudioDownloadStatus.Waiting;
      }
    }
    this.pump();
  }

  /** 摘除任务（管理页删除未完成任务；下载中的先暂停再移除）。 */
  public removeTask(key: string): void {
    this.pause(key);
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].key === key) {
        this.taskList.splice(i, 1);
        return;
      }
    }
  }

  /** 摘除某书全部未完成任务。 */
  public removeTasksOf(bookId: string): void {
    const keys: string[] = [];
    for (const task of this.taskList) {
      if (task.bookId === bookId && task.status !== AudioDownloadStatus.Completed) {
        keys.push(task.key);
      }
    }
    for (const key of keys) {
      this.removeTask(key);
    }
  }

  /** 调度：补齐并发额度内的 Waiting 任务。 */
  private pump(): void {
    let active: number = 0;
    for (const task of this.taskList) {
      if (task.status === AudioDownloadStatus.Downloading) {
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
      if (task.status === AudioDownloadStatus.Waiting) {
        active++;
        this.runTask(task);
      }
    }
  }

  private async runTask(task: FqAudioDownloadTask): Promise<void> {
    const context: common.Context | null = this.context;
    if (context === null) {
      task.status = AudioDownloadStatus.Failed;
      task.errorText = '未初始化';
      return;
    }
    task.status = AudioDownloadStatus.Downloading;
    task.errorText = '';
    const partPath: string = FqAudioCacheStore.partPath(task.key);
    const client: http.HttpRequest = http.createHttp();
    this.clients.set(task.key, client);
    let file: fs.File | null = null;
    let writeFailed: boolean = false;
    try {
      await FqBackend.get().start(context);
      if (task.status !== AudioDownloadStatus.Downloading) {
        return;
      }
      if (FqAudioCacheStore.has(task.key)) {
        task.status = AudioDownloadStatus.Completed;
        return;
      }
      const source = await FqBackend.get().audioChapterSource(task.bookId, task.itemId, task.toneId);
      if (task.status !== AudioDownloadStatus.Downloading) {
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
      file = FqAudioDownloader.openPartFile(partPath, useRange);
      if (file === null) {
        task.status = AudioDownloadStatus.Failed;
        task.errorText = '缓存目录不可用';
        this.pump();
        return;
      }
      const currentFile = file;
      client.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (writeFailed || task.status !== AudioDownloadStatus.Downloading) {
          return;
        }
        try {
          fs.writeSync(currentFile.fd, chunk);
        } catch (error) {
          writeFailed = true;
        }
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo): void => {
        if (task.status !== AudioDownloadStatus.Downloading) {
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
        hilog.info(0x0001, TAG, `range ignored, restart full: ${task.key}`);
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
        file = FqAudioDownloader.openPartFile(partPath, false);
        if (file === null) {
          task.status = AudioDownloadStatus.Failed;
          task.errorText = '缓存目录不可用';
          this.pump();
          return;
        }
        const retryFile = file;
        client.on('dataReceive', (chunk: ArrayBuffer): void => {
          if (writeFailed || task.status !== AudioDownloadStatus.Downloading) {
            return;
          }
          try {
            fs.writeSync(retryFile.fd, chunk);
          } catch (error) {
            writeFailed = true;
          }
        });
        client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo): void => {
          if (task.status !== AudioDownloadStatus.Downloading) {
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
        task.status = AudioDownloadStatus.Failed;
        task.errorText = '下载失败，点击重试';
        this.pump();
        return;
      }
      this.closeFile(file);
      file = null;
      const finalPath: string = FqAudioCacheStore.filePath(task.key);
      try {
        fs.renameSync(partPath, finalPath);
      } catch (error) {
        task.status = AudioDownloadStatus.Failed;
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
      task.status = AudioDownloadStatus.Completed;
      FqAudioCacheStore.addChapter(new FqCachedAudioChapter(task.key, task.bookId,
        task.itemId, task.toneId, task.title, task.bookTitle, task.cover,
        task.index, bytes, Date.now()));
      this.pump();
    } catch (error) {
      if (!fqIsPaused(task.status)) {
        task.status = AudioDownloadStatus.Failed;
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
      this.clients.delete(task.key);
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
export const fqAudioDownloader: FqAudioDownloader = new FqAudioDownloader();

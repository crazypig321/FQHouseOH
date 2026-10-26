/**
 * 漫画离线下载器（对齐 FqAudioDownloader 语义，粒度=话）：
 * - 任务 = 一话：先取图片 URL 列表（store 列表缓存优先，未命中请求后端并回填），
 *   逐图下载落盘 offline_comic/<bookId>__<itemId>/<i>，全部完成后入库
 *   （FqComicCacheStore.addChapter）；
 * - 断点续传粒度=图：已落盘的 <i> 跳过，中断后重新发起只补缺图；
 * - 并发 2 话；暂停/失败/重试/移除与听书下载器同款语义；
 * - 任务进度按图计数（receivedBytes=已下图数 / totalBytes=总图数），
 *   FqCacheSheet 百分比展示直接可用；真实字节数单独累计供记录。
 */

import http from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqBackend } from './FqBackend';
import { FqComicCacheStore, FqCachedComicChapter } from './FqComicCacheStore';
import { FqCacheTaskView } from '../model/FqModels';

const TAG: string = 'FqComicDL';

/** 下载任务状态（取值与 FQ_CACHE_TASK_* 一致）。 */
export enum ComicDownloadStatus {
  Waiting = 0,
  Downloading = 1,
  Paused = 2,
  Completed = 3,
  Failed = 4,
}

/** 是否暂停态（函数封装规避编译期枚举字面量收窄的「无重叠」误报）。 */
function fqIsPaused(status: ComicDownloadStatus): boolean {
  return status === ComicDownloadStatus.Paused;
}

@ObservedV2
export class FqComicDownloadTask implements FqCacheTaskView {
  /** 复合键（bookId__itemId）。 */
  public readonly key: string;
  public readonly bookId: string;
  public readonly itemId: string;
  /** 话标题。 */
  public readonly title: string;
  /** 书名（管理页分组标题兜底）。 */
  public readonly bookTitle: string;
  /** 话序号（1 起）。 */
  public readonly index: number;
  /** 已下载图数 / 总图数（进度条与计数展示）。 */
  @Trace public receivedBytes: number = 0;
  @Trace public totalBytes: number = 0;
  @Trace public status: ComicDownloadStatus = ComicDownloadStatus.Waiting;
  @Trace public errorText: string = '';

  constructor(key: string, bookId: string, itemId: string, title: string,
    bookTitle: string, index: number) {
    this.key = key;
    this.bookId = bookId;
    this.itemId = itemId;
    this.title = title;
    this.bookTitle = bookTitle;
    this.index = index;
  }
}

@ObservedV2
export class FqComicDownloader {
  /** 下载任务列表（完成的保留供进度回看，重启即清）。 */
  @Trace public taskList: FqComicDownloadTask[] = [];
  private readonly maxConcurrent: number = 2;
  private context: common.Context | null = null;
  /** 复合键 → 进行中的 HTTP 请求（暂停时 destroy 中断当前图）。 */
  private clients: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();

  public init(context: common.Context): void {
    this.context = context;
  }

  /** 入队一话下载：已完整离线/已在队列则跳过。 */
  public enqueue(bookId: string, itemId: string, title: string,
    bookTitle: string, index: number): void {
    const key: string = FqComicCacheStore.key(bookId, itemId);
    if (key.length === 0 || FqComicCacheStore.has(key)) {
      return;
    }
    const existing: FqComicDownloadTask | null = this.taskOf(key);
    if (existing !== null) {
      if (existing.status === ComicDownloadStatus.Failed
        || existing.status === ComicDownloadStatus.Paused) {
        existing.status = ComicDownloadStatus.Waiting;
        existing.errorText = '';
        this.pump();
      }
      return;
    }
    this.taskList.push(new FqComicDownloadTask(key, bookId, itemId, title,
      bookTitle, index));
    this.pump();
  }

  public taskOf(key: string): FqComicDownloadTask | null {
    for (const task of this.taskList) {
      if (task.key === key) {
        return task;
      }
    }
    return null;
  }

  /** 书 + 话定位任务（缓存 sheet taskViewOf / taskClick 用）。 */
  public taskOfItem(bookId: string, itemId: string): FqComicDownloadTask | null {
    for (const task of this.taskList) {
      if (task.bookId === bookId && task.itemId === itemId) {
        return task;
      }
    }
    return null;
  }

  /** 暂停：等待中直接置 Paused；下载中置 Paused 后 destroy 当前图请求（已落盘图保留）。 */
  public pause(key: string): void {
    const task: FqComicDownloadTask | null = this.taskOf(key);
    if (task === null) {
      return;
    }
    if (task.status === ComicDownloadStatus.Waiting) {
      task.status = ComicDownloadStatus.Paused;
      return;
    }
    if (task.status !== ComicDownloadStatus.Downloading) {
      return;
    }
    task.status = ComicDownloadStatus.Paused;
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
    const task: FqComicDownloadTask | null = this.taskOf(key);
    if (task !== null && task.status === ComicDownloadStatus.Paused) {
      task.status = ComicDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 失败重试。 */
  public retry(key: string): void {
    const task: FqComicDownloadTask | null = this.taskOf(key);
    if (task !== null && task.status === ComicDownloadStatus.Failed) {
      task.status = ComicDownloadStatus.Waiting;
      task.errorText = '';
      this.pump();
    }
  }

  /** 暂停全部进行中/排队中任务。 */
  public pauseAll(): void {
    for (const task of this.taskList) {
      if (task.status === ComicDownloadStatus.Waiting
        || task.status === ComicDownloadStatus.Downloading) {
        this.pause(task.key);
      }
    }
  }

  /** 继续全部暂停任务。 */
  public resumeAll(): void {
    for (const task of this.taskList) {
      if (task.status === ComicDownloadStatus.Paused) {
        task.status = ComicDownloadStatus.Waiting;
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
      if (task.bookId === bookId && task.status !== ComicDownloadStatus.Completed) {
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
      if (task.status === ComicDownloadStatus.Downloading) {
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
      if (task.status === ComicDownloadStatus.Waiting) {
        active++;
        this.runTask(task);
      }
    }
  }

  private async runTask(task: FqComicDownloadTask): Promise<void> {
    const context: common.Context | null = this.context;
    if (context === null) {
      task.status = ComicDownloadStatus.Failed;
      task.errorText = '未初始化';
      return;
    }
    task.status = ComicDownloadStatus.Downloading;
    task.errorText = '';
    try {
      await FqBackend.get().start(context);
      if (task.status !== ComicDownloadStatus.Downloading) {
        return;
      }
      if (FqComicCacheStore.has(task.key)) {
        task.status = ComicDownloadStatus.Completed;
        return;
      }
      // 图片列表：store 列表缓存优先（秒开层），未命中请求后端并回填
      let urls: string[] | null = FqComicCacheStore.cachedImageList(task.bookId, task.itemId);
      if (urls === null) {
        urls = await FqBackend.get().chapterImages(task.itemId);
        FqComicCacheStore.saveImageList(task.bookId, task.itemId, urls);
      }
      if (task.status !== ComicDownloadStatus.Downloading) {
        return;
      }
      const dir: string = FqComicCacheStore.chapterDir(task.key);
      try {
        fs.mkdirSync(dir, true);
      } catch (error) {
        // 已存在
      }
      task.totalBytes = urls.length;
      let done: number = 0;
      let bytes: number = 0;
      // 断点续传：已落盘图跳过
      for (let i: number = 0; i < urls.length; i++) {
        const target: string = FqComicCacheStore.imagePath(task.key, i);
        try {
          if (fs.accessSync(target)) {
            done++;
            task.receivedBytes = done;
            continue;
          }
        } catch (error) {
          // 不存在则下载
        }
        const imageBytes: number = await this.downloadImage(task.key, urls[i], target);
        if (task.status !== ComicDownloadStatus.Downloading) {
          // 暂停/移除：已落盘图保留，静默退出
          return;
        }
        if (imageBytes < 0) {
          task.status = ComicDownloadStatus.Failed;
          task.errorText = '下载失败，点击重试';
          this.pump();
          return;
        }
        bytes += imageBytes;
        done++;
        task.receivedBytes = done;
      }
      task.status = ComicDownloadStatus.Completed;
      FqComicCacheStore.addChapter(new FqCachedComicChapter(task.key, task.bookId,
        task.itemId, task.title, task.bookTitle, task.index, urls.length,
        bytes, Date.now()));
      this.pump();
    } catch (error) {
      if (!fqIsPaused(task.status)) {
        task.status = ComicDownloadStatus.Failed;
        task.errorText = '下载失败，点击重试';
      }
      this.pump();
    }
  }

  /** 下载单图：request → 落盘；返回字节数（-1 失败；请求被暂停 destroy 视为暂停）。 */
  private async downloadImage(key: string, url: string, target: string): Promise<number> {
    const client: http.HttpRequest = http.createHttp();
    this.clients.set(key, client);
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true,
        connectTimeout: 15000,
        readTimeout: 60000,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        hilog.error(0x0001, TAG, 'image http %{public}d: %{public}s',
          response.responseCode, url);
        return -1;
      }
      const result: string | Object | ArrayBuffer = response.result;
      if (!(result instanceof ArrayBuffer) || result.byteLength === 0) {
        return -1;
      }
      const file: fs.File = fs.openSync(target,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, result);
      } finally {
        fs.closeSync(file);
      }
      return result.byteLength;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(0x0001, TAG, 'image failed: %{public}s code=%{public}d msg=%{public}s',
        url, err.code, err.message);
      return -1;
    } finally {
      try {
        client.destroy();
      } catch (error) {
        // 忽略销毁失败
      }
      this.clients.delete(key);
    }
  }
}

/** 全局单例（EntryAbility.init 注入 context；页面直接绑定做实时进度）。 */
export const fqComicDownloader: FqComicDownloader = new FqComicDownloader();

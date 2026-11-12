/**
 * 视频/听视频媒体会话助手（PlayerPage / ListenVideoPage 共用）：
 * AVSession（通知栏/锁屏播控中心 + 状态栏胶囊）+ 后台 audioPlayback 长时任务。
 * 复制 FqAudioSession 的 AVSession 模式为页面级生命周期——
 * 进页 init（注入播控命令回调）、起播 ensureSession + startBackground、
 * 周期 syncPlayback（内部 1s 节流）与 updateMetadata（封面 PixelMap 后台拉取）、
 * 离页/让路 release（停后台任务 + AVSession deactivate/destroy）。
 * sessionTag 由构造传入（'FqVideo' / 'FqListenVideo'），避免双页共存时会话撞名。
 */

import avSession from '@ohos.multimedia.avsession';
import image from '@ohos.multimedia.image';
import http from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqAppSettingsStore } from './FqAppSettingsStore';
import { FqMediaBgTask } from './FqMediaBgTask';
import { FqAvArbiter, FqAvVideoHolder } from './FqAvArbiter';

const TAG: string = 'FqVideoMedia';

export class FqVideoMedia {
  /** 播控命令回调（页面注入：播放/暂停/上一集/下一集/seek/停止）。 */
  onPlay: () => void = (): void => {};
  onPause: () => void = (): void => {};
  onPrevious: () => void = (): void => {};
  onNext: () => void = (): void => {};
  onSeek: (sec: number) => void = (_sec: number): void => {};
  onStop: () => void = (): void => {};
  /** 快进/快退（播控中心 video 模板 ±15s 按钮；sec 为秒，未带时长时默认 15）。 */
  onFastForward: (sec: number) => void = (_sec: number): void => {};
  onRewind: (sec: number) => void = (_sec: number): void => {};
  /** 被仲裁让路回调（其他持有者接管时暂停播放，防叠栈双声道；页面注入）。 */
  onYield: () => void = (): void => {};

  private readonly sessionTag: string;
  private context: common.UIAbilityContext | null = null;
  private sessionValue: avSession.AVSession | null = null;
  /** 会话创建进行中（防同标签并发 create：服务侧报 session is existed 且引用被置空泄漏）。 */
  private sessionCreating: boolean = false;
  /** 会话代际（release/teardown 后作废在途创建与重试）。 */
  private sessionEpoch: number = 0;
  /** 创建失败有界重试定时器（0 无任务）。 */
  private ensureRetryTimer: number = 0;
  /** 创建失败有界重试计数。 */
  private ensureRetryCount: number = 0;
  private bgStarted: boolean = false;
  /** 最近一次 ensureSession 的会话类型（后台播放开关重开时重建会话用）。 */
  private lastSessionType: string = 'video';
  /** AVSession 后台播放模式最近一次已应用值（undefined=未应用，会话新建后重设）。 */
  private bgPlayModeApplied: boolean | undefined = undefined;
  private lastSyncAt: number = 0;
  private coverPixel: image.PixelMap | null = null;
  private coverPixelUrl: string = '';
  /** 最近一次元数据（会话晚到/封面就绪后重发）。 */
  private lastMeta: avSession.AVMetadata | null = null;
  /** 封面拉取进行中（单飞：失败后下轮 updateMetadata 才重试）。 */
  private coverLoading: boolean = false;
  /** 仲裁注册项（init 注册；dispose 注销；null 未注册）。 */
  private arbiterHolder: FqAvVideoHolder | null = null;
  /** 已销毁（页面 aboutToDisappear 后永久置位）：一切会话/后台/封面/同步操作全部禁用，
   *  防止泄漏的心跳定时器或迟到异步回调在页面销毁后"复活"出无主会话永久占住槽位。 */
  private disposed: boolean = false;
  /** 已让路释放（openListenMode / 仲裁让路后置位）：隐式心跳不得复活会话，
   *  仅显式接管（返回续播/切集起播）清除本标志重建。 */
  private released: boolean = false;
  /** 封面拉取失败退避重试时间戳（毫秒；之前失败不重试导致胶囊永远无封面）。 */
  private coverRetryAt: number = 0;

  constructor(sessionTag: string) {
    this.sessionTag = sessionTag;
  }

  public init(context: common.UIAbilityContext): void {
    this.context = context;
    if (this.arbiterHolder === null) {
      const self: FqVideoMedia = this;
      this.arbiterHolder = new FqAvVideoHolder(
        (): void => {
          self.onYield();
          self.release();
        },
        (): boolean => self.sessionValue !== null);
      FqAvArbiter.registerVideo(this.arbiterHolder);
    }
  }

  /** 起播时确保 AVSession（sessionType：'video' 视频页 / 'audio' 听视频页）。
   * 显式开启后台播放模式：video 会话默认 DISABLE_BACKGROUND_PLAY，不设则退后台无实况窗胶囊。
   * 让路页旧会话销毁为异步：创建报 session is existed 时 600ms 有界重试自愈。
   * implicit=false 显式接管（起播/返回续播）：先让路听书与其他视频页（顶层意图优先）；
   * implicit=true 隐式重建（1s tick）：听书或其他视频页持有时跳过（埋页不回抢）。 */
  public ensureSession(sessionType: string, implicit: boolean = false): void {
    if (this.disposed || this.sessionValue !== null || this.sessionCreating || this.context === null) {
      return;
    }
    // 设置开关：后台播放/画中画均关闭时不创建 AVSession（无胶囊/播控中心通知）
    if (!this.bgAllowed()) {
      return;
    }
    if (implicit) {
      // 已让路释放的实例不得由心跳隐式复活（上次释放后会话已交出，复活即产生无主僵尸会话）
      if (this.released || FqAvArbiter.isListenActive() || FqAvArbiter.videoHeldByOther(this.arbiterHolder)) {
        return;
      }
    } else {
      this.released = false;
      FqAvArbiter.yieldListen();
      FqAvArbiter.yieldAllVideoExcept(this.arbiterHolder);
    }
    if (this.ensureRetryTimer !== 0) {
      clearTimeout(this.ensureRetryTimer);
      this.ensureRetryTimer = 0;
    }
    this.sessionCreating = true;
    this.lastSessionType = sessionType;
    const epoch: number = this.sessionEpoch;
    const context: common.UIAbilityContext = this.context;
    avSession.createAVSession(context, this.sessionTag, sessionType === 'audio' ? 'audio' : 'video')
      .then((session: avSession.AVSession): void => {
        this.sessionCreating = false;
        if (epoch !== this.sessionEpoch) {
          // teardown 已作废本次创建：立即销毁防泄漏（先 deactivate 再 destroy）
          hilog.info(0x0001, TAG, `AVSession stale create discarded: ${this.sessionTag}`);
          session.deactivate().catch((error: BusinessError): void => {
            hilog.warn(0x0001, TAG, `AVSession deactivate failed (stale): ${error.message}`);
          }).then((): Promise<void> => session.destroy()).catch((error: BusinessError): void => {
            hilog.warn(0x0001, TAG, `AVSession destroy failed (stale): ${error.message}`);
          });
          return;
        }
        this.ensureRetryCount = 0;
        this.sessionValue = session;
        session.on('play', (): void => {
          this.onPlay();
        });
        session.on('pause', (): void => {
          this.onPause();
        });
        session.on('playNext', (): void => {
          this.onNext();
        });
        session.on('playPrevious', (): void => {
          this.onPrevious();
        });
        session.on('stop', (): void => {
          this.onStop();
        });
        session.on('seek', (time: number): void => {
          this.onSeek(time / 1000);
        });
        session.on('fastForward', (time?: number): void => {
          this.onFastForward(time !== undefined ? time / 1000 : 15);
        });
        session.on('rewind', (time?: number): void => {
          this.onRewind(time !== undefined ? time / 1000 : 15);
        });
        if (this.lastMeta !== null) {
          session.setAVMetadata(this.lastMeta).catch((): void => {
          });
        }
        this.bgPlayModeApplied = undefined;
        this.syncBackgroundPlayMode();
        session.activate().catch((error: BusinessError): void => {
          hilog.warn(0x0001, TAG, `AVSession activate failed: ${error.message}`);
        });
        hilog.info(0x0001, TAG,
          `AVSession created: ${this.sessionTag} ${sessionType}${implicit ? ' implicit' : ''}`);
      })
      .catch((error: BusinessError): void => {
        this.sessionCreating = false;
        const created: avSession.AVSession | null =
          epoch === this.sessionEpoch ? this.sessionValue : null;
        this.sessionValue = null;
        if (created !== null) {
          // 创建成功但注册链路异常：销毁防泄漏
          created.deactivate().catch((): void => {
          }).then((): Promise<void> => created.destroy()).catch((): void => {
          });
        } else {
          hilog.warn(0x0001, TAG, `AVSession create failed: ${error.message}`);
        }
        if (epoch !== this.sessionEpoch || this.ensureRetryCount >= 6) {
          return;
        }
        this.ensureRetryCount += 1;
        this.ensureRetryTimer = setTimeout((): void => {
          this.ensureRetryTimer = 0;
          this.ensureSession(sessionType, implicit);
        }, 600);
      });
  }

  /** 同步元数据（切集调用；封面像素未就绪时后台拉取后重发）。 */
  public updateMetadata(assetId: string, title: string, subtitle: string,
    durationSec: number, coverUrl: string): void {
    if (this.disposed) {
      return;
    }
    const meta: avSession.AVMetadata = {
      assetId: assetId,
      title: title,
      artist: subtitle,
      duration: Math.round(durationSec * 1000),
    };
    this.lastMeta = meta;
    if (this.coverPixel !== null && this.coverPixelUrl === coverUrl) {
      meta.mediaImage = this.coverPixel;
    } else if (coverUrl.length > 0 && coverUrl !== this.coverPixelUrl && !this.coverLoading) {
      this.loadCoverPixel(coverUrl);
    }
    const session: avSession.AVSession | null = this.sessionValue;
    if (session !== null) {
      session.setAVMetadata(meta).catch((): void => {
      });
    }
  }

  /** 同步播放态（1s tick 或状态突变调用；内部 1s 节流，force 立即）。 */
  public syncPlayback(force: boolean, playing: boolean, speed: number,
    positionSec: number): void {
    if (this.disposed) {
      return;
    }
    // 设置开关：后台播放/画中画均关闭时停长时任务 + 销毁 AVSession（无法后台播放）
    if (!this.bgAllowed()) {
      if (this.bgStarted) {
        this.stopBackground();
      }
      this.teardownSession();
    } else {
      this.ensureSession(this.lastSessionType, true);
      this.syncBackgroundPlayMode();
    }
    const session: avSession.AVSession | null = this.sessionValue;
    if (session === null) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastSyncAt < 1000) {
      return;
    }
    this.lastSyncAt = now;
    const state: avSession.PlaybackState = playing
      ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
      : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    const playback: avSession.AVPlaybackState = {
      state: state,
      speed: speed,
      position: {
        elapsedTime: Math.round(positionSec * 1000),
        updateTime: now,
      },
    };
    session.setAVPlaybackState(playback).catch((): void => {
    });
  }

  /** AVSession 后台播放模式随设置开关：开=允许后台播放，关=禁止（后台被系统停止）。 */
  private syncBackgroundPlayMode(): void {
    const session: avSession.AVSession | null = this.sessionValue;
    if (session === null) {
      return;
    }
    const enabled: boolean = this.bgAllowed();
    if (this.bgPlayModeApplied === enabled) {
      return;
    }
    this.bgPlayModeApplied = enabled;
    session.setBackgroundPlayMode(enabled
      ? avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY
      : avSession.BackgroundPlayMode.DISABLE_BACKGROUND_PLAY).catch((): void => {
      });
  }

  /** 后台能力开关：后台播放或画中画任一开启即放行（画中画退后台续播同样需要 AVSession/长时任务）。 */
  private bgAllowed(): boolean {
    return FqAppSettingsStore.isBackgroundAudio() || FqAppSettingsStore.isPipVideoEnabled();
  }

  /** 后台长时任务（audioPlayback：应用级引用计数共享，首个引用申请，release 释放）。 */
  public startBackground(): void {
    if (this.disposed) {
      return;
    }
    // 设置开关：后台播放/画中画均关闭后不再申请长时任务（无法后台播放）
    if (!this.bgAllowed()) {
      return;
    }
    if (this.bgStarted || this.context === null) {
      return;
    }
    this.bgStarted = true;
    FqMediaBgTask.acquire(this.context);
  }

  /** 销毁 AVSession（关闭后台播放/release：无胶囊/播控中心通知）。 */
  private teardownSession(): void {
    this.sessionEpoch += 1;
    this.sessionCreating = false;
    hilog.info(0x0001, TAG, `AVSession teardown: ${this.sessionTag}`);
    if (this.ensureRetryTimer !== 0) {
      clearTimeout(this.ensureRetryTimer);
      this.ensureRetryTimer = 0;
    }
    this.ensureRetryCount = 0;
    const session: avSession.AVSession | null = this.sessionValue;
    this.sessionValue = null;
    this.bgPlayModeApplied = undefined;
    if (session !== null) {
      // deactivate 失败也必须 destroy：泄漏会永久阻塞本应用后续 create（session is existed）
      session.deactivate().catch((error: BusinessError): void => {
        hilog.warn(0x0001, TAG, `AVSession deactivate failed: ${error.message}`);
      }).then((): Promise<void> => session.destroy()).catch((error: BusinessError): void => {
        hilog.warn(0x0001, TAG, `AVSession destroy failed: ${error.message}`);
      });
    }
    this.coverPixel = null;
    this.coverPixelUrl = '';
  }

  /** 释放（离页/让路）：停后台任务 + AVSession deactivate/destroy（保持仲裁注册，
   * 埋页仍可被后续接管者让路/在持有者消失后由 tick 隐式重建）。 */
  public release(): void {
    this.released = true;
    hilog.info(0x0001, TAG, `AVSession release: ${this.sessionTag}`);
    this.stopBackground();
    this.teardownSession();
    this.lastMeta = null;
    this.coverLoading = false;
  }

  /** 销毁（页面 aboutToDisappear）：注销仲裁注册 + 释放；此后实例永久禁用。 */
  public dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    hilog.info(0x0001, TAG, `AVSession dispose: ${this.sessionTag}`);
    if (this.arbiterHolder !== null) {
      FqAvArbiter.unregisterVideo(this.arbiterHolder);
      this.arbiterHolder = null;
    }
    this.release();
  }

  /** 封面拉取失败退避重试（页面 1s 心跳调用；成功后幂等、失败 5s 退避）。 */
  public ensureCoverLoaded(coverUrl: string): void {
    if (this.disposed || this.sessionValue === null || coverUrl.length === 0 || this.coverLoading) {
      return;
    }
    if (this.coverPixel !== null && this.coverPixelUrl === coverUrl) {
      return;
    }
    if (Date.now() < this.coverRetryAt) {
      return;
    }
    this.loadCoverPixel(coverUrl);
  }

  /** 拉取封面 → PixelMap（AVSession mediaImage；就绪后重发元数据）。 */
  private loadCoverPixel(url: string): void {
    this.coverLoading = true;
    const client: http.HttpRequest = http.createHttp();
    client.request(url, {
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: true,
      connectTimeout: 10000,
      readTimeout: 15000,
    })
      .then((response: http.HttpResponse): Promise<image.PixelMap> => {
        if (response.responseCode < 200 || response.responseCode >= 300
          || !(response.result instanceof ArrayBuffer)) {
          return Promise.reject(new Error(`cover fetch failed: ${response.responseCode}`));
        }
        const source: image.ImageSource = image.createImageSource(response.result);
        return source.createPixelMap();
      })
      .then((pixel: image.PixelMap): void => {
        this.coverPixel = pixel;
        this.coverPixelUrl = url;
        this.coverLoading = false;
        this.coverRetryAt = 0;
        const meta: avSession.AVMetadata | null = this.lastMeta;
        const session: avSession.AVSession | null = this.sessionValue;
        if (meta !== null && session !== null) {
          meta.mediaImage = pixel;
          session.setAVMetadata(meta).catch((): void => {
          });
        }
      })
      .catch((error: BusinessError): void => {
        this.coverLoading = false;
        // 退避 5s 后由页面心跳重试（此前失败即永久无封面）
        this.coverRetryAt = Date.now() + 5000;
        hilog.warn(0x0001, TAG, `cover fetch failed: ${error.message}`);
        client.destroy();
      });
  }

  private stopBackground(): void {
    if (!this.bgStarted) {
      return;
    }
    this.bgStarted = false;
    FqMediaBgTask.release();
  }
}

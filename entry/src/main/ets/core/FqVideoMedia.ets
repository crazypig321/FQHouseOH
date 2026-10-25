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
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FqVideoMedia';

export class FqVideoMedia {
  /** 播控命令回调（页面注入：播放/暂停/上一集/下一集/seek/停止）。 */
  onPlay: () => void = (): void => {};
  onPause: () => void = (): void => {};
  onPrevious: () => void = (): void => {};
  onNext: () => void = (): void => {};
  onSeek: (sec: number) => void = (_sec: number): void => {};
  onStop: () => void = (): void => {};

  private readonly sessionTag: string;
  private context: common.UIAbilityContext | null = null;
  private sessionValue: avSession.AVSession | null = null;
  private bgStarted: boolean = false;
  private lastSyncAt: number = 0;
  private coverPixel: image.PixelMap | null = null;
  private coverPixelUrl: string = '';
  /** 最近一次元数据（会话晚到/封面就绪后重发）。 */
  private lastMeta: avSession.AVMetadata | null = null;
  /** 封面拉取进行中（单飞：失败后下轮 updateMetadata 才重试）。 */
  private coverLoading: boolean = false;

  constructor(sessionTag: string) {
    this.sessionTag = sessionTag;
  }

  public init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 起播时确保 AVSession（sessionType：'video' 视频页 / 'audio' 听视频页）。
   * 显式开启后台播放模式：video 会话默认 DISABLE_BACKGROUND_PLAY，不设则退后台无实况窗胶囊。 */
  public ensureSession(sessionType: string): void {
    if (this.sessionValue !== null || this.context === null) {
      return;
    }
    const context: common.UIAbilityContext = this.context;
    avSession.createAVSession(context, this.sessionTag, sessionType === 'audio' ? 'audio' : 'video')
      .then((session: avSession.AVSession): Promise<void> => {
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
        this.sessionValue = session;
        if (this.lastMeta !== null) {
          session.setAVMetadata(this.lastMeta).catch((): void => {
          });
        }
        session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY).catch((): void => {
        });
        return session.activate();
      })
      .catch((error: BusinessError): void => {
        this.sessionValue = null;
        hilog.warn(0x0001, TAG, `AVSession create failed: ${error.message}`);
      });
  }

  /** 同步元数据（切集调用；封面像素未就绪时后台拉取后重发）。 */
  public updateMetadata(assetId: string, title: string, subtitle: string,
    durationSec: number, coverUrl: string): void {
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

  /** 后台长时任务（audioPlayback：首次播放申请，release 释放）。 */
  public startBackground(): void {
    if (this.bgStarted || this.context === null) {
      return;
    }
    const context: common.UIAbilityContext = this.context;
    this.bgStarted = true;
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent): void => {
        backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent)
          .then((): void => {
            hilog.info(0x0001, TAG, 'background audioPlayback task started');
          })
          .catch((error: BusinessError): void => {
            this.bgStarted = false;
            hilog.warn(0x0001, TAG, `startBackgroundRunning failed: ${error.message}`);
          });
      })
      .catch((error: BusinessError): void => {
        this.bgStarted = false;
        hilog.warn(0x0001, TAG, `getWantAgent failed: ${error.message}`);
      });
  }

  /** 释放（离页/让路）：停后台任务 + AVSession deactivate/destroy。 */
  public release(): void {
    this.stopBackground();
    const session: avSession.AVSession | null = this.sessionValue;
    this.sessionValue = null;
    if (session !== null) {
      session.deactivate().then((): Promise<void> => session.destroy()).catch((): void => {
      });
    }
    this.coverPixel = null;
    this.coverPixelUrl = '';
    this.lastMeta = null;
    this.coverLoading = false;
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
        const meta: avSession.AVMetadata | null = this.lastMeta;
        const session: avSession.AVSession | null = this.sessionValue;
        if (meta !== null && session !== null) {
          meta.mediaImage = pixel;
          session.setAVMetadata(meta).catch((): void => {
          });
        }
      })
      .catch((): void => {
        this.coverLoading = false;
        client.destroy();
      });
  }

  private stopBackground(): void {
    if (!this.bgStarted || this.context === null) {
      return;
    }
    this.bgStarted = false;
    backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
    });
  }
}

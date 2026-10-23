/**
 * 听书播放引擎（对齐 musicfreeOH PlayerEngine 的 avPlayer 子集，去 PCM/EQ）：
 * 状态机封装 + 音频打断转暂停 + 倍速映射。
 * 会话层（FqAudioSession）负责章节/音色/历史；本文件只管一个音频流。
 */

import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export enum FqPlayState {
  Idle = 'idle',
  Initialized = 'initialized',
  Prepared = 'prepared',
  Playing = 'playing',
  Paused = 'paused',
  Completed = 'completed',
  Stopped = 'stopped',
  Error = 'error',
  Released = 'released',
}

const FQ_WAIT_INITIALIZED_MS: number = 8000;

function fqWait(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

export class FqAudioEngine {
  private player: media.AVPlayer | null = null;
  private createPromise: Promise<media.AVPlayer> | null = null;
  private stateInternal: FqPlayState = FqPlayState.Idle;
  private rateValue: number = 1;

  /** 引擎状态翻转（completed/error 之外的状态迁移）。 */
  onStateChanged: (state: FqPlayState) => void = (_state: FqPlayState) => {
  };
  /** 当前流播完（completed）。 */
  onEndReached: () => void = () => {
  };
  onError: (message: string) => void = (_message: string) => {
  };
  /** 被其他应用/系统打断转暂停（会话层同步 wantPlay/播控卡片）。 */
  onPausedByInterrupt: () => void = () => {
  };

  get state(): FqPlayState {
    return this.stateInternal;
  }

  /** 当前播放位置（秒）。 */
  get positionSec(): number {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return 0;
    }
    return player.currentTime / 1000;
  }

  /** 总时长（秒；未知为 0）。 */
  get durationSec(): number {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return 0;
    }
    const duration: number = player.duration;
    return duration > 0 ? duration / 1000 : 0;
  }

  get isPlaying(): boolean {
    return this.stateInternal === FqPlayState.Playing;
  }

  private ensurePlayer(): Promise<media.AVPlayer> {
    if (this.player !== null) {
      return Promise.resolve(this.player);
    }
    if (this.createPromise === null) {
      this.createPromise = media.createAVPlayer().then((player: media.AVPlayer) => {
        this.player = player;
        this.setupListeners(player);
        this.createPromise = null;
        return player;
      });
    }
    return this.createPromise;
  }

  private setupListeners(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason) => {
      this.stateInternal = FqAudioEngine.mapState(state);
      if (state === 'completed') {
        this.onEndReached();
      }
      this.onStateChanged(this.stateInternal);
    });
    player.on('error', (error: BusinessError) => {
      hilog.error(0x0001, 'FqAudioEngine', `avPlayer error: ${error.message}`);
      this.stateInternal = FqPlayState.Error;
      this.onError(error.message);
    });
    player.on('audioInterrupt', (info: audio.InterruptEvent) => {
      this.handleInterrupt(info);
    });
  }

  private handleInterrupt(info: audio.InterruptEvent): void {
    if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.pause().catch((): void => {
      });
      this.onPausedByInterrupt();
    }
  }

  private static mapState(state: media.AVPlayerState): FqPlayState {
    if (state === 'idle') {
      return FqPlayState.Idle;
    }
    if (state === 'initialized') {
      return FqPlayState.Initialized;
    }
    if (state === 'prepared') {
      return FqPlayState.Prepared;
    }
    if (state === 'playing') {
      return FqPlayState.Playing;
    }
    if (state === 'paused') {
      return FqPlayState.Paused;
    }
    if (state === 'completed') {
      return FqPlayState.Completed;
    }
    if (state === 'stopped') {
      return FqPlayState.Stopped;
    }
    if (state === 'released') {
      return FqPlayState.Released;
    }
    return FqPlayState.Error;
  }

  /** 回收到 idle（error/released 重建实例）。 */
  private async recycle(): Promise<media.AVPlayer> {
    const player: media.AVPlayer = await this.ensurePlayer();
    const state: media.AVPlayerState = player.state;
    if (state === 'idle') {
      return player;
    }
    if (state === 'error' || state === 'released') {
      try {
        player.release();
      } catch (error) {
        // 忽略释放失败
      }
      this.player = null;
      this.stateInternal = FqPlayState.Idle;
      return this.ensurePlayer();
    }
    await player.reset();
    this.stateInternal = FqPlayState.Idle;
    return player;
  }

  /** 加载音源并 prepare 完成（网络 http(s) 地址）。 */
  async load(url: string): Promise<void> {
    const player: media.AVPlayer = await this.recycle();
    player.url = url;
    // url 赋值后播放器异步迁移 idle → initialized，必须等迁移完成才能 prepare
    await FqAudioEngine.waitInitialized(player, FQ_WAIT_INITIALIZED_MS);
    await player.prepare();
    if (this.rateValue !== 1) {
      player.setSpeed(FqAudioEngine.speedToEnum(this.rateValue));
    }
  }

  private static async waitInitialized(player: media.AVPlayer,
    timeoutMs: number): Promise<void> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const state: media.AVPlayerState = player.state;
      if (state === 'initialized' || state === 'prepared') {
        return;
      }
      await fqWait(20);
    }
    const state: media.AVPlayerState = player.state;
    if (state !== 'initialized' && state !== 'prepared') {
      throw new Error(`播放器加载源超时（state=${state}）`);
    }
  }

  async play(): Promise<void> {
    const player: media.AVPlayer = await this.ensurePlayer();
    const state: media.AVPlayerState = player.state;
    if (state === 'playing') {
      return;
    }
    if (state === 'completed') {
      // 播完重播由会话层显式 seek(0) 后处理；这里只接受 prepared/paused
      return;
    }
    if (state !== 'prepared' && state !== 'paused') {
      throw new Error('player is not prepared');
    }
    await player.play();
  }

  async pause(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (state !== 'playing' && state !== 'completed') {
      return;
    }
    await player.pause();
  }

  /** 跳转（秒；非法值钳位到 0）。 */
  seek(positionSec: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (!(positionSec > 0)) {
      positionSec = 0;
    }
    let ms: number = Math.floor(positionSec * 1000);
    if (ms < 0) {
      ms = 0;
    }
    const state: media.AVPlayerState = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused'
      || state === 'completed') {
      player.seek(ms, media.SeekMode.SEEK_CLOSEST);
    }
  }

  /** 倍速（0.5 ~ 2）。 */
  setRate(rate: number): void {
    this.rateValue = rate;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused'
      || state === 'completed') {
      player.setSpeed(FqAudioEngine.speedToEnum(rate));
    }
  }

  async release(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    this.stateInternal = FqPlayState.Released;
    if (player !== null) {
      try {
        await player.release();
      } catch (error) {
        // 忽略
      }
    }
  }

  private static speedToEnum(rate: number): media.PlaybackSpeed {
    if (rate < 0.625) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (rate < 0.875) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (rate < 1.125) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (rate < 1.375) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (rate < 1.625) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (rate < 1.875) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }
}

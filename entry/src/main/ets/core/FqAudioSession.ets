/**
 * 听书会话（对齐 fqapp AudioPlaybackController + AudioPlaybackScope 语义）。
 *
 * 应用级持久单例：页面 pop 不停播；close 仅由 AVSession stop 命令 /
 * EntryAbility onDestroy 触发。负责：
 * - 章节装载（generation 取消、NO_THIS_TONE 兜底、历史恢复、播完态恢复）；
 * - 音色切换（智能朗读 toneId 重载 / 真人讲书跨书 switchBookVersion）；
 * - 离线朗读（CoreSpeechKit textToSpeech：正文句读切分串行合成，
 *   playType 0 仅合成 + onData PCM 由本应用 AudioRenderer 自渲染，
 *   音频归属本应用（实况窗胶囊跟随 AVSession），与在线听书共享章节
 *   进度 / AVSession / 长时任务 / 睡眠定时，随时互切）；
 * - 历史持久化（5s 周期 + 暂停/切章/关闭即时写）；
 * - 睡眠定时（分钟档 + 播完本章）；
 * - AVSession 同步（胶囊/播控中心，1s 节流）与播控命令；
 * - 后台长时任务（首次播放申请，暂停保持，close 释放）。
 */

import avSession from '@ohos.multimedia.avsession';
import audio from '@ohos.multimedia.audio';
import image from '@ohos.multimedia.image';
import http from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { BusinessError, Callback, ErrorCallback } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqAudioEngine } from './FqAudioEngine';
import { FqMediaBgTask } from './FqMediaBgTask';
import { FqAudioHistory, FqListenRecord } from './FqAudioHistory';
import { FqReadStatsStore } from './FqReadStatsStore';
import { FqAppSettingsStore } from './FqAppSettingsStore';
import { FqBackend, fqErrorMessage } from './FqBackend';
import { FqAudioCacheStore } from './FqAudioCacheStore';
import { FqChapterCacheStore } from './FqChapterCacheStore';
import { FqLocalBookStore } from './FqLocalBookStore';
import { FqChapter } from '../model/FqModels';
import { FqNormalizedChapter } from '../reader/ReaderTypes';
import {
  FqAudioSource,
  FqAudioTone,
  FqAudioToneSet,
  FqAudioVoice,
  fqDefaultVoices,
  FqRelatedWork,
  FqSubtitleCue,
  FqSubtitleTrack,
  fqEmptySubtitleTrack,
  fqEmptyToneSet,
} from '../model/FqAudioModels';
import { fqMergeToneVoices, fqUniqueTones } from './FqAudioParser';

const TAG: string = 'FqAudioSession';

/** 离线朗读单次合成片段上限（字符，句读边界切分；官方接口单次上限 10000）。 */
const FQ_TTS_PIECE_MAX: number = 280;

/** 预合成 lookahead 上限（字节；16kHz/16bit/单声道 32KB/s，约 20 秒音频）。 */
const FQ_TTS_LOOKAHEAD_BYTES: number = 640000;

/** onData 乱序到达的合成音频块（sequence 排序缓冲）。 */
class FqTtsAudioChunk {
  readonly seq: number;
  readonly data: ArrayBuffer;

  constructor(seq: number, data: ArrayBuffer) {
    this.seq = seq;
    this.data = data;
  }
}

/** 离线朗读可选音色。 */
export class FqTtsVoice {
  /** textToSpeech person 音色 id。 */
  readonly person: number;
  readonly name: string;
  readonly description: string;
  /** 是否已安装（未安装音色选中后创建引擎失败会回退）。 */
  readonly installed: boolean;

  constructor(person: number, name: string, description: string, installed: boolean) {
    this.person = person;
    this.name = name;
    this.description = description;
    this.installed = installed;
  }
}

/** 章节装载参数。 */
export class FqChapterOpenOptions {
  readonly toneId: string;
  /** 恢复位置（秒）。 */
  readonly positionSec: number;
  readonly autoplay: boolean;
  /** 恢复播完态（seek 至末尾、不自动播）。 */
  readonly completed: boolean;

  constructor(toneId: string, positionSec: number, autoplay: boolean, completed: boolean) {
    this.toneId = toneId;
    this.positionSec = positionSec;
    this.autoplay = autoplay;
    this.completed = completed;
  }
}

@ObservedV2
export class FqAudioSession {
  // ---- 基本标识 ----
  @Trace bookId: string = '';
  @Trace title: string = '';
  @Trace cover: string = '';
  /** 目录 tab（'听书' / '小说'）。 */
  tab: string = '听书';

  // ---- 章节与装饰 ----
  @Trace chapters: FqChapter[] = [];
  @Trace index: number = 0;
  @Trace toneSet: FqAudioToneSet = fqEmptyToneSet();
  /** detail CSV voices（与 /tones 音色名合并后；智能朗读回退源）。 */
  @Trace voices: FqAudioVoice[] = fqDefaultVoices();
  @Trace relatedWorks: FqRelatedWork[] = [];
  @Trace subtitleTrack: FqSubtitleTrack = fqEmptySubtitleTrack();
  @Trace excerpt: string = '';
  private itemId: string = '';
  private rawVoices: FqAudioVoice[] = fqDefaultVoices();
  private voicesPromise: Promise<FqAudioVoice[]> | null = null;

  // ---- 播放状态 ----
  @Trace hasSession: boolean = false;
  @Trace loading: boolean = false;
  @Trace switchingVersion: boolean = false;
  @Trace wantPlay: boolean = false;
  @Trace completed: boolean = false;
  @Trace autoAdvance: boolean = true;
  @Trace errorMessage: string = '';
  @Trace positionSec: number = 0;
  @Trace durationSec: number = 0;
  @Trace rate: number = 1;
  @Trace toneId: string = '0';

  // ---- 睡眠定时 ----
  private sleepDeadline: number = 0;
  @Trace sleepRemainingSec: number = -1;

  @Trace sleepAtChapterEnd: boolean = false;

  /** 定时关闭所选分钟档（0 = 未选分钟档）。 */
  @Trace sleepMinutesChoice: number = 0;

  // ---- 离线朗读（CoreSpeechKit textToSpeech）----
  /** 离线朗读模式（与在线听书互斥，共享章节/历史/AVSession/长时任务，随时互切）。 */
  @Trace ttsMode: boolean = false;
  /** 当前章朗读进度（0~1，字符偏移比）。 */
  @Trace ttsProgress: number = 0;
  /** 当前朗读片段原文（阅读页边听边读段落高亮用）。 */
  @Trace ttsCueText: string = '';
  /** 当前音色（textToSpeech person）。 */
  @Trace ttsVoicePerson: number = 0;
  /** 可选音色（listVoices 动态加载，失败回退静态表）。 */
  @Trace ttsVoices: FqTtsVoice[] = FqAudioSession.fallbackTtsVoices();
  /** 音色列表来自系统 listVoices（false = 静态回退表，音色下载不可用）。 */
  @Trace ttsVoicesFromSystem: boolean = false;
  /** 正在下载的音色 person（-1 无）。 */
  @Trace ttsVoiceDownloading: number = -1;
  /** 音色下载进度百分比（-1 未知/待开始）。 */
  @Trace ttsVoiceDownloadPercent: number = -1;
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private ttsEnginePerson: number = -1;
  private ttsVoicesLoaded: boolean = false;
  /** listVoices 原始结果（downloadVoice 参数源：language/person/style）。 */
  private ttsVoiceInfos: textToSpeech.VoiceInfo[] = [];
  /** listVoices / downloadVoice requestId 序号（与时间戳拼接成跨重启唯一 id）。 */
  private ttsVoicesQuerySerial: number = 0;
  private ttsVoiceDownloadSerial: number = 0;
  private ttsText: string = '';
  private ttsOffset: number = 0;
  private ttsPieceStart: number = 0;
  private ttsPieceEnd: number = 0;
  private ttsSerial: number = 0;
  /** 待重启朗读的字符偏移（stop→onStop 后续读；-1 无待重启）。 */
  private ttsRestartOffset: number = -1;
  private ttsRestartTimer: number = -1;
  /** 章节装载中暂存的定位 cue（正文就绪后按原文定位）。 */
  private ttsPendingCue: string = '';
  /** 切回在线时按比例续播的字符比（-1 无；新章时长就绪后换算秒级位置）。 */
  private pendingOnlineFraction: number = -1;
  /** 朗读估算总时长（秒；AVSession 实况窗/播控展示用，不影响实际朗读）。 */
  private ttsEstimatedDurationSec: number = 0;
  // ---- 自渲染管线（playType 0 + onData PCM → 本应用 AudioRenderer）----
  private ttsRenderer: audio.AudioRenderer | null = null;
  /** 待写入渲染器的 PCM 队列。 */
  private ttsQueue: ArrayBuffer[] = [];
  /** 写泵占用标记（按渲染器实例防并发泵）。 */
  private ttsPumpingFor: audio.AudioRenderer | null = null;
  /** 合成中片段已收 PCM 字节。 */
  private ttsPieceBytes: number = 0;
  /** 已完成片段累计 PCM 字节。 */
  private ttsTotalSynthBytes: number = 0;
  /** 已完成片段的字符区间与累计字节边界（播放位置→片段映射）。 */
  private ttsPieceStarts: number[] = [];
  private ttsPieceEnds: number[] = [];
  private ttsPieceBytesAtEnd: number[] = [];
  /** 预合成游标（下一片段起始字符偏移，先于播放推进）。 */
  private ttsSynthOffset: number = 0;
  private ttsSynthInFlight: boolean = false;
  private ttsSynthDone: boolean = false;
  private ttsExpectedSeq: number = 0;
  private ttsPendingChunks: FqTtsAudioChunk[] = [];
  // ---- 内部 ----
  private context: common.UIAbilityContext | null = null;
  private readonly engine: FqAudioEngine = new FqAudioEngine();
  private generation: number = 0;
  /** 装饰专用代际：openChapter 不递增，避免装饰回调被章节装载判过期。 */
  private decorationsGeneration: number = 0;
  private tonesPromise: Promise<FqAudioToneSet> | null = null;
  private tickTimer: number = -1;
  private lastAvSyncAt: number = 0;
  private lastHistorySaveAt: number = 0;
  /** 今日已读统计：播放中 tick 计数，满 10 次（5s）累计一次。 */
  private statPlayingTicks: number = 0;
  private avSessionValue: avSession.AVSession | null = null;
  /** 会话创建进行中（防同标签并发 create：服务侧报 session is existed 且引用被置空泄漏）。 */
  private avCreating: boolean = false;
  /** 会话代际（close/teardown 后作废在途创建）。 */
  private avEpoch: number = 0;
  private bgStarted: boolean = false;
  /** AVSession 后台播放模式最近一次已应用值（undefined=未应用，会话新建后重设）。 */
  private bgPlayModeApplied: boolean | undefined = undefined;
  private coverPixel: image.PixelMap | null = null;
  private coverPixelUrl: string = '';

  constructor() {
    this.engine.onEndReached = (): void => {
      this.handleChapterEnd();
    };
    this.engine.onError = (message: string): void => {
      this.errorMessage = message.length > 0 ? message : '播放失败，请稍后重试';
      this.wantPlay = false;
      this.syncAvPlaybackState(true);
    };
    this.engine.onPausedByInterrupt = (): void => {
      this.wantPlay = false;
      this.persistHistory();
      this.syncAvPlaybackState(true);
    };
  }

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  public init(context: common.UIAbilityContext): void {
    this.context = context;
    FqAudioHistory.init(context);
    FqChapterCacheStore.init(context);
    FqLocalBookStore.init(context);
  }

  /** 当前章节（无目录时 null）。 */
  get chapter(): FqChapter | null {
    const chapter: FqChapter | undefined = this.chapters[this.index];
    return chapter !== undefined ? chapter : null;
  }

  get isPlaying(): boolean {
    return this.wantPlay && !this.completed && !this.loading && this.errorMessage.length === 0;
  }

  get hasFixedTone(): boolean {
    return this.toneSet.hasFixedTone;
  }

  get hasNextChapter(): boolean {
    return this.index + 1 < this.chapters.length;
  }

  get sleepActive(): boolean {
    return this.sleepDeadline > 0 || this.sleepAtChapterEnd;
  }

  /**
   * 打开一本书（页面进入时调用）。同书重进不清状态（续播）。
   */
  public async open(bookId: string, tab: string, title: string, cover: string,
    presetChapters?: FqChapter[]): Promise<void> {
    if (this.hasSession && this.bookId === bookId) {
      return;
    }
    this.generation += 1;
    const gen: number = this.generation;
    this.hasSession = true;
    this.bookId = bookId;
    this.tab = tab;
    this.title = title;
    this.cover = cover;
    this.chapters = [];
    this.toneSet = fqEmptyToneSet();
    this.voices = fqDefaultVoices();
    this.rawVoices = fqDefaultVoices();
    this.voicesPromise = null;
    this.relatedWorks = [];
    this.subtitleTrack = fqEmptySubtitleTrack();
    this.excerpt = '';
    this.index = 0;
    this.itemId = '';
    this.toneId = '0';
    this.positionSec = 0;
    this.durationSec = 0;
    this.completed = false;
    this.loading = true;
    this.switchingVersion = false;
    this.errorMessage = '';
    this.wantPlay = false;
    this.rate = 1;
    this.ttsMode = false;
    this.ttsProgress = 0;
    this.ttsCueText = '';
    this.ttsVoicePerson = FqAppSettingsStore.getTtsPerson();
    this.ttsText = '';
    this.ttsOffset = 0;
    this.ttsSerial += 1;
    this.ttsRestartOffset = -1;
    this.ttsPendingCue = '';
    this.pendingOnlineFraction = -1;
    this.ttsEstimatedDurationSec = 0;
    this.cancelTtsRestartTimer();
    this.flushTtsAudio();
    this.startTick();
    try {
      let chapters: FqChapter[] = [];
      if (presetChapters !== undefined && presetChapters.length > 0) {
        chapters = presetChapters.slice();
      } else {
        chapters = await FqBackend.get().directoryChapters(bookId, tab);
      }
      if (gen !== this.generation) {
        return;
      }
      if (chapters.length === 0) {
        throw new Error('暂无章节');
      }
      this.chapters = chapters;
    } catch (error) {
      if (gen !== this.generation) {
        return;
      }
      this.loading = false;
      this.errorMessage = fqErrorMessage(error);
      return;
    }
    // 历史恢复
    let openIndex: number = 0;
    let positionSec: number = 0;
    let toneId: string = '0';
    let completed: boolean = false;
    let autoplay: boolean = true;
    const record: FqListenRecord | null = FqAudioHistory.get(bookId);
    if (record !== null) {
      if (record.chapterIndex >= 0 && record.chapterIndex < this.chapters.length) {
        openIndex = record.chapterIndex;
      }
      positionSec = record.positionSec;
      toneId = record.toneId.length > 0 ? record.toneId : '0';
      completed = record.completed;
      if (record.mode === 'tts') {
        // 离线朗读续读：恢复全局语速，位置从章首（秒级位置无法换算）
        this.ttsMode = true;
      this.rate = FqAppSettingsStore.getTtsRate();
      this.refreshTtsVoices(false);
      } else if (record.rate > 0) {
        this.rate = record.rate;
      }
      autoplay = !completed;
    }
    this.loadDecorations(this.nextDecorationsGeneration());
    if (this.ttsMode) {
      await this.openTtsChapter(openIndex, autoplay, completed ? 1 : 0, '');
      return;
    }
    await this.openChapter(openIndex, new FqChapterOpenOptions(toneId, positionSec, autoplay, completed));
  }

  /** 装饰代际：open/close/switchBookVersion 递增，openChapter 不递增。 */
  private nextDecorationsGeneration(): number {
    this.decorationsGeneration += 1;
    return this.decorationsGeneration;
  }

  /** 释放会话（AVSession stop / Ability destroy）。 */
  public close(): void {
    if (!this.hasSession) {
      return;
    }
    this.generation += 1;
    this.decorationsGeneration += 1;
    this.persistHistory();
    this.hasSession = false;
    this.wantPlay = false;
    this.completed = false;
    this.loading = false;
    this.switchingVersion = false;
    this.errorMessage = '';
    this.sleepDeadline = 0;
    this.sleepAtChapterEnd = false;
    this.sleepRemainingSec = -1;
    this.sleepMinutesChoice = 0;
    this.tonesPromise = null;
    this.voicesPromise = null;
    this.ttsMode = false;
    this.ttsProgress = 0;
    this.ttsCueText = '';
    this.ttsText = '';
    this.ttsOffset = 0;
    this.ttsSerial += 1;
    this.ttsRestartOffset = -1;
    this.ttsPendingCue = '';
    this.pendingOnlineFraction = -1;
    this.ttsEstimatedDurationSec = 0;
    this.cancelTtsRestartTimer();
    this.flushTtsAudio();
    this.shutdownTtsEngine();
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    this.engine.release().catch((): void => {
    });
    this.stopBackgroundTask();
    this.teardownAvSession();
  }

  // ---------------------------------------------------------------------------
  // 播放控制
  // ---------------------------------------------------------------------------

  public play(): void {
    if (!this.hasSession) {
      return;
    }
    this.ensureAvSession();
    this.startBackgroundTask();
    if (this.completed) {
      this.completed = false;
      if (this.ttsMode) {
        this.ttsOffset = 0;
        this.ttsProgress = 0;
      } else {
        this.positionSec = 0;
        this.engine.seek(0);
      }
    }
    if (this.loading) {
      // 章节装载中：openChart 完成后按 wantPlay 起播
      this.wantPlay = true;
      this.syncAvPlaybackState(true);
      return;
    }
    this.wantPlay = true;
    if (this.ttsMode) {
      this.playTts();
    } else {
      this.engine.play().catch((error: BusinessError): void => {
        this.wantPlay = false;
        this.errorMessage = fqErrorMessage(error);
      });
    }
    this.syncAvPlaybackState(true);
  }

  public pause(): void {
    if (!this.hasSession) {
      return;
    }
    this.wantPlay = false;
    if (this.ttsMode) {
      this.stopTtsSpeak();
    } else {
      this.engine.pause().catch((): void => {
      });
    }
    this.persistHistory();
    this.syncAvPlaybackState(true);
  }

  /** 主播放/暂停键：错误态点击 = 重试。 */
  public togglePlayPause(): void {
    if (this.errorMessage.length > 0 && !this.loading) {
      if (this.ttsMode) {
        this.openTtsChapter(this.index, true, 0, '');
      } else {
        this.openChapter(this.index, new FqChapterOpenOptions(this.toneId, this.positionSec, true, false));
      }
      return;
    }
    if (this.wantPlay && !this.completed) {
      this.pause();
    } else {
      this.play();
    }
  }

  public seekTo(positionSec: number): void {
    if (!this.hasSession) {
      return;
    }
    if (this.ttsMode) {
      // 播控中心拖动：时间轴为估算时长，反算字符进度比后走 TTS 定位
      if (this.ttsEstimatedDurationSec > 0) {
        let fraction: number = positionSec / this.ttsEstimatedDurationSec;
        if (fraction < 0) {
          fraction = 0;
        }
        if (fraction > 1) {
          fraction = 1;
        }
        this.seekTts(fraction);
      }
      return;
    }
    let position: number = positionSec;
    if (position < 0) {
      position = 0;
    }
    if (this.durationSec > 0 && position > this.durationSec) {
      position = this.durationSec;
    }
    this.positionSec = position;
    if (this.completed && position < this.durationSec) {
      this.completed = false;
    }
    this.engine.seek(position);
    this.syncAvPlaybackState(true);
    this.persistHistory();
  }

  public next(): void {
    if (this.index + 1 < this.chapters.length) {
      this.openChapter(this.index + 1,
        new FqChapterOpenOptions(this.toneId, 0, this.wantPlay && !this.completed, false));
    }
  }

  public previous(): void {
    if (this.index > 0) {
      this.openChapter(this.index - 1,
        new FqChapterOpenOptions(this.toneId, 0, this.wantPlay && !this.completed, false));
    } else if (this.ttsMode) {
      this.seekTts(0);
    } else {
      this.seekTo(0);
    }
  }

  public setRate(rate: number): void {
    if (this.ttsMode) {
      this.setTtsRate(rate);
      return;
    }
    this.rate = rate;
    this.engine.setRate(rate);
    this.persistHistory();
    this.syncAvPlaybackState(true);
  }

  public setAutoAdvance(enabled: boolean): void {
    this.autoAdvance = enabled;
  }

  // ---------------------------------------------------------------------------
  // 音色 / 版本切换
  // ---------------------------------------------------------------------------

  /** 选智能朗读音色；固定录音书内选择时切到关联小说。 */
  public selectTone(tone: FqAudioTone): void {
    if (!this.hasSession || tone.id.length === 0 || tone.id === this.toneId) {
      return;
    }
    if (this.toneSet.hasFixedTone) {
      const related: FqRelatedWork | null = this.toneSet.relatedNovel;
      if (related !== null && related.id.length > 0 && related.id !== this.bookId) {
        this.switchBookVersion(related.id,
          related.title.length > 0 ? related.title : this.title,
          related.cover.length > 0 ? related.cover : this.cover, tone.id, '小说');
      }
      return;
    }
    this.openChapter(this.index,
      new FqChapterOpenOptions(tone.id, this.positionSec, this.wantPlay && !this.completed,
        this.completed));
  }

  /** 选真人讲书（跨书到有声书版本）。 */
  public selectNarrator(tone: FqAudioTone): void {
    if (!this.hasSession || tone.id.length === 0 || tone.id === this.bookId) {
      return;
    }
    this.switchBookVersion(tone.id, tone.title.length > 0 ? tone.title : this.title, this.cover,
      '0', '听书');
  }

  /** 切换书籍版本（真人讲书 ↔ 原小说）。 */
  public async switchBookVersion(targetId: string, title: string, cover: string,
    toneId: string, tab: string): Promise<void> {
    if (!this.hasSession || this.switchingVersion || targetId.length === 0
      || targetId === this.bookId) {
      return;
    }
    this.switchingVersion = true;
    const gen: number = ++this.generation;
    const wasPlaying: boolean = this.wantPlay && !this.completed;
    try {
      const chapters: FqChapter[] = await FqBackend.get().directoryChapters(targetId, tab);
      if (gen !== this.generation) {
        return;
      }
      if (chapters.length === 0) {
        throw new Error('所选声音版本暂无目录');
      }
      const start: number = this.narratorChapterIndex(chapters);
      this.persistHistory();
      this.bookId = targetId;
      this.title = title;
      this.cover = cover;
      this.tab = tab;
      this.chapters = chapters;
      this.index = start;
      this.positionSec = 0;
      this.durationSec = 0;
      this.toneId = toneId;
      this.excerpt = '';
      this.subtitleTrack = fqEmptySubtitleTrack();
      this.toneSet = fqEmptyToneSet();
      this.voices = fqDefaultVoices();
      this.rawVoices = fqDefaultVoices();
      this.voicesPromise = null;
      this.relatedWorks = [];
      this.tonesPromise = null;
      this.loadDecorations(this.nextDecorationsGeneration());
      await this.openChapter(start, new FqChapterOpenOptions(toneId, 0, wasPlaying, false));
    } catch (error) {
      if (gen === this.generation) {
        this.errorMessage = fqErrorMessage(error);
      }
    } finally {
      this.switchingVersion = false;
    }
  }

  /** 章节装载（generation 取消 + NO_THIS_TONE 兜底 + 装饰后台加载）。 */
  public async openChapter(index: number, options: FqChapterOpenOptions): Promise<void> {
    if (!this.hasSession) {
      return;
    }
    if (index < 0 || index >= this.chapters.length) {
      return;
    }
    // 离线朗读模式：同章切换走朗读装载（秒级位置不适用，从章首朗读）
    if (this.ttsMode) {
      await this.openTtsChapter(index, options.autoplay || this.wantPlay, 0, '');
      return;
    }
    const chapter: FqChapter = this.chapters[index];
    const gen: number = ++this.generation;
    const wantAutoplay: boolean = options.autoplay || this.wantPlay;
    this.index = index;
    this.itemId = chapter.itemId;
    if (options.toneId.length > 0) {
      this.toneId = options.toneId;
    }
    this.completed = options.completed;
    this.loading = true;
    // 切章先停旧音频：取流/装载期间旧章立即静下来，新章就绪后起播
    await this.engine.pause().catch((): void => {
    });
    this.errorMessage = '';
    this.excerpt = '';
    this.subtitleTrack = fqEmptySubtitleTrack();
    this.lastHistorySaveAt = Date.now();
    try {
      const source: FqAudioSource = await this.fetchSource(chapter.itemId, this.toneId, gen);
      if (gen !== this.generation) {
        return;
      }
      await this.engine.load(source.url);
      if (gen !== this.generation) {
        return;
      }
      const duration: number = source.durationSec > 0 ? source.durationSec : this.engine.durationSec;
      if (duration > 0) {
        this.durationSec = duration;
      }
      this.engine.setRate(this.rate);
      let position: number = options.positionSec;
      if (this.pendingOnlineFraction >= 0) {
        // 离线朗读切回：按字符比换算秒级位置（时长未知则回退章首）
        const fraction: number = this.pendingOnlineFraction;
        this.pendingOnlineFraction = -1;
        if (this.durationSec > 1 && fraction > 0) {
          position = Math.min(this.durationSec - 1, Math.floor(fraction * this.durationSec));
        }
      }
      if (options.completed) {
        // 播完态恢复：seek 至末尾
        position = this.durationSec;
      } else if (position > 0 && this.durationSec > 0 && position > this.durationSec - 1) {
        position = 0;
      }
      if (position < 0) {
        position = 0;
      }
      this.positionSec = position;
      this.engine.seek(position);
      this.completed = options.completed;
      if (wantAutoplay && !options.completed) {
        this.wantPlay = true;
        // 自动起播不走 play()，需在此申请 audioPlayback 长时任务，否则退后台数秒后被静音
        this.startBackgroundTask();
        try {
          await this.engine.play();
        } catch (playError) {
          this.wantPlay = false;
          this.errorMessage = fqErrorMessage(playError);
        }
      } else {
        this.wantPlay = false;
      }
      this.loading = false;
      this.ensureAvSession();
      this.syncAvMetadata();
      this.syncAvPlaybackState(true);
      this.persistHistory();
      this.loadExcerpt(gen, chapter.itemId);
      this.loadSubtitles(gen, chapter.itemId, this.toneId);
    } catch (error) {
      if (gen !== this.generation) {
        return;
      }
      this.wantPlay = false;
      this.loading = false;
      this.errorMessage = fqErrorMessage(error);
      this.persistHistory();
      hilog.error(0x0001, TAG, `openChapter failed: ${this.errorMessage}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 睡眠定时
  // ---------------------------------------------------------------------------

  /** minutes <= 0 关闭定时。 */
  public setSleepMinutes(minutes: number): void {
    this.sleepAtChapterEnd = false;
    this.sleepMinutesChoice = minutes > 0 ? minutes : 0;
    if (minutes <= 0) {
      this.sleepDeadline = 0;
      this.sleepRemainingSec = -1;
      return;
    }
    this.sleepDeadline = Date.now() + minutes * 60000;
    this.sleepRemainingSec = minutes * 60;
  }

  public setSleepAtChapterEnd(): void {
    this.sleepAtChapterEnd = true;
    this.sleepMinutesChoice = 0;
    this.sleepDeadline = 0;
    this.sleepRemainingSec = -1;
  }

  public clearSleep(): void {
    this.sleepDeadline = 0;
    this.sleepRemainingSec = -1;
    this.sleepAtChapterEnd = false;
    this.sleepMinutesChoice = 0;
  }

  // ---------------------------------------------------------------------------
  // 离线朗读（CoreSpeechKit textToSpeech）
  // ---------------------------------------------------------------------------

  /** 切到离线朗读：保留当前章，按当前进度续读（字幕 cue 原文定位，比例兜底）。 */
  public switchToTts(): void {
    if (!this.hasSession || this.ttsMode || this.loading || this.switchingVersion) {
      return;
    }
    this.persistHistory();
    // 位置携带：优先当前字幕行原文（段落级精准续读），时长比例作 cue 匹配失败的兜底
    let startFraction: number = 0;
    let carryCue: string = '';
    if (!this.completed && this.positionSec > 0) {
      const posMs: number = this.positionSec * 1000;
      if (!this.subtitleTrack.isEmpty && posMs >= this.subtitleTrack.cues[0].startMs) {
        const cueIndex: number = this.subtitleTrack.indexAt(posMs);
        const cue: FqSubtitleCue | undefined =
          cueIndex >= 0 ? this.subtitleTrack.cues[cueIndex] : undefined;
        if (cue !== undefined) {
          carryCue = cue.text.trim();
        }
      }
      if (this.durationSec > 0) {
        startFraction = Math.min(0.98, this.positionSec / this.durationSec);
      }
    }
    this.ttsMode = true;
    this.ttsVoicePerson = FqAppSettingsStore.getTtsPerson();
    this.rate = FqAppSettingsStore.getTtsRate();
    this.refreshTtsVoices(false);
    this.openTtsChapter(this.index, this.wantPlay && !this.completed, startFraction, carryCue);
  }

  /** 切回在线听书：保留当前章，按朗读字符比折算秒级位置续播。 */
  public switchToOnline(): void {
    if (!this.hasSession || !this.ttsMode) {
      return;
    }
    this.stopTtsSpeak();
    this.persistHistory();
    // 位置携带：暂存字符比，新章时长就绪后换算秒级位置
    this.pendingOnlineFraction = this.completed ? -1 : this.ttsProgress;
    this.ttsMode = false;
    this.ttsProgress = 0;
    this.ttsCueText = '';
    this.ttsEstimatedDurationSec = 0;
    const wasPlaying: boolean = this.wantPlay && !this.completed;
    this.openChapter(this.index, new FqChapterOpenOptions(this.toneId, 0, wasPlaying, false));
  }

  /** 设置离线朗读语速（全局持久化；朗读中即时重起当前片段）。 */
  public setTtsRate(rate: number): void {
    this.rate = rate;
    FqAppSettingsStore.setTtsRate(rate);
    if (this.ttsMode) {
      // 估算时长随语速变化：同步刷新实况窗/播控展示
      this.ttsEstimatedDurationSec = FqAudioSession.estimateTtsDurationSec(this.ttsText, rate);
      this.syncAvMetadata();
    }
    if (this.ttsMode && this.wantPlay && !this.completed && !this.loading
      && this.errorMessage.length === 0) {
      this.restartTtsFrom(this.ttsOffset);
    }
    this.persistHistory();
    this.syncAvPlaybackState(true);
  }

  /** 选择离线朗读音色（全局持久化；朗读中停当前播报后续读）。 */
  public selectTtsVoice(person: number): void {
    if (!this.hasSession || person === this.ttsVoicePerson) {
      return;
    }
    this.ttsVoicePerson = person;
    FqAppSettingsStore.setTtsPerson(person);
    this.shutdownTtsEngine();
    if (this.ttsMode && this.wantPlay && !this.completed && !this.loading
      && this.errorMessage.length === 0) {
      this.restartTtsFrom(this.ttsOffset);
    }
  }

  /** 章内定位（0~1 字符比）；朗读中即时重起，暂停态仅记录。 */
  public seekTts(fraction: number): void {
    if (!this.hasSession || !this.ttsMode || this.loading) {
      return;
    }
    let target: number = fraction;
    if (target < 0) {
      target = 0;
    }
    if (target > 1) {
      target = 1;
    }
    if (this.completed && target < 1) {
      this.completed = false;
    }
    this.ttsOffset = FqAudioSession.skipWhitespace(this.ttsText, Math.floor(target * this.ttsText.length));
    this.updateTtsProgress();
    if (this.wantPlay && !this.completed && this.errorMessage.length === 0) {
      this.restartTtsFrom(this.ttsOffset);
    } else {
      this.ttsCueText = '';
      this.persistHistory();
      this.syncAvPlaybackState(true);
    }
  }

  /** 按朗读片段原文定位（阅读页边听边读进入听书页续读；装载中延后，匹配失败忽略）。
   * 返回是否已受理（立即定位或装载后定位）。 */
  public seekTtsByText(cue: string): boolean {
    if (!this.hasSession || !this.ttsMode || cue.length === 0) {
      return false;
    }
    if (this.loading) {
      // 章节装载中：正文就绪后再定位
      this.ttsPendingCue = cue;
      return true;
    }
    if (this.ttsText.length === 0 || this.completed) {
      return false;
    }
    let index: number = this.ttsText.indexOf(cue);
    if (index < 0 && cue.length > 12) {
      index = this.ttsText.indexOf(cue.substring(0, 12));
    }
    if (index < 0) {
      return false;
    }
    this.seekTts(index / this.ttsText.length);
    return true;
  }

  /** 起播/续播当前片段（wantPlay 已置位）。 */
  private playTts(): void {
    if (this.completed || this.ttsText.trim().length === 0) {
      return;
    }
    this.startTtsPipeline(this.ttsOffset);
  }

  /** 离线朗读章节装载：取正文 → 就绪后按 wantPlay 起播（generation 守卫）。 */
  private async openTtsChapter(index: number, autoplay: boolean, startFraction: number,
    pendingCue: string): Promise<void> {
    if (!this.hasSession) {
      return;
    }
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return;
    }
    const gen: number = ++this.generation;
    const wantAutoplay: boolean = autoplay || this.wantPlay;
    this.index = index;
    this.itemId = chapter.itemId;
    this.completed = startFraction >= 1;
    this.wantPlay = wantAutoplay && !this.completed;
    this.loading = true;
    this.errorMessage = '';
    this.ttsText = '';
    this.ttsCueText = '';
    this.ttsOffset = 0;
    this.ttsProgress = this.completed ? 1 : 0;
    this.ttsSerial += 1;
    this.ttsRestartOffset = -1;
    this.ttsPendingCue = pendingCue;
    this.cancelTtsRestartTimer();
    // 切章清自渲染管线并停在途合成（免旧片段 PCM 混入新章）
    this.flushTtsAudio();
    const speakingEngine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    if (speakingEngine !== null && speakingEngine.isBusy()) {
      speakingEngine.stop();
    }
    this.lastHistorySaveAt = Date.now();
    // 切章先停旧音频：在线引擎立即静下来
    await this.engine.pause().catch((): void => {
    });
    if (gen !== this.generation) {
      return;
    }
    try {
      const text: string = await this.fetchTtsChapterText(index);
      if (gen !== this.generation) {
        return;
      }
      if (text.trim().length === 0) {
        throw new Error('本章暂无正文，无法离线朗读');
      }
      this.ttsText = text;
      this.ttsEstimatedDurationSec = FqAudioSession.estimateTtsDurationSec(text, this.rate);
      if (startFraction > 0 && startFraction < 1) {
        this.ttsOffset = FqAudioSession.skipWhitespace(text, Math.floor(startFraction * text.length));
        this.updateTtsProgress();
      }
      this.loading = false;
      this.ensureAvSession();
      this.syncAvMetadata();
      this.syncAvPlaybackState(true);
      this.persistHistory();
      // 装载期间暂存的原文定位：就绪后按 cue 定位续读
      const pendingCue: string = this.ttsPendingCue;
      this.ttsPendingCue = '';
      if (pendingCue.length > 0 && !this.completed) {
        if (this.seekTtsByText(pendingCue)) {
          return;
        }
      }
      if (this.wantPlay && !this.completed) {
        this.startBackgroundTask();
        this.startTtsPipeline(this.ttsOffset);
      }
    } catch (error) {
      if (gen !== this.generation) {
        return;
      }
      this.ttsPendingCue = '';
      this.wantPlay = false;
      this.loading = false;
      this.errorMessage = fqErrorMessage(error);
      this.persistHistory();
      hilog.error(0x0001, TAG, `openTtsChapter failed: ${this.errorMessage}`);
    }
  }

  /** 朗读正文：本地书按导入偏移切片；在线拉取并写章节缓存，失败回退缓存（离线续读）。 */
  private async fetchTtsChapterText(index: number): Promise<string> {
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return '';
    }
    if (FqLocalBookStore.isLocalBookId(this.bookId)) {
      return FqLocalBookStore.chapterText(this.bookId, index);
    }
    try {
      const normalized: FqNormalizedChapter =
        await FqBackend.get().chapterTextWithIdx(chapter.itemId, chapter.title);
      if (normalized.text.trim().length === 0) {
        throw new Error('本章暂无正文，无法离线朗读');
      }
      FqChapterCacheStore.write(this.bookId, chapter.itemId, chapter.title, normalized.text);
      return normalized.text;
    } catch (error) {
      const cached: string = FqChapterCacheStore.read(this.bookId, chapter.itemId);
      if (cached.trim().length > 0) {
        return cached;
      }
      throw new Error(fqErrorMessage(error));
    }
  }

  /** 创建/复用朗读引擎（音色变更时重建）。 */
  private async ensureTtsEngine(): Promise<boolean> {
    if (this.ttsEngine !== null && this.ttsEnginePerson === this.ttsVoicePerson) {
      return true;
    }
    this.shutdownTtsEngine();
    if (this.context === null) {
      return false;
    }
    const extraParams: Record<string, Object> = {
      'style': 'interaction-broadcast',
      'locate': 'CN',
      'name': 'FqHouse',
      'isBackStage': true,
    };
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: this.ttsVoicePerson,
      online: 1,
      extraParams: extraParams,
    };
    try {
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      this.ttsEngine = engine;
      this.ttsEnginePerson = this.ttsVoicePerson;
      engine.setListener(this.buildTtsListener());
      return true;
    } catch (error) {
      hilog.warn(0x0001, TAG,
        `tts createEngine failed person=${this.ttsVoicePerson}: ${fqErrorMessage(error)}`);
      return false;
    }
  }

  private buildTtsListener(): textToSpeech.SpeakListener {
    const listener: textToSpeech.SpeakListener = {
      onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        this.onTtsComplete(requestId, response);
      },
      onStop: (_requestId: string, _response: textToSpeech.StopResponse): void => {
        this.runPendingTtsRestart();
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        this.onTtsError(requestId, errorCode, errorMessage);
      },
      onData: (requestId: string, audioData: ArrayBuffer, response: textToSpeech.SynthesisResponse): void => {
        this.onTtsData(requestId, audioData, response);
      },
    };
    return listener;
  }

  /** 起播/续播朗读管线（wantPlay 已置位）：引擎+渲染器就绪后从 offset 续读。 */
  private async startTtsPipeline(offset: number): Promise<void> {
    if (!this.ttsMode || this.ttsText.trim().length === 0) {
      return;
    }
    // 先落预合成游标：await 期间 tick 续合成也定位正确
    this.ttsSynthOffset = offset;
    const engineReady: boolean = await this.ensureTtsEngine();
    if (!engineReady) {
      if (this.ttsMode && this.wantPlay) {
        this.wantPlay = false;
        this.errorMessage = '离线朗读引擎初始化失败，请稍后重试';
        this.persistHistory();
        this.syncAvPlaybackState(true);
      }
      return;
    }
    if (!this.ttsMode || !this.wantPlay || this.completed) {
      return;
    }
    const start: number = FqAudioSession.skipWhitespace(this.ttsText, this.ttsSynthOffset);
    if (start >= this.ttsText.length) {
      this.handleTtsChapterEnd();
      return;
    }
    const rendererReady: boolean = await this.ensureTtsRenderer();
    if (!rendererReady) {
      if (this.ttsMode && this.wantPlay) {
        this.wantPlay = false;
        this.errorMessage = '离线朗读音频设备初始化失败，请稍后重试';
        this.persistHistory();
        this.syncAvPlaybackState(true);
      }
      return;
    }
    if (!this.ttsMode || !this.wantPlay || this.completed) {
      return;
    }
    this.pumpTtsWrites();
    this.ttsOffset = start;
    this.ttsCueText = this.ttsText.substring(start, FqAudioSession.findPieceEnd(this.ttsText, start));
    this.updateTtsProgress();
    this.syncAvPlaybackState(true);
    this.speakNextTtsPiece(start);
  }

  /** 合成下一片段（playType 0 仅合成，PCM 经 onData 自渲染播放）。 */
  private speakNextTtsPiece(fromOffset: number): void {
    if (!this.ttsMode || !this.wantPlay || this.completed || this.loading || this.ttsSynthInFlight) {
      return;
    }
    const start: number = FqAudioSession.skipWhitespace(this.ttsText, fromOffset);
    if (start >= this.ttsText.length) {
      this.ttsSynthDone = true;
      return;
    }
    const end: number = FqAudioSession.findPieceEnd(this.ttsText, start);
    const piece: string = this.ttsText.substring(start, end);
    this.ttsPieceStart = start;
    this.ttsPieceEnd = end;
    this.ttsSynthOffset = end;
    this.ttsPieceBytes = 0;
    this.ttsExpectedSeq = 0;
    this.ttsPendingChunks = [];
    this.ttsSerial += 1;
    this.ttsSynthInFlight = true;
    const speakExtra: Record<string, Object> = {
      'speed': this.rate,
      'languageContext': 'zh-CN',
      'playType': 0,
      'queueMode': 1,
      'isBackStage': true,
    };
    const speakParams: textToSpeech.SpeakParams = {
      requestId: `fqTts${this.ttsSerial}`,
      extraParams: speakExtra,
    };
    const engine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    if (engine === null) {
      this.ttsSynthInFlight = false;
      return;
    }
    try {
      engine.speak(piece, speakParams);
    } catch (error) {
      this.ttsSynthInFlight = false;
      this.wantPlay = false;
      this.errorMessage = fqErrorMessage(error);
      this.persistHistory();
      this.syncAvPlaybackState(true);
    }
  }

  /** onData：按 sequence 排序后入 PCM 队列并驱动写泵。 */
  private onTtsData(requestId: string, audioData: ArrayBuffer,
    response: textToSpeech.SynthesisResponse): void {
    if (!this.ttsMode || requestId !== `fqTts${this.ttsSerial}`) {
      return;
    }
    const seq: number = response.sequence;
    if (seq === this.ttsExpectedSeq) {
      this.ttsExpectedSeq += 1;
      this.enqueueTtsAudio(audioData);
      while (this.ttsPendingChunks.length > 0) {
        const head: FqTtsAudioChunk = this.ttsPendingChunks[0];
        if (head.seq !== this.ttsExpectedSeq) {
          break;
        }
        this.ttsExpectedSeq += 1;
        this.ttsPendingChunks.shift();
        this.enqueueTtsAudio(head.data);
      }
      return;
    }
    if (seq > this.ttsExpectedSeq) {
      let pos: number = this.ttsPendingChunks.length;
      for (let i: number = 0; i < this.ttsPendingChunks.length; i++) {
        if (this.ttsPendingChunks[i].seq > seq) {
          pos = i;
          break;
        }
      }
      this.ttsPendingChunks.splice(pos, 0, new FqTtsAudioChunk(seq, audioData));
    }
    // seq < expected：重复块，丢弃
  }

  private enqueueTtsAudio(buffer: ArrayBuffer): void {
    this.ttsPieceBytes += buffer.byteLength;
    this.ttsQueue.push(buffer);
    this.pumpTtsWrites();
  }

  /** PCM 写泵：队列 → renderer.write（背压由 write 的 Promise 天然承担）。 */
  private async pumpTtsWrites(): Promise<void> {
    const renderer: audio.AudioRenderer | null = this.ttsRenderer;
    if (renderer === null || this.ttsPumpingFor === renderer) {
      return;
    }
    this.ttsPumpingFor = renderer;
    try {
      while (this.ttsRenderer === renderer && this.ttsQueue.length > 0) {
        const buffer: ArrayBuffer = this.ttsQueue[0];
        const written: number = await renderer.write(buffer);
        if (this.ttsQueue.length === 0 || this.ttsQueue[0] !== buffer) {
          continue;
        }
        if (written >= buffer.byteLength) {
          this.ttsQueue.shift();
        } else if (written > 0) {
          this.ttsQueue[0] = buffer.slice(written);
        } else {
          this.ttsQueue.shift();
        }
      }
    } catch (error) {
      // 渲染器已释放/状态异常：静默退出，等下一次 pump
    }
    if (this.ttsPumpingFor === renderer) {
      this.ttsPumpingFor = null;
    }
  }

  private onTtsComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
    if (!this.ttsMode || requestId !== `fqTts${this.ttsSerial}`) {
      return;
    }
    // playType 0：仅合成完成（type=0）。记录片段边界，lookahead 预算内继续预合成
    if (response.type !== 0) {
      return;
    }
    // 残留乱序块按序补入（计入本片段）
    for (const chunk of this.ttsPendingChunks) {
      this.ttsPieceBytes += chunk.data.byteLength;
      this.ttsQueue.push(chunk.data);
    }
    this.ttsPendingChunks = [];
    this.ttsTotalSynthBytes += this.ttsPieceBytes;
    this.ttsPieceStarts.push(this.ttsPieceStart);
    this.ttsPieceEnds.push(this.ttsPieceEnd);
    this.ttsPieceBytesAtEnd.push(this.ttsTotalSynthBytes);
    this.ttsPieceBytes = 0;
    this.ttsSynthInFlight = false;
    this.pumpTtsWrites();
    if (this.ttsPieceEnd >= this.ttsText.length) {
      this.ttsSynthDone = true;
      return;
    }
    if (this.wantPlay && !this.completed && this.ttsUnplayedBytes() < FQ_TTS_LOOKAHEAD_BYTES) {
      this.speakNextTtsPiece(this.ttsPieceEnd);
    }
  }

  /** 渲染器已播字节数（单声道 16bit：帧数 ×2）。 */
  private ttsPlayedBytes(): number {
    const renderer: audio.AudioRenderer | null = this.ttsRenderer;
    if (renderer === null) {
      return 0;
    }
    try {
      const info: audio.AudioTimestampInfo = renderer.getAudioTimestampInfoSync();
      return info.framePos * 2;
    } catch (error) {
      return 0;
    }
  }

  /** 已合成未播放字节数（lookahead 预算判据）。 */
  private ttsUnplayedBytes(): number {
    return this.ttsTotalSynthBytes + this.ttsPieceBytes - this.ttsPlayedBytes();
  }

  /** 播放进度 → 片段定位（进度/高亮/章尾判定），tick 驱动。 */
  private updateTtsPlayback(): void {
    const totalBytes: number = this.ttsTotalSynthBytes + this.ttsPieceBytes;
    if (totalBytes <= 0) {
      return;
    }
    const playedBytes: number = this.ttsPlayedBytes();
    let pieceIndex: number = -1;
    for (let i: number = 0; i < this.ttsPieceBytesAtEnd.length; i++) {
      if (playedBytes < this.ttsPieceBytesAtEnd[i]) {
        pieceIndex = i;
        break;
      }
    }
    if (pieceIndex >= 0) {
      const newOffset: number = this.ttsPieceStarts[pieceIndex];
      if (newOffset !== this.ttsOffset) {
        this.ttsOffset = newOffset;
        this.ttsCueText = this.ttsText.substring(this.ttsPieceStarts[pieceIndex],
          this.ttsPieceEnds[pieceIndex]);
        this.updateTtsProgress();
        this.persistHistory();
      }
      return;
    }
    // 已播完所有已合成音频且合成完毕：章尾
    if (this.ttsSynthDone && !this.ttsSynthInFlight && playedBytes >= totalBytes - 640) {
      this.finishTtsPlayback();
    }
  }

  /** 播放追平后继续预合成（lookahead 预算内）。 */
  private maybeContinueTtsSynth(): void {
    if (!this.ttsMode || !this.wantPlay || this.completed || this.loading
      || this.ttsSynthInFlight || this.ttsSynthDone || this.errorMessage.length > 0) {
      return;
    }
    if (this.ttsUnplayedBytes() >= FQ_TTS_LOOKAHEAD_BYTES) {
      return;
    }
    this.speakNextTtsPiece(this.ttsSynthOffset);
  }

  /** 渲染器播完全章：清管线并进入章尾流程。 */
  private finishTtsPlayback(): void {
    this.flushTtsAudio();
    this.handleTtsChapterEnd();
  }

  /** 清空自渲染管线：作废在途回调、丢弃队列/片段表、释放渲染器。 */
  private flushTtsAudio(): void {
    this.ttsSerial += 1;
    this.ttsQueue = [];
    this.ttsPendingChunks = [];
    this.ttsPieceBytes = 0;
    this.ttsTotalSynthBytes = 0;
    this.ttsPieceStarts = [];
    this.ttsPieceEnds = [];
    this.ttsPieceBytesAtEnd = [];
    this.ttsSynthOffset = 0;
    this.ttsSynthInFlight = false;
    this.ttsSynthDone = false;
    this.ttsExpectedSeq = 0;
    const renderer: audio.AudioRenderer | null = this.ttsRenderer;
    this.ttsRenderer = null;
    if (renderer !== null) {
      renderer.release().catch((): void => {
      });
    }
  }

  /** 创建自渲染 AudioRenderer（16kHz/16bit/单声道 PCM，媒体流）。 */
  private async ensureTtsRenderer(): Promise<boolean> {
    if (this.ttsRenderer !== null) {
      return true;
    }
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    };
    const rendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0,
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: rendererInfo,
    };
    let renderer: audio.AudioRenderer;
    try {
      renderer = await audio.createAudioRenderer(options);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.warn(0x0001, TAG, `create tts renderer failed: ${err.code} ${err.message}`);
      return false;
    }
    renderer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      this.onTtsRendererInterrupt(event);
    });
    this.ttsRenderer = renderer;
    try {
      await renderer.start();
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.warn(0x0001, TAG, `start tts renderer failed: ${err.code} ${err.message}`);
      if (this.ttsRenderer === renderer) {
        this.ttsRenderer = null;
      }
      renderer.release().catch((): void => {
      });
      return false;
    }
    if (this.ttsRenderer !== renderer) {
      // 启动期间管线被 flush：释放让位
      renderer.release().catch((): void => {
      });
      return false;
    }
    return true;
  }

  /** 音频焦点被打断（来电/其他应用抢焦点）：暂停朗读。 */
  private onTtsRendererInterrupt(event: audio.InterruptEvent): void {
    if (!this.ttsMode || !this.wantPlay) {
      return;
    }
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.pause();
    }
  }

  private onTtsError(requestId: string, errorCode: number, errorMessage: string): void {
    if (requestId !== `fqTts${this.ttsSerial}` || !this.ttsMode) {
      return;
    }
    hilog.error(0x0001, TAG, `tts error ${errorCode}: ${errorMessage}`);
    this.flushTtsAudio();
    this.wantPlay = false;
    this.errorMessage = errorMessage.length > 0 ? errorMessage : `离线朗读失败（${errorCode}）`;
    this.persistHistory();
    this.syncAvPlaybackState(true);
  }

  /** 停止合成与自渲染播放并作废在途回调。 */
  private stopTtsSpeak(): void {
    this.ttsSerial += 1;
    this.ttsRestartOffset = -1;
    this.cancelTtsRestartTimer();
    this.flushTtsAudio();
    const engine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    if (engine !== null && engine.isBusy()) {
      engine.stop();
    }
  }

  /** 变速/定位/换音色续读：停合成清管线，onStop（或 600ms 超时兜底）后从 offset 重起。 */
  private restartTtsFrom(offset: number): void {
    this.ttsRestartOffset = offset;
    this.cancelTtsRestartTimer();
    this.flushTtsAudio();
    const engine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    if (engine !== null && engine.isBusy()) {
      engine.stop();
      this.ttsRestartTimer = setTimeout((): void => {
        this.ttsRestartTimer = -1;
        this.runPendingTtsRestart();
      }, 600);
      return;
    }
    this.runPendingTtsRestart();
  }

  /** stop→onStop 续读（无待重启时忽略）。 */
  private runPendingTtsRestart(): void {
    if (this.ttsRestartTimer >= 0) {
      clearTimeout(this.ttsRestartTimer);
      this.ttsRestartTimer = -1;
    }
    const offset: number = this.ttsRestartOffset;
    if (offset < 0) {
      return;
    }
    this.ttsRestartOffset = -1;
    if (!this.ttsMode || !this.wantPlay || this.completed || this.loading) {
      return;
    }
    this.startTtsPipeline(offset);
  }

  private handleTtsChapterEnd(): void {
    this.completed = true;
    this.wantPlay = false;
    this.ttsProgress = 1;
    this.ttsCueText = '';
    this.persistHistory();
    this.syncAvPlaybackState(true);
    if (this.sleepAtChapterEnd) {
      this.sleepAtChapterEnd = false;
      return;
    }
    if (this.autoAdvance && this.index + 1 < this.chapters.length) {
      this.openChapter(this.index + 1, new FqChapterOpenOptions(this.toneId, 0, true, false));
    }
  }

  private updateTtsProgress(): void {
    if (this.ttsText.length === 0) {
      this.ttsProgress = 0;
      return;
    }
    const progress: number = this.ttsOffset / this.ttsText.length;
    this.ttsProgress = Math.min(1, Math.max(0, progress));
  }

  /** 动态加载可选音色（listVoices；force 强刷状态，失败/为空保留静态回退表）。 */
  public refreshTtsVoices(force: boolean): void {
    if (!force && this.ttsVoicesLoaded) {
      return;
    }
    const query: textToSpeech.VoiceQuery = {
      // 时间戳 + 序号全局唯一：hsp 侧对 requestId 去重且记忆跨应用冷启动存活，
      // 固定前缀短序号（fqVoices1）每次冷启动归零重复即被拒（40000 repeated）
      requestId: `${Date.now()}${this.ttsVoicesQuerySerial += 1}`,
      online: 1,
    };
    textToSpeech.listVoices(query)
      .then((list: textToSpeech.VoiceInfo[]): void => {
        if (list.length === 0) {
          hilog.warn(0x0001, TAG, 'listVoices returned empty');
          return;
        }
        this.ttsVoiceInfos = list;
        const voices: FqTtsVoice[] = [];
        for (const info of list) {
          // 仅中文音色（8 劳拉为英语音色，无法朗读中文正文）；EOM 不可用
          if (info.language.indexOf('zh') !== 0 || info.status === 'EOM') {
            continue;
          }
          // 13/0 同为聆小珊（文档不一致）：统一为 0
          const person: number = info.person === 13 ? 0 : info.person;
          const installed: boolean = info.status === undefined || info.status === 'INSTALLED';
          let merged: boolean = false;
          for (let i: number = 0; i < voices.length; i++) {
            if (voices[i].person === person) {
              // 重复音色合并：任一已安装即视为已安装
              if (installed && !voices[i].installed) {
                voices[i] = new FqTtsVoice(person, voices[i].name, voices[i].description, true);
              }
              merged = true;
              break;
            }
          }
          if (merged) {
            continue;
          }
          voices.push(new FqTtsVoice(person, FqAudioSession.ttsVoiceName(person),
            info.description.length > 0 ? info.description : FqAudioSession.ttsVoiceDesc(person),
            installed));
        }
        if (voices.length === 0) {
          return;
        }
        this.ttsVoices = voices;
        this.ttsVoicesLoaded = true;
        this.ttsVoicesFromSystem = true;
      })
      .catch((error: BusinessError): void => {
        // 保留静态回退表
        hilog.error(0x0001, TAG, `listVoices failed: ${error.code} ${error.message}`);
      });
  }

  /** 选离线朗读音色（设置页用：无播放会话也生效，全局持久化）。 */
  public applyTtsVoiceChoice(person: number): void {
    if (this.hasSession) {
      this.selectTtsVoice(person);
      return;
    }
    if (person === this.ttsVoicePerson) {
      return;
    }
    this.ttsVoicePerson = person;
    FqAppSettingsStore.setTtsPerson(person);
  }

  /** 下载未安装音色（系统弹窗确认后下载；@Trace 下载态驱动 UI）。
   * 返回是否已受理（无音色信息时 false）。 */
  public downloadTtsVoice(person: number): boolean {
    if (this.ttsVoiceDownloading >= 0) {
      return true;
    }
    let info: textToSpeech.VoiceInfo | undefined = undefined;
    for (const item of this.ttsVoiceInfos) {
      if (item.person === person || (person === 0 && item.person === 13)) {
        info = item;
        if (item.person === person) {
          break;
        }
      }
    }
    if (info === undefined) {
      return false;
    }
    const params: textToSpeech.VoiceDownload = {
      // 同 listVoices：时间戳 + 序号全局唯一（hsp 对 requestId 去重跨冷启动存活）
      requestId: `${Date.now()}${this.ttsVoiceDownloadSerial += 1}`,
      language: info.language,
      person: info.person,
      style: info.style.length > 0 ? info.style : 'interaction-broadcast',
    };
    this.ttsVoiceDownloading = person;
    this.ttsVoiceDownloadPercent = -1;
    textToSpeech.downloadVoice(params, (error: BusinessError,
      response: textToSpeech.DownloadResponse): void => {
      if (error !== undefined && error !== null) {
        // 1002300010 已下载过：直接标记已安装
        if (error.code === 1002300010) {
          this.markTtsVoiceInstalled(person);
        } else {
          hilog.error(0x0001, TAG,
            `downloadVoice failed person=${person}: ${error.code} ${error.message}`);
        }
        this.resetTtsVoiceDownload();
        return;
      }
      if (response === undefined || response === null) {
        this.resetTtsVoiceDownload();
        return;
      }
      const startCallback: Callback<string> = (_info: string): void => {
        this.ttsVoiceDownloadPercent = -1;
      };
      const progressCallback: Callback<string> = (schedule: string): void => {
        this.ttsVoiceDownloadPercent = FqAudioSession.parseDownloadPercent(schedule);
      };
      const cancelCallback: Callback<string> = (_info: string): void => {
        this.resetTtsVoiceDownload();
      };
      const errorCallback: ErrorCallback<BusinessError> = (err: BusinessError): void => {
        hilog.error(0x0001, TAG,
          `download voice error person=${person}: ${err.code} ${err.message}`);
        this.resetTtsVoiceDownload();
      };
      const completeCallback: Callback<textToSpeech.VoiceInfo> =
        (_voice: textToSpeech.VoiceInfo): void => {
          this.markTtsVoiceInstalled(person);
          this.resetTtsVoiceDownload();
          response.off('start', startCallback);
          response.off('progress', progressCallback);
          response.off('complete', completeCallback);
          response.off('cancel', cancelCallback);
          response.off('error', errorCallback);
        };
      response.on('start', startCallback);
      response.on('progress', progressCallback);
      response.on('complete', completeCallback);
      response.on('cancel', cancelCallback);
      response.on('error', errorCallback);
    });
    return true;
  }

  /** 标记音色已安装（重建数组触发 @Trace 刷新）。 */
  private markTtsVoiceInstalled(person: number): void {
    const voices: FqTtsVoice[] = [];
    for (const voice of this.ttsVoices) {
      voices.push(new FqTtsVoice(voice.person, voice.name, voice.description,
        voice.installed || voice.person === person));
    }
    this.ttsVoices = voices;
  }

  private resetTtsVoiceDownload(): void {
    this.ttsVoiceDownloading = -1;
    this.ttsVoiceDownloadPercent = -1;
  }

  /** 解析下载进度字符串中的首个 0~100 整数（无法解析返回 -1）。 */
  private static parseDownloadPercent(value: string): number {
    let start: number = -1;
    for (let i: number = 0; i < value.length; i++) {
      const isDigit: boolean = value.charCodeAt(i) >= 48 && value.charCodeAt(i) <= 57;
      if (isDigit && start < 0) {
        start = i;
      }
      if (!isDigit && start >= 0) {
        return FqAudioSession.clampPercent(Number(value.substring(start, i)));
      }
    }
    if (start >= 0) {
      return FqAudioSession.clampPercent(Number(value.substring(start)));
    }
    return -1;
  }

  private static clampPercent(value: number): number {
    if (!Number.isFinite(value)) {
      return -1;
    }
    return Math.min(100, Math.max(0, Math.round(value)));
  }

  /** 朗读估算总时长（秒）：有效字数 / (语速 × 基准 4.5 字/秒)；仅 AVSession 展示用。 */
  private static estimateTtsDurationSec(text: string, rate: number): number {
    const charCount: number = text.replace(/\s+/g, '').length;
    if (charCount === 0) {
      return 0;
    }
    const effectiveRate: number = rate > 0 ? rate : 1;
    return Math.max(1, Math.round(charCount / (4.5 * effectiveRate)));
  }

  private shutdownTtsEngine(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.ttsEngine;
    this.ttsEngine = null;
    this.ttsEnginePerson = -1;
    if (engine !== null) {
      try {
        engine.shutdown();
      } catch (error) {
        // 忽略关闭异常
      }
    }
  }

  private cancelTtsRestartTimer(): void {
    if (this.ttsRestartTimer >= 0) {
      clearTimeout(this.ttsRestartTimer);
      this.ttsRestartTimer = -1;
    }
  }

  /** 跳过 offset 起的空白字符。 */
  private static skipWhitespace(text: string, offset: number): number {
    let index: number = offset;
    if (index < 0) {
      index = 0;
    }
    while (index < text.length) {
      const code: number = text.charCodeAt(index);
      if (code !== 32 && code !== 10 && code !== 13 && code !== 9 && code !== 0x3000) {
        break;
      }
      index += 1;
    }
    return index;
  }

  /** 片段窗口内最后一个句读断点（换行即段界；无句读 1.5 倍扩找再硬切）。 */
  private static findPieceEnd(text: string, start: number): number {
    const limit: number = Math.min(text.length, start + FQ_TTS_PIECE_MAX);
    let end: number = -1;
    for (let i: number = start + 1; i < limit; i++) {
      const ch: string = text.charAt(i);
      if (ch === '\n') {
        return i;
      }
      if (FqAudioSession.isTtsBreakChar(ch)) {
        let j: number = i + 1;
        // 断点后闭合引号跟随
        while (j < limit && FqAudioSession.isTtsCloseQuote(text.charAt(j))) {
          j += 1;
        }
        end = j;
      }
    }
    if (end > start) {
      return end;
    }
    if (limit >= text.length) {
      return text.length;
    }
    // 窗口内无句读：1.5 倍扩找
    const extended: number = Math.min(text.length, start + Math.floor(FQ_TTS_PIECE_MAX * 1.5));
    for (let i: number = limit; i < extended; i++) {
      const ch: string = text.charAt(i);
      if (ch === '\n' || FqAudioSession.isTtsBreakChar(ch)) {
        return i;
      }
    }
    return extended;
  }

  private static isTtsBreakChar(ch: string): boolean {
    return ch === '。' || ch === '！' || ch === '？' || ch === '；' || ch === '!' || ch === '?';
  }

  private static isTtsCloseQuote(ch: string): boolean {
    return ch === '”' || ch === '』' || ch === '」' || ch === '"' || ch === '’';
  }

  /** 音色显示名（设置页入口右侧文案用，公开静态）。 */
  public static ttsVoiceName(person: number): string {
    if (person === 21) {
      return '凌飞哲';
    }
    if (person === 8) {
      return '劳拉';
    }
    return '聆小珊';
  }

  private static ttsVoiceDesc(person: number): string {
    if (person === 21) {
      return '男声';
    }
    if (person === 8) {
      return '英语女声';
    }
    return '女声';
  }

  /** listVoices 不可用时的静态音色表。 */
  private static fallbackTtsVoices(): FqTtsVoice[] {
    const voices: FqTtsVoice[] = [];
    voices.push(new FqTtsVoice(0, '聆小珊', '女声', true));
    voices.push(new FqTtsVoice(21, '凌飞哲', '男声（需在系统下载音色）', false));
    return voices;
  }

  // ---------------------------------------------------------------------------
  // 内部：取源 / 装饰 / 定时
  // ---------------------------------------------------------------------------

  private async fetchSource(itemId: string, toneId: string,
    gen: number): Promise<FqAudioSource> {
    // 离线优先：该章当前音色已缓存直接回本地文件（durationSec 由引擎 prepare 后补全）
    const cachedPath: string | null = FqAudioCacheStore.cachedFilePath(this.bookId, itemId, toneId);
    if (cachedPath !== null) {
      return new FqAudioSource(itemId, `file://${cachedPath}`, toneId, 0);
    }
    const backend: FqBackend = FqBackend.get();
    try {
      return await backend.audioChapterSource(this.bookId, itemId, toneId);
    } catch (error) {
      const message: string = fqErrorMessage(error);
      if (!message.includes('NO_THIS_TONE')) {
        throw new Error(message);
      }
      // 纯 TTS 书无默认音色：等待音色表就绪后取首个可用音色重试一次
      const fallback: string | null = await this.awaitSelectableTone(gen);
      if (fallback === null || gen !== this.generation) {
        throw new Error(message);
      }
      this.toneId = fallback;
      return await backend.audioChapterSource(this.bookId, itemId, fallback);
    }
  }

  private async awaitSelectableTone(gen: number): Promise<string | null> {
    const immediate: string | null = this.firstSelectableTone();
    if (immediate !== null) {
      return immediate;
    }
    const pending: Promise<FqAudioToneSet> | null = this.tonesPromise;
    if (pending === null) {
      return null;
    }
    await pending;
    if (gen !== this.generation) {
      return null;
    }
    const fromTones: string | null = this.firstSelectableTone();
    if (fromTones !== null) {
      return fromTones;
    }
    const voicesPending: Promise<FqAudioVoice[]> | null = this.voicesPromise;
    if (voicesPending !== null) {
      await voicesPending;
      if (gen !== this.generation) {
        return null;
      }
    }
    return this.firstSelectableTone();
  }

  private firstSelectableTone(): string | null {
    for (const tone of this.toneSet.ttsTones) {
      if (tone.id.trim().length > 0) {
        return tone.id;
      }
    }
    for (const tone of this.toneSet.narratorTones) {
      if (tone.id.trim().length > 0) {
        return tone.id;
      }
    }
    for (const voice of this.voices) {
      const id: string = voice.id.trim();
      if (id.length > 0 && id !== '0') {
        return voice.id;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 声音设置面板可选项（fqapp _onlineOptions / _selectableTone / _ttsBookId）
  // ---------------------------------------------------------------------------

  /** fqapp _ttsBookId：固定录音需关联小说才可智能朗读，否则 null。 */
  public ttsTargetId(): string | null {
    if (!this.toneSet.hasFixedTone) {
      return this.bookId;
    }
    const related: FqRelatedWork | null = this.toneSet.relatedNovel;
    if (related !== null && related.id.length > 0 && related.id !== this.bookId) {
      return related.id;
    }
    return null;
  }

  /** 声音设置-智能朗读可选项：/tones tts 优先，空则回退 detail CSV voices。 */
  public onlineToneOptions(): FqAudioTone[] {
    const target: string | null = this.ttsTargetId();
    if (target === null) {
      return [];
    }
    const narratorIds: string[] = [];
    for (const tone of this.toneSet.narratorTones) {
      narratorIds.push(tone.id);
    }
    const offlineIds: string[] = [];
    for (const tone of this.toneSet.offlineTones) {
      offlineIds.push(tone.id);
    }
    const options: FqAudioTone[] = [];
    const seen: string[] = [];
    for (const tone of fqUniqueTones(this.toneSet.ttsTones)) {
      if (this.selectableToneId(tone.id, narratorIds, offlineIds) && !seen.includes(tone.id)) {
        seen.push(tone.id);
        options.push(tone);
      }
    }
    if (options.length > 0) {
      return options;
    }
    for (const voice of this.voices) {
      if (this.selectableToneId(voice.id, narratorIds, offlineIds) && !seen.includes(voice.id)) {
        seen.push(voice.id);
        options.push(new FqAudioTone(voice.id, voice.label, '', '', '', false));
      }
    }
    return options;
  }

  private selectableToneId(toneId: string, narratorIds: string[], offlineIds: string[]): boolean {
    const id: string = toneId.trim();
    return id.length > 0 && id !== '0' && !narratorIds.includes(id) && !offlineIds.includes(id);
  }

  /** 音色表 / CSV voices / 相关作品 / 播控封面（后台装饰，失败容忍；decGen 与章节装载解耦）。 */
  private loadDecorations(decGen: number): void {
    const backend: FqBackend = FqBackend.get();
    const tonesPromise: Promise<FqAudioToneSet> = backend.audioTones(this.bookId)
      .then((toneSet: FqAudioToneSet): FqAudioToneSet => {
        hilog.info(0x0001, TAG, `tones book=${this.bookId} tts=${toneSet.ttsTones.length}`
          + ` narrator=${toneSet.narratorTones.length} offline=${toneSet.offlineTones.length}`
          + ` genre=${toneSet.genreType} related=${toneSet.relatedNovel !== null}`);
        if (decGen === this.decorationsGeneration) {
          this.toneSet = toneSet;
          this.applyVoices(decGen);
        }
        return toneSet;
      })
      .catch((error: BusinessError): FqAudioToneSet => {
        hilog.info(0x0001, TAG, `tones failed book=${this.bookId}: ${fqErrorMessage(error)}`);
        return fqEmptyToneSet();
      });
    this.tonesPromise = tonesPromise;
    const voicesPromise: Promise<FqAudioVoice[]> = backend.audioVoices(this.bookId)
      .then((list: FqAudioVoice[]): FqAudioVoice[] => {
        const ids: string[] = [];
        for (const voice of list) {
          ids.push(voice.id);
        }
        hilog.info(0x0001, TAG, `voices book=${this.bookId} csv=[${ids.join(',')}]`);
        if (decGen === this.decorationsGeneration) {
          this.rawVoices = list;
          this.applyVoices(decGen);
        }
        return list;
      })
      .catch((): FqAudioVoice[] => fqDefaultVoices());
    this.voicesPromise = voicesPromise;
    backend.relatedWorks(this.bookId)
      .then((works: FqRelatedWork[]): void => {
        if (decGen === this.decorationsGeneration) {
          this.relatedWorks = works;
        }
      })
      .catch((): void => {
      });
    this.loadCoverPixel(decGen);
  }

  /** /tones 真实音色名覆盖 CSV 占位标签后落到 voices。 */
  private applyVoices(decGen: number): void {
    if (decGen !== this.decorationsGeneration) {
      return;
    }
    this.voices = fqMergeToneVoices(this.toneSet, this.rawVoices);
  }

  private loadExcerpt(gen: number, itemId: string): void {
    FqBackend.get().chapterSummaries(this.bookId, [itemId])
      .then((map: Map<string, string>): void => {
        if (gen !== this.generation || this.itemId !== itemId) {
          return;
        }
        const text: string | undefined = map.get(itemId);
        this.excerpt = text !== undefined ? text : '';
      })
      .catch((): void => {
      });
  }

  private loadSubtitles(gen: number, itemId: string, toneId: string): void {
    FqBackend.get().chapterTimeline(itemId, toneId)
      .then((track: FqSubtitleTrack): void => {
        if (gen !== this.generation || this.itemId !== itemId) {
          return;
        }
        this.subtitleTrack = track;
      })
      .catch((): void => {
      });
  }

  /** 500ms 轮询：位置、睡眠倒计时、AVSession/历史节流同步。 */
  private startTick(): void {
    if (this.tickTimer >= 0) {
      return;
    }
    this.tickTimer = setInterval((): void => {
      this.tick();
    }, 500);
  }

  private tick(): void {
    if (!this.hasSession) {
      return;
    }
    // 设置开关：后台播放关闭时停长时任务 + 销毁 AVSession（无法后台播放，无胶囊/播控中心通知）
    if (!FqAppSettingsStore.isBackgroundAudio()) {
      if (this.bgStarted) {
        this.stopBackgroundTask();
      }
      this.teardownAvSession();
    } else {
      this.ensureAvSession();
      this.syncBackgroundPlayMode();
    }
    const now: number = Date.now();
    if (this.engine.isPlaying) {
      // 兜底：任何路径进入播放态都确保持有长时任务（startBackgroundTask 内部去重）
      this.startBackgroundTask();
      this.positionSec = this.engine.positionSec;
      const duration: number = this.engine.durationSec;
      if (duration > 0 && Math.abs(duration - this.durationSec) > 0.5) {
        this.durationSec = duration;
      }
    }
    const ttsActive: boolean = this.ttsMode && this.wantPlay && !this.completed && !this.loading
      && this.errorMessage.length === 0;
    if (ttsActive) {
      // 朗读中同样需要长时任务兜底（息屏/后台续读）
      this.startBackgroundTask();
      // 自渲染播放位置推进（进度/高亮/章尾）与 lookahead 预合成续投
      this.updateTtsPlayback();
      this.maybeContinueTtsSynth();
    }
    if (this.sleepDeadline > 0) {
      const remainSec: number = (this.sleepDeadline - now) / 1000;
      this.sleepRemainingSec = Math.max(0, Math.ceil(remainSec));
      if (remainSec <= 0) {
        this.sleepDeadline = 0;
        this.sleepRemainingSec = -1;
        this.pause();
      }
    }
    if (now - this.lastAvSyncAt >= 1000) {
      this.syncAvPlaybackState(false);
    }
    if ((this.engine.isPlaying || ttsActive) && now - this.lastHistorySaveAt >= 5000) {
      this.lastHistorySaveAt = now;
      this.persistHistory();
    }
    // 播放中累计今日已读时长（每 10 次 tick = 5 秒落一次）
    if (this.engine.isPlaying || ttsActive) {
      this.statPlayingTicks += 1;
      if (this.statPlayingTicks >= 10) {
        this.statPlayingTicks = 0;
        FqReadStatsStore.addBookSeconds(this.bookId, 5);
      }
    } else {
      this.statPlayingTicks = 0;
    }
  }

  private handleChapterEnd(): void {
    if (!this.hasSession || this.completed) {
      return;
    }
    this.completed = true;
    this.positionSec = this.durationSec;
    this.persistHistory();
    this.syncAvPlaybackState(true);
    if (this.sleepAtChapterEnd) {
      this.sleepAtChapterEnd = false;
      this.wantPlay = false;
      return;
    }
    if (this.autoAdvance && this.index + 1 < this.chapters.length) {
      this.openChapter(this.index + 1, new FqChapterOpenOptions(this.toneId, 0, true, false));
    } else {
      this.wantPlay = false;
    }
  }

  private persistHistory(): void {
    if (!this.hasSession || this.bookId.length === 0 || this.chapters.length === 0) {
      return;
    }
    // 离线朗读：秒级位置无意义，写 0 + mode='tts'（章节进度与在线共享）
    const positionSec: number = this.ttsMode ? 0 : this.positionSec;
    const durationSec: number = this.ttsMode ? 0 : this.durationSec;
    FqAudioHistory.put(new FqListenRecord(this.bookId, this.index, positionSec,
      durationSec, this.toneId, this.rate, this.completed, this.title, this.cover,
      this.ttsMode ? 'tts' : 'online'));
  }

  /** 真人讲书目录对位：核心标题 → 序号 → 原下标。 */
  private narratorChapterIndex(chapters: FqChapter[]): number {
    const current: FqChapter | undefined = this.chapters[this.index];
    if (current === undefined) {
      return 0;
    }
    const want: string = FqAudioSession.chapterCore(current.title);
    if (want.length > 0) {
      for (let i: number = 0; i < chapters.length; i++) {
        if (FqAudioSession.chapterCore(chapters[i].title) === want) {
          return i;
        }
      }
    }
    const ordinal: number | null = FqAudioSession.chapterOrdinal(current.title);
    if (ordinal !== null) {
      for (let i: number = 0; i < chapters.length; i++) {
        if (FqAudioSession.chapterOrdinal(chapters[i].title) === ordinal) {
          return i;
        }
      }
    }
    return this.index < chapters.length ? this.index : 0;
  }

  /** `第一章合着…` / `001 合着…` → `合着…`。 */
  private static chapterCore(title: string): string {
    return title.trim()
      .replace(new RegExp('^(?:第\\s*[0-9零一二三四五六七八九十百千]+\\s*[章节集回话]?|\\d+)'
        + '\\s*[、.，,：:·\\-]?\\s*'), '')
      .trim();
  }

  /** 标题携带的首个数字序号（无数字 null）。 */
  private static chapterOrdinal(title: string): number | null {
    const match: RegExpExecArray | null = new RegExp('\\d+').exec(title);
    if (match === null) {
      return null;
    }
    const value: number = Number(match[0]);
    return Number.isFinite(value) ? value : null;
  }

  // ---------------------------------------------------------------------------
  // AVSession / 后台长时任务
  // ---------------------------------------------------------------------------

  private ensureAvSession(): void {
    if (this.avSessionValue !== null || this.avCreating || this.context === null) {
      return;
    }
    // 设置开关：后台播放关闭时不创建 AVSession（无胶囊/播控中心通知）
    if (!FqAppSettingsStore.isBackgroundAudio()) {
      return;
    }
    this.avCreating = true;
    const epoch: number = this.avEpoch;
    const context: common.UIAbilityContext = this.context;
    avSession.createAVSession(context, 'FqListen', 'audio')
      .then((session: avSession.AVSession): void => {
        this.avCreating = false;
        if (epoch !== this.avEpoch) {
          // teardown 已作废本次创建：立即销毁防泄漏
          session.destroy().catch((): void => {
          });
          return;
        }
        this.avSessionValue = session;
        session.on('play', (): void => {
          hilog.info(0x0001, TAG, 'AVSession cmd: play');
          this.play();
        });
        session.on('pause', (): void => {
          hilog.info(0x0001, TAG, 'AVSession cmd: pause');
          this.pause();
        });
        session.on('playNext', (): void => {
          hilog.info(0x0001, TAG, 'AVSession cmd: playNext');
          this.next();
        });
        session.on('playPrevious', (): void => {
          hilog.info(0x0001, TAG, 'AVSession cmd: playPrevious');
          this.previous();
        });
        session.on('stop', (): void => {
          hilog.info(0x0001, TAG, 'AVSession cmd: stop');
          this.close();
        });
        session.on('seek', (time: number): void => {
          hilog.info(0x0001, TAG, `AVSession cmd: seek ${time}`);
          this.seekTo(time / 1000);
        });
        this.syncAvMetadata();
        this.syncAvPlaybackState(true);
        this.bgPlayModeApplied = undefined;
        this.syncBackgroundPlayMode();
        session.activate().catch((error: BusinessError): void => {
          hilog.warn(0x0001, TAG, `AVSession activate failed: ${error.message}`);
        });
      })
      .catch((error: BusinessError): void => {
        this.avCreating = false;
        const created: avSession.AVSession | null =
          epoch === this.avEpoch ? this.avSessionValue : null;
        this.avSessionValue = null;
        if (created !== null) {
          // 创建成功但注册链路异常：销毁防泄漏
          created.deactivate().catch((): void => {
          }).then((): Promise<void> => created.destroy()).catch((): void => {
          });
        } else {
          hilog.warn(0x0001, TAG, `AVSession create failed: ${error.message}`);
        }
      });
  }

  /** 销毁 AVSession（关闭后台播放/close：无胶囊/播控中心通知）。 */
  private teardownAvSession(): void {
    this.avEpoch += 1;
    this.avCreating = false;
    const session: avSession.AVSession | null = this.avSessionValue;
    this.avSessionValue = null;
    this.bgPlayModeApplied = undefined;
    if (session !== null) {
      // deactivate 失败也必须 destroy：泄漏会永久阻塞本应用后续 create（session is existed）
      session.deactivate().catch((): void => {
      }).then((): Promise<void> => session.destroy()).catch((): void => {
      });
    }
    this.coverPixel = null;
    this.coverPixelUrl = '';
  }

  private syncAvMetadata(): void {
    const session: avSession.AVSession | null = this.avSessionValue;
    if (session === null) {
      return;
    }
    const chapter: FqChapter | undefined = this.chapters[this.index];
    const meta: avSession.AVMetadata = {
      assetId: `${this.bookId}:${this.itemId}:${this.toneId}`,
      title: this.title,
      artist: chapter !== undefined ? chapter.title : '',
      duration: Math.round((this.ttsMode ? this.ttsEstimatedDurationSec : this.durationSec) * 1000),
    };
    if (this.coverPixel !== null && this.coverPixelUrl === this.cover) {
      meta.mediaImage = this.coverPixel;
    }
    session.setAVMetadata(meta).catch((): void => {
    });
  }

  private syncAvPlaybackState(force: boolean): void {
    const session: avSession.AVSession | null = this.avSessionValue;
    if (session === null) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastAvSyncAt < 1000) {
      return;
    }
    this.lastAvSyncAt = now;
    let state: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    if (this.completed) {
      state = avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    } else if (this.wantPlay) {
      state = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    const playback: avSession.AVPlaybackState = {
      state: state,
      speed: this.rate,
      position: {
        elapsedTime: Math.round((this.ttsMode
          ? this.ttsProgress * this.ttsEstimatedDurationSec
          : this.positionSec) * 1000),
        updateTime: now,
      },
    };
    session.setAVPlaybackState(playback).catch((): void => {
    });
  }

  /** 拉取封面 → PixelMap（AVSession mediaImage；decGen 与章节装载解耦）。 */
  private loadCoverPixel(decGen: number): void {
    const url: string = this.cover;
    if (url.length === 0 || url === this.coverPixelUrl) {
      return;
    }
    const client: http.HttpRequest = http.createHttp();
    client.request(url, {
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: true,
      connectTimeout: 10000,
      readTimeout: 15000,
    })
      .then((response: http.HttpResponse): Promise<image.PixelMap> => {
        if (decGen !== this.decorationsGeneration) {
          return Promise.reject(new Error('stale'));
        }
        if (response.responseCode < 200 || response.responseCode >= 300
          || !(response.result instanceof ArrayBuffer)) {
          return Promise.reject(new Error(`cover fetch failed: ${response.responseCode}`));
        }
        const source: image.ImageSource = image.createImageSource(response.result);
        return source.createPixelMap();
      })
      .then((pixel: image.PixelMap): void => {
        if (decGen !== this.decorationsGeneration) {
          return;
        }
        this.coverPixel = pixel;
        this.coverPixelUrl = url;
        this.syncAvMetadata();
      })
      .catch((): void => {
        client.destroy();
      });
  }

  /** AVSession 后台播放模式随设置开关：开=允许后台播放，关=禁止（后台被系统停止）。 */
  private syncBackgroundPlayMode(): void {
    const session: avSession.AVSession | null = this.avSessionValue;
    if (session === null) {
      return;
    }
    const enabled: boolean = FqAppSettingsStore.isBackgroundAudio();
    if (this.bgPlayModeApplied === enabled) {
      return;
    }
    this.bgPlayModeApplied = enabled;
    session.setBackgroundPlayMode(enabled
      ? avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY
      : avSession.BackgroundPlayMode.DISABLE_BACKGROUND_PLAY).catch((): void => {
      });
  }

  /** 后台长时任务（audioPlayback：应用级引用计数共享，首个引用申请，release 释放）。 */
  private startBackgroundTask(): void {
    // 设置开关：关闭后台播放后不再申请长时任务（无法后台播放）
    if (!FqAppSettingsStore.isBackgroundAudio()) {
      return;
    }
    if (this.bgStarted || this.context === null) {
      return;
    }
    this.bgStarted = true;
    FqMediaBgTask.acquire(this.context);
  }

  private stopBackgroundTask(): void {
    if (!this.bgStarted) {
      return;
    }
    this.bgStarted = false;
    FqMediaBgTask.release();
  }
}

export const fqAudioSession: FqAudioSession = new FqAudioSession();

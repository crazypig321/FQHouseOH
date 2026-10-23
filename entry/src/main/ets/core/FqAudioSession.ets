/**
 * 听书会话（对齐 fqapp AudioPlaybackController + AudioPlaybackScope 语义）。
 *
 * 应用级持久单例：页面 pop 不停播；close 仅由 AVSession stop 命令 /
 * EntryAbility onDestroy 触发。负责：
 * - 章节装载（generation 取消、NO_THIS_TONE 兜底、历史恢复、播完态恢复）；
 * - 音色切换（智能朗读 toneId 重载 / 真人讲书跨书 switchBookVersion）；
 * - 历史持久化（5s 周期 + 暂停/切章/关闭即时写）；
 * - 睡眠定时（分钟档 + 播完本章）；
 * - AVSession 同步（胶囊/播控中心，1s 节流）与播控命令；
 * - 后台长时任务（首次播放申请，暂停保持，close 释放）。
 */

import avSession from '@ohos.multimedia.avsession';
import image from '@ohos.multimedia.image';
import http from '@ohos.net.http';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqAudioEngine } from './FqAudioEngine';
import { FqAudioHistory, FqListenRecord } from './FqAudioHistory';
import { FqBackend, fqErrorMessage } from './FqBackend';
import { FqChapter } from '../model/FqModels';
import {
  FqAudioSource,
  FqAudioTone,
  FqAudioToneSet,
  FqAudioVoice,
  fqDefaultVoices,
  FqRelatedWork,
  FqSubtitleTrack,
  fqEmptySubtitleTrack,
  fqEmptyToneSet,
} from '../model/FqAudioModels';
import { fqMergeToneVoices, fqUniqueTones } from './FqAudioParser';

const TAG: string = 'FqAudioSession';

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
  private avSessionValue: avSession.AVSession | null = null;
  private bgStarted: boolean = false;
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
      if (record.rate > 0) {
        this.rate = record.rate;
      }
      autoplay = !completed;
    }
    this.loadDecorations(this.nextDecorationsGeneration());
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
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    this.engine.release().catch((): void => {
    });
    this.stopBackgroundTask();
    const session: avSession.AVSession | null = this.avSessionValue;
    this.avSessionValue = null;
    if (session !== null) {
      session.deactivate().then((): Promise<void> => session.destroy()).catch((): void => {
      });
    }
    this.coverPixel = null;
    this.coverPixelUrl = '';
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
      this.positionSec = 0;
      this.engine.seek(0);
    }
    if (this.loading) {
      // 章节装载中：openChart 完成后按 wantPlay 起播
      this.wantPlay = true;
      this.syncAvPlaybackState(true);
      return;
    }
    this.wantPlay = true;
    this.engine.play().catch((error: BusinessError): void => {
      this.wantPlay = false;
      this.errorMessage = fqErrorMessage(error);
    });
    this.syncAvPlaybackState(true);
  }

  public pause(): void {
    if (!this.hasSession) {
      return;
    }
    this.wantPlay = false;
    this.engine.pause().catch((): void => {
    });
    this.persistHistory();
    this.syncAvPlaybackState(true);
  }

  /** 主播放/暂停键：错误态点击 = 重试。 */
  public togglePlayPause(): void {
    if (this.errorMessage.length > 0 && !this.loading) {
      this.openChapter(this.index, new FqChapterOpenOptions(this.toneId, this.positionSec, true, false));
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
    if (this.positionSec > 3 || this.completed) {
      this.seekTo(0);
      return;
    }
    if (this.index > 0) {
      this.openChapter(this.index - 1, new FqChapterOpenOptions(this.toneId, 0, this.wantPlay, false));
    } else {
      this.seekTo(0);
    }
  }

  public setRate(rate: number): void {
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
  // 内部：取源 / 装饰 / 定时
  // ---------------------------------------------------------------------------

  private async fetchSource(itemId: string, toneId: string,
    gen: number): Promise<FqAudioSource> {
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
    const now: number = Date.now();
    if (this.engine.isPlaying) {
      this.positionSec = this.engine.positionSec;
      const duration: number = this.engine.durationSec;
      if (duration > 0 && Math.abs(duration - this.durationSec) > 0.5) {
        this.durationSec = duration;
      }
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
    if (this.engine.isPlaying && now - this.lastHistorySaveAt >= 5000) {
      this.lastHistorySaveAt = now;
      this.persistHistory();
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
    FqAudioHistory.put(new FqListenRecord(this.bookId, this.index, this.positionSec,
      this.durationSec, this.toneId, this.rate, this.completed, this.title, this.cover));
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
    if (this.avSessionValue !== null || this.context === null) {
      return;
    }
    const context: common.UIAbilityContext = this.context;
    avSession.createAVSession(context, 'FqListen', 'audio')
      .then((session: avSession.AVSession): Promise<void> => {
        session.on('play', (): void => {
          this.play();
        });
        session.on('pause', (): void => {
          this.pause();
        });
        session.on('playNext', (): void => {
          this.next();
        });
        session.on('playPrevious', (): void => {
          this.previous();
        });
        session.on('stop', (): void => {
          this.close();
        });
        session.on('seek', (time: number): void => {
          this.seekTo(time / 1000);
        });
        this.avSessionValue = session;
        this.syncAvMetadata();
        this.syncAvPlaybackState(true);
        return session.activate();
      })
      .catch((error: BusinessError): void => {
        hilog.warn(0x0001, TAG, `AVSession create failed: ${error.message}`);
      });
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
      duration: Math.round(this.durationSec * 1000),
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
        elapsedTime: Math.round(this.positionSec * 1000),
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

  private startBackgroundTask(): void {
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

  private stopBackgroundTask(): void {
    if (!this.bgStarted || this.context === null) {
      return;
    }
    this.bgStarted = false;
    backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
    });
  }
}

export const fqAudioSession: FqAudioSession = new FqAudioSession();

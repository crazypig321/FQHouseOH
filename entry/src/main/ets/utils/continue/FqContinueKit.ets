/**
 * 应用流转（应用接续）工具：
 * - 源端：writeToWantParam() 在 EntryAbility.onContinue 中采集五场景
 *   （阅读 / 听书 / 漫画 / 视频 / 听视频）接续载荷并序列化进 wantParam；
 * - 目标端：parsePending() 在 onCreate / onNewWant（LaunchReason.CONTINUATION）解析载荷，
 *   applyPending() 写入进度 store + 设静态跳转参数 + 推入对应页面完成精确恢复
 *   （Navigation 页面栈不迁移：SUPPORT_CONTINUE_PAGE_STACK_KEY = false，目标端手动导航）；
 * - 应用内入口：startInAppContinuation() 经 continuationManager 拉起系统设备选择面板，
 *   用户选定设备后系统回调源端 onContinue 完成流转。
 */

import { continuationManager, wantConstant, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../../entryability/AppState';
import { FqReaderStore, FqReaderProgress } from '../../core/FqReaderStore';
import { FqAudioHistory, FqListenRecord } from '../../core/FqAudioHistory';
import { FqWatchedStore, FqWatchedProgress } from '../../core/FqWatchedStore';
import { FqLocalBookStore } from '../../core/FqLocalBookStore';
import { fqAudioSession } from '../../core/FqAudioSession';
import { FqBackend } from '../../core/FqBackend';
import { fqParseObject, fqStr, fqNum, fqBool } from '../../core/FqJson';
import { FqChapter, fqKindToTab } from '../../model/FqModels';
import {
  ReaderNavParams,
  ListenNavParams,
  PlayerNavParams,
  ListenVideoNavParams,
  ComicNavParams,
  ROUTE_READER2,
  ROUTE_LISTEN,
  ROUTE_PLAYER,
  ROUTE_LISTEN_VIDEO,
  ROUTE_COMIC,
} from '../../model/FqNavModels';
import { NavPathUtils } from '../NavPathUtils';
import { FqShareKit } from '../share/FqShareKit';

const DOMAIN = 0x0000;
/** wantParam 载荷键（序列化 JSON，规避与系统键冲突）。 */
const FQ_CONTINUE_WANT_KEY = 'fqContinue';
/** 场景：阅读（小说）。 */
const FQ_CONTINUE_SCENE_READ = 'read';
/** 场景：漫画阅读。 */
const FQ_CONTINUE_SCENE_COMIC = 'comic';
/** 场景：听书（在线音频 / 离线朗读）。 */
const FQ_CONTINUE_SCENE_LISTEN = 'listen';
/** 场景：视频（短剧 / 漫剧）。 */
const FQ_CONTINUE_SCENE_VIDEO = 'video';
/** 场景：听视频（听剧模式）。 */
const FQ_CONTINUE_SCENE_LISTEN_VIDEO = 'listenVideo';
/** 书旗只读来源 id 前缀（目标端按 raw id 拉目录正文，正常接续）。 */
const FQ_SHUQI_ID_PREFIX = 'shuqi:';

/** 接续载荷（源端采集 → wantParam 序列化 → 目标端解析恢复）。 */
export class FqContinuePayload {
  /** 场景（read / comic / listen / video / listenVideo）。 */
  scene: string = '';
  /** 作品 id：阅读 / 听书为 bookId，视频 / 听视频为 seriesId。 */
  id: string = '';
  /** 类型：read = ReaderNavParams.kind；listen = 详情 tab；video / listenVideo = kind。 */
  kind: string = '';
  title: string = '';
  cover: string = '';
  /** 章节 / 集下标（read / listen 目录序）。 */
  chapterIndex: number = -1;
  /** read：章内定位（'p2:段:字符'）。 */
  domPos: string = '';
  /** read / video / listenVideo：整书（剧）百分比。 */
  percent: number = -1;
  /** listen / video / listenVideo：当前章（集）内位置（秒）。 */
  positionSec: number = 0;
  /** listen / video：当前章（集）时长（秒）。 */
  durationSec: number = 0;
  /** video / listenVideo：当前集 itemId（listen 兼作 chapterItemId）。 */
  episodeItemId: string = '';
  /** listen：音色 id。 */
  toneId: string = '0';
  /** listen：播放速率。 */
  rate: number = 1;
  /** listen：当前章是否已播完。 */
  completed: boolean = false;
  /** listen：收听来源（online / tts）。 */
  mode: string = 'online';
  /** 记录时间戳（ms）。 */
  updatedAt: number = 0;
  /** listen：章内定位锚点原文。 */
  cueText: string = '';
  /** video：剧集状态（0 完结 / 1 连载中 / -1 未知）。 */
  creationStatus: number = -1;
  /** video：剧简介。 */
  intro: string = '';
}

/** 应用流转工具（源端采集 / 目标端恢复 / 应用内设备选择面板）。 */
export class FqContinueKit {
  /** 目标端待恢复载荷（onCreate / onNewWant 解析，Index 挂载后消费）。 */
  private static pendingPayload: FqContinuePayload | null = null;
  /** continuationManager 注册令牌（进程内一次注册复用，-1 未注册）。 */
  private static continuationToken: number = -1;

  /** 目标端是否存在待恢复的接续载荷。 */
  public static hasPending(): boolean {
    return FqContinueKit.pendingPayload !== null;
  }

  /**
   * 源端：onContinue 采集载荷写入 wantParam。
   * 按导航栈顶路由判定场景；栈顶非四页时回退听书会话（后台听书可接续）；
   * 无可接续内容时只禁用页面栈迁移（目标端按普通启动打开）。
   */
  public static writeToWantParam(wantParam: Record<string, Object>): void {
    // Navigation 路由栈不支持系统页面栈迁移，目标端手动恢复导航
    wantParam[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
    const payload: FqContinuePayload | null = FqContinueKit.buildPayload();
    if (payload === null) {
      return;
    }
    wantParam[FQ_CONTINUE_WANT_KEY] = JSON.stringify(payload);
  }

  /**
   * 目标端：onCreate / onNewWant（CONTINUATION）解析 want 载荷存为待恢复态。
   * 须在 restoreWindowStage 前同步调用（载荷仅在 Index 挂载后消费）。
   */
  public static parsePending(want: Want): void {
    FqContinueKit.pendingPayload = null;
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const text: string = fqStr(params, FQ_CONTINUE_WANT_KEY);
    if (text.length === 0) {
      return;
    }
    const rec: Record<string, Object> | null = fqParseObject(text);
    if (rec === null) {
      hilog.warn(DOMAIN, 'FqContinue', 'payload json invalid, skip');
      return;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = fqStr(rec, 'scene');
    payload.id = fqStr(rec, 'id');
    payload.kind = fqStr(rec, 'kind');
    payload.title = fqStr(rec, 'title');
    payload.cover = fqStr(rec, 'cover');
    payload.chapterIndex = Math.trunc(fqNum(rec, 'chapterIndex'));
    payload.domPos = fqStr(rec, 'domPos');
    payload.percent = Math.trunc(fqNum(rec, 'percent'));
    payload.positionSec = fqNum(rec, 'positionSec');
    payload.durationSec = fqNum(rec, 'durationSec');
    payload.episodeItemId = fqStr(rec, 'episodeItemId');
    payload.toneId = fqStr(rec, 'toneId');
    payload.rate = fqNum(rec, 'rate');
    payload.completed = fqBool(rec, 'completed');
    payload.mode = fqStr(rec, 'mode') === 'tts' ? 'tts' : 'online';
    payload.updatedAt = Math.trunc(fqNum(rec, 'updatedAt'));
    payload.cueText = fqStr(rec, 'cueText');
    payload.creationStatus = Math.trunc(fqNum(rec, 'creationStatus'));
    payload.intro = fqStr(rec, 'intro');
    if (payload.id.length === 0 || payload.scene.length === 0) {
      hilog.warn(DOMAIN, 'FqContinue', 'payload missing id/scene, skip');
      return;
    }
    hilog.info(DOMAIN, 'FqContinue', 'pending parsed: scene=%{public}s id=%{public}s',
      payload.scene, payload.id);
    FqContinueKit.pendingPayload = payload;
  }

  /**
   * 目标端：Index 挂载后消费待恢复载荷——按场景写入进度 store、
   * 设静态跳转参数并推入对应页面（页面按 store / 参数自行精确续播）。
   * 全程自捕获异常：恢复失败保持普通首页打开。
   */
  public static applyPending(): void {
    const payload: FqContinuePayload | null = FqContinueKit.pendingPayload;
    if (payload === null) {
      return;
    }
    FqContinueKit.pendingPayload = null;
    FqContinueKit.applyPayload(payload).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, 'FqContinue', 'apply failed: %{public}s', `${error.code} ${error.message}`);
    });
  }

  /** 应用内流转入口：拉起系统设备选择面板（用户选定设备后系统回调源端 onContinue）。 */
  public static startInAppContinuation(): void {
    if (FqContinueKit.continuationToken >= 0) {
      FqContinueKit.openContinuationPanel();
      return;
    }
    continuationManager.registerContinuation().then((token: number): void => {
      FqContinueKit.continuationToken = token;
      FqContinueKit.openContinuationPanel();
    }).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, 'FqContinue', 'register failed: %{public}s', `${error.code} ${error.message}`);
    });
  }

  /** 拉起设备选择面板（令牌已注册）。 */
  private static openContinuationPanel(): void {
    continuationManager.startContinuationDeviceManager(FqContinueKit.continuationToken)
      .catch((error: BusinessError): void => {
        hilog.error(DOMAIN, 'FqContinue', 'panel failed: %{public}s', `${error.code} ${error.message}`);
      });
  }

  /**
   * 源端载荷采集：栈顶路由 → 场景；本地导入书内容仅本机可取，跳过；
   * 书旗来源目标端同款后端可按 id 自取，正常采集。
   */
  private static buildPayload(): FqContinuePayload | null {
    const names: string[] = appState.pageInfos.getAllPathName();
    const top: string = names.length > 0 ? names[names.length - 1] : '';
    if (top === ROUTE_READER2) {
      const payload: FqContinuePayload | null = FqContinueKit.buildReadPayload();
      if (payload !== null) {
        return payload;
      }
    } else if (top === ROUTE_LISTEN) {
      const listenPayload: FqContinuePayload | null = FqContinueKit.buildListenPayload();
      if (listenPayload !== null) {
        return listenPayload;
      }
    } else if (top === ROUTE_COMIC) {
      const comicPayload: FqContinuePayload | null = FqContinueKit.buildComicPayload();
      if (comicPayload !== null) {
        return comicPayload;
      }
    } else if (top === ROUTE_PLAYER) {
      const videoPayload: FqContinuePayload | null = FqContinueKit.buildVideoPayload();
      if (videoPayload !== null) {
        return videoPayload;
      }
    } else if (top === ROUTE_LISTEN_VIDEO) {
      const listenVideoPayload: FqContinuePayload | null = FqContinueKit.buildListenVideoPayload();
      if (listenVideoPayload !== null) {
        return listenVideoPayload;
      }
    }
    // 栈顶非四页：后台听书会话兜底（听书不驻页也可接续）
    return FqContinueKit.buildListenPayload();
  }

  /** 阅读：身份取 ReaderNavParams，进度取 FqReaderStore（翻页即存，章内定位精确）。 */
  private static buildReadPayload(): FqContinuePayload | null {
    const id: string = ReaderNavParams.id;
    if (id.length === 0 || FqLocalBookStore.isLocalBookId(id)) {
      return null;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = FQ_CONTINUE_SCENE_READ;
    payload.id = id;
    payload.kind = ReaderNavParams.kind;
    payload.title = ReaderNavParams.title;
    payload.cover = ReaderNavParams.cover;
    const progress: FqReaderProgress = FqReaderStore.getProgress(id);
    payload.chapterIndex = Math.max(0, progress.chapterIndex);
    payload.domPos = progress.domPos;
    payload.percent = progress.percent;
    payload.updatedAt = progress.updatedAt;
    return payload;
  }

  /** 听书：身份取播放会话（含后台），记录取 FqAudioHistory（暂停 / 跳章 / 心跳即存）。 */
  private static buildListenPayload(): FqContinuePayload | null {
    if (!fqAudioSession.hasSession || fqAudioSession.bookId.length === 0) {
      return null;
    }
    const id: string = fqAudioSession.bookId;
    if (id.length === 0 || FqLocalBookStore.isLocalBookId(id)) {
      return null;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = FQ_CONTINUE_SCENE_LISTEN;
    payload.id = id;
    payload.kind = fqAudioSession.tab;
    payload.title = fqAudioSession.title;
    payload.cover = fqAudioSession.cover;
    const record: FqListenRecord | null = FqAudioHistory.get(id);
    if (record !== null) {
      payload.chapterIndex = record.chapterIndex;
      payload.positionSec = record.positionSec;
      payload.durationSec = record.durationSec;
      payload.toneId = record.toneId;
      payload.rate = record.rate;
      payload.completed = record.completed;
      payload.mode = record.mode;
      payload.updatedAt = record.updatedAt;
      payload.cueText = record.cueText;
      payload.episodeItemId = record.chapterItemId;
      return payload;
    }
    // 会话已开但历史未落（起播初期）：取会话当前态
    payload.chapterIndex = fqAudioSession.index;
    payload.positionSec = fqAudioSession.ttsMode ? 0 : fqAudioSession.positionSec;
    payload.durationSec = fqAudioSession.ttsMode ? 0 : fqAudioSession.durationSec;
    payload.toneId = fqAudioSession.toneId;
    payload.rate = fqAudioSession.rate;
    payload.completed = fqAudioSession.completed;
    payload.mode = fqAudioSession.ttsMode ? 'tts' : 'online';
    payload.updatedAt = Date.now();
    return payload;
  }

  /** 漫画：身份取 ComicNavParams，进度取 FqReaderStore（domPos 'img:N' 章内图定位）。 */
  private static buildComicPayload(): FqContinuePayload | null {
    const id: string = ComicNavParams.id;
    if (id.length === 0) {
      return null;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = FQ_CONTINUE_SCENE_COMIC;
    payload.id = id;
    payload.kind = 'manga';
    payload.title = ComicNavParams.title;
    payload.cover = ComicNavParams.cover;
    const progress: FqReaderProgress = FqReaderStore.getProgress(id);
    payload.chapterIndex = Math.max(0, progress.chapterIndex);
    payload.domPos = progress.domPos;
    payload.percent = progress.percent;
    payload.updatedAt = progress.updatedAt;
    return payload;
  }

  /** 视频：身份取 PlayerNavParams，续播取 FqWatchedStore（5s 心跳 + 暂停即存）。 */
  private static buildVideoPayload(): FqContinuePayload | null {
    if (PlayerNavParams.contentId.length === 0) {
      return null;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = FQ_CONTINUE_SCENE_VIDEO;
    payload.id = PlayerNavParams.contentId;
    payload.kind = PlayerNavParams.kind;
    payload.title = PlayerNavParams.title;
    payload.cover = PlayerNavParams.cover;
    payload.creationStatus = PlayerNavParams.creationStatus;
    payload.intro = PlayerNavParams.intro;
    const progress: FqWatchedProgress | null =
      FqWatchedStore.progress(PlayerNavParams.contentId);
    if (progress !== null) {
      payload.episodeItemId = progress.episodeId;
      payload.positionSec = progress.position;
      payload.durationSec = progress.duration;
      payload.percent = progress.percent;
      payload.completed = progress.duration > 0 && progress.position >= progress.duration - 0.5;
    }
    return payload;
  }

  /** 听视频：身份取 ListenVideoNavParams，位置取退出回传静态参数（1s tick 持续刷新）。 */
  private static buildListenVideoPayload(): FqContinuePayload | null {
    if (ListenVideoNavParams.contentId.length === 0) {
      return null;
    }
    const payload: FqContinuePayload = new FqContinuePayload();
    payload.scene = FQ_CONTINUE_SCENE_LISTEN_VIDEO;
    payload.id = ListenVideoNavParams.contentId;
    payload.kind = ListenVideoNavParams.kind;
    payload.title = ListenVideoNavParams.title;
    payload.cover = ListenVideoNavParams.cover;
    const index: number = ListenVideoNavParams.resultIndex;
    if (index >= 0 && index < ListenVideoNavParams.chapters.length) {
      payload.episodeItemId = ListenVideoNavParams.chapters[index].itemId;
      payload.positionSec = ListenVideoNavParams.resultPositionSec;
    }
    const progress: FqWatchedProgress | null =
      FqWatchedStore.progress(ListenVideoNavParams.contentId);
    if (progress !== null) {
      payload.durationSec = progress.duration;
      payload.percent = progress.percent;
    }
    return payload;
  }

  /**
   * 目标端恢复执行：写进度 store → 设静态跳转参数 → 推路由。
   * 各页面按既有续播链路精确恢复（阅读 domPos / 听书历史 / 视频按集 itemId 续播）。
   */
  private static async applyPayload(payload: FqContinuePayload): Promise<void> {
    if (payload.scene === FQ_CONTINUE_SCENE_READ) {
      FqReaderStore.saveProgress(payload.id, payload.chapterIndex, payload.domPos,
        payload.percent, payload.updatedAt > 0 ? payload.updatedAt : -1);
      // 书旗来源：目标端后端按 raw id 拉目录 + 只读阅读器（进度已落本机，续读生效）
      if (payload.id.startsWith(FQ_SHUQI_ID_PREFIX)) {
        await FqShareKit.openShuqiReader(payload.id.substring(FQ_SHUQI_ID_PREFIX.length),
          payload.title, payload.cover);
        return;
      }
      ReaderNavParams.id = payload.id;
      ReaderNavParams.kind = payload.kind;
      ReaderNavParams.title = payload.title;
      ReaderNavParams.cover = payload.cover;
      ReaderNavParams.chapterIndex = -1;
      ReaderNavParams.listenAlong = false;
      ReaderNavParams.readOnly = false;
      ReaderNavParams.presetChapters = [];
      ReaderNavParams.chapterLoader = null;
      NavPathUtils.push(ROUTE_READER2);
      return;
    }
    if (payload.scene === FQ_CONTINUE_SCENE_COMIC) {
      FqReaderStore.saveProgress(payload.id, payload.chapterIndex, payload.domPos,
        payload.percent, payload.updatedAt > 0 ? payload.updatedAt : -1);
      ComicNavParams.id = payload.id;
      ComicNavParams.chapterIndex = -1;
      ComicNavParams.title = payload.title;
      ComicNavParams.cover = payload.cover;
      NavPathUtils.push(ROUTE_COMIC);
      return;
    }
    if (payload.scene === FQ_CONTINUE_SCENE_LISTEN) {
      FqAudioHistory.put(new FqListenRecord(payload.id, payload.chapterIndex,
        payload.positionSec, payload.durationSec, payload.toneId, payload.rate,
        payload.completed, payload.title, payload.cover, payload.mode,
        payload.updatedAt > 0 ? payload.updatedAt : Date.now(), payload.cueText,
        payload.episodeItemId));
      ListenNavParams.bookId = payload.id;
      ListenNavParams.tab = payload.kind;
      ListenNavParams.title = payload.title;
      ListenNavParams.cover = payload.cover;
      ListenNavParams.chapters = [];
      ListenNavParams.chapterIndex = -1;
      ListenNavParams.startCueText = '';
      NavPathUtils.push(ROUTE_LISTEN);
      return;
    }
    if (payload.scene === FQ_CONTINUE_SCENE_VIDEO) {
      if (payload.episodeItemId.length > 0) {
        FqWatchedStore.saveProgress(payload.id, new FqWatchedProgress(payload.episodeItemId,
          payload.positionSec, payload.durationSec, payload.percent));
      }
      PlayerNavParams.contentId = payload.id;
      PlayerNavParams.kind = payload.kind;
      PlayerNavParams.title = payload.title;
      PlayerNavParams.cover = payload.cover;
      PlayerNavParams.chapters = [];
      PlayerNavParams.startIndex = -1;
      PlayerNavParams.creationStatus = payload.creationStatus;
      PlayerNavParams.intro = payload.intro;
      NavPathUtils.push(ROUTE_PLAYER);
      return;
    }
    if (payload.scene === FQ_CONTINUE_SCENE_LISTEN_VIDEO) {
      // 听视频页无自拉目录：目标端先取剧集目录，再按集 itemId 定位 + 偏移起听
      const context: common.UIAbilityContext | null = appState.abilityContext;
      if (context === null) {
        return;
      }
      await FqBackend.get().start(context);
      const episodes: FqChapter[] =
        await FqBackend.get().directoryChapters(payload.id, fqKindToTab(payload.kind));
      if (episodes.length === 0) {
        return;
      }
      let startIndex: number = 0;
      if (payload.episodeItemId.length > 0) {
        for (let i: number = 0; i < episodes.length; i++) {
          if (episodes[i].itemId === payload.episodeItemId) {
            startIndex = i;
            break;
          }
        }
      }
      ListenVideoNavParams.contentId = payload.id;
      ListenVideoNavParams.kind = payload.kind;
      ListenVideoNavParams.title = payload.title;
      ListenVideoNavParams.cover = payload.cover;
      ListenVideoNavParams.chapters = episodes;
      ListenVideoNavParams.startIndex = startIndex;
      ListenVideoNavParams.startPositionSec = payload.positionSec;
      ListenVideoNavParams.resultIndex = -1;
      ListenVideoNavParams.resultPositionSec = 0;
      NavPathUtils.push(ROUTE_LISTEN_VIDEO);
    }
  }
}

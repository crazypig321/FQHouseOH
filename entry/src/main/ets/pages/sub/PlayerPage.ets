/**
 * 视频播放页（PlayerPage，mpv 播放器，对齐 fqapp 官方短剧竖屏播放页布局）：
 * - 竖屏（fqapp video_player_chrome.dart catalog 样式）：
 *   顶栏（返回 + 「第N集」+ 播放设置菜单）、视频区 contain（底部预留 163vp 信息区）、
 *   「全屏观看」药丸 + 右侧评论按钮跟随播放区域下方（videoBottom+30）、
 *   底部信息区（自上而下：剧名行 → 细进度线（#FFFA6725、4vp）→
 *   「选集 · 已完结 · 全N集」胶囊（#E6222222、圆角 8））；
 *   控件常驻（官方竖屏无自动收起）；画面中央播放/暂停按钮点击才出现
 *   （仅非全屏渲染；暂停时常驻、播放 3s 后自动隐藏，单击画面切播放）。
 * - 全屏（fqapp _landscapeBar / _fullscreenPill）：
 *   横屏片源（videoParams.dw > dh）进入沉浸横屏（AUTO_ROTATION_LANDSCAPE +
 *   隐藏系统栏），底部控制条（播放/下一集/时间/进度/倍速/选集）3s 自动隐藏；
 *   全屏（横竖屏）单击切控件显隐、双击切播放/暂停；竖屏片源全屏顶栏避让
 *   maxTopRect（沉浸隐藏状态栏后 topRect 归零），且不渲染中央播放按钮。
 *   横屏片源全屏的选集/播放设置改走右侧边栏（深色面板 + 全屏遮罩，
 *   遮罩点击收起；底部 sheet 遮幅大影响观看，侧边栏只占右侧一条）。
 * - 选集半模态 FqStoryPanel（官方 StoryPlayerPanel 白底样式）；剧名行与
 *   「全屏观看」药丸层锚定底部信息区，恒在进度线与选集胶囊上方。
 * - 原著横幅（官方 _originalBookCard）：剧名行与进度线之间，仅剧有原著
 *   （/api/v1/series/{id} 的 video_relate_book.book_info）才显示；白方徽
 *   书本图标 + 「原著《书名》」+ 右箭头，点击进原著详情页。横幅出现时信息
 *   列向上生长（官方 informationTop 上移），全屏药丸钳制让位（官方 maximumTop）。
 * - 半模态均走公共框架 FqSheetOptions，只是不触发前景光感模糊；
 *   右上角菜单呼出「播放设置」半模态（倍速档位）；
 *   评论按钮呼出「集评」半模态（公共 FqCommentSheet + 弹幕接口加载器：
 *   当前播放集的评论而非整部剧剧评，切集面板开着自动重载）。
 * - 离线缓存（fqapp DramaDownloadSheet 语义）：选集胶囊行「缓存」入口 /
 *   播放设置「离线缓存」行呼出缓存选集半模态（已缓存集置灰打勾、任务态
 *   实时进度、默认全选未缓存集、头部「管理」进剧集缓存管理页）；
 *   已缓存集 loadEpisode 直接播本地文件，在线取流失败也回退缓存文件。
 * - 播完自动连播；aboutToDisappear 销毁 mpv 实例并恢复沉浸前的系统 UI。
 * - 长按屏幕右侧 2 倍速快进（官方 jq3 长按带外分支 / fqapp _startBoost）：
 *   按住期间 2x、松开恢复原倍速，画面中央「2倍速快进中」指示。
 * - 全屏半屏竖滑调节：左半屏上下滑调窗口亮度（setWindowBrightness 0-100%，
 *   离页恢复跟随系统）、右半屏上下滑调播放音量（mpv 软音量 0-100，
 *   无需权限；系统 AudioManager.setVolume 已废弃不走）；滑动中中央
 *   浮层显示档位图标与百分比，松手后短驻自隐。
 * - 全屏防误触锁（官方 fullscreen/d.K6）：横屏片源左侧竖直居中（圆形
 *   半透明黑底），竖屏片源最底部左边（无底色）；锁定后上下工具不可呼出、
 *   画面操作与返回手势全吞（禁止手势退出全屏），仅锁按钮可唤出
 *   （5s 自隐，任意触摸重新唤出）；解锁立即恢复控件。
 * - 已看集标记与续播（fqapp watched_episodes.dart / video_progress 一族）：
 *   已看按集 itemId 持久化（FqWatchedStore），实际播放过（position > 0）才标记，
 *   跳集观看绝不误标中间集；续播进度（集 + 位置）暂停/切集/周期 5s/退出保存，
 *   再次进入自动续播上次看到的集与位置（播完则该集从头）。
 * - 弹幕（全屏展示）：/api/v1/videos/{vid}/danmaku 按 cursor 续拉，
 *   切集整池作废、seek 按目标时间重取；FqDanmakuView 车道避让右→左飞行，
 *   全屏控制条「弹幕」开关（官方 Toast 文案）。
 */

import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Player, PlayerSurface, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';
import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { FqSheetOptions } from '../../view/CommonSheet';
import { FqCommentSheet, fqCommentSheetHeightVp } from '../../view/FqCommentSheet';
import { FqMenu, FqMenuItem } from '../../view/CommonMenu';
import { FqDanmakuView } from '../../view/FqDanmakuView';
import { FqSettingRow } from '../../view/FqSettingRow';
import { FqStoryPanel } from '../../view/FqStoryPanel';
import { DetailNavParams, PlayerNavParams, ListenVideoNavParams, ROUTE_DETAIL, ROUTE_LISTEN_VIDEO, ROUTE_CACHED_DRAMAS } from '../../model/FqNavModels';
import { FqBookCommentPage, FqChapter, FqDanmaku, FqDanmakuPage, FqEpisodeCommentPage, FqEpisodeSource, FqSeriesRelateBook, fqKindToTab } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { fqAudioSession } from '../../core/FqAudioSession';
import { FqVideoMedia } from '../../core/FqVideoMedia';
import { FqWatchedStore, FqWatchedProgress } from '../../core/FqWatchedStore';
import { FqDramaCacheStore } from '../../core/FqDramaCacheStore';
import { fqDramaDownloader, FqDramaDownloader, FqDramaDownloadTask, DramaDownloadStatus } from '../../core/FqDramaDownloader';
import { FqReadStatsStore } from '../../core/FqReadStatsStore';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';

/** 官方竖屏播放页底部信息/进度/选集区高度（PlayerVideoLayout bottom 163）。 */
const FQ_STORY_BOTTOM_INSET: number = 163;
/** 官方短剧橙（#FFFA6725：进度线/当前集/角标）。 */
const FQ_STORY_ORANGE: string = '#FFFA6725';
/** 全屏控件自动隐藏延时（官方横屏 3s，_scheduleHide）。 */
const FQ_FS_HIDE_MS: number = 3000;
/** 播放设置倍速滑杆范围与步进（0.5-2.0、步进 0.25）。 */
const FQ_SPEED_MIN: number = 0.5;
const FQ_SPEED_MAX: number = 2.0;
const FQ_SPEED_STEP: number = 0.25;
/** 倍速滑杆断点档数（0.5-2.0 步进 0.25，共 7 档）。 */
const FQ_SPEED_STEP_COUNT: number = 7;

/** 倍速滑杆断点值（0.5 → 2.0 步进 0.25）。 */
function fqSpeedSteps(): number[] {
  const steps: number[] = [];
  for (let i: number = 0; i < FQ_SPEED_STEP_COUNT; i++) {
    steps.push(FQ_SPEED_MIN + i * FQ_SPEED_STEP);
  }
  return steps;
}

/** 倍速断点显示文案（去尾零，如 0.75× / 1× / 1.5×）。 */
function fqSpeedStepLabel(step: number): string {
  const rounded: number = Math.round(step * 100) / 100;
  return `${rounded}×`;
}
/** 长按临时快进倍速（官方长按 setRate(2)）。 */
const FQ_BOOST_SPEED: number = 2.0;
/** 长按识别时长（ms）。 */
const FQ_LONG_PRESS_MS: number = 500;
/** 锁定按钮自动隐藏延时（官方 d.G6() 5s）。 */
const FQ_LOCK_HIDE_MS: number = 5000;
/** 全屏半屏竖滑调节浮层松手后驻留时长（ms）。 */
const FQ_ADJUST_HIDE_MS: number = 600;
/** 全屏竖滑灵敏度：滑过 1.2 倍屏高走完全量程（0-100）。 */
const FQ_ADJUST_FULL_SWIPE: number = 1.2;
/** 首次调节亮度起始百分比（窗口亮度只写不读，无从取当前值）。 */
const FQ_ADJUST_INIT_PERCENT: number = 50;
/** 横屏全屏右侧边栏宽（选集/播放设置共用）。 */
const FQ_FS_SIDE_PANEL_W: number = 300;
/** 侧边栏背景（近黑高不透明，压得住浅色画面又不糊死视频）。 */
const FQ_FS_SIDE_BG: string = '#F0141414';
/** 全屏底部倍速按钮锚点 id（FqMenu 档位菜单挂靠）。 */
const PLAYER_FS_SPEED_ANCHOR_ID: string = 'player_fs_speed_anchor';
/** 播放设置深色（横屏侧边栏）配色：半透明白卡片/分隔线/滑轨/次级文字。 */
const FQ_DARK_CARD_BG: string = '#26FFFFFF';
const FQ_DARK_DIVIDER: string = '#1FFFFFFF';
const FQ_DARK_TRACK: string = '#33FFFFFF';
const FQ_DARK_TERTIARY_TEXT: string = '#99FFFFFF';

/** 播放设置行描述（key 决定右侧控件：speed 滑杆 / cache、listen 箭头 / danmaku 开关）。 */
class FqSettingItem {
  readonly key: string;
  readonly title: string;
  readonly icon: Resource;

  constructor(key: string, title: string, icon: Resource) {
    this.key = key;
    this.title = title;
    this.icon = icon;
  }
}

/** mm:ss 播放时间。 */
function fqFormatClock(seconds: number): string {
  let value: number = seconds;
  if (!Number.isFinite(value) || value < 0) {
    value = 0;
  }
  const total: number = Math.floor(value);
  const minutes: number = Math.floor(total / 60);
  const rest: number = total % 60;
  return `${minutes}:${rest < 10 ? '0' : ''}${rest}`;
}

/** 选集半模态高度（官方竖屏面板 55% 屏高，PlayerVideoLayout.panelFractionFor）。 */
function fqPlayerSheetHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  let screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  // 沉浸横屏（全屏横屏片源）时屏高取短边，避免面板超出横屏可视区
  if (displayData.rotation % 2 === 1 && appState.screenWidth > 0) {
    screenHeight = Math.min(screenHeight, appState.screenWidth);
  }
  const height: number = Math.round((screenHeight / density) * 0.55);
  return height > 0 ? height : 480;
}

@ComponentV2
export struct PlayerPage {
  /** mpv 播放器（@ObservedV2；state 经 @Trace 驱动本页渲染）。 */
  private player: Player = new Player(new PlayerConfig());
  /** 剧集目录（详情页预载；为空则本页拉目录）。 */
  @Local episodes: FqChapter[] = [];
  /** 当前集下标。 */
  @Local index: number = 0;
  /** 集流加载中（/api/content 取流）。 */
  @Local loading: boolean = true;
  @Local errorMsg: string = '';
  /** 选集半模态（打开时视频区撑满全屏、chrome 隐藏）。 */
  @Local sheetVisible: boolean = false;
  /** 播放设置半模态（右上角菜单呼出：倍速滑杆/离线缓存/听视频/弹幕开关，公共 FqSettingRow）。 */
  @Local settingsVisible: boolean = false;
  /** 倍速滑杆拖动预览值（-1 未拖动；拖动中文案实时跟随，松手提交 mpv）。 */
  @Local speedPreview: number = -1;
  /** 集评半模态（评论按钮呼出：公共 FqCommentSheet，当前播放集的评论）。 */
  @Local commentSheetVisible: boolean = false;
  /** 集评打开令牌（每次打开/开着时切集 +1，FqCommentSheet 据此重置重载当前集）。 */
  @Local commentOpenToken: number = 0;
  /** 全屏沉浸态（「全屏观看」进入；横屏片源锁横屏 + 隐藏系统栏）。 */
  @Local fullScreen: boolean = false;
  /** 全屏控件显隐（横片源 3s 自动隐藏，单击画面切换）。 */
  @Local fsControlsVisible: boolean = true;
  /** 中央播放按钮显隐（点击才出现；暂停时常驻，播放 3s 后自动隐藏）。 */
  @Local centerBtnVisible: boolean = false;
  /** 进度条拖动预览（-1 未拖动；拖动时画面中央出时间浮层）。 */
  @Local seekPreview: number = -1;
  /** 封面绝对地址（加载占位图/面板头部；start 后由 resourceUrl 锚定）。 */
  @Local coverUrl: string = '';
  /** 弹幕开关（全屏弹幕层显隐；官方开关 Toast 文案）。 */
  @Local danmakuOn: boolean = true;
  /** 当前集已加载弹幕（offsetMs 升序，按 id 去重）。 */
  @Local danmakuItems: FqDanmaku[] = [];
  /** 弹幕层重置令牌（seek/切集 +1，清已飞/在飞状态）。 */
  @Local danmakuResetToken: number = 0;
  /** 关联原著（剧有原著才显示横幅；装饰性数据，失败静默）。 */
  @Local originalBook: FqSeriesRelateBook | null = null;
  /** 已看集 itemId 集合（FqWatchedStore；标记后重赋值驱动选集面板刷新）。 */
  @Local watchedIds: Set<string> = new Set<string>();
  /** 横屏全屏右侧边栏（'episodes' 选集 / 'settings' 播放设置；'' 关闭）。 */
  @Local sidePanel: string = '';
  /** 离线缓存选集半模态（选集胶囊行「缓存」/播放设置「离线缓存」行呼出）。 */
  @Local cacheSheetVisible: boolean = false;
  /** 缓存 sheet 内已勾选集 itemId（打开时默认全选未缓存集）。 */
  @Local cacheSelectedIds: Set<string> = new Set<string>();
  /** 缓存 sheet 内已完整缓存集 itemId（打开时从 FqDramaCacheStore 刷新）。 */
  @Local cacheDownloadedIds: Set<string> = new Set<string>();

  private title: string = '';
  private tab: string = '短剧';
  /** 剧集状态（0 完结 / 1 连载中 / -1 未知）。 */
  private creationStatus: number = -1;
  /** 异步加载令牌（页面销毁/切集后旧请求作废）。 */
  private loadToken: number = 0;
  /** 半模态关闭令牌。 */
  private sheetCloseToken: number = 0;
  /** 播放设置半模态关闭令牌。 */
  private settingsCloseToken: number = 0;
  /** 离线缓存半模态关闭令牌。 */
  private cacheCloseToken: number = 0;
  /** 剧集下载引擎单例（@Trace taskList/任务进度实时驱动缓存 sheet 刷新）。 */
  @Local dl: FqDramaDownloader = fqDramaDownloader;
  /** 剧评半模态关闭令牌。 */
  private commentCloseToken: number = 0;
  /** 集评游标（弹幕接口 cursor 不透明续拉串；切集/重开由加载器重置）。 */
  private episodeCommentCursor: string = '';
  /** 集评游标所属集 itemId（换集时作废旧游标）。 */
  private episodeCommentVid: string = '';
  /** 全屏控件自动隐藏定时器（0 无任务）。 */
  private fsHideTimer: number = 0;
  /** 中央播放按钮 3s 自动隐藏定时器（0 无任务）。 */
  private centerHideTimer: number = 0;
  /** 弹幕加载令牌（切集/seek 后旧请求作废）。 */
  private danmakuLoadToken: number = 0;
  /** 当前集已实际播放（position > 0；切集重置，已看标记 guard）。 */
  private hasDisplayed: boolean = false;
  /** 本剧续播进度（进页恢复；暂停/切集/周期/退出保存）。 */
  private progress: FqWatchedProgress | null = null;
  /** 进页待恢复的续播位置（秒；仅首开命中的那一次消费）。 */
  private pendingResumeSec: number = -1;
  /** 显式起播集下标（详情目录点击进页播对应集）；-1 未指定走续播/从头。 */
  private explicitStartIndex: number = -1;
  /** 周期保存计数（5s 一存，仅播放中）。 */
  private progressTick: number = 0;
  /** 长按右侧 2 倍速快进中（松开恢复原倍速）。 */
  @Local speedBoost: boolean = false;
  /** 快进前倍速（松开恢复）。 */
  private boostRestoreSpeed: number = -1;
  /** 横屏全屏防误触锁（锁定后控件不可呼出，仅锁按钮可唤出）。 */
  @Local fsLocked: boolean = false;
  /** 锁定按钮可见（锁定后 5s 自隐，任意触摸唤出）。 */
  @Local lockVisible: boolean = false;
  /** 锁定按钮自动隐藏定时器（0 无任务）。 */
  private lockHideTimer: number = 0;
  /** 全屏手势调节目标（'' 无 | 'brightness' 亮度 | 'volume' 音量）。 */
  @Local gestureAdjust: string = '';
  /** 手势调节当前百分比（0-100，浮层显示）。 */
  @Local gestureAdjustPercent: number = 0;
  /** 手势调节起始值（0-100）。 */
  private adjustStartValue: number = 0;
  /** 手势调节起始纵坐标（vp，globalY）。 */
  private adjustStartY: number = 0;
  /** 手势调节浮层隐藏定时器（0 无任务）。 */
  private adjustHideTimer: number = 0;
  /** 窗口亮度百分比（-1 未手动调过；首次滑动从 50 起，离页恢复跟随系统）。 */
  private brightnessPercent: number = -1;
  /** 侧边栏选集滚动器（打开时滚到当前集竖直居中）。 */
  private sideScroller: Scroller = new Scroller();
  /** 侧边栏选集定位定时器（0 无任务）。 */
  private sideLocateTimer: number = 0;
  /** 弹幕续拉游标（common_list_info.cursor）。 */
  private danmakuCursor: string = '';
  /** 弹幕还有更多（common_list_info.has_more）。 */
  private danmakuHasMore: boolean = false;
  /** 弹幕已加载覆盖到的位置（毫秒，next_query_danmaku_list_time）。 */
  private danmakuLoadedToMs: number = 0;
  /** 弹幕进度心跳定时器（0 无任务）。 */
  private danmakuTimer: number = 0;
  /** 听视频页返回待消费（onShown 时按听到的集/位置续看）。 */
  private listenReturnPending: boolean = false;
  /** 听视频返回切集标记：听视频页已持久化最新（集,位置），loadEpisode 跳过旧集续播回写与新集 0 位置覆盖。 */
  private listenReturnSwitch: boolean = false;
  /** 屏幕尺寸（vp，布局定位用）。 */
  private screenW: number = 0;
  private screenH: number = 0;
  /** AVSession/后台播放助手（通知栏播控中心/胶囊 + 后台 audioPlayback 长时任务）。 */
  private media: FqVideoMedia = new FqVideoMedia('FqVideo');
  /** AVSession 元数据已同步时长（切集重置 -1；时长事件到达后补发元数据）。 */
  private mediaDurationSynced: number = -1;
  /** 切后台主动暂停回调（关闭后台播放时 EntryAbility onBackground 调用）。 */
  private backgroundPause: () => void = (): void => {};
  /** 视听统计累计秒（播放中每满 15s 落一次按书统计）。 */
  private statsSec: number = 0;

  aboutToAppear(): void {
    this.title = PlayerNavParams.title;
    this.tab = fqKindToTab(PlayerNavParams.kind);
    this.creationStatus = PlayerNavParams.creationStatus;
    this.episodes = PlayerNavParams.chapters;
    if (PlayerNavParams.startIndex >= 0) {
      this.explicitStartIndex = PlayerNavParams.startIndex;
    }
    let start: number = PlayerNavParams.startIndex;
    if (start < 0 || start >= this.episodes.length) {
      start = 0;
    }
    this.index = start;
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    this.screenW = displayData.width / density;
    this.screenH = displayData.height / density;
    this.player.stream.eof.listen((eof: boolean): void => {
      if (eof) {
        this.onEpisodeEnd();
      }
    });
    // 已看集：按集 itemId 持久化（FqWatchedStore），加载本剧已看集合与续播进度
    FqWatchedStore.init(getContext(this));
    this.progress = FqWatchedStore.progress(PlayerNavParams.contentId);
    this.watchedIds = this.copyWatchedIds();
    // 实际播放 guard：position 走表（非加载期）才视为看过（对齐 fqapp 首帧不标）
    this.player.stream.position.listen((pos: number): void => {
      if (pos > 0 && !this.loading) {
        this.hasDisplayed = true;
      }
    });
    // 弹幕进度心跳：接近已加载右界时按 cursor 续拉；同时周期保存续播进度
    this.danmakuTimer = setInterval((): void => {
      this.danmakuTick();
      this.progressSaveTick();
      this.mediaTick();
    }, 1000);
    // AVSession（通知栏播控中心/胶囊）播控命令 + 后台播放长时任务
    const mediaContext: common.UIAbilityContext | null = appState.abilityContext;
    if (mediaContext !== null) {
      this.media.init(mediaContext);
    }
    this.media.onPlay = (): void => {
      if (this.errorMsg.length > 0) {
        return;
      }
      this.player.play();
      this.syncMediaState(true);
    };
    this.media.onPause = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    this.media.onStop = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    this.media.onPrevious = (): void => {
      if (this.player.state.position > 3) {
        this.player.seek(0);
        return;
      }
      if (this.index > 0) {
        this.loadEpisode(this.index - 1);
      } else {
        this.player.seek(0);
      }
    };
    this.media.onNext = (): void => {
      this.nextEpisode();
    };
    this.media.onSeek = (sec: number): void => {
      this.player.seek(sec);
      this.seekDanmaku(sec * 1000);
      this.saveCurrentProgress();
      this.syncMediaState(this.player.state.playing);
    };
    this.media.onFastForward = (sec: number): void => {
      this.skipPosition(sec, true);
    };
    this.media.onRewind = (sec: number): void => {
      this.skipPosition(sec, false);
    };
    // 关闭后台播放：切后台主动暂停（图标/状态一致，回前台一键续播）
    this.backgroundPause = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    appState.backgroundPauseHandlers.push(this.backgroundPause);
    if (this.episodes.length === 0) {
      this.loadEpisodes();
    } else {
      // 显式起播集（详情目录点击进页）优先；否则续播（fqapp resumeEpisodeIndex）
      const resumeIndex: number = this.explicitStartIndex >= 0 ? -1 : this.resumeStartIndex();
      if (resumeIndex >= 0) {
        this.index = resumeIndex;
      }
      this.loadEpisode(this.index);
    }
    // 关联原著（官方 _loadBandExtras：装饰性数据，失败静默不影响播放）
    this.loadOriginalBook();
  }

  aboutToDisappear(): void {
    const bgHandlerIdx: number = appState.backgroundPauseHandlers.indexOf(this.backgroundPause);
    if (bgHandlerIdx >= 0) {
      appState.backgroundPauseHandlers.splice(bgHandlerIdx, 1);
    }
    this.endSpeedBoost();
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.loadToken += 1;
    this.cancelFsHide();
    this.cancelCenterHide();
    this.cancelLockHide();
    this.cancelAdjustHide();
    this.cancelSideLocate();
    if (this.danmakuTimer !== 0) {
      clearInterval(this.danmakuTimer);
      this.danmakuTimer = 0;
    }
    if (this.fullScreen) {
      this.applyImmersive(false);
    }
    // 手动调过窗口亮度则恢复跟随系统（-1），避免亮度残留影响其他页面
    if (this.brightnessPercent >= 0) {
      this.brightnessPercent = -1;
      window.getLastWindow(getContext(this)).then((win: window.Window): void => {
        win.setWindowBrightness(-1);
      }).catch((): void => {
        // 恢复失败交由系统窗口销毁兜底
      });
    }
    this.media.release();
    this.player.destroy();
  }

  build() {
    CommonNav({
      hideTitleBar: true,
      showBrandGradient: false,
      pageBackgroundColor: Color.Black,
      showPlaybackBall: false,
      onShown: (): void => {
        this.onNavShown();
      },
      backPressed: (): boolean => {
        // 全屏沉浸态先退全屏（官方返回语义），再返回上一页；
        // 防误触锁开启时吞掉返回手势：禁止手势退出全屏，只唤出锁按钮
        if (this.fullScreen) {
          if (this.fsLocked) {
            this.refreshLockVisibility();
            return true;
          }
          this.exitFullscreen();
          return true;
        }
        return false;
      },
    }) {
      Stack() {
        // 视频区（contain；mpv 内部保持比例留黑边；全屏时撑满，面板展开时几何不变）
        Stack() {
          PlayerSurface({ player: this.player, ignoreSafeArea: false })

          if (this.errorMsg.length === 0 && this.loading) {
            this.LoadingOverlay()
          }

          if (this.errorMsg.length === 0 && !this.loading && this.player.state.buffering) {
            this.BufferingOverlay()
          }

          // 拖动进度时的中央时间浮层（官方 _seeking 覆盖层，24sp）
          if (this.seekPreview >= 0) {
            Text(`${fqFormatClock(this.seekPreview)} / ${fqFormatClock(this.player.state.duration)}`)
              .fontSize(24)
              .fontColor(Color.White)
          }

          // 长按 2 倍速快进指示（官方「2倍速快进中」，长按期间显示）
          if (this.speedBoost) {
            Text('2倍速快进中')
              .fontSize(13)
              .fontColor(Color.White)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(16)
              .backgroundColor('rgba(0,0,0,0.55)')
          }

          // 全屏半屏竖滑调节浮层（左亮度/右音量：档位图标 + 百分比，松手短驻自隐；
          // 固定宽度，避免 0%→100% 文字变长时背景宽度跳动）
          if (this.gestureAdjust.length > 0) {
            Column({ space: 6 }) {
              SymbolGlyph(this.adjustIconRes())
                .fontSize(26)
                .fontColor([Color.White])
              Text(`${Math.round(this.gestureAdjustPercent)}%`)
                .fontSize(16)
                .fontColor(Color.White)
            }
            .width(84)
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 14, bottom: 14 })
            .borderRadius(18)
            .backgroundColor('rgba(0,0,0,0.55)')
          }

          if (this.errorMsg.length > 0) {
            this.ErrorOverlay()
          }
        }
        .width('100%')
        .height(this.fullScreen ? '100%' : this.videoRegionHeight())
        .position({ x: 0, y: this.fullScreen ? 0 : this.videoTopAbs() })
        .backgroundColor(Color.Black)
        // 全屏：单击切控件显隐、双击切播放/暂停（互斥识别，双击优先）；
        // 长按屏幕右侧 2 倍速快进（锁定态全部吞掉，只唤出锁按钮）；
        // 全屏竖滑：左半屏调亮度、右半屏调音量（滑过 1.2 倍屏高走完全量程）；
        // 非全屏：单击切播放（保持原样）
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 })
              .onAction((): void => {
                if (this.fullScreen) {
                  if (this.fsLocked) {
                    this.refreshLockVisibility();
                    return;
                  }
                  this.syncFsControls(this.togglePlay());
                }
              }),
            TapGesture({ count: 1 })
              .onAction((): void => {
                this.onVideoTap();
              }),
            LongPressGesture({ duration: FQ_LONG_PRESS_MS })
              .onAction((event?: GestureEvent): void => {
                this.beginSpeedBoost(event);
              })
              .onActionEnd((): void => {
                this.endSpeedBoost();
              })
              .onActionCancel((): void => {
                this.endSpeedBoost();
              }),
            PanGesture({ fingers: 1, direction: PanDirection.Vertical })
              .onActionStart((event?: GestureEvent): void => {
                this.onAdjustPanStart(event);
              })
              .onActionUpdate((event?: GestureEvent): void => {
                this.onAdjustPanUpdate(event);
              })
              .onActionEnd((): void => {
                this.onAdjustPanEnd();
              })
              .onActionCancel((): void => {
                this.onAdjustPanEnd();
              })
          )
        )
        // 右上角菜单呼出的播放设置半模态（公共框架，不触发前景模糊）
        .bindSheet(this.settingsVisible, this.SettingsSheetBuilder(),
          FqSheetOptions((): void => {
            this.closeSettings();
          }, 320, false))

        // 中央播放/暂停按钮（非全屏渲染：点击才出现：暂停时常驻、播放 3s 后隐藏）
        if (this.errorMsg.length === 0 && !this.loading && !this.sheetVisible && !this.fullScreen &&
          (!this.player.state.playing || this.centerBtnVisible)) {
          this.CenterPlayButton()
        }

        // 弹幕层：只占屏上 20% 高度、锚定顶部（尽量少遮挡画面）；
        // 竖屏片源全屏沉浸后 topRect 归零，用 maxTopRect 保底下移避开摄像头孔条（同 FsTopBar 语义）；
        // 且整棵子树不参与触摸测试，绝不影响底部控制条交互
        if (this.fullScreen && this.danmakuOn && this.errorMsg.length === 0 && this.danmakuItems.length > 0) {
          FqDanmakuView({
            items: this.danmakuItems,
            positionMs: Math.floor(this.player.state.position * 1000),
            resetToken: this.danmakuResetToken,
            playing: this.player.state.playing,
          })
            .width('100%')
            .height('20%')
            .position({ x: 0, y: this.isLandscapeVideo() ? appState.topRect : appState.maxTopRect })
            .hitTestBehavior(HitTestMode.None)
        }

        if (!this.fullScreen) {
          this.TopBar()
          this.CatalogBar()
        }

        if (this.fullScreen && !this.sheetVisible && this.sidePanel.length === 0 && this.fsControlsVisible) {
          this.FsTopBar()
          this.FsBottomBar()
        }

        // 全屏防误触锁：横屏左侧竖直居中（黑底圆钮）/ 竖屏最底部左边（无底色）；
        // 解锁随控件显隐，锁定后仅本按钮可唤出（5s 自隐，任意触摸重新唤出）
        if (this.fullScreen && !this.sheetVisible &&
          (this.fsLocked ? this.lockVisible : this.fsControlsVisible)) {
          this.LockButton()
        }

        // 横屏全屏右侧边栏（选集/播放设置）：全屏遮罩点击收起，深色面板贴右滑入；
        // 底部 sheet 遮幅大影响观看，侧边栏只占右侧一条，视频不停播
        if (this.fullScreen && this.isLandscapeVideo() && this.sidePanel.length > 0) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,0.35)')
            .onClick((): void => {
              this.closeSidePanel();
            })
            .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))

          Column() {
            if (this.sidePanel === 'episodes') {
              this.SideEpisodes()
            } else {
              this.SideSettings()
            }
          }
          .width(FQ_FS_SIDE_PANEL_W)
          .height('100%')
          .position({ x: '100%', y: 0 })
          .markAnchor({ x: FQ_FS_SIDE_PANEL_W, y: 0 })
          .backgroundColor(FQ_FS_SIDE_BG)
          .transition(TransitionEffect.translate({ x: FQ_FS_SIDE_PANEL_W })
            .animation({ duration: 200, curve: Curve.Friction }))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .bindSheet(this.sheetVisible, this.EpisodeSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, fqPlayerSheetHeightVp(), false))
    }
  }

  // ---------------------------------------------------------------------------
  // 控件层（官方竖屏常驻：顶栏 / 剧名行 / 全屏药丸+评论 / 细进度线 / 选集胶囊）
  // ---------------------------------------------------------------------------

  /** 顶栏：渐变底、返回 + 「第N集」+ 倍速菜单（官方竖屏顶栏标题就是集数）。 */
  @Builder
  private TopBar() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          NavPathUtils.pop();
        })

        Text(`第${this.episodes.length > 0 ? this.index + 1 : 1}集`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .padding({ left: 4 })

        Row() {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openSettings();
        })
      }
      .height(44)
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: appState.topRect, left: 8, right: 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.54)', 0.0], ['rgba(0,0,0,0.0)', 1.0]],
    })
    .position({ x: 0, y: 0 })
  }

  /** 剧名行：锚定底部信息区顶（恒在进度线/选集胶囊上方），点击回剧集详情。 */
  @Builder
  private SeriesTitleRow() {
    Row() {
      Row({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 官方标题行 Shadow(black45, blur 8)：原著横幅撑高信息列后剧名行
          // 可能压到画面下沿，靠阴影保可读
          .textShadow({ radius: 8, color: 'rgba(0,0,0,0.45)', offsetX: 0, offsetY: 0 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([Color.White])
          .opacity(0.85)
      }
      .constraintSize({ maxWidth: '100%' })
      .onClick((): void => {
        NavPathUtils.pop();
      })
    }
    .width('100%')
    .padding({ left: 6, right: 6 })
  }

  /**
   * 原著横幅（官方 _originalBookCard）：深色圆角条，白色小方徽（20×20、
   * 深色书本图标）+「原著《书名》」14sp bold 白 + 右箭头；点击进原著详情页
   * （官方 /related kind=book 跳转链路）。
   */
  @Builder
  private OriginalBookBanner() {
    Row({ space: 8 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.book_open_fill'))
          .fontSize(13)
          .fontColor(['#FF1B1B1B'])
      }
      .width(20)
      .height(20)
      .borderRadius(5)
      .backgroundColor(Color.White)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Text(`原著《${this.originalBookTitle()}》`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([Color.White])
        .opacity(0.85)
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .borderRadius(10)
    .backgroundColor('rgba(255,255,255,0.08)')
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.openOriginalBook();
    })
  }

  /**
   * 「全屏观看」药丸（官方 _fullscreenPill）：水平居中，纵向在画面下沿与
   * 底部信息区之间的空带居中（不与剧名行/进度线/选集胶囊重叠）。
   */
  @Builder
  private FullscreenPill() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
        .fontSize(16)
        .fontColor([Color.White])
      Text('全屏观看')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .borderRadius(8)
    .backgroundColor('#B3262626')
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.enterFullscreen();
    })
  }

  /** 中央播放/暂停按钮（暂停态实心、播放态半透明提示可暂停）。 */
  @Builder
  private CenterPlayButton() {
    Row() {
      SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(30)
        .fontColor([Color.White])
    }
    .width(64)
    .height(64)
    .borderRadius(32)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.28)')
    .opacity(this.player.state.playing ? 0.45 : 1)
    .position({
      x: this.screenW / 2,
      y: this.videoTopAbs() + this.videoRegionHeight() / 2,
    })
    .markAnchor({ x: '50%', y: '50%' })
    .onClick((): void => {
      this.syncFsControls(this.togglePlay());
    })
  }

  /** 细进度线：4vp 轨道、官方橙进度、白拖点；两侧显示当前时间/总时长。 */
  @Builder
  private SeekBar() {
    Row() {
      Text(fqFormatClock(this.displayPosition()))
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.85)')
        .margin({ right: 8 })
      this.SeekSlider()
      Text(fqFormatClock(this.player.state.duration))
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.85)')
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .height(30)
  }

  /** 进度滑杆（竖屏进度线与横屏控制条共用）。 */
  @Builder
  private SeekSlider() {
    Slider({
      value: this.displayPosition(),
      min: 0,
      max: this.displayDuration(),
      step: 1,
    })
      .layoutWeight(1)
      .height(30)
      .trackThickness(4)
      .trackColor('rgba(255,255,255,0.3)')
      .selectedColor(FQ_STORY_ORANGE)
      .blockColor(Color.White)
      .blockSize({ width: 14, height: 14 })
      .onChange((value: number, mode: SliderChangeMode) => {
        if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
          this.seekPreview = value;
        } else {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.player.seek(value);
            this.seekDanmaku(value * 1000);
          }
          this.seekPreview = -1;
          this.scheduleFsHide();
        }
      })
  }

  /** 选集胶囊：深灰条「选集 · 已完结 · 全82集 ↑」（官方 player-catalog-bar）。 */
  @Builder
  private CatalogBar() {
    Column({ space: 12 }){
      // 「全屏观看」药丸：视频实际画面出现（尺寸就绪）才显示，加载占位期不出现
      if (this.player.state.videoParams.dw > 0) {
        this.FullscreenPill()
      }

      Column({ space: 2 }){
        this.SeriesTitleRow()

        // 原著横幅（官方 _originalBookCard）：剧名行与进度线之间，仅有原著时显示
        if (this.originalBook !== null) {
          this.OriginalBookBanner()
        }
      }.padding({ left: 10, right: 10 })

      this.SeekBar()

      Row() {
        Row() {
          Text(this.catalogLabel())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 官方 keyboard_arrow_up：本地用已验证的 chevron_right 旋转 -90° 等价
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(20)
            .fontColor([Color.White])
            .rotate({ angle: -90 })
        }
        .height(40)
        .padding({ left: 16, right: 12 })
        .borderRadius(8)
        .backgroundColor('#E6222222')
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)
        .onClick((): void => {
          this.openCatalog();
        })

        // 评论入口：并入选集行右端，呼出集评半模态（公共 FqCommentSheet）
        Column({ space: 1 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(22)
            .fontColor([Color.White])
            .opacity(0.9)
          Text('评论')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(255,255,255,0.9)')
        }
        .width(44)
        .height(40)
        .margin({ left: 8 })
        .borderRadius(8)
        .backgroundColor('#E6222222')
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openComments();
        })
        .bindSheet(this.commentSheetVisible, this.CommentsSheetBuilder(),
          FqSheetOptions((): void => {
            this.closeComments();
          }, fqCommentSheetHeightVp(), false))

        // 缓存入口：并入选集行右端（评论旁），呼出离线缓存选集半模态
        Column({ space: 1 }) {
          SymbolGlyph($r('sys.symbol.download'))
            .fontSize(22)
            .fontColor([Color.White])
            .opacity(0.9)
          Text('缓存')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(255,255,255,0.9)')
        }
        .width(44)
        .height(40)
        .margin({ left: 8 })
        .borderRadius(8)
        .backgroundColor('#E6222222')
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openCacheSheet();
        })
        .bindSheet(this.cacheSheetVisible, this.CacheSheetBuilder(),
          FqSheetOptions((): void => {
            this.closeCacheSheet();
          }, fqPlayerSheetHeightVp(), false))
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }.layoutGravity(LocalizedAlignment.BOTTOM_END)// stack组件中子组件对齐位置
    .offset({ bottom: appState.bottomRect })
  }

  // ---------------------------------------------------------------------------
  // 全屏控件层（官方 _landscapeBar：顶栏 + 底部控制条，3s 自动隐藏）
  // ---------------------------------------------------------------------------

  /** 全屏顶栏：渐变底、返回（退全屏）+「剧名(粗) 第N集」+ 倍速菜单。 */
  @Builder
  private FsTopBar() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.exitFullscreen();
        })

        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .padding({ left: 4 })

        Text(`第${this.episodes.length > 0 ? this.index + 1 : 1}集`)
          .fontSize(16)
          .fontColor(Color.White)
          .maxLines(1)
          .padding({ left: 6, right: 4 })

        Row() {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openSettings();
        })
      }
      .height(44)
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // 竖屏片源全屏沉浸隐藏状态栏后 topRect 归零，用 maxTopRect 保底避让；
    // 横屏片源维持 topRect（沉浸态贴边）；左右 padding 横竖屏区分（竖屏 8）
    .padding({ top: this.isLandscapeVideo() ? appState.topRect : appState.maxTopRect, left: this.isLandscapeVideo() ? 20 : 8, right: this.isLandscapeVideo() ? 20 : 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.54)', 0.0], ['rgba(0,0,0,0.0)', 1.0]],
    })
    .position({ x: 0, y: 0 })
  }

  /** 全屏底部控制条（官方 _landscapeBar）：播放/下一集/时间/进度/总时长 + 倍速/选集。 */
  @Builder
  private FsBottomBar() {
    Column() {
      Row() {
        SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(26)
          .fontColor([Color.White])
          .onClick((): void => {
            this.syncFsControls(this.togglePlay());
          })

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(24)
          .fontColor([Color.White])
          .margin({ left: 18 })
          .onClick((): void => {
            this.nextEpisode();
            this.scheduleFsHide();
          })

        Text(fqFormatClock(this.displayPosition()))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ left: 18, right: 10 })

        this.SeekSlider()

        Text(fqFormatClock(this.player.state.duration))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ left: 10 })
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)

      Row({ space: 24 }) {
        Text('弹幕')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .opacity(this.danmakuOn ? 1 : 0.45)
          .onClick((): void => {
            this.toggleDanmaku();
          })

        Text(`${this.player.state.speed}×`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .id(PLAYER_FS_SPEED_ANCHOR_ID)
          .onClick((): void => {
            this.openSpeedMenu();
          })

        Text('选集')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .onClick((): void => {
            this.openCatalog();
          })
      }
      .width('100%')
      .height(36)
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: appState.bottomRect > 0 ? appState.bottomRect : 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.0)', 0.0], ['rgba(0,0,0,0.5)', 1.0]],
    })
    .position({ x: 0, y: '100%' })
    .markAnchor({ x: 0, y: '100%' })
  }

  /**
   * 全屏防误触锁按钮（官方 uk3/c）：横屏片源左侧竖直居中（44 圆形半透明
   * 黑底）；竖屏片源最底部左边（无底色，避让底部条第二行左空带）；
   * 锁定 lock_fill / 解锁 lock_open；点按切换锁定。
   */
  @Builder
  private LockButton() {
    if (this.isLandscapeVideo()) {
      Row() {
        SymbolGlyph(this.fsLocked ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open'))
          .fontSize(20)
          .fontColor([Color.White])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(78, 78, 78, 0.45)')
      .position({ x: 36, y: '50%' })
      .markAnchor({ x: 0, y: '50%' })
      .onClick((): void => {
        this.toggleLock();
      })
    } else {
      Row() {
        SymbolGlyph(this.fsLocked ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock_open'))
          .fontSize(22)
          .fontColor([Color.White])
      }
      .padding({
        left: 16,
        bottom: 12 + (appState.bottomRect > 0 ? appState.bottomRect : 0),
      })
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
      .onClick((): void => {
        this.toggleLock();
      })
    }
  }

  /** 加载占位：封面 contain + spinner（官方 PlayerCover/PlayerLoadingFeedback）。 */
  @Builder
  private LoadingOverlay() {
    Stack() {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Black)
          .autoResize(true)
      }
      Column({ space: 10 }) {
        LoadingProgress()
          .width(42)
          .height(42)
          .color(Color.White)
        Text(`正在加载第 ${this.index + 1} 集`)
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.85)')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 缓冲指示（起播后 mpv buffering，不遮画面只出 spinner）。 */
  @Builder
  private BufferingOverlay() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(42)
        .height(42)
        .color(Color.White)
      Text('缓冲中…')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.85)')
    }
  }

  /** 加载/取流失败重试卡。 */
  @Builder
  private ErrorOverlay() {
    Column({ space: 14 }) {
      Text(this.errorMsg)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.9)')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('重试')
        .type(ButtonType.Capsule)
        .height(34)
        .fontSize(14)
        .backgroundColor(FQ_ACCENT)
        .onClick((): void => {
          this.retry();
        })
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 26, right: 26, top: 22, bottom: 22 })
    .borderRadius(16)
    .backgroundColor('rgba(0,0,0,0.7)')
    .onClick((): void => {
    })
  }

  /** 选集半模态（官方 StoryPlayerPanel 白底样式）。 */
  @Builder
  private EpisodeSheetBuilder() {
    FqStoryPanel({
      episodes: this.episodes,
      currentIndex: this.index,
      watchedIds: this.watchedIds,
      seriesTitle: this.title,
      seriesCover: this.coverUrl,
      seriesIntro: PlayerNavParams.intro,
      episodeLabel: this.episodeLabel(),
      onSelectEpisode: (index: number): void => {
        this.closeSheet();
        this.loadEpisode(index);
      },
    })
  }

  /** 集评半模态：公共 FqCommentSheet + 弹幕接口集评加载器
   *  （首拉 Loading / 错误重试 / 空态 / cursor 分页列表，评论为当前播放集的）。 */
  @Builder
  private CommentsSheetBuilder() {
    FqCommentSheet({
      bookId: PlayerNavParams.contentId,
      fontColor: $r('sys.color.font_primary'),
      commentLabel: '集评',
      cursorLoader: (refresh: boolean): Promise<FqBookCommentPage> => this.loadEpisodeComments(refresh),
      openToken: this.commentOpenToken,
    })
  }

  /**
   * 离线缓存选集半模态（fqapp DramaDownloadSheet 语义）：头部「离线缓存 · 剧名」
   * +「管理」（进剧集缓存管理页）、集数网格复选（已缓存置灰打勾、任务态实时
   * 进度/排队/暂停/失败、选中橙底描边打勾、默认全选未缓存集）、全选 + 下载按钮。
   */
  @Builder
  private CacheSheetBuilder() {
    Column() {
      Row() {
        Text(`离线缓存 · ${this.title}`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FF000000')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('管理')
          .fontSize(14)
          .fontColor(FQ_STORY_ORANGE)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.closeCacheSheet();
            NavPathUtils.push(ROUTE_CACHED_DRAMAS);
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: 20, right: 8 })
      .alignItems(VerticalAlign.Center)

      Grid() {
        ForEach(this.episodes, (episode: FqChapter, index: number) => {
          GridItem() {
            this.CacheEpisodeCell(episode, index)
          }
        }, (episode: FqChapter) => episode.itemId)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Row() {
        Text(this.cacheAllSelected() ? '取消全选' : '全选')
          .fontSize(14)
          .fontColor(this.cachePendingCount() === 0 ? $r('sys.color.font_tertiary') : FQ_STORY_ORANGE)
          .padding({ left: 4, right: 4, top: 10, bottom: 10 })
          .onClick((): void => {
            this.toggleCacheSelectAll();
          })

        Blank()

        Button(`下载 (${this.cacheSelectedIds.size})`)
          .type(ButtonType.Capsule)
          .height(36)
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.cacheSelectedIds.size > 0 ? FQ_STORY_ORANGE : '#33000000')
          .enabled(this.cacheSelectedIds.size > 0)
          .onClick((): void => {
            this.confirmCacheDownload();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 缓存格：已缓存置灰打勾 / 任务态橙色（进度%/排队/暂停/失败）/ 可选集（选中橙底描边打勾）。 */
  @Builder
  private CacheEpisodeCell(episode: FqChapter, index: number) {
    Row({ space: 3 }) {
      Text(this.cacheCellLabel(episode, index))
        .fontSize(13)
        .fontColor(this.cacheCellTextColor(episode))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.cacheCellShowCheck(episode)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor([this.cacheCellTextColor(episode)])
      }
    }
    .height(32)
    .padding({ left: 6, right: 6 })
    .borderRadius(8)
    .backgroundColor(this.cacheCellBg(episode))
    .border({ width: this.cacheCellSelected(episode) ? 1 : 0, color: FQ_STORY_ORANGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onCacheCellClick(episode);
    })
  }

  /** 打开离线缓存选集半模态：刷新缓存/勾选状态（默认全选未缓存集）。 */
  private openCacheSheet(): void {
    if (this.episodes.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '剧集目录加载中', duration: 1500 });
      return;
    }
    if (this.fullScreen) {
      this.exitFullscreen();
    }
    this.closeSettings();
    this.refreshCacheSheetState();
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.cacheSheetVisible = true;
    });
  }

  /** 刷新缓存 sheet 状态：已缓存集合 + 默认全选未缓存集。 */
  private refreshCacheSheetState(): void {
    const cached: Set<string> = FqDramaCacheStore.cachedEpisodeIds(PlayerNavParams.contentId);
    this.cacheDownloadedIds = cached;
    const selected: Set<string> = new Set<string>();
    for (const episode of this.episodes) {
      if (!cached.has(episode.itemId)) {
        selected.add(episode.itemId);
      }
    }
    this.cacheSelectedIds = selected;
  }

  /** 关闭离线缓存半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeCacheSheet(): void {
    const token: number = ++this.cacheCloseToken;
    setTimeout((): void => {
      if (token === this.cacheCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.cacheSheetVisible = false;
        });
      }
    }, 0);
  }

  /** 未缓存集数（全选按钮置灰判定）。 */
  private cachePendingCount(): number {
    let count: number = 0;
    for (const episode of this.episodes) {
      if (!this.cacheDownloadedIds.has(episode.itemId)) {
        count++;
      }
    }
    return count;
  }

  /** 全选判定（存在未缓存集且全部已勾选）。 */
  private cacheAllSelected(): boolean {
    if (this.cachePendingCount() === 0) {
      return false;
    }
    for (const episode of this.episodes) {
      if (!this.cacheDownloadedIds.has(episode.itemId) && !this.cacheSelectedIds.has(episode.itemId)) {
        return false;
      }
    }
    return true;
  }

  /** 全选/取消全选未缓存集。 */
  private toggleCacheSelectAll(): void {
    if (this.cachePendingCount() === 0) {
      return;
    }
    if (this.cacheAllSelected()) {
      this.cacheSelectedIds = new Set<string>();
      return;
    }
    const selected: Set<string> = new Set<string>();
    for (const episode of this.episodes) {
      if (!this.cacheDownloadedIds.has(episode.itemId)) {
        selected.add(episode.itemId);
      }
    }
    this.cacheSelectedIds = selected;
  }

  /** 缓存格点击：已缓存不响应；失败重试/暂停继续；可选集勾选切换。 */
  private onCacheCellClick(episode: FqChapter): void {
    if (this.cacheDownloadedIds.has(episode.itemId)) {
      return;
    }
    const task: FqDramaDownloadTask | null = this.dl.taskOf(episode.itemId);
    if (task !== null) {
      if (task.status === DramaDownloadStatus.Failed) {
        this.dl.retry(episode.itemId);
      } else if (task.status === DramaDownloadStatus.Paused) {
        this.dl.resume(episode.itemId);
      }
      return;
    }
    const next: Set<string> = new Set<string>(this.cacheSelectedIds);
    if (next.has(episode.itemId)) {
      next.delete(episode.itemId);
    } else {
      next.add(episode.itemId);
    }
    this.cacheSelectedIds = next;
  }

  /** 下载勾选集（已完整缓存/已在队列的 enqueue 内部跳过），完成后清空勾选。 */
  private confirmCacheDownload(): void {
    if (this.cacheSelectedIds.size === 0) {
      return;
    }
    for (let i: number = 0; i < this.episodes.length; i++) {
      const episode: FqChapter | undefined = this.episodes[i];
      if (episode !== undefined && this.cacheSelectedIds.has(episode.itemId)) {
        this.dl.enqueue(PlayerNavParams.contentId, episode.itemId, episode.title,
          this.title, PlayerNavParams.cover, PlayerNavParams.kind, i + 1);
      }
    }
    this.cacheSelectedIds = new Set<string>();
  }

  /** 缓存格是否选中（未缓存、无任务且已勾选，橙色描边判定）。 */
  private cacheCellSelected(episode: FqChapter): boolean {
    return !this.cacheDownloadedIds.has(episode.itemId)
      && this.dl.taskOf(episode.itemId) === null
      && this.cacheSelectedIds.has(episode.itemId);
  }

  /** 缓存格文案：已缓存 / 任务态（下载百分比）/ 第 N 集。 */
  private cacheCellLabel(episode: FqChapter, index: number): string {
    if (this.cacheDownloadedIds.has(episode.itemId)) {
      return '已缓存';
    }
    const task: FqDramaDownloadTask | null = this.dl.taskOf(episode.itemId);
    if (task !== null) {
      if (task.status === DramaDownloadStatus.Downloading) {
        if (task.totalBytes > 0) {
          return `${Math.floor(task.receivedBytes / task.totalBytes * 100)}%`;
        }
        return '下载中';
      }
      if (task.status === DramaDownloadStatus.Waiting) {
        return '排队中';
      }
      if (task.status === DramaDownloadStatus.Paused) {
        return '已暂停';
      }
      if (task.status === DramaDownloadStatus.Failed) {
        return '失败';
      }
      return '已缓存';
    }
    return `第 ${index + 1} 集`;
  }

  /** 缓存格文字色：已缓存灰、失败红、任务/选中橙、普通黑。 */
  private cacheCellTextColor(episode: FqChapter): ResourceColor {
    if (this.cacheDownloadedIds.has(episode.itemId)) {
      return '#66000000';
    }
    const task: FqDramaDownloadTask | null = this.dl.taskOf(episode.itemId);
    if (task !== null) {
      if (task.status === DramaDownloadStatus.Failed) {
        return '#FFD33918';
      }
      return FQ_STORY_ORANGE;
    }
    if (this.cacheSelectedIds.has(episode.itemId)) {
      return FQ_STORY_ORANGE;
    }
    return '#FF000000';
  }

  /** 缓存格底色：任务/选中橙 8% 底，其余黑 6% 底。 */
  private cacheCellBg(episode: FqChapter): ResourceColor {
    if (!this.cacheDownloadedIds.has(episode.itemId)
      && (this.dl.taskOf(episode.itemId) !== null || this.cacheSelectedIds.has(episode.itemId))) {
      return '#14FA6725';
    }
    return '#0F000000';
  }

  /** 缓存格尾随勾：已缓存或选中。 */
  private cacheCellShowCheck(episode: FqChapter): boolean {
    return this.cacheDownloadedIds.has(episode.itemId) || this.cacheCellSelected(episode);
  }

  /** 播放设置半模态（右上角菜单）：公共 FqSettingRow 设置行 List（与横屏侧边栏共用）——
   * 倍速（Slider 滑杆 0.5-2.0 步进 0.25，拖动实时预览、松手生效）、
   * 离线缓存/听视频（跳转箭头）、弹幕开关（Switch 开关）。 */
  @Builder
  private SettingsSheetBuilder() {
    Column() {
      Column().height(12)

      Row() {
        Text('播放设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(48)
      .padding({ left: 20, right: 16 })
      .alignItems(VerticalAlign.Center)

      this.SettingRows(false)
    }
    .width('100%')
    .height('100%')
  }

  /** 播放设置行 List（半模态浅色/横屏侧边栏深色共用，dark 控制前景与分隔线配色）：
   * ForEach 渲染公共 FqSettingRow——倍速（滑杆）/离线缓存、听视频（箭头占位）/弹幕开关。 */
  @Builder
  private SettingRows(dark: boolean) {
    List() {
      ListItemGroup(){
        ForEach(this.settingItems(), (item: FqSettingItem) => {
          ListItem() {
            FqSettingRow({
              icon: item.icon,
              title: item.title,
              tintColor: dark ? Color.White : $r('sys.color.font'),
              click: (): void => {
                this.onSettingRowClick(item.key);
              }
            }) {
            if (item.key === 'speed') {
              // 倍速：滑杆切换（轨道分段刻度 + 断点倍速文本标识；拖动实时预览，松手提交 mpv）
                Column({ space: 2 }) {
                  Slider({
                    value: this.player.state.speed,
                    min: FQ_SPEED_MIN,
                    max: FQ_SPEED_MAX,
                    step: FQ_SPEED_STEP,
                    style: SliderStyle.InSet
                  })
                    .width('100%')
                    .height(30)
                    .showSteps(true)
                    .stepColor(dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
                    .blockColor(FQ_STORY_ORANGE)
                    .selectedColor('#33FA6725')
                    .trackColor(dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
                    .onChange((value: number, mode: SliderChangeMode): void => {
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.player.setSpeed(value);
                      } else {
                        this.speedPreview = value;
                      }
                    })

                  // 断点倍速文本标识：第 i 档锚定在 i/(档数-1)*100% 处，与滑杆刻度两端对齐
                  Row() {
                    ForEach(fqSpeedSteps(), (step: number, index: number) => {
                      Text(fqSpeedStepLabel(step))
                        .fontSize(7)
                        .fontWeight(this.isCurrentSpeedStep(step) ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(this.isCurrentSpeedStep(step) ? FQ_STORY_ORANGE :
                          (dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_tertiary')))
                    }, (step: number) => `${step}`)
                  }
                  .justifyContent(FlexAlign.SpaceBetween)
                  .width('100%')
                  .hitTestBehavior(HitTestMode.None)
                }.layoutWeight(1)
            } else if (item.key === 'danmaku') {
                // 弹幕开关：Switch（同全屏控制条 toggleDanmaku，含官方 Toast 文案）
                Toggle({ type: ToggleType.Switch, isOn: this.danmakuOn })
                  .selectedColor(FQ_STORY_ORANGE)
                  .onChange((isOn: boolean): void => {
                    if (isOn !== this.danmakuOn) {
                      this.toggleDanmaku();
                    }
                  })
              } else {
                // 离线缓存/听视频：跳转箭头
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([dark ? '#99FFFFFF' : $r('sys.color.font_tertiary')])
              }
            }
          }
        }, (item: FqSettingItem) => item.key)
      }
      .borderRadius(14)
      .backgroundColor(dark ? FQ_DARK_CARD_BG : $r('sys.color.comp_background_list_card'))
      .divider({
        strokeWidth: 0.5,
        color: dark ? FQ_DARK_DIVIDER : $r('sys.color.comp_divider'),
        startMargin: 48,
        endMargin: 14
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .padding({ right: 20, left: 20 })
  }

  /** 设置行点击：听视频进听剧模式页；离线缓存呼出缓存选集半模态（倍速/弹幕行右侧控件自理）。 */
  private onSettingRowClick(key: string): void {
    if (key === 'cache') {
      this.openCacheSheet();
    } else if (key === 'listen') {
      this.openListenMode();
    }
  }

  /**
   * 听视频（fqapp listen_mode_page 语义）：暂停视频页播放，推入听视频页
   * （独立 mpv 只听不看）；全屏沉浸先退全屏。已看/续播由听视频页写入同键
   * FqWatchedStore，退出回传结果由 onNavShown 消费续看。
   */
  private openListenMode(): void {
    if (this.episodes.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '剧集目录加载中', duration: 1500 });
      return;
    }
    if (this.fullScreen) {
      this.exitFullscreen();
    }
    this.closeSettings();
    if (this.sidePanel.length > 0) {
      this.closeSidePanel();
    }
    this.player.pause();
    this.saveCurrentProgress();
    // 让路听视频页：释放本页 AVSession/后台任务（通知栏由听视频会话接管）
    this.media.release();
    ListenVideoNavParams.contentId = PlayerNavParams.contentId;
    ListenVideoNavParams.kind = PlayerNavParams.kind;
    ListenVideoNavParams.title = this.title;
    ListenVideoNavParams.cover = PlayerNavParams.cover;
    ListenVideoNavParams.chapters = this.episodes;
    ListenVideoNavParams.startIndex = this.index;
    ListenVideoNavParams.startPositionSec = this.player.state.position;
    ListenVideoNavParams.resultIndex = -1;
    ListenVideoNavParams.resultPositionSec = 0;
    this.listenReturnPending = true;
    NavPathUtils.push(ROUTE_LISTEN_VIDEO);
  }

  /**
   * NavDestination 显示回调（含从听视频页返回）：按听到的集/位置续看
   * （fqapp sync_progress_strategy_listen_mode）并自动续播——
   * 跨集走切集链路偏移起播（open 自动播），同集 seek 到听到位置后 play；
   * 续播记录由听视频页退出时写入，这里跳过 loadEpisode 的旧集回写。
   */
  private onNavShown(): void {
    if (!this.listenReturnPending) {
      return;
    }
    this.listenReturnPending = false;
    const listenIndex: number = ListenVideoNavParams.resultIndex;
    const listenPos: number = ListenVideoNavParams.resultPositionSec;
    ListenVideoNavParams.resultIndex = -1;
    ListenVideoNavParams.resultPositionSec = 0;
    if (listenIndex < 0) {
      return;
    }
    if (listenIndex !== this.index && listenIndex < this.episodes.length) {
      this.pendingResumeSec = listenPos > 0 ? listenPos : -1;
      // 听视频页已把（新集,听到位置）写入 FqWatchedStore：
      // loadEpisode 跳过旧集续播回写与新集 0 位置覆盖，起播位置由 Media start 对齐
      this.listenReturnSwitch = true;
      this.loadEpisode(listenIndex);
      // 中央按钮随新集起播短暂显示暂停态，3s 自动隐藏（对齐手动点击播放）
      this.centerBtnVisible = true;
      this.scheduleCenterHide();
      return;
    }
    if (listenPos > 0) {
      this.player.seek(listenPos);
    }
    // 退出听视频自动续播 + 重建 openListenMode 让路的 AVSession/后台任务
    this.player.play();
    this.media.ensureSession('video');
    this.media.startBackground();
    this.pushMediaMetadata();
    this.syncMediaState(true);
    // 中央按钮短暂显示暂停态，3s 自动隐藏（对齐手动点击播放的交互）
    this.centerBtnVisible = true;
    this.scheduleCenterHide();
  }

  /** AVSession 元数据推送（剧名/集名/时长/封面）。 */
  private pushMediaMetadata(): void {
    const episode: FqChapter | undefined = this.episodes[this.index];
    this.media.updateMetadata(
      `${PlayerNavParams.contentId}:${episode !== undefined ? episode.itemId : this.index}`,
      this.title,
      episode !== undefined ? episode.title : '',
      this.player.state.duration,
      this.coverUrl);
  }

  /** AVSession 播放态立即同步（播放意图优先，绕过 mpv 状态异步）。 */
  private syncMediaState(playing: boolean): void {
    this.media.syncPlayback(true, playing, this.player.state.speed, this.player.state.position);
  }

  /** 播控中心快进/快退 ±sec 秒（夹在 [0, 时长]；同步弹幕、续播进度与播放态）。 */
  private skipPosition(sec: number, forward: boolean): void {
    const target: number = forward
      ? Math.min(this.player.state.position + sec, this.player.state.duration)
      : Math.max(this.player.state.position - sec, 0);
    this.player.seek(target);
    this.seekDanmaku(target * 1000);
    this.saveCurrentProgress();
    this.syncMediaState(this.player.state.playing);
  }

  /** AVSession 周期同步（1s 节流内含；时长事件到达后补发元数据）+ 视听统计累计。 */
  private mediaTick(): void {
    const duration: number = this.player.state.duration;
    if (duration > 0 && Math.abs(duration - this.mediaDurationSynced) > 0.5) {
      this.mediaDurationSynced = duration;
      this.pushMediaMetadata();
    }
    this.media.syncPlayback(false, this.player.state.playing, this.player.state.speed,
      this.player.state.position);
    // 播放中累计视听统计（每 15s 落一次按书+全局）
    if (this.player.state.playing) {
      this.statsSec += 1;
      if (this.statsSec >= 15) {
        this.statsSec = 0;
        FqReadStatsStore.addBookSeconds(PlayerNavParams.contentId, 15);
      }
    } else {
      this.statsSec = 0;
    }
  }

  /** 播放设置行描述（key 决定右侧控件：speed 滑杆 / cache、listen 箭头 / danmaku 开关）。 */
  private settingItems(): FqSettingItem[] {
    const items: FqSettingItem[] = [
      new FqSettingItem('speed', '倍速', $r('sys.symbol.speed_multiple')),
      new FqSettingItem('cache', '离线缓存', $r('sys.symbol.download')),
      new FqSettingItem('listen', '听视频', $r('sys.symbol.waveform_tv')),
      new FqSettingItem('danmaku', '弹幕开关', $r('sys.symbol.ellipsis_bubble'))
    ];
    return items;
  }

  /** 倍速显示文案（拖动中取预览值；最多两位小数去尾零，如 0.75× / 1× / 1.5×）。 */
  private speedLabel(): string {
    const value: number = this.speedPreview >= 0 ? this.speedPreview : this.player.state.speed;
    const rounded: number = Math.round(value * 100) / 100;
    return `${rounded}×`;
  }

  /** 断点倍速高亮判定（当前值取拖动预览优先；半步容差内视为命中该断点）。 */
  private isCurrentSpeedStep(step: number): boolean {
    const value: number = this.speedPreview >= 0 ? this.speedPreview : this.player.state.speed;
    return Math.abs(value - step) < FQ_SPEED_STEP / 2;
  }

  // ---------------------------------------------------------------------------
  // 横屏全屏右侧边栏（选集/播放设置）
  // ---------------------------------------------------------------------------

  /** 侧边栏头：标题 + 右上关闭。 */
  @Builder
  private SidePanelHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(16)
        .fontColor([Color.White])
        .padding(10)
        .onClick((): void => {
          this.closeSidePanel();
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** 侧边栏·选集：4 列序号格（当前集橙、已看灰、普通白），点选切集并收起。 */
  @Builder
  private SideEpisodes() {
    Column() {
      this.SidePanelHeader('选集')

      if (this.episodes.length === 0) {
        Column() {
          Text('暂无剧集')
            .fontSize(14)
            .fontColor('#99FFFFFF')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid(this.sideScroller) {
          ForEach(this.episodes, (episode: FqChapter, index: number) => {
            GridItem() {
              Row() {
                Text(`${index + 1}`)
                  .fontSize(15)
                  .fontWeight(index === this.index ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.sideEpisodeColor(index))
              }
              .width('100%')
              .aspectRatio(1)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(8)
              .backgroundColor(index === this.index ? '#1AFA6725' : '#26FFFFFF')
              .onClick((): void => {
                this.closeSidePanel();
                this.loadEpisode(index);
              })
            }
          }, (episode: FqChapter, index: number) => `${episode.itemId}-${index}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .scrollBar(BarState.Off)
        .padding({ left: 12, right: 12, top: 4, bottom: 16 })
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏·播放设置：公共设置行 List（同半模态结构，深色配色）。 */
  @Builder
  private SideSettings() {
    Column() {
      this.SidePanelHeader('播放设置')

      this.SettingRows(true)
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏选集格文字色：当前集橙、已看（按集 itemId 记录）灰、普通白。 */
  private sideEpisodeColor(index: number): ResourceColor {
    if (index === this.index) {
      return FQ_STORY_ORANGE;
    }
    const episode: FqChapter | undefined = this.episodes[index];
    if (episode !== undefined && this.watchedIds.has(episode.itemId)) {
      return '#99FFFFFF';
    }
    return Color.White;
  }

  // ---------------------------------------------------------------------------
  // 布局几何（官方 PlayerVideoLayout 竖屏语义）
  // ---------------------------------------------------------------------------

  /** 视频区顶：全屏贴顶；常驻态顶栏 44 + 状态栏（与面板展开无关，面板只是覆盖）。 */
  private videoTopAbs(): number {
    if (this.fullScreen) {
      return 0;
    }
    return appState.topRect + 44;
  }

  /** 视频区高：全屏撑满；常驻态 = 屏高 − 顶栏 − 底部 163 信息区（与面板展开无关）。 */
  private videoRegionHeight(): number {
    if (this.fullScreen) {
      return this.screenH;
    }
    return Math.max(0,
      this.screenH - (appState.topRect + 44) - appState.bottomRect - FQ_STORY_BOTTOM_INSET);
  }

  /**
   * 底部信息区顶（官方 163 信息区）：剧名行锚点，
   * 恒在细进度线与选集胶囊上方（自上而下：剧名行 → 进度线 → 选集胶囊）。
   */
  private infoTop(): number {
    return this.screenH - appState.bottomRect - FQ_STORY_BOTTOM_INSET;
  }

  /**
   * 画面（contain 矩形）下沿：「全屏观看」药丸 + 评论按钮跟随播放区域下方
   * （官方 _PortraitControlsLayout videoBottom + 20；未知尺寸回退 9:16 预览）。
   */
  private videoBottom(): number {
    const regionH: number = this.videoRegionHeight();
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    let videoH: number = 0;
    if (dw > 0 && dh > 0) {
      videoH = Math.min(regionH, this.screenW / dw * dh);
    } else {
      videoH = Math.min(regionH, this.screenW * 16 / 9);
    }
    return this.videoTopAbs() + (regionH + videoH) / 2;
  }

  /** 底部信息列内容高：剧名行 22 + 进度线 30 + 选集行 40 + 间距 12×3；原著横幅 +12+44。 */
  private bandContentHeight(): number {
    const base: number = 22 + 12 + 30 + 12 + 40;
    return this.originalBook !== null ? base + 12 + 44 : base;
  }

  /** 底部信息列顶（列自底向上生长，官方 informationTop；药丸让位钳制用）。 */
  private bandTopAbs(): number {
    return this.screenH - appState.bottomRect - this.bandContentHeight();
  }

  // ---------------------------------------------------------------------------
  // 文案
  // ---------------------------------------------------------------------------

  /** 选集胶囊文案：官方「选集 · ${状态} · 全N集」（e6r/ag_/agb）。 */
  private catalogLabel(): string {
    const count: number = this.episodes.length;
    if (this.creationStatus === 0) {
      return `选集 · 已完结 · 全${count}集`;
    }
    if (this.creationStatus === 1) {
      return `选集 · 连载中 · 全${count}集`;
    }
    return `选集 · 全${count}集`;
  }

  /** 面板头部集数/状态文案（官方 seriesEpisodeLabel：更新至N/已完结 共N）。 */
  private episodeLabel(): string {
    const count: number = this.episodes.length;
    if (this.creationStatus === 1) {
      return `更新至${count}集`;
    }
    if (this.creationStatus === 0) {
      return `已完结 共${count}集`;
    }
    return `共${count}集`;
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  /** 进度条显示值（拖动预览优先）。 */
  private displayPosition(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.player.state.position;
  }

  /** 进度条最大值（时长未知时占位 1，避免 max<=min）。 */
  private displayDuration(): number {
    const duration: number = this.player.state.duration;
    return duration > 0 ? duration : 1;
  }

  /** 横屏片源判定（官方 videoParams.dw > dh；加载前按竖屏处理）。 */
  private isLandscapeVideo(): boolean {
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    return dw > 0 && dh > 0 && dw > dh;
  }

  /** 打开播放设置（横屏全屏走右侧边栏，其余右上角菜单半模态）。 */
  private openSettings(): void {
    this.speedPreview = -1;
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.openSidePanel('settings');
      return;
    }
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.settingsVisible = true;
    });
    if (this.fullScreen) {
      this.scheduleFsHide();
    }
  }

  /** 打开集评半模态：bump 打开令牌（重置重载当前集评论），数据由 FqCommentSheet 自理。 */
  private openComments(): void {
    this.commentCloseToken += 1;
    this.commentOpenToken += 1;
    this.commentSheetVisible = true;
  }

  /**
   * 集评页加载器（弹幕接口全量列表形态：当前播放集的评论一页，cursor 续拉）：
   * 换集/refresh 自动作废旧游标从首页重取；失败向上抛由 FqCommentSheet 落错误态。
   */
  private async loadEpisodeComments(refresh: boolean): Promise<FqBookCommentPage> {
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return new FqBookCommentPage([], 0, 0, '', false, 0);
    }
    if (refresh || this.episodeCommentVid !== episode.itemId) {
      this.episodeCommentCursor = '';
      this.episodeCommentVid = episode.itemId;
    }
    const page: FqEpisodeCommentPage = await FqBackend.get().episodeComments(
      episode.itemId, PlayerNavParams.contentId, this.episodeCommentCursor);
    this.episodeCommentCursor = page.cursor;
    return new FqBookCommentPage(page.comments, page.totalCount, 0, '', page.hasMore, 0);
  }

  /** 全屏底部倍速按钮：公共 FqMenu 档位直选（0.5-2.0 步进 0.25，
   *  当前档尾勾标识；选中即提交 mpv，无需打开播放设置半模态）。 */
  private openSpeedMenu(): void {
    const items: Array<FqMenuItem> = [];
    const steps: number[] = fqSpeedSteps();
    for (const step of steps) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = fqSpeedStepLabel(step);
      if (this.isCurrentSpeedStep(step)) {
        item.endIcon = $r('sys.symbol.checkmark_circle_fill');
      }
      item.onAction = (): void => {
        this.player.setSpeed(step);
      };
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), PLAYER_FS_SPEED_ANCHOR_ID, items);
  }

  /** 关闭集评半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeComments(): void {
    const token: number = ++this.commentCloseToken;
    setTimeout((): void => {
      if (token === this.commentCloseToken) {
        this.commentSheetVisible = false;
      }
    }, 0);
  }

  /** 关闭播放设置半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeSettings(): void {
    this.speedPreview = -1;
    const token: number = ++this.settingsCloseToken;
    setTimeout((): void => {
      if (token === this.settingsCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.settingsVisible = false;
        });
      }
    }, 0);
  }

  /** 画面单击：锁定态只唤出锁按钮（官方 G6）；全屏切控件显隐，非全屏切播放。 */
  private onVideoTap(): void {
    if (this.fullScreen && this.fsLocked) {
      this.refreshLockVisibility();
      return;
    }
    if (this.fullScreen) {
      this.toggleFsControls();
    } else {
      this.togglePlay();
    }
  }

  /** 全屏控件显隐切换（播放态显示时重新计时自动隐藏，暂停态常驻）。 */
  private toggleFsControls(): void {
    if (this.fsControlsVisible) {
      this.fsControlsVisible = false;
      this.cancelFsHide();
    } else {
      this.fsControlsVisible = true;
      if (this.player.state.playing) {
        this.scheduleFsHide();
      }
    }
  }

  /**
   * 全屏内播放状态切换后同步控制条（mpv 状态异步，以切换意图为准）：
   * 播放 → 亮出 3s 自动隐藏；暂停 → 亮出常驻。
   */
  private syncFsControls(nowPlaying: boolean): void {
    if (!this.fullScreen) {
      return;
    }
    this.fsControlsVisible = true;
    if (nowPlaying) {
      this.scheduleFsHide(nowPlaying);
    } else {
      this.cancelFsHide();
    }
  }

  /**
   * 全屏控件 3s 自动隐藏计时（暂停态跳过：控制条常驻可见）；
   * 显式传入播放意图可避开 mpv 状态异步延迟。
   */
  private scheduleFsHide(playing: boolean | null = null): void {
    this.cancelFsHide();
    const isPlaying: boolean = playing === null ? this.player.state.playing : playing;
    if (!isPlaying) {
      return;
    }
    this.fsHideTimer = setTimeout((): void => {
      this.fsHideTimer = 0;
      this.fsControlsVisible = false;
    }, FQ_FS_HIDE_MS);
  }

  private cancelFsHide(): void {
    if (this.fsHideTimer !== 0) {
      clearTimeout(this.fsHideTimer);
      this.fsHideTimer = 0;
    }
  }

  /** 进入全屏沉浸：横屏片源锁横屏并隐藏系统栏（官方 _enterFullscreen）。 */
  private enterFullscreen(): void {
    this.fullScreen = true;
    this.fsControlsVisible = true;
    this.scheduleFsHide();
    this.applyImmersive(true);
  }

  /** 退出全屏沉浸：恢复方向与系统栏；离开横屏解除防误触锁（官方 _releaseLock）。 */
  private exitFullscreen(): void {
    this.fullScreen = false;
    this.fsLocked = false;
    this.lockVisible = false;
    this.cancelFsHide();
    this.cancelLockHide();
    this.fsControlsVisible = true;
    this.applyImmersive(false);
  }

  /** 沉浸全屏：进入隐藏系统栏（横屏片源同时锁 AUTO_ROTATION_LANDSCAPE），退出恢复。 */
  private applyImmersive(enter: boolean): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      if (enter) {
        if (this.isLandscapeVideo()) {
          win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        }
        win.setWindowSystemBarEnable([]);
      } else {
        win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
        win.setWindowSystemBarEnable(['status', 'navigation']);
      }
    }).catch((): void => {
      // 沉浸设置失败保持系统默认 UI，不影响播放
    });
  }

  /** 封面锚定（start 后 baseUrl 就绪；官方面板头/加载占位同源）。 */
  private resolveCover(): void {
    if (this.coverUrl.length === 0 && PlayerNavParams.cover.length > 0) {
      this.coverUrl = FqBackend.get().resourceUrl(PlayerNavParams.cover);
    }
  }

  /** 加载关联原著（/api/v1/series/{id} 的 video_relate_book；失败静默，不显示横幅）。 */
  private async loadOriginalBook(): Promise<void> {
    const seriesId: string = PlayerNavParams.contentId;
    if (seriesId.length === 0) {
      return;
    }
    try {
      await FqBackend.get().start(getContext(this));
      this.originalBook = await FqBackend.get().seriesRelateBook(seriesId);
    } catch (error) {
      this.originalBook = null;
    }
  }

  /** 原著书名（横幅文案；无原著为空）。 */
  private originalBookTitle(): string {
    return this.originalBook !== null ? this.originalBook.title : '';
  }

  /** 原著横幅点击 → 原著详情页（官方 kind=book 跳转链路；先暂停播放）。 */
  private openOriginalBook(): void {
    const book: FqSeriesRelateBook | null = this.originalBook;
    if (book === null || book.id.length === 0) {
      return;
    }
    this.player.pause();
    // 暂停即保存续播进度（fqapp 暂停写入点；进详情页期间周期保存已停）
    this.saveCurrentProgress();
    DetailNavParams.id = book.id;
    DetailNavParams.kind = 'book';
    DetailNavParams.title = book.title;
    DetailNavParams.cover = book.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 目录为空时先拉剧集目录（tab 由 kind 映射：短剧/漫剧）。 */
  private async loadEpisodes(): Promise<void> {
    const token: number = ++this.loadToken;
    this.loading = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      this.resolveCover();
      const episodes: FqChapter[] =
        await FqBackend.get().directoryChapters(PlayerNavParams.contentId, this.tab);
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      if (episodes.length === 0) {
        this.errorMsg = '暂无剧集';
        return;
      }
      this.episodes = episodes;
      // 显式起播集（详情目录点击进页）优先；否则续播（fqapp resumeEpisodeIndex）
      const resumeIndex: number = this.explicitStartIndex >= 0 ? -1 : this.resumeStartIndex();
      let target: number = resumeIndex >= 0 ? resumeIndex : 0;
      if (this.explicitStartIndex >= 0) {
        target = this.explicitStartIndex < episodes.length ? this.explicitStartIndex : 0;
      }
      this.loadEpisode(target);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.errorMsg = fqErrorMessage(error);
    }
  }

  /** 加载并起播一集（/api/content 取流 → mpv open）。 */
  private async loadEpisode(index: number): Promise<void> {
    const episode: FqChapter | undefined = this.episodes[index];
    if (episode === undefined) {
      return;
    }
    // 离开的旧集：实际播放过才标已看/存续播进度（this.index 尚未切换）；
    // 听视频返回切集例外——续播记录以听视频页写入的（新集,听到位置）为准，
    // 跳过旧集回写，避免用进听视频前的旧位置覆盖
    const wasDisplayed: boolean = this.hasDisplayed;
    const switched: boolean = index !== this.index;
    const keepListenProgress: boolean = this.listenReturnSwitch;
    this.listenReturnSwitch = false;
    this.markCurrentWatched();
    if (!keepListenProgress) {
      this.saveCurrentProgress();
    }
    const token: number = ++this.loadToken;
    // 续播位置（仅进页首开那一次）：Media start 偏移起播
    let startSec: number = -1;
    if (this.pendingResumeSec > 0) {
      startSec = this.pendingResumeSec;
      this.pendingResumeSec = -1;
    }
    this.index = index;
    this.loading = true;
    this.errorMsg = '';
    this.seekPreview = -1;
    // 切集且集评面板开着：bump 打开令牌让面板重置重载新集评论
    if (switched && this.commentSheetVisible) {
      this.commentOpenToken += 1;
    }
    try {
      let playUrl: string = '';
      // 离线缓存命中：直接播本地文件，跳过在线取流（无网也可看已缓存集）
      if (FqDramaCacheStore.has(episode.itemId)) {
        playUrl = FqDramaCacheStore.filePath(episode.itemId);
      } else {
        await FqBackend.get().start(getContext(this));
        this.resolveCover();
        const source: FqEpisodeSource =
          await FqBackend.get().episodeSource(episode.itemId, this.tab);
        playUrl = source.url;
      }
      if (token !== this.loadToken) {
        return;
      }
      this.startEpisodePlayback(episode, playUrl, startSec, wasDisplayed, switched, keepListenProgress);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      // 在线取流失败回退离线缓存（联网失败仍可看已缓存集）
      if (FqDramaCacheStore.has(episode.itemId)) {
        this.startEpisodePlayback(episode, FqDramaCacheStore.filePath(episode.itemId),
          startSec, wasDisplayed, switched, keepListenProgress);
        return;
      }
      this.loading = false;
      this.errorMsg = fqErrorMessage(error);
    }
  }

  /**
   * 起播公共尾段（在线取流 / 离线缓存命中 / 取流失败回退缓存共用）：
   * 关听书、mpv open（含续播 start 偏移）、AVSession/后台任务、
   * 续播记录重置与弹幕整池作废。
   */
  private startEpisodePlayback(episode: FqChapter, url: string, startSec: number,
    wasDisplayed: boolean, switched: boolean, keepListenProgress: boolean): void {
    this.loading = false;
    // 播放视频即停止听书（fqAudioSession 完整关闭链路：进度持久化、
    // 引擎释放、后台任务停止、AVSession 销毁、播控球消失）
    if (fqAudioSession.hasSession) {
      fqAudioSession.close();
    }
    this.player.open(startSec > 0
      ? new Media(url, { start: startSec })
      : new Media(url));
    // 新集起播：重置「实际播放」guard（旧集残余走表不再计入）
    this.hasDisplayed = false;
    // AVSession/后台长时任务：会话确保 + 元数据（时长随 1s tick 补发）
    this.mediaDurationSynced = -1;
    this.media.ensureSession('video');
    this.media.startBackground();
    this.pushMediaMetadata();
    if (wasDisplayed && switched && !keepListenProgress) {
      // 切集：续播记录立即指向新集（位置 0；周期/暂停/退出再精化），
      // 避免切集后立刻退出仍续播回旧集；同集重试不覆盖原位置
      // （听视频返回切集跳过：新集起播位置由听到的位置决定，不重置为 0）
      this.progress = new FqWatchedProgress(episode.itemId, 0, 0);
      FqWatchedStore.saveProgress(PlayerNavParams.contentId, this.progress);
    }
    // 弹幕整池作废（切集），按 0 起取新集首批
    this.resetDanmaku();
  }

  /**
   * 标记当前集已看（对齐 fqapp watched_episodes.dart：按集 itemId 逐集持久化）：
   * 实际播放过（hasDisplayed）才标，绝不按「当前集之前」补造中间集；
   * 切集（loadEpisode 入口）与页面销毁时调用。
   */
  private markCurrentWatched(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    if (FqWatchedStore.mark(PlayerNavParams.contentId, episode.itemId)) {
      this.watchedIds = this.copyWatchedIds();
    }
  }

  /** 从 store 拷贝本剧已看集合（Set 重赋值驱动选集面板刷新）。 */
  private copyWatchedIds(): Set<string> {
    const ids: Set<string> = new Set<string>();
    FqWatchedStore.ids(PlayerNavParams.contentId).forEach((id: string): void => {
      ids.add(id);
    });
    return ids;
  }

  /**
   * 进页续播集下标（fqapp startEpisodeIndex ?? resumeEpisodeIndex ?? 0）：
   * 按集 itemId 匹配进度记录；命中且未播完时挂待恢复位置（首开 Media start 消费），
   * 播完则该集从头；无记录/不在目录返回 -1。
   */
  private resumeStartIndex(): number {
    const saved: FqWatchedProgress | null = this.progress;
    if (saved === null) {
      return -1;
    }
    for (let index: number = 0; index < this.episodes.length; index++) {
      if (this.episodes[index].itemId === saved.episodeId) {
        const finished: boolean = saved.duration > 0 && saved.position >= saved.duration - 0.5;
        this.pendingResumeSec = finished ? -1 : saved.position;
        return index;
      }
    }
    return -1;
  }

  /**
   * 保存当前集续播进度（fqapp _persistProgress：以集 itemId 为键、与已看分开记录）；
   * 实际播放过才存（hasDisplayed guard，首帧/起播不存）。
   */
  private saveCurrentProgress(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    this.progress = new FqWatchedProgress(episode.itemId,
      this.player.state.position, this.player.state.duration);
    FqWatchedStore.saveProgress(PlayerNavParams.contentId, this.progress);
  }

  /** 周期保存续播进度（5s 一存，仅播放中；暂停不重复盖时间戳）。 */
  private progressSaveTick(): void {
    this.progressTick += 1;
    if (this.progressTick < 5) {
      return;
    }
    this.progressTick = 0;
    if (this.player.state.playing) {
      this.saveCurrentProgress();
    }
  }

  /**
   * 长按屏幕右侧 2 倍速快进（官方 jq3 长按带外分支 / fqapp _startBoost）：
   * 按住期间 2x，松开恢复原倍速；锁定态不响应（只唤出锁按钮）。
   */
  private beginSpeedBoost(event?: GestureEvent): void {
    if (this.fsLocked) {
      this.refreshLockVisibility();
      return;
    }
    if (this.speedBoost || event === undefined || event.fingerList.length === 0) {
      return;
    }
    // 仅屏幕右侧生效（globalX 与 display 宽同取当前方向、统一换算 vp）
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const widthVp: number = displayData.width / density;
    if (event.fingerList[0].globalX < widthVp / 2) {
      return;
    }
    const current: number = this.player.state.speed;
    this.boostRestoreSpeed = current > 0 ? current : 1.0;
    this.speedBoost = true;
    this.player.setSpeed(FQ_BOOST_SPEED);
  }

  /** 松开长按：结束 2 倍速快进，恢复原倍速。 */
  private endSpeedBoost(): void {
    if (!this.speedBoost) {
      return;
    }
    this.speedBoost = false;
    this.player.setSpeed(this.boostRestoreSpeed > 0 ? this.boostRestoreSpeed : 1.0);
    this.boostRestoreSpeed = -1;
  }

  /**
   * 全屏半屏竖滑调节起始：左半屏 → 窗口亮度（-1 未调过从 50 起）、
   * 右半屏 → 播放器软音量（mpv state.volume，钳制 0-100）；
   * 锁定态只唤出锁按钮；半模态/侧边栏打开时不响应；非全屏不响应。
   */
  private onAdjustPanStart(event?: GestureEvent): void {
    if (this.fsLocked) {
      this.refreshLockVisibility();
      return;
    }
    if (!this.fullScreen || this.sheetVisible || this.settingsVisible || this.commentSheetVisible ||
      this.sidePanel.length > 0 || event === undefined || event.fingerList.length === 0) {
      return;
    }
    this.cancelAdjustHide();
    // 左右半屏判定（globalX 与 display 宽同取当前方向、统一换算 vp，同长按快进）
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const widthVp: number = displayData.width / density;
    if (event.fingerList[0].globalX < widthVp / 2) {
      this.gestureAdjust = 'brightness';
      this.adjustStartValue = this.brightnessPercent >= 0 ? this.brightnessPercent : FQ_ADJUST_INIT_PERCENT;
    } else {
      this.gestureAdjust = 'volume';
      const current: number = this.player.state.volume;
      this.adjustStartValue = current > 100 ? 100 : (current < 0 ? 0 : current);
    }
    this.adjustStartY = event.fingerList[0].globalY;
    this.gestureAdjustPercent = this.adjustStartValue;
  }

  /**
   * 竖滑过程：上滑增大、下滑减小（滑过 FQ_ADJUST_FULL_SWIPE 倍屏高走完全量程）；
   * 亮度即时写窗口 setWindowBrightness（最小 0.01 防全黑），音量即时写 mpv setVolume。
   */
  private onAdjustPanUpdate(event?: GestureEvent): void {
    if (this.gestureAdjust.length === 0 || event === undefined || event.fingerList.length === 0) {
      return;
    }
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const heightVp: number = displayData.height / density;
    const dy: number = this.adjustStartY - event.fingerList[0].globalY;
    const delta: number = heightVp > 0 ? dy / (heightVp * FQ_ADJUST_FULL_SWIPE) * 100 : 0;
    let value: number = this.adjustStartValue + delta;
    if (value < 0) {
      value = 0;
    }
    if (value > 100) {
      value = 100;
    }
    this.gestureAdjustPercent = value;
    if (this.gestureAdjust === 'brightness') {
      this.brightnessPercent = value;
      window.getLastWindow(getContext(this)).then((win: window.Window): void => {
        win.setWindowBrightness(Math.max(0.01, value / 100));
      }).catch((): void => {
        // 亮度设置失败保持当前亮度，不影响调节浮层展示
      });
    } else {
      this.player.setVolume(value);
    }
  }

  /** 竖滑结束/取消：浮层短驻后自隐（连续滑动重新开始则保持显示）。 */
  private onAdjustPanEnd(): void {
    if (this.gestureAdjust.length === 0) {
      return;
    }
    this.cancelAdjustHide();
    this.adjustHideTimer = setTimeout((): void => {
      this.adjustHideTimer = 0;
      this.gestureAdjust = '';
    }, FQ_ADJUST_HIDE_MS);
  }

  private cancelAdjustHide(): void {
    if (this.adjustHideTimer !== 0) {
      clearTimeout(this.adjustHideTimer);
      this.adjustHideTimer = 0;
    }
  }

  /** 调节浮层图标：亮度按高低切太阳档位、音量按档位切喇叭波纹（0 静音斜杠）。 */
  private adjustIconRes(): Resource {
    if (this.gestureAdjust === 'brightness') {
      return this.gestureAdjustPercent < 25 ? $r('sys.symbol.sun_min') : $r('sys.symbol.sun_max');
    }
    if (this.gestureAdjustPercent <= 0) {
      return $r('sys.symbol.speaker_slash_fill');
    }
    if (this.gestureAdjustPercent < 34) {
      return $r('sys.symbol.speaker_wave_1_fill');
    }
    if (this.gestureAdjustPercent < 67) {
      return $r('sys.symbol.speaker_wave_2_fill');
    }
    return $r('sys.symbol.speaker_wave_3_fill');
  }

  /** 锁定态任意触摸：唤出锁按钮并重新计 5s 自隐（官方 d.G6()）。 */
  private refreshLockVisibility(): void {
    this.lockVisible = true;
    this.scheduleLockHide();
  }

  /**
   * 全屏防误触锁切换（官方 d.K6）：锁定 → 控件隐藏且不可呼出、画面操作全吞，
   * 仅锁按钮可唤出（5s 自隐）；解锁 → 控件立即恢复可见；锁不改变播放状态。
   */
  private toggleLock(): void {
    if (this.fsLocked) {
      this.fsLocked = false;
      this.lockVisible = false;
      this.cancelLockHide();
      this.fsControlsVisible = true;
      this.scheduleFsHide();
    } else {
      this.fsLocked = true;
      this.fsControlsVisible = false;
      this.cancelFsHide();
      this.lockVisible = true;
      this.scheduleLockHide();
    }
  }

  /** 锁定按钮自动隐藏计时（锁定后 5s；官方 d.G6()）。 */
  private scheduleLockHide(): void {
    this.cancelLockHide();
    this.lockHideTimer = setTimeout((): void => {
      this.lockHideTimer = 0;
      if (this.fsLocked) {
        this.lockVisible = false;
      }
    }, FQ_LOCK_HIDE_MS);
  }

  private cancelLockHide(): void {
    if (this.lockHideTimer !== 0) {
      clearTimeout(this.lockHideTimer);
      this.lockHideTimer = 0;
    }
  }

  /**
   * 播放暂停切换：mpv 状态异步更新，判定一律以返回的切换意图为准；
   * 暂停即保存续播进度（fqapp 暂停写入点）；中央按钮点击才出现
   * （暂停常驻/播放 3s 隐藏）。
   */
  private togglePlay(): boolean {
    if (this.errorMsg.length > 0) {
      return this.player.state.playing;
    }
    const wasPlaying: boolean = this.player.state.playing;
    if (this.player.state.eof) {
      this.player.play();
    } else {
      this.player.playOrPause();
    }
    const nowPlaying: boolean = !wasPlaying;
    this.centerBtnVisible = true;
    // AVSession 播放态立即同步（意图优先，绕过 mpv 状态异步）
    this.syncMediaState(nowPlaying);
    if (wasPlaying) {
      // 点击后进入暂停：按钮常驻
      this.cancelCenterHide();
      this.saveCurrentProgress();
    } else {
      // 点击后进入播放：3s 后自动隐藏
      this.scheduleCenterHide();
    }
    return nowPlaying;
  }

  /** 中央播放按钮 3s 自动隐藏计时。 */
  private scheduleCenterHide(): void {
    this.cancelCenterHide();
    this.centerHideTimer = setTimeout((): void => {
      this.centerHideTimer = 0;
      this.centerBtnVisible = false;
    }, FQ_FS_HIDE_MS);
  }

  private cancelCenterHide(): void {
    if (this.centerHideTimer !== 0) {
      clearTimeout(this.centerHideTimer);
      this.centerHideTimer = 0;
    }
  }

  // ---------------------------------------------------------------------------
  // 弹幕（/api/v1/videos/{vid}/danmaku，vid = 当前集 itemId）
  // ---------------------------------------------------------------------------

  /** 切集：弹幕整池作废（官方 w()），按 0 起取新集首批。 */
  private resetDanmaku(): void {
    this.danmakuLoadToken += 1;
    this.danmakuCursor = '';
    this.danmakuHasMore = false;
    this.danmakuLoadedToMs = 0;
    this.danmakuItems = [];
    this.danmakuResetToken += 1;
    this.fetchDanmaku(0);
  }

  /** seek：清已飞状态、cursor 清空，按目标时间重取（官方 ON_SEEK_FINISH）。 */
  private seekDanmaku(targetMs: number): void {
    this.danmakuCursor = '';
    this.danmakuHasMore = false;
    this.danmakuResetToken += 1;
    this.fetchDanmaku(Math.max(0, targetMs));
  }

  /** 弹幕进度心跳：接近已加载右界时按 cursor 续拉下一批。 */
  private danmakuTick(): void {
    if (this.errorMsg.length > 0 || this.episodes.length === 0 || !this.danmakuOn) {
      return;
    }
    const posMs: number = Math.floor(this.player.state.position * 1000);
    if (this.danmakuHasMore && posMs + 4000 >= this.danmakuLoadedToMs) {
      this.fetchDanmaku(this.danmakuLoadedToMs);
    }
  }

  /** 取弹幕一页：按 id 去重合并、保持 offsetMs 升序；失败静默降级不影响播放。 */
  private async fetchDanmaku(startMs: number): Promise<void> {
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    const token: number = ++this.danmakuLoadToken;
    try {
      const page: FqDanmakuPage = await FqBackend.get().videoDanmaku(
        episode.itemId, PlayerNavParams.contentId,
        startMs, Math.floor(this.player.state.duration), this.danmakuCursor);
      if (token !== this.danmakuLoadToken) {
        return;
      }
      this.danmakuCursor = page.cursor;
      this.danmakuHasMore = page.hasMore;
      this.danmakuLoadedToMs = page.nextQueryMs > startMs ? page.nextQueryMs : startMs + 5000;
      const seen: Set<string> = new Set<string>();
      const merged: FqDanmaku[] = [];
      for (const item of this.danmakuItems) {
        if (!seen.has(item.id)) {
          seen.add(item.id);
          merged.push(item);
        }
      }
      for (const item of page.items) {
        if (!seen.has(item.id)) {
          seen.add(item.id);
          merged.push(item);
        }
      }
      merged.sort((a: FqDanmaku, b: FqDanmaku): number => a.offsetMs - b.offsetMs);
      this.danmakuItems = merged;
    } catch (error) {
      // 弹幕拉取失败静默降级：不影响播放
      if (token === this.danmakuLoadToken) {
        this.danmakuHasMore = false;
      }
    }
  }

  /** 弹幕开关（官方 Toast 文案：弹幕已开启/已关闭）。 */
  private toggleDanmaku(): void {
    this.danmakuOn = !this.danmakuOn;
    this.getUIContext().getPromptAction().showToast({
      message: this.danmakuOn ? '弹幕已开启' : '弹幕已关闭',
      duration: 1200,
    });
    this.scheduleFsHide();
  }

  /** 下一集（横屏控制条/自动连播共用）。 */
  private nextEpisode(): void {
    if (this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1);
    }
  }

  /** 播完回调：自动连播下一集；末集停在末帧。 */
  private onEpisodeEnd(): void {
    this.nextEpisode();
  }

  /** 失败重试：无目录先拉目录，否则重取当前集。 */
  private retry(): void {
    if (this.episodes.length === 0) {
      this.loadEpisodes();
    } else {
      this.loadEpisode(this.index);
    }
  }

  private openCatalog(): void {
    if (this.episodes.length === 0) {
      return;
    }
    // 横屏全屏走右侧边栏（少遮挡画面），其余走官方底部半模态
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.openSidePanel('episodes');
      return;
    }
    // 官方面板展开 200ms：视频区随面板撑满全屏（_positionVideo panelFraction）
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sheetVisible = true;
    });
  }

  /** 横屏全屏右侧边栏打开：收控件、面板贴右滑入；选集滚到当前集竖直居中。 */
  private openSidePanel(kind: string): void {
    this.cancelFsHide();
    this.fsControlsVisible = false;
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sidePanel = kind;
    });
    if (kind === 'episodes' && this.episodes.length > 0) {
      this.cancelSideLocate();
      this.sideLocateTimer = setTimeout((): void => {
        this.sideLocateTimer = 0;
        this.sideScroller.scrollToIndex(this.index, false, ScrollAlign.CENTER);
      }, 120);
    }
  }

  /** 关闭横屏全屏右侧边栏：面板滑出，亮出全屏控件并重新计自动隐藏。 */
  private closeSidePanel(): void {
    this.cancelSideLocate();
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sidePanel = '';
    });
    this.fsControlsVisible = true;
    this.scheduleFsHide();
  }

  private cancelSideLocate(): void {
    if (this.sideLocateTimer !== 0) {
      clearTimeout(this.sideLocateTimer);
      this.sideLocateTimer = 0;
    }
  }

  /** 关闭半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.sheetVisible = false;
        });
      }
    }, 0);
  }
}

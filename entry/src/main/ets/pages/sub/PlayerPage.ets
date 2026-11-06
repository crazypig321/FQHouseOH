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
 *   评论按钮呼出「剧评」半模态（公共 FqCommentSheet + 剧评接口加载器：
 *   /api/v1/series/{id}/comments 整部剧评论列表，sort=1 cursor 分页，
 *   对齐官方播放页评论区；弹幕接口按 30s 窗口实时分页，只适合浮层轮播）。
 * - 离线缓存（fqapp DramaDownloadSheet 语义）：选集胶囊行「缓存」入口 /
 *   播放设置「离线缓存」行呼出缓存选集半模态（已缓存集置灰打勾、任务态
 *   实时进度、默认全选未缓存集、头部「管理」进剧集缓存管理页）；
 *   已缓存集 loadEpisode 直接播本地文件，在线取流失败也回退缓存文件。
 * - 边看边往后缓存（fqapp _scheduleAutoCache/_autoCacheNext/_trimAutoCache）：
 *   起播 2s 后把后面 N 集自动排进下载队列（剧集缓存页「边看边缓存」开关 +
 *   3/5/10 档，默认 5，仅 Wi-Fi）；自动缓存的旧集跟着播放进度滚动清理
 *   （只留当前集之前 2×N 集以后，手动下载不动）；入队后剧集缓存页实时显示。
 * - 同系列（fqapp RelatedSeriesSheet/_switchRelatedSeries 语义）：选集面板
 *   「同系列」入口呼出同系列剧列表（/api/v1/series/{id}/related，双列卡片：
 *   封面 + 标题 + 集数；不可播置灰文案仍展示），选中先暂停存进度再进新剧
 *   详情页；横屏全屏改走右侧边栏深色面板。
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
 * - 弹幕样式可调（fqapp danmaku_config / playlet_danmaku_settings）：播放设置
 *   「弹幕设置」二级页（sheet 与横屏侧边栏深色变体共用）——不透明度 20-100%、
 *   速度 5 档、显示区域（竖屏 1-4 行 / 横屏 单行·1/4·1/2·3/4 屏）、字号 5 档、
 *   弹幕背景透明开关 + 恢复默认（Toast「设置成功」），FqAppSettingsStore 持久化。
 * - PC 大窗口右侧详情侧边栏（fqapp 桌面停靠目录 desktop_video_chrome）：窗口
 *   ≥1000vp 的 PC 布局常驻（横竖屏片源、全屏与否均展示，可收起成窄轨）；
 *   剧名/共N集·第N集/简介/原著横幅/入口药丸（作品详情·评论·缓存·听剧·同系列）/
 *   选集头 + >30 集分页条 + 5 列选集网格；播放区缩窄让位，几何一律走
 *   pageW()/pageH()（根 Stack 实测），不出侧边栏的设备回退屏宽屏高。
 */

import { display, window, PiPWindow } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { Player, PlayerSurface, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';
import { CommonNav } from '../../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../../view/sheet/CommonSheet';
import { FqCacheSheet } from '../../view/sheet/FqCacheSheet';
import { FqRelatedSheet, FqRelatedList } from '../../view/sheet/FqRelatedSheet';
import { FqCommentSheet, fqCommentSheetHeightVp } from '../../view/sheet/FqCommentSheet';
import { FqMenu, FqMenuItem } from '../../view/CommonMenu';
import { FqDanmakuView, FqDanmakuViewConfig } from '../../view/FqDanmakuView';
import { FqStoryPanel } from '../../view/FqStoryPanel';
import { FqPlayerSidebar } from '../../view/player/FqPlayerSidebar';
import { FqPlayerSettingsSheet } from '../../view/player/FqPlayerSettingsSheet';
import { FqPlayerSettingsPanel } from '../../view/player/FqPlayerSettingsPanel';
import { FqDanmakuSettingsPanel } from '../../view/player/FqDanmakuSettingsPanel';
import { fqPushBookOrDetail, PlayerNavParams, ListenVideoNavParams, ROUTE_LISTEN_VIDEO, ROUTE_CACHED_DRAMAS, DetailNavParams, ROUTE_DETAIL } from '../../model/FqNavModels';
import { FqBookCommentPage, FqChapter, FqDanmaku, FqDanmakuPage, FqEpisodeCommentPage, FqEpisodeSource, FqEpisodeVariant, FqSeriesRelateBook, FqRelatedSeries, fqKindToTab, FqCacheTaskView } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { fqAudioSession } from '../../core/FqAudioSession';
import { FqVideoMedia } from '../../core/FqVideoMedia';
import {
  FqAppSettingsStore,
  FQ_DANMAKU_SPEED_MULTIPLIERS,
  FQ_DANMAKU_TEXT_SIZES,
  FQ_DANMAKU_LINE_SPACE_FACTORS,
} from '../../core/FqAppSettingsStore';
import { FqWatchedStore, FqWatchedProgress } from '../../core/FqWatchedStore';
import { FqDramaCacheStore } from '../../core/FqDramaCacheStore';
import { fqDramaDownloader, FqDramaDownloader, FqDramaDownloadTask, DramaDownloadStatus } from '../../core/FqDramaDownloader';
import { FqReadStatsStore } from '../../core/FqReadStatsStore';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { useSidebarLayout } from '../../utils/BreakpointUtils';
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
/** 边看边往后缓存起播延时（fqapp Timer 2s：起播稳定后再排，避免抢起播带宽）。 */
const FQ_AUTO_CACHE_DELAY_MS: number = 2000;
/** 边看边往后缓存诊断日志 tag。 */
const FQ_AUTO_CACHE_LOG_TAG: string = 'FqAutoCache';

/** 横滑快进/快退：滑过一整屏宽度走过的秒数。 */
const FQ_SEEK_FULL_SWIPE_SEC: number = 90;
/** 横屏全屏右侧边栏宽（选集/播放设置共用）。 */
const FQ_FS_SIDE_PANEL_W: number = 300;
/** 侧边栏背景（近黑高不透明，压得住浅色画面又不糊死视频）。 */
const FQ_FS_SIDE_BG: string = '#F0141414';
/** 全屏底部倍速按钮锚点 id（FqMenu 档位菜单挂靠）。 */
const PLAYER_FS_SPEED_ANCHOR_ID: string = 'player_fs_speed_anchor';
/** 全屏底部清晰度按钮锚点 id（FqMenu 档位菜单挂靠）。 */
const PLAYER_FS_QUALITY_ANCHOR_ID: string = 'player_fs_quality_anchor';
/** 播放设置深色（横屏侧边栏）配色：半透明白卡片/分隔线/滑轨/次级文字。 */
const FQ_DARK_CARD_BG: string = '#26FFFFFF';
const FQ_DARK_DIVIDER: string = '#1FFFFFFF';
const FQ_DARK_TRACK: string = '#33FFFFFF';
const FQ_DARK_TERTIARY_TEXT: string = '#99FFFFFF';
/** 离线缓存 sheet/侧边栏分页条粒度（与选集面板 FqStoryPanel 一致 30/段）。 */
const FQ_CACHE_PAGE_SIZE: number = 30;
/** 预热下一集提前量（秒；fqapp player_page_preload _warmLead = 30s）。 */
const FQ_WARM_LEAD_SEC: number = 30;
/** PC 右侧详情侧边栏宽（对齐 fqapp 桌面停靠目录 304 一档，取本项目圆整）。 */
const FQ_PC_DETAIL_SIDEBAR_W: number = 320;
/** PC 右侧详情侧边栏最小窗口宽（对齐 fqapp 桌面 width >= 1000 才停靠）。 */
const FQ_PC_DETAIL_SIDEBAR_MIN_W: number = 1000;
/** PC 详情侧边栏背景（fqapp 桌面停靠面板 0xff1c1c1f）。 */
const FQ_PC_DETAIL_SIDEBAR_BG: string = '#FF1C1C1F';
/** PC 详情侧边栏左缘关闭长条宽（点击整条收起侧边栏）。 */
const FQ_PC_SIDEBAR_CLOSE_STRIP_W: number = 18;
/** PC 详情侧边栏关闭长条背景（略亮于面板底色以示可点）。 */
const FQ_PC_SIDEBAR_CLOSE_STRIP_BG: string = '#FF26262B';
/** PC 布局非全屏底部组件（选集行/进度等）整体抬高距离（窗口无底部手势区，留出下边距）。 */
const FQ_PC_BOTTOM_LIFT_VP: number = 12;

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
  /** mpv 播放器（@ObservedV2；state 经 @Trace 驱动本页渲染）。
   * onReady = XComponent surface 挂载回调：离线缓存秒开时 open 可能先于
   * surface 创建执行（aboutToAppear 同步链路零 await），mpv 无 wid 起播
   * 后补挂 surface 概率性黑屏有声音——未就绪时暂存 Media，此回调补播。 */
  private player: Player = new Player(new PlayerConfig({ onReady: (): void => this.onPlayerSurfaceReady() }));
  /** XComponent surface 是否已挂载（PlayerSurface 首帧构建后为 true）。 */
  private surfaceReady: boolean = false;
  /** surface 未就绪时暂存的起播媒体（onReady 回调补 open）。 */
  private pendingOpenMedia: Media | null = null;
  /** 剧集目录（详情页预载；为空则本页拉目录）。 */
  @Local episodes: FqChapter[] = [];
  /** 当前集下标。 */
  @Local index: number = 0;
  /** 集流加载中（/api/content 取流）。 */
  @Local loading: boolean = true;
  @Local errorMsg: string = '';
  /** 选集半模态（打开时视频区撑满全屏、chrome 隐藏）。 */
  @Local sheetVisible: boolean = false;
  /** 播放设置半模态（右上角菜单呼出：倍速滑杆/离线缓存/听视频/弹幕开关，公共 FqPlayerSettingsSheet）。 */
  @Local settingsVisible: boolean = false;
  /** 倍速滑杆拖动预览值（-1 未拖动；拖动中文案实时跟随，松手提交 mpv）。 */
  @Local speedPreview: number = -1;
  /** 剧评半模态（评论按钮呼出：公共 FqCommentSheet，整部剧的评论列表）。 */
  @Local commentSheetVisible: boolean = false;
  /** 剧评打开令牌（每次打开 +1，FqCommentSheet 据此重置重载）。 */
  @Local commentOpenToken: number = 0;
  /** 全屏沉浸态（「全屏观看」进入；横屏片源锁横屏 + 隐藏系统栏）。 */
  @Local fullScreen: boolean = false;
  /** 进入 PC 沉浸全屏前窗口是否为最大化（true 退出回最大化，false recover 回自由窗口原尺寸）。 */
  private pcFullscreenWasMaximized: boolean = false;
  /** 进入 PC 沉浸全屏前窗口已是沉浸全屏（用户双击标题栏等进入）：退出保持全屏形态不缩窗。 */
  private pcFullscreenWasFullscreen: boolean = false;
  /** PC 窗口形态变化回调：全屏播放中被系统窗口化（ESC 系统窗口化快捷键/标题栏操作）→
   *  窗口形态已由系统接管，同步退出应用内全屏播放态（不再 maximize/recover 还原）。 */
  private onWindowStatusChange: (status: window.WindowStatusType) => void =
    (status: window.WindowStatusType): void => {
      if (!this.fullScreen || status === window.WindowStatusType.FULL_SCREEN) {
        return;
      }
      const pcLayout: boolean =
        useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp);
      if (!pcLayout) {
        return;
      }
      this.exitFullscreen(true);
    };
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
  /** 弹幕样式配置（对齐 fqapp danmaku_config：字号/不透明度/速度倍率/背景透明；设置实时生效）。 */
  @Local danmakuCfg: FqDanmakuViewConfig = new FqDanmakuViewConfig();
  /** 弹幕不透明度（%，20-100，fqapp 默认 100）。 */
  @Local danmakuAlphaPercent: number = 100;
  /** 弹幕速度档（1-5：0.5/0.7/1.0/1.25/1.5 倍，fqapp 默认 3）。 */
  @Local danmakuSpeedTier: number = 3;
  /** 竖屏弹幕行数（1-4 行，fqapp 默认 4）。 */
  @Local danmakuLineCount: number = 4;
  /** 横屏弹幕显示区域档（1-4：单行/1/4屏/1/2屏/3/4屏，fqapp 默认 2）。 */
  @Local danmakuLineSpaceTier: number = 2;
  /** 弹幕字号档（1-5：12/14/16/18/20sp，fqapp 默认 3=16sp）。 */
  @Local danmakuSizeTier: number = 3;
  /** 弹幕背景透明（不画官方 40% 黑底气泡，本地开关）。 */
  @Local danmakuBgTransparent: boolean = false;
  /** 播放设置二级页（'' 主设置 / 'danmaku' 弹幕设置；sheet 与横屏侧边栏共用）。 */
  @Local settingsPage: string = '';
  /** 关联原著（剧有原著才显示横幅；装饰性数据，失败静默）。 */
  @Local originalBook: FqSeriesRelateBook | null = null;
  /** 已看集 itemId 集合（FqWatchedStore；标记后重赋值驱动选集面板刷新）。 */
  @Local watchedIds: Set<string> = new Set<string>();
  /** 横屏全屏右侧边栏（'episodes' 选集 / 'settings' 播放设置；'' 关闭）。 */
  @Local sidePanel: string = '';
  /** 离线缓存选集半模态（选集胶囊行「缓存」/播放设置「离线缓存」行呼出）。 */
  @Local cacheSheetVisible: boolean = false;
  /** 缓存 sheet/侧边栏内已勾选集 itemId（打开时默认全选未缓存集）。 */
  @Local cacheSelectedIds: Set<string> = new Set<string>();
  /** 已完整缓存集 itemId（打开时从 FqDramaCacheStore 刷新，供侧边栏与 FqCacheSheet）。 */
  @Local cacheDownloadedIds: Set<string> = new Set<string>();
  /** 缓存 sheet 打开令牌（每次打开 +1，FqCacheSheet 据此重置勾选并定位当前集）。 */
  @Local cacheOpenToken: number = 0;
  /** 同系列半模态（选集面板「同系列」呼出；横屏全屏改走右侧边栏）。 */
  @Local relatedSheetVisible: boolean = false;
  /** 同系列条目（/api/v1/series/{id}/related，打开面板时加载）。 */
  @Local relatedList: FqRelatedSeries[] = [];
  /** 同系列加载中。 */
  @Local relatedLoading: boolean = false;
  /** 同系列加载错误文案（空串无错；展示重试按钮）。 */
  @Local relatedErrorMsg: string = '';
  /** 侧边栏缓存分页条当前段。 */
  @Local sideCachePage: number = 0;
  /** 侧边栏选集分页条当前段。 */
  @Local sideEpisodePage: number = 0;
  /** 当前集清晰度档列表（/api/content data.variants；空 = 上游仅一路流）。 */
  @Local qualityVariants: FqEpisodeVariant[] = [];
  /** 当前播放清晰度档下标（-1 = 默认流 source.url）。 */
  @Local qualityIndex: number = -1;
  /** 侧边栏缓存网格滚动器。 */
  private sideCacheScroller: Scroller = new Scroller();
  /** 侧边栏缓存面板打开后定位当前集的定时器（0 无任务）。 */
  private cacheLocateTimer: number = 0;

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
  /** 同系列请求令牌（重开作废旧请求）。 */
  private relatedLoadToken: number = 0;
  /** 同系列半模态关闭令牌。 */
  private relatedCloseToken: number = 0;
  /** 剧评游标（/api/v1/series/{id}/comments 不透明续拉串；重开由加载器重置）。 */
  private seriesCommentCursor: string = '';
  /** 全屏控件自动隐藏定时器（0 无任务）。 */
  private fsHideTimer: number = 0;
  /** 中央播放按钮 3s 自动隐藏定时器（0 无任务）。 */
  private centerHideTimer: number = 0;
  /** 弹幕加载令牌（切集/seek 后旧请求作废）。 */
  private danmakuLoadToken: number = 0;
  /** 当前集已实际播放（position > 0；切集重置，已看标记 guard）。 */
  private hasDisplayed: boolean = false;
  /** 用户选定的清晰度档名（跨集记忆；空 = 跟默认最高档）。 */
  private qualityPreference: string = '';
  /** 预热的下一集流（fqapp _WarmEpisode；null = 无预热；单 mpv 实例，预热=取流先行）。 */
  private warmSource: FqEpisodeSource | null = null;
  /** 预热对应集 itemId（takeWarm 匹配用）。 */
  private warmItemId: string = '';
  /** 预热时的画质偏好（偏好变了作废）。 */
  private warmQuality: string = '';
  /** 预热取流进行中（防重复发起）。 */
  private warmInFlight: boolean = false;
  /** 边看边往后缓存已排过的集下标（-1 未排；同一集起播/换流/重试只排一次）。 */
  private autoCacheFor: number = -1;
  /** 边看边往后缓存延时定时器（0 无任务）。 */
  private autoCacheTimer: number = 0;
  /** 延时定时器对应集下标（同集首帧多次到达只推延不重排）。 */
  private autoCacheTimerIndex: number = -1;
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
  /** 横滑快进/快退起始播放位置（秒，-1 未在滑）。 */
  private dragSeekFrom: number = -1;
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
  /** 播放区实测宽（vp；PC 出右侧详情侧边栏后回填缩窄值，0 = 未实测回退屏宽）。 */
  @Local layoutW: number = 0;
  /** 播放区实测高（vp；0 = 未实测回退屏高）。 */
  @Local layoutH: number = 0;
  /** PC 详情侧边栏选集滚动器。 */
  private pcScroller: Scroller = new Scroller();
  /** PC 详情侧边栏选集分页条当前段。 */
  @Local pcEpisodePage: number = 0;
  /** PC 详情侧边栏内容页（'' 目录 / 'related' 同系列；选集头「同系列」按钮切换）。 */
  @Local pcPanel: string = '';
  /** PC 详情侧边栏收起（窄轨只留展开钮，fqapp 桌面目录收起语义）。 */
  @Local pcSidebarCollapsed: boolean = false;
  /** AVSession/后台播放助手（通知栏播控中心/胶囊 + 后台 audioPlayback 长时任务）。 */
  private media: FqVideoMedia = new FqVideoMedia('FqVideo');
  /** AVSession 元数据已同步时长（切集重置 -1；时长事件到达后补发元数据）。 */
  private mediaDurationSynced: number = -1;
  /** 切后台主动暂停回调（关闭后台播放时 EntryAbility onBackground 调用）。 */
  private backgroundPause: () => void = (): void => {};
  /** 视听统计累计秒（播放中每满 15s 落一次按书统计）。 */
  private statsSec: number = 0;
  /** 全屏底部菜单（倍速/清晰度）打开中：菜单关闭点击穿透守卫 + 暂停控件自动隐藏。 */
  @Local fsMenuOpen: boolean = false;
  /** 画中画控制器（设置开启且系统支持时创建；null 未启用）。 */
  private pipController: PiPWindow.PiPController | null = null;
  /** 画中画控制器创建中（防重复 create）。 */
  private pipCreating: boolean = false;
  /** 画中画小窗已拉起（退后台自动/前台手动）。 */
  private pipStarted: boolean = false;
  /** 画中画控制器已随离页销毁（create 迟到的结果直接停用丢弃）。 */
  private pipDisposed: boolean = false;
  /** 画中画自动拉起已武装（仅播放页前台显示时武装；onHidden/离页解除）。 */
  private pipArmed: boolean = false;
  /** 系统「自动启动画中画」开关（getPiPSettingSwitch 查询；查询失败按开处理保功能）。 */
  private pipSystemSwitch: boolean = true;
  /** onHidden 延迟解除武装令牌（++ 使正在等待的延迟判定作废：onShown/离页取消）。 */
  private pipHideToken: number = 0;

  aboutToAppear(): void {
    this.title = PlayerNavParams.title;
    this.tab = fqKindToTab(PlayerNavParams.kind);
    this.creationStatus = PlayerNavParams.creationStatus;
    this.episodes = PlayerNavParams.chapters;
    // PC 布局隐藏左侧主导航栏（onHidden 被上层页面覆盖/离页复位）
    appState.hidePcSideNav = true;
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
    // 弹幕样式：载入持久化设置（fqapp danmaku_config 五项 + 背景透明）
    this.danmakuAlphaPercent = FqAppSettingsStore.getDanmakuAlphaPercent();
    this.danmakuSpeedTier = FqAppSettingsStore.getDanmakuSpeedTier();
    this.danmakuLineCount = FqAppSettingsStore.getDanmakuLineCount();
    this.danmakuLineSpaceTier = FqAppSettingsStore.getDanmakuLineSpaceTier();
    this.danmakuSizeTier = FqAppSettingsStore.getDanmakuSizeTier();
    this.danmakuBgTransparent = FqAppSettingsStore.isDanmakuBgTransparent();
    this.applyDanmakuCfg();
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
      this.warmNextTick();
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
      // 画中画接管后台续播：播放页前台武装中 + 系统自动小窗开关开 + 播放中
      // 才不主动暂停（退后台自动小窗继续播）；否则照常暂停，避免后台只有声音没有小窗
      if (this.pipArmed && this.pipSystemSwitch && this.player.state.playing) {
        return;
      }
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    appState.backgroundPauseHandlers.push(this.backgroundPause);
    // 播放页常亮：进入开 keepScreenOn（播放视频不熄屏），离页恢复；
    // 同时监听 PC 窗口形态变化（全屏播放中按 ESC 系统窗口化时同步退出全屏）
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      win.setWindowKeepScreenOn(true);
      win.on('windowStatusChange', this.onWindowStatusChange);
    }).catch((): void => {
      // 常亮设置失败不影响播放
    });
    // 画中画：设置开启且系统支持时前台创建控制器（退后台自动小窗续播）
    this.setupPip();
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
    // 复位 PC 左侧主导航显隐（离页交还主导航）
    appState.hidePcSideNav = false;
    const bgHandlerIdx: number = appState.backgroundPauseHandlers.indexOf(this.backgroundPause);
    if (bgHandlerIdx >= 0) {
      appState.backgroundPauseHandlers.splice(bgHandlerIdx, 1);
    }
    this.endSpeedBoost();
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.loadToken += 1;
    this.dropWarmSource();
    this.cancelFsHide();
    this.cancelCenterHide();
    this.cancelLockHide();
    this.cancelAdjustHide();
    this.cancelSideLocate();
    if (this.autoCacheTimer !== 0) {
      clearTimeout(this.autoCacheTimer);
      this.autoCacheTimer = 0;
      this.autoCacheTimerIndex = -1;
    }
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
    // 播放页常亮恢复 + 画中画控制器销毁（停自动拉起/事件订阅/小窗）；
    // 同时注销 PC 窗口形态变化监听
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      win.setWindowKeepScreenOn(false);
      win.off('windowStatusChange');
    }).catch((): void => {
      // 恢复失败交由系统窗口销毁兜底
    });
    this.teardownPip();
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
        appState.hidePcSideNav = true;
        this.onNavPipShown();
      },
      onHidden: (): void => {
        appState.hidePcSideNav = false;
        this.onNavPipHidden();
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
      Row() {
        Stack() {
        // 视频区（contain；mpv 内部保持比例留黑边；全屏时撑满，面板展开时几何不变）
        Stack() {
          // 非全屏：surface 只取画面 contain 矩形（区域内居中），mpv 填满 surface 即画面居中；
          // 全屏：surface 撑满区域（沉浸黑边语义不变）
          Stack() {
            PlayerSurface({ player: this.player, ignoreSafeArea: false })
          }
          .width(this.fullScreen ? '100%' : this.videoRectWidth())
          .height(this.fullScreen ? '100%' : this.videoRectHeight())

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
        // 横滑：快进/快退（滑过一屏走 90s，复用中央时间浮层与进度条预览）；
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
              }),
            PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
              .onActionStart((event?: GestureEvent): void => {
                this.onSeekPanStart(event);
              })
              .onActionUpdate((event?: GestureEvent): void => {
                this.onSeekPanUpdate(event);
              })
              .onActionEnd((): void => {
                this.onSeekPanEnd();
              })
              .onActionCancel((): void => {
                this.onSeekPanEnd();
              })
          )
        )
        // 右上角菜单呼出的播放设置半模态（公共框架，不触发前景模糊）；
        // 二级「弹幕设置」页行数多，sheet 高度随之抬高
        .bindSheet(this.settingsVisible, this.SettingsSheetBuilder(),
          FqSheetOptions((): void => {
            this.closeSettings();
          }, this.settingsPage === 'danmaku' ? 380 : 330, false))

        // 中央播放/暂停按钮（非全屏渲染：点击才出现：暂停时常驻、播放 3s 后隐藏）
        if (this.errorMsg.length === 0 && !this.loading && !this.sheetVisible && !this.fullScreen &&
          (!this.player.state.playing || this.centerBtnVisible)) {
          this.CenterPlayButton()
        }

        // 弹幕层：竖屏片源占屏上 20%、横屏片源按「显示区域」档（fqapp danmaku_config）；
        // 竖屏片源全屏沉浸后 topRect 归零，用 maxTopRect 保底下移避开摄像头孔条（同 FsTopBar 语义）；
        // 且整棵子树不参与触摸测试，绝不影响底部控制条交互
        if (this.fullScreen && this.danmakuOn && this.errorMsg.length === 0 && this.danmakuItems.length > 0) {
          FqDanmakuView({
            items: this.danmakuItems,
            positionMs: Math.floor(this.player.state.position * 1000),
            resetToken: this.danmakuResetToken,
            playing: this.player.state.playing,
            config: this.danmakuCfg,
            maxLanes: this.danmakuMaxLanes(),
          })
            .width('100%')
            .height(this.danmakuLayerHeight())
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

        // 离线缓存 sheet 常驻宿主：缓存入口在非全屏选集行内，全屏态不渲染；
        // bindSheet 挂本常驻零尺寸节点，保证任意形态（全屏/侧边栏/设置 sheet）都能呼出
        Column()
          .width(1)
          .height(1)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet(this.cacheSheetVisible, this.CacheSheetBuilder(),
            FqSheetOptions((): void => {
              this.closeCacheSheet();
            }, fqPlayerSheetHeightVp(), false))

        // 同系列 sheet 常驻宿主：选集面板「同系列」呼出，横屏全屏走侧边栏不出此 sheet
        Column()
          .width(1)
          .height(1)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet(this.relatedSheetVisible, this.RelatedSheetBuilder(),
            FqSheetOptions((): void => {
              this.closeRelatedSheet();
            }, fqPlayerSheetHeightVp(), false))

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
            } else if (this.sidePanel === 'cache') {
              this.SideCache()
            } else if (this.sidePanel === 'related') {
              this.SideRelated()
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
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(Color.Black)
      .bindSheet(this.sheetVisible, this.EpisodeSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, fqPlayerSheetHeightVp(), false))
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.layoutW = Number(newArea.width);
          this.layoutH = Number(newArea.height);
        })

        // PC 大窗口右侧详情侧边栏（对齐 fqapp 桌面停靠目录）：非全屏常驻；
        // 全屏随控件层显隐同步消失/出现（含收起窄轨：3s 自隐、单击唤出、sheet/横屏侧栏打开让位），
        // 播放区缩窄让位（几何走 pageW()/pageH()），面板本身不遮挡画面
        if (this.pcSidebarOn() && (!this.fullScreen ||
          (!this.sheetVisible && this.sidePanel.length === 0 && this.fsControlsVisible))) {
          this.PcDetailSidebar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
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

        // PC 侧边栏在场时设置按钮移入侧边栏标题右侧，顶栏不再显示
        if (!this.pcSidebarOn()) {
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
      x: this.pageW() / 2,
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
      // 「全屏观看」药丸：视频实际画面出现（尺寸就绪）才显示，加载占位期不出现；
      // PC 布局不出药丸，全屏入口移到选集行缓存按钮右侧
      if (this.player.state.videoParams.dw > 0 && !this.pcSidebarOn()) {
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

        // 评论入口：并入选集行右端，呼出剧评半模态（公共 FqCommentSheet）
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

        // 全屏入口（PC 布局）：缓存按钮右侧按钮，替代「全屏观看」药丸
        if (this.pcSidebarOn()) {
          Column({ space: 1 }) {
            SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
              .fontSize(22)
              .fontColor([Color.White])
              .opacity(0.9)
            Text('全屏')
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
            this.enterFullscreen();
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }.layoutGravity(LocalizedAlignment.BOTTOM_END)// stack组件中子组件对齐位置
    // PC 窗口无底部手势区（bottomRect 为 0），底部组件整体抬高留出下边距
    .offset({ bottom: appState.bottomRect + (this.pcSidebarOn() ? FQ_PC_BOTTOM_LIFT_VP : 0) })
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

        Row({ space: 6 }) {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
            .padding({ left: 4 })
          Text(`第${this.episodes.length > 0 ? this.index + 1 : 1}集`)
            .fontSize(16)
            .fontColor(Color.White)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        // PC 侧边栏在场时设置按钮移入侧边栏标题右侧，全屏顶栏不再显示
        if (!this.pcSidebarOn()) {
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
    // 控制条触摸不触发自动隐藏（按下暂停计时，抬起恢复），仅空闲超时隐藏
    .onTouch((event: TouchEvent): void => {
      this.onFsBarTouch(event);
    })
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

        Text(this.qualityLabel())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .id(PLAYER_FS_QUALITY_ANCHOR_ID)
          .onClick((): void => {
            this.openQualityMenu();
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
    // 控制条触摸不触发自动隐藏（按下暂停计时，抬起恢复），仅空闲超时隐藏
    .onTouch((event: TouchEvent): void => {
      this.onFsBarTouch(event);
    })
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
        .backgroundColor(appState.accentColor)
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
      onOpenRelatedSeries: (): void => {
        this.openRelatedSeries();
      },
      onSelectEpisode: (index: number): void => {
        this.closeSheet();
        this.loadEpisode(index);
      },
    })
  }

  /** 同系列半模态（公共 FqRelatedSheet：加载/错误重试/空态/双列卡片）。 */
  @Builder
  private RelatedSheetBuilder() {
    FqRelatedSheet({
      items: this.relatedList,
      loading: this.relatedLoading,
      errorMsg: this.relatedErrorMsg,
      closeClick: (): void => {
        this.closeRelatedSheet();
      },
      retryClick: (): void => {
        this.loadRelatedSeries();
      },
      itemClick: (entry: FqRelatedSeries): void => {
        this.switchRelatedSeries(entry);
      },
    })
  }

  /** 剧评半模态：公共 FqCommentSheet + 剧评接口加载器
   *  （首拉 Loading / 错误重试 / 空态 / cursor 分页列表，评论为整部剧的）。 */
  @Builder
  private CommentsSheetBuilder() {
    FqCommentSheet({
      bookId: PlayerNavParams.contentId,
      fontColor: $r('sys.color.font_primary'),
      commentLabel: '剧评',
      cursorLoader: (refresh: boolean): Promise<FqBookCommentPage> => this.loadSeriesComments(refresh),
      openToken: this.commentOpenToken,
    })
  }

  /**
    * 离线缓存选集半模态（公共 FqCacheSheet 组件，CommonSheet 承载）：
    * 标题栏主标题 + 右侧「管理」「关闭」菜单；>30 集分页条横向滚动直达；
    * 集数网格复选（已缓存置灰打勾、任务态实时进度/排队/暂停/失败、
    * 选中橙底描边打勾、默认全选未缓存集）、全选 + 下载按钮。
    */
  @Builder
  private CacheSheetBuilder() {
    FqCacheSheet({
      sheetTitle: `离线缓存 · ${this.title}`,
      items: this.episodes,
      currentIndex: this.index,
      downloadedIds: this.cacheDownloadedIds,
      taskViewOf: (itemId: string): FqCacheTaskView | null => this.dl.taskOf(itemId),
      openToken: this.cacheOpenToken,
      itemLabel: '集',
      manageClick: (): void => {
        this.closeCacheSheet();
        NavPathUtils.push(ROUTE_CACHED_DRAMAS);
      },
      closeClick: (): void => {
        this.closeCacheSheet();
      },
      download: (itemIds: string[]): void => {
        this.confirmCacheDownload(itemIds);
      },
      taskClick: (itemId: string): void => {
        this.onCacheTaskClick(itemId);
      },
    })
  }

  /** 打开离线缓存选集半模态：刷新缓存/勾选状态（默认全选未缓存集）。
   *  横屏沉浸全屏：改走右侧边栏（与切集/播放设置同款 UI，不退全屏）；
   *  其余形态（竖屏全屏/非全屏）原样呼出底部 sheet（openToken 驱动组件重置定位）。 */
  private openCacheSheet(): void {
    if (this.episodes.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '剧集目录加载中', duration: 1500 });
      return;
    }
    this.closeSettings();
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.refreshCacheSheetState();
      this.locateSideCacheToCurrent();
      this.openSidePanel('cache');
      return;
    }
    if (this.sidePanel.length > 0) {
      this.closeSidePanel();
    }
    if (this.fullScreen) {
      // 全屏（竖屏片源）缓存 sheet 打开期间暂停控件自动隐藏（关闭后恢复空闲计时）
      this.cancelFsHide();
    }
    this.refreshCacheSheetState();
    this.cacheOpenToken += 1;
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.cacheSheetVisible = true;
    });
  }

  /** 侧边栏缓存面板打开后定位当前集（分页条选中段跟随）。 */
  private locateSideCacheToCurrent(): void {
    this.cancelCacheLocate();
    this.sideCachePage = Math.floor(this.index / FQ_CACHE_PAGE_SIZE);
    this.cacheLocateTimer = setTimeout((): void => {
      this.cacheLocateTimer = 0;
      this.sideCacheScroller.scrollToIndex(this.index, false, ScrollAlign.CENTER);
    }, 120);
  }

  /** 缓存格：已缓存置灰打勾 / 任务态橙色（进度%/排队/暂停/失败）/ 可选集（选中橙底描边打勾）。 */
  @Builder
  private CacheEpisodeCell(episode: FqChapter, index: number, dark: boolean) {
    Row({ space: 3 }) {
      Text(this.cacheCellLabel(episode, index))
        .fontSize(13)
        .fontColor(this.cacheCellTextColor(episode, dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.cacheCellShowCheck(episode)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(13)
          .fontColor([this.cacheCellTextColor(episode, dark)])
      }
    }
    .height(32)
    .width('100%')
    .padding({ left: 6, right: 6 })
    .borderRadius(8)
    .backgroundColor(this.cacheCellBg(episode, dark))
    .border({ width: this.cacheCellSelected(episode) ? 1 : 0, color: FQ_STORY_ORANGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onCacheCellClick(episode);
    })
  }

  private cancelCacheLocate(): void {
    if (this.cacheLocateTimer !== 0) {
      clearTimeout(this.cacheLocateTimer);
      this.cacheLocateTimer = 0;
    }
  }

  /** 缓存分页条尾段下标。 */
  private cacheLastPage(): number {
    return Math.max(0, Math.ceil(this.episodes.length / FQ_CACHE_PAGE_SIZE) - 1);
  }

  /** 缓存分页条标签（「1-30」「31-60」…）。 */
  private cachePageLabels(): string[] {
    const labels: string[] = [];
    const pages: number = this.cacheLastPage() + 1;
    for (let page: number = 0; page < pages; page++) {
      const start: number = page * FQ_CACHE_PAGE_SIZE + 1;
      const end: number = Math.min((page + 1) * FQ_CACHE_PAGE_SIZE, this.episodes.length);
      labels.push(`${start}-${end}`);
    }
    return labels;
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
        this.resumeFsAutoHide();
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

  /** 下载勾选集（FqCacheSheet/侧边栏回传 itemId 数组；已完整缓存/已在队列的
   *  enqueue 内部跳过），完成后清空侧边栏勾选。 */
  private confirmCacheDownload(itemIds: string[]): void {
    if (itemIds.length === 0) {
      return;
    }
    for (let i: number = 0; i < this.episodes.length; i++) {
      const episode: FqChapter | undefined = this.episodes[i];
      if (episode !== undefined && itemIds.includes(episode.itemId)) {
        this.dl.enqueue(PlayerNavParams.contentId, episode.itemId, episode.title,
          this.title, PlayerNavParams.cover, PlayerNavParams.kind, i + 1, false);
      }
    }
    this.cacheSelectedIds = new Set<string>();
  }

  /** 缓存任务格点击（FqCacheSheet 转发）：失败重试 / 暂停继续。 */
  private onCacheTaskClick(itemId: string): void {
    const task: FqDramaDownloadTask | null = this.dl.taskOf(itemId);
    if (task === null) {
      return;
    }
    if (task.status === DramaDownloadStatus.Failed) {
      this.dl.retry(itemId);
    } else if (task.status === DramaDownloadStatus.Paused) {
      this.dl.resume(itemId);
    }
  }

  /** 侧边栏勾选集转有序 itemId 数组（按剧集目录顺序）。 */
  private cacheSelectedIdList(): string[] {
    const itemIds: string[] = [];
    for (const episode of this.episodes) {
      if (this.cacheSelectedIds.has(episode.itemId)) {
        itemIds.push(episode.itemId);
      }
    }
    return itemIds;
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

  /** 缓存格文字色：已缓存系统三级、失败红、任务/选中橙、普通系统主色。 */
  private cacheCellTextColor(episode: FqChapter, dark: boolean): ResourceColor {
    if (this.cacheDownloadedIds.has(episode.itemId)) {
      return dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_tertiary');
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
    return dark ? Color.White : $r('sys.color.font_primary');
  }

  /** 缓存格底色：任务/选中橙 8% 底，其余浅色黑 6% / 深色白 15% 底。 */
  private cacheCellBg(episode: FqChapter, dark: boolean): ResourceColor {
    if (!this.cacheDownloadedIds.has(episode.itemId)
      && (this.dl.taskOf(episode.itemId) !== null || this.cacheSelectedIds.has(episode.itemId))) {
      return '#14FA6725';
    }
    return dark ? FQ_DARK_CARD_BG : '#0F000000';
  }

  /** 缓存格尾随勾：已缓存或选中。 */
  private cacheCellShowCheck(episode: FqChapter): boolean {
    return this.cacheDownloadedIds.has(episode.itemId) || this.cacheCellSelected(episode);
  }

  /** 播放设置半模态（公共 FqPlayerSettingsSheet：HDS 标题栏 + 播放设置/弹幕设置两级页；
   *  弹幕设置页 nav 返回按钮回播放设置、右上「恢复默认」，参数与事件桥接本页业务状态）。 */
  @Builder
  private SettingsSheetBuilder() {
    FqPlayerSettingsSheet({
      page: this.settingsPage,
      speed: this.player.state.speed,
      speedPreview: this.speedPreview,
      danmakuOn: this.danmakuOn,
      danmakuIsLandscape: this.isLandscapeDanmaku(),
      alphaPercent: this.danmakuAlphaPercent,
      speedTier: this.danmakuSpeedTier,
      lineCount: this.danmakuLineCount,
      lineSpaceTier: this.danmakuLineSpaceTier,
      sizeTier: this.danmakuSizeTier,
      bgTransparent: this.danmakuBgTransparent,
      speedCommit: (value: number): void => {
        this.player.setSpeed(value);
      },
      speedPreviewChange: (value: number): void => {
        this.speedPreview = value;
      },
      danmakuToggle: (on: boolean): void => {
        this.toggleDanmaku();
      },
      rowClick: (key: string): void => {
        this.onSettingRowClick(key);
      },
      alphaChange: (value: number): void => {
        this.setDanmakuAlpha(value);
      },
      speedTierChange: (tier: number): void => {
        this.setDanmakuSpeedTier(tier);
      },
      lineCountChange: (count: number): void => {
        this.setDanmakuLineCount(count);
      },
      lineSpaceTierChange: (tier: number): void => {
        this.setDanmakuLineSpaceTier(tier);
      },
      sizeTierChange: (tier: number): void => {
        this.setDanmakuSizeTier(tier);
      },
      bgTransparentChange: (on: boolean): void => {
        this.setDanmakuBgTransparent(on);
      },
      backClick: (): void => {
        this.settingsPage = '';
      },
      resetClick: (): void => {
        this.resetDanmakuSettings();
      },
      closeClick: (): void => {
        this.closeSettings();
      },
    })
  }

  /** 设置行点击：听视频进听剧模式页；离线缓存呼出缓存选集半模态；
   * 弹幕设置进二级设置页（倍速/弹幕行右侧控件自理）。 */
  private onSettingRowClick(key: string): void {
    if (key === 'cache') {
      this.openCacheSheet();
    } else if (key === 'listen') {
      this.openListenMode();
    } else if (key === 'danmakuSettings') {
      this.settingsPage = 'danmaku';
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

  /** AVSession 播放态立即同步（播放意图优先，绕过 mpv 状态异步）+ 画中画按钮状态。 */
  private syncMediaState(playing: boolean): void {
    this.media.syncPlayback(true, playing, this.player.state.speed, this.player.state.position);
    const controller: PiPWindow.PiPController | null = this.pipController;
    if (controller !== null) {
      try {
        controller.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
          playing ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
      } catch (error) {
        // 控制器未创建/已销毁时忽略
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 画中画（设置开启 + 系统支持：退后台自动小窗续播；关小窗暂停保存）
  // ---------------------------------------------------------------------------

  /** 播放页回到前台显示（NavDestination onShown，含从听视频页返回）：
   *  取消待执行的延迟解除武装，再重新武装画中画退后台自动拉起。 */
  private onNavPipShown(): void {
    this.onNavShown();
    this.pipHideToken += 1;
    this.setPipAutoStart(true);
  }

  /** 播放页被覆盖/退出（NavDestination onHidden）：延迟解除画中画自动拉起——
   *  应用切后台也会触发 onHidden，此时须保持武装让小窗正常拉起，
   *  延迟后按 appState.appInBackground 判定：仅页内路由覆盖（推听视频页等）才真正解除。 */
  private onNavPipHidden(): void {
    this.pipHideToken += 1;
    const token: number = this.pipHideToken;
    setTimeout((): void => {
      if (token !== this.pipHideToken || appState.appInBackground) {
        return;
      }
      this.setPipAutoStart(false);
    }, 200);
  }

  /** 前台创建画中画控制器（XComponent 方式：画面 + 播放/暂停 + 上一集/下一集）。 */
  private setupPip(): void {
    if (!PiPWindow.isPiPEnabled() || !FqAppSettingsStore.isPipVideoEnabled()) {
      return;
    }
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null || this.pipController !== null || this.pipCreating) {
      return;
    }
    this.pipCreating = true;
    // 画中画还原锚点：手机端 Index / PC 侧边栏 PcMainLayout 的 Navigation id
    const pcLayout: boolean = useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp);
    const config: PiPWindow.PiPConfiguration = {
      context: context,
      componentController: this.player,
      navigationId: pcLayout ? 'pc_main_nav' : 'main_nav',
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      controlGroups: [PiPWindow.VideoPlayControlGroup.VIDEO_PREVIOUS_NEXT],
    };
    PiPWindow.create(config).then((controller: PiPWindow.PiPController): void => {
      this.pipCreating = false;
      // 离页后 create 才返回：控制器直接停用丢弃，绝不武装自动拉起
      if (this.pipDisposed) {
        try {
          controller.setAutoStartEnabled(false);
          controller.off('stateChange');
          controller.off('controlEvent');
        } catch (error) {
          // 控制器状态异常时忽略
        }
        controller.stopPiP().catch((): void => {
          // 小窗未启动时停止报错忽略
        });
        return;
      }
      this.pipController = controller;
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string): void => {
        this.onPipStateChange(state, reason);
      });
      controller.on('controlEvent', (control: PiPWindow.ControlEventParam): void => {
        this.onPipControlEvent(control);
      });
      // 播放页正在显示：先武装退后台自动拉起（须前台调用），再查系统开关，
      // 避免系统开关查询异常中断武装导致退后台小窗拉不起来
      this.setPipAutoStart(true);
      // 系统「自动启动画中画」开关：关时退后台不豁免暂停（小窗拉不起来，只有声音没有画面）
      try {
        controller.getPiPSettingSwitch().then((enabled: boolean): void => {
          this.pipSystemSwitch = enabled;
        }).catch((): void => {
          // 查询失败按系统开关开启处理（保画中画功能）
          this.pipSystemSwitch = true;
        });
      } catch (error) {
        // 查询同步异常同样按系统开关开启处理
        this.pipSystemSwitch = true;
      }
    }).catch((): void => {
      // 创建失败静默降级：不影响正常播放（画中画为可选能力）
      this.pipCreating = false;
    });
  }

  /**
   * 武装/解除画中画退后台自动拉起：仅播放页前台显示期间武装
   * （onShown 武装、onHidden/离页解除），退出播放页后画中画不再生效。
   */
  private setPipAutoStart(enable: boolean): void {
    const controller: PiPWindow.PiPController | null = this.pipController;
    if (controller === null) {
      return;
    }
    this.pipArmed = enable;
    try {
      controller.setAutoStartEnabled(enable);
    } catch (error) {
      // 控制器状态异常时忽略
    }
  }

  /**
   * 离页销毁画中画：先停播（退出播放页不再有视频声音），再解除自动拉起 +
   * 退订事件 + 关小窗；create 迟到的结果也一并作废（pipDisposed）。
   */
  private teardownPip(): void {
    this.pipDisposed = true;
    // 作废 onHidden 可能挂起的延迟解除武装令牌（离页已同步解除）
    this.pipHideToken += 1;
    const controller: PiPWindow.PiPController | null = this.pipController;
    if (controller !== null && this.player.state.playing) {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    }
    this.pipController = null;
    this.pipArmed = false;
    this.pipStarted = false;
    if (controller === null) {
      return;
    }
    try {
      controller.setAutoStartEnabled(false);
      controller.off('stateChange');
      controller.off('controlEvent');
    } catch (error) {
      // 控制器状态异常时忽略
    }
    controller.stopPiP().catch((): void => {
      // 小窗未启动时停止报错忽略
    });
  }

  /** 画中画状态回调：用户主动关小窗（关闭按钮/拖拽删除）暂停并保存续播进度；
   *  小窗异常终止（ERROR）同样停播，避免退后台只剩声音没有小窗。 */
  private onPipStateChange(state: PiPWindow.PiPState, reason: string): void {
    if (state === PiPWindow.PiPState.STARTED) {
      this.pipStarted = true;
      return;
    }
    if (state === PiPWindow.PiPState.STOPPED) {
      this.pipStarted = false;
      if (reason === 'panelActionDelete' || reason === 'dragDelete') {
        this.player.pause();
        this.saveCurrentProgress();
        this.syncMediaState(false);
      }
      return;
    }
    if (state === PiPWindow.PiPState.ERROR) {
      this.pipStarted = false;
      if (this.player.state.playing) {
        this.player.pause();
        this.saveCurrentProgress();
        this.syncMediaState(false);
      }
    }
  }

  /** 画中画控制事件：播放/暂停、上一集/下一集（对齐播控中心语义）。 */
  private onPipControlEvent(control: PiPWindow.ControlEventParam): void {
    if (control.controlType === PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE) {
      if (control.status === PiPWindow.PiPControlStatus.PLAY) {
        this.player.play();
        this.syncMediaState(true);
      } else {
        this.player.pause();
        this.saveCurrentProgress();
        this.syncMediaState(false);
      }
      return;
    }
    if (control.controlType === PiPWindow.PiPControlType.VIDEO_NEXT) {
      this.nextEpisode();
      return;
    }
    if (control.controlType === PiPWindow.PiPControlType.VIDEO_PREVIOUS) {
      if (this.player.state.position > 3) {
        this.player.seek(0);
        return;
      }
      if (this.index > 0) {
        this.loadEpisode(this.index - 1);
      } else {
        this.player.seek(0);
      }
    }
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

  /** 侧边栏·选集（公共 FqPlayerSidebar 壳：标题「选集」+ 右上「同系列」文本按钮 + 关闭）。 */
  @Builder
  private SideEpisodes() {
    FqPlayerSidebar({
      title: '选集',
      showRelated: true,
      relatedClick: (): void => {
        this.openRelatedSeries();
      },
      showClose: true,
      closeClick: (): void => {
        this.closeSidePanel();
      },
      panelBgColor: FQ_FS_SIDE_BG,
      content: (): void => {
        this.SideEpisodesBody();
      },
    })
  }

  /** 侧边栏·选集内容体：>30 集分页条横向直达 + 4 列序号格（当前集橙、已看灰、普通白），点选切集并收起。 */
  @Builder
  private SideEpisodesBody() {
    Column() {
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
        if (this.episodes.length > FQ_CACHE_PAGE_SIZE) {
          this.SideEpisodePagingStrip()
        }
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
        .onScrollIndex((first: number, last: number): void => {
          const page: number = Math.floor(first / FQ_CACHE_PAGE_SIZE);
          if (page !== this.sideEpisodePage && page >= 0 && page <= this.cacheLastPage()) {
            this.sideEpisodePage = page;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏选集 >30 集分页条（深色，横向滚动直达 + 滚动联动；对齐非全屏选集面板分段条）。 */
  @Builder
  private SideEpisodePagingStrip() {
    Scroll() {
      Row({ space: 20 }) {
        ForEach(this.cachePageLabels(), (label: string, page: number) => {
          Text(label)
            .fontSize(14)
            .fontWeight(page === this.sideEpisodePage ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(page === this.sideEpisodePage ? Color.White : FQ_DARK_TERTIARY_TEXT)
            .onClick((): void => {
              this.sideEpisodePage = page;
              this.sideScroller.scrollToIndex(page * FQ_CACHE_PAGE_SIZE, false, ScrollAlign.START);
            })
        }, (label: string) => label)
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(32)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  // ---------------------------------------------------------------------------
  // PC 右侧详情侧边栏（fqapp 桌面停靠目录 desktop_video_chrome）
  // ---------------------------------------------------------------------------

  /** PC 详情侧边栏入口药丸（作品详情/评论/缓存/听剧/同系列，深色圆角芯片；芯片间留间隔）。 */
  @Builder
  private PcSidebarPill(label: string, onClick: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(Color.White)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(15)
      .backgroundColor('#33FFFFFF')
      .margin({ right: 8, bottom: 8 })
      .onClick((): void => {
        onClick();
      })
  }

  /** PC 详情侧边栏选集 >30 集分页条（横向滚动直达 + 滚动联动）。 */
  @Builder
  private PcEpisodePagingStrip() {
    Scroll() {
      Row({ space: 16 }) {
        ForEach(this.cachePageLabels(), (label: string, page: number) => {
          Text(label)
            .fontSize(12)
            .fontWeight(page === this.pcEpisodePage ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(page === this.pcEpisodePage ? Color.White : FQ_DARK_TERTIARY_TEXT)
            .onClick((): void => {
              this.pcEpisodePage = page;
              this.pcScroller.scrollToIndex(page * FQ_CACHE_PAGE_SIZE, false, ScrollAlign.START);
            })
        }, (label: string) => label)
      }
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
    .height(24)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  /**
   * PC 右侧详情侧边栏（fqapp 桌面停靠目录）：左缘关闭长条 + 剧名 + 设置按钮（顶栏原设置按钮移入）/
   * 共N集·第N集 / 简介 3 行 / 原著横幅 / 入口药丸（作品详情/评论/缓存/听剧/同系列）/ 选集头 /
   * 分页条 / 5 列选集网格（集数区独立滚动，滚动不动上方固定区，分段按钮直达）；
   * 同系列页顶部标题栏不显示；横竖屏片源、全屏与否均常驻，播放区缩窄让位。
   */
  @Builder
  private PcDetailSidebar() {
    if (this.pcSidebarCollapsed) {
      // 收起窄轨：只留展开钮（向左，展开拉回侧边栏）
      Column() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([Color.White])
      }
      .width(FQ_PC_SIDEBAR_CLOSE_STRIP_W)
      .height('100%')
      .backgroundColor(FQ_PC_DETAIL_SIDEBAR_BG)
      .justifyContent(FlexAlign.Center)
      .onClick((): void => {
        this.pcSidebarCollapsed = false;
      })
    } else {
      Row() {
        // 关闭长条：整个侧边栏左缘竖条，点击收起整个侧边栏
        Column() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(20)
            .fontColor(['#99FFFFFF'])
        }
        .width(FQ_PC_SIDEBAR_CLOSE_STRIP_W)
        .height('100%')
        .backgroundColor(FQ_PC_SIDEBAR_CLOSE_STRIP_BG)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.pcSidebarCollapsed = true;
        })

        Column() {
          if (this.pcPanel === 'related') {
            // 同系列页（选集头「同系列」/药丸进入）：标题栏返回按钮 + 深色双列卡片网格
            FqPlayerSidebar({
              title: '同系列剧',
              showBack: true,
              backClick: (): void => {
                this.pcPanel = '';
              },
              panelBgColor: FQ_PC_DETAIL_SIDEBAR_BG,
              content: (): void => {
                this.PcRelatedBody();
              },
            })
          } else {
            // 目录页（公共 FqPlayerSidebar 壳）：标题=剧名 + 右上设置按钮（PC 把顶栏原设置按钮移到标题栏右侧）
            FqPlayerSidebar({
              title: this.title,
              showSettings: true,
              settingsClick: (): void => {
                this.openSettings();
              },
              panelBgColor: FQ_PC_DETAIL_SIDEBAR_BG,
              content: (): void => {
                this.PcCatalogBody();
              },
            })
          }
        }
        .width(FQ_PC_DETAIL_SIDEBAR_W - FQ_PC_SIDEBAR_CLOSE_STRIP_W)
        .height('100%')
        .backgroundColor(FQ_PC_DETAIL_SIDEBAR_BG)
      }
      .width(FQ_PC_DETAIL_SIDEBAR_W)
      .height('100%')
    }
  }

  /** 作品详情入口（fqapp 桌面「作品详情」）：暂停存进度后进本剧详情页。 */
  private openDramaDetail(): void {
    this.player.pause();
    this.saveCurrentProgress();
    fqPushBookOrDetail(PlayerNavParams.contentId, PlayerNavParams.kind, this.title, PlayerNavParams.cover);
  }

  /** PC 侧边栏·目录内容体：固定区（不随集数滚动）+ 独立滚动集数网格（分段按钮直达当前段）。 */
  @Builder
  private PcCatalogBody() {
    Column() {
      // 固定区（不随集数滚动）：集数/状态、简介、原著横幅、入口药丸、选集头、分段条
      Column({ space: 10 }) {
        // 集数/状态 + 当前集
        Text(`共${this.episodes.length}集 · 第${this.episodes.length > 0 ? this.index + 1 : 1}集 · ${this.episodeLabel()}`)
          .fontSize(12)
          .fontColor('#99FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 简介（3 行，fqapp 桌面 synopsis）
        if (PlayerNavParams.intro.length > 0) {
          Text(PlayerNavParams.intro)
            .fontSize(12)
            .fontColor('#99FFFFFF')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(18)
        }

        // 原著横幅（有原著才显示）
        if (this.originalBook !== null) {
          this.OriginalBookBanner()
        }

        // 入口药丸（fqapp 桌面 Wrap 按钮组）
        Flex({ wrap: FlexWrap.Wrap }) {
          this.PcSidebarPill('作品详情', (): void => {
            this.openDramaDetail();
          })
          this.PcSidebarPill('评论', (): void => {
            this.openComments();
          })
          this.PcSidebarPill('缓存', (): void => {
            this.openCacheSheet();
          })
          this.PcSidebarPill('听剧', (): void => {
            this.openListenMode();
          })
          this.PcSidebarPill('同系列', (): void => {
            this.openRelatedSeries();
          })
        }
        .width('100%')

        // 选集头（右侧「同系列」入口：点击侧边栏内容切换为同系列组件，目录让位）
        Row({ space: 8 }) {
          Text('选集')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)

          Text(this.episodeLabel())
            .fontSize(12)
            .fontColor('#99FFFFFF')
            .layoutWeight(1)

          Text('同系列')
            .fontSize(13)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(13)
            .backgroundColor('#33FFFFFF')
            .onClick((): void => {
              this.openRelatedSeries();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.episodes.length > FQ_CACHE_PAGE_SIZE) {
          this.PcEpisodePagingStrip()
        }

        if (this.episodes.length === 0) {
          Text('暂无剧集')
            .fontSize(13)
            .fontColor('#99FFFFFF')
            .padding({ top: 24, bottom: 24 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2 })
      .alignItems(HorizontalAlign.Start)

      if (this.episodes.length > 0) {
        // 集数网格独立滚动（占满余高）：分段按钮 scrollToIndex 直达当前段，
        // 滚动只动集数，不动上方固定区
        Grid(this.pcScroller) {
          ForEach(this.episodes, (episode: FqChapter, index: number) => {
            GridItem() {
              Row() {
                Text(`${index + 1}`)
                  .fontSize(14)
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
                this.loadEpisode(index);
              })
            }
          }, (episode: FqChapter, index: number) => `${episode.itemId}-${index}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        .onScrollIndex((first: number, last: number): void => {
          const page: number = Math.floor(first / FQ_CACHE_PAGE_SIZE);
          if (page !== this.pcEpisodePage && page >= 0 && page <= this.cacheLastPage()) {
            this.pcEpisodePage = page;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** PC 侧边栏·同系列内容体：深色双列卡片网格，选中新剧进详情页。 */
  @Builder
  private PcRelatedBody() {
    Column() {
      FqRelatedList({
        items: this.relatedList,
        loading: this.relatedLoading,
        errorMsg: this.relatedErrorMsg,
        dark: true,
        retryClick: (): void => {
          this.loadRelatedSeries();
        },
        itemClick: (entry: FqRelatedSeries): void => {
          this.switchRelatedSeries(entry);
        },
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏·播放设置（公共 FqPlayerSidebar 壳）：主设置页/二级「弹幕设置」页，
   *  标题栏随 settingsPage 切换（弹幕页：返回按钮 + 右上「恢复默认」+ 关闭）。 */
  @Builder
  private SideSettings() {
    FqPlayerSidebar({
      title: this.settingsPage === 'danmaku' ? '弹幕设置' : '播放设置',
      showBack: this.settingsPage === 'danmaku',
      backClick: (): void => {
        this.settingsPage = '';
      },
      showReset: this.settingsPage === 'danmaku',
      resetClick: (): void => {
        this.resetDanmakuSettings();
      },
      showClose: true,
      closeClick: (): void => {
        this.closeSidePanel();
      },
      panelBgColor: FQ_FS_SIDE_BG,
      content: (): void => {
        this.SideSettingsBody();
      },
    })
  }

  /** 侧边栏·播放设置内容体：主设置页（FqPlayerSettingsPanel 深色）/弹幕设置页（FqDanmakuSettingsPanel 深色）。 */
  @Builder
  private SideSettingsBody() {
    if (this.settingsPage === 'danmaku') {
      FqDanmakuSettingsPanel({
        dark: true,
        isLandscape: this.isLandscapeDanmaku(),
        alphaPercent: this.danmakuAlphaPercent,
        speedTier: this.danmakuSpeedTier,
        lineCount: this.danmakuLineCount,
        lineSpaceTier: this.danmakuLineSpaceTier,
        sizeTier: this.danmakuSizeTier,
        bgTransparent: this.danmakuBgTransparent,
        alphaChange: (value: number): void => {
          this.setDanmakuAlpha(value);
        },
        speedTierChange: (tier: number): void => {
          this.setDanmakuSpeedTier(tier);
        },
        lineCountChange: (count: number): void => {
          this.setDanmakuLineCount(count);
        },
        lineSpaceTierChange: (tier: number): void => {
          this.setDanmakuLineSpaceTier(tier);
        },
        sizeTierChange: (tier: number): void => {
          this.setDanmakuSizeTier(tier);
        },
        bgTransparentChange: (on: boolean): void => {
          this.setDanmakuBgTransparent(on);
        },
      })
    } else {
      FqPlayerSettingsPanel({
        dark: true,
        speed: this.player.state.speed,
        speedPreview: this.speedPreview,
        danmakuOn: this.danmakuOn,
        speedCommit: (value: number): void => {
          this.player.setSpeed(value);
        },
        speedPreviewChange: (value: number): void => {
          this.speedPreview = value;
        },
        danmakuToggle: (on: boolean): void => {
          this.toggleDanmaku();
        },
        rowClick: (key: string): void => {
          this.onSettingRowClick(key);
        },
      })
    }
  }

  /** 侧边栏·同系列（横屏全屏形态，公共 FqPlayerSidebar 壳）：深色双列卡片网格，选中新剧进详情页。 */
  @Builder
  private SideRelated() {
    FqPlayerSidebar({
      title: '同系列剧',
      showClose: true,
      closeClick: (): void => {
        this.closeSidePanel();
      },
      panelBgColor: FQ_FS_SIDE_BG,
      content: (): void => {
        this.SideRelatedBody();
      },
    })
  }

  /** 侧边栏·同系列内容体。 */
  @Builder
  private SideRelatedBody() {
    Column() {
      FqRelatedList({
        items: this.relatedList,
        loading: this.relatedLoading,
        errorMsg: this.relatedErrorMsg,
        dark: true,
        retryClick: (): void => {
          this.loadRelatedSeries();
        },
        itemClick: (entry: FqRelatedSeries): void => {
          this.switchRelatedSeries(entry);
        },
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏·离线缓存（横屏全屏形态，公共 FqPlayerSidebar 壳）：标题栏返回（回播放设置侧边栏）+
   *  右上关闭；「管理」行在标题栏下方（进剧集缓存管理页）；
   *  >30 集分页条横向滚动直达；集数网格 3 列复选（4 列勾选态文字超出单格宽度）/
   *  全选/下载行与底部半模态同款逻辑。 */
  @Builder
  private SideCache() {
    FqPlayerSidebar({
      title: `离线缓存 · ${this.title}`,
      showBack: true,
      backClick: (): void => {
        this.openSidePanel('settings');
      },
      showClose: true,
      closeClick: (): void => {
        this.closeSidePanel();
      },
      panelBgColor: FQ_FS_SIDE_BG,
      content: (): void => {
        this.SideCacheBody();
      },
    })
  }

  /** 侧边栏·离线缓存内容体。 */
  @Builder
  private SideCacheBody() {
    Column() {
      Row() {
        Text('管理')
          .fontSize(14)
          .fontColor(FQ_STORY_ORANGE)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick((): void => {
            this.closeSidePanel();
            NavPathUtils.push(ROUTE_CACHED_DRAMAS);
          })
      }
      .width('100%')
      .padding({ left: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.episodes.length > FQ_CACHE_PAGE_SIZE) {
        this.SideCachePagingStrip()
      }

      Grid(this.sideCacheScroller) {
        ForEach(this.episodes, (episode: FqChapter, index: number) => {
          GridItem() {
            this.CacheEpisodeCell(episode, index, true)
          }
        }, (episode: FqChapter) => episode.itemId)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 12, right: 12, top: 4, bottom: 8 })
      .onScrollIndex((first: number, last: number): void => {
        const page: number = Math.floor(first / FQ_CACHE_PAGE_SIZE);
        if (page !== this.sideCachePage && page >= 0 && page <= this.cacheLastPage()) {
          this.sideCachePage = page;
        }
      })

      Row() {
        Text(this.cacheAllSelected() ? '取消全选' : '全选')
          .fontSize(14)
          .fontColor(this.cachePendingCount() === 0 ? FQ_DARK_TERTIARY_TEXT : FQ_STORY_ORANGE)
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
            this.confirmCacheDownload(this.cacheSelectedIdList());
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16, top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 侧边栏缓存 >30 集分页条（深色配色，横向滚动直达 + 滚动联动）。 */
  @Builder
  private SideCachePagingStrip() {
    Scroll() {
      Row({ space: 20 }) {
        ForEach(this.cachePageLabels(), (label: string, page: number) => {
          Text(label)
            .fontSize(14)
            .fontWeight(page === this.sideCachePage ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(page === this.sideCachePage ? Color.White : FQ_DARK_TERTIARY_TEXT)
            .onClick((): void => {
              this.sideCachePage = page;
              this.sideCacheScroller.scrollToIndex(page * FQ_CACHE_PAGE_SIZE, false, ScrollAlign.START);
            })
        }, (label: string) => label)
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(32)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
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

  /**
   * 播放区宽（vp）：根 Stack 实测宽（PC 侧边栏挤占后回填；未实测回退屏宽）。
   * 几何一律走这里而不是屏宽，PC 大窗口出右侧详情侧边栏时画面区按缩窄后布局。
   */
  private pageW(): number {
    return this.layoutW > 0 ? this.layoutW : this.screenW;
  }

  /** 播放区高（vp）：根 Stack 实测高（未实测回退屏高）。 */
  private pageH(): number {
    return this.layoutH > 0 ? this.layoutH : this.screenH;
  }

  /** PC 右侧详情侧边栏显隐：PC 布局且窗口够宽（对齐 fqapp 桌面停靠目录阈值）时常驻。 */
  private pcSidebarOn(): boolean {
    return useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp) &&
      appState.windowWidthVp >= FQ_PC_DETAIL_SIDEBAR_MIN_W;
  }

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
      return this.pageH();
    }
    return Math.max(0,
      this.pageH() - (appState.topRect + 44) - appState.bottomRect - FQ_STORY_BOTTOM_INSET);
  }

  /**
   * 底部信息区顶（官方 163 信息区）：剧名行锚点，
   * 恒在细进度线与选集胶囊上方（自上而下：剧名行 → 进度线 → 选集胶囊）。
   */
  private infoTop(): number {
    return this.pageH() - appState.bottomRect - FQ_STORY_BOTTOM_INSET;
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
      videoH = Math.min(regionH, this.pageW() / dw * dh);
    } else {
      videoH = Math.min(regionH, this.pageW() * 16 / 9);
    }
    return this.videoTopAbs() + (regionH + videoH) / 2;
  }

  /** 非全屏画面（contain 矩形）宽：surface 只取画面比例矩形（区域内居中，mpv 填满无黑边）。 */
  private videoRectWidth(): number {
    const regionH: number = this.videoRegionHeight();
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    const ratioW: number = dw > 0 && dh > 0 ? dw : 9;
    const ratioH: number = dw > 0 && dh > 0 ? dh : 16;
    const byHeight: number = regionH / ratioH * ratioW;
    return Math.max(1, Math.min(this.pageW(), byHeight));
  }

  /** 非全屏画面（contain 矩形）高：与 videoRectWidth 同一 contain 约束的另一边。 */
  private videoRectHeight(): number {
    const regionH: number = this.videoRegionHeight();
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    const ratioW: number = dw > 0 && dh > 0 ? dw : 9;
    const ratioH: number = dw > 0 && dh > 0 ? dh : 16;
    const byWidth: number = this.pageW() / ratioW * ratioH;
    return Math.max(1, Math.min(regionH, byWidth));
  }

  /** 底部信息列内容高：剧名行 22 + 进度线 30 + 选集行 40 + 间距 12×3；原著横幅 +12+44。 */
  private bandContentHeight(): number {
    const base: number = 22 + 12 + 30 + 12 + 40;
    return this.originalBook !== null ? base + 12 + 44 : base;
  }

  /** 底部信息列顶（列自底向上生长，官方 informationTop；药丸让位钳制用）。 */
  private bandTopAbs(): number {
    return this.pageH() - appState.bottomRect - this.bandContentHeight();
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
    this.settingsPage = '';
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.openSidePanel('settings');
      return;
    }
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.settingsVisible = true;
    });
    if (this.fullScreen) {
      // 全屏设置 sheet 打开期间暂停控件自动隐藏（关闭后恢复空闲计时）
      this.cancelFsHide();
    }
  }

  /** 打开剧评半模态：bump 打开令牌（重置重载剧评列表），数据由 FqCommentSheet 自理。 */
  private openComments(): void {
    this.commentCloseToken += 1;
    this.commentOpenToken += 1;
    this.commentSheetVisible = true;
  }

  /**
   * 剧评页加载器（/api/v1/series/{id}/comments，官方 gx1/m.java：整部剧评论列表，
   * sort=1 最热 + cursor 续拉）：refresh 自动作废旧游标从首页重取；
   * 失败向上抛由 FqCommentSheet 落错误态。
   */
  private async loadSeriesComments(refresh: boolean): Promise<FqBookCommentPage> {
    if (PlayerNavParams.contentId.length === 0) {
      return new FqBookCommentPage([], 0, 0, '', false, 0);
    }
    if (refresh) {
      this.seriesCommentCursor = '';
    }
    const cursorIn: string = this.seriesCommentCursor;
    const page: FqEpisodeCommentPage = await FqBackend.get().seriesComments(
      PlayerNavParams.contentId, cursorIn);
    this.seriesCommentCursor = page.cursor;
    return new FqBookCommentPage(page.comments, page.totalCount, 0, '', page.hasMore, 0);
  }

  // ---------------------------------------------------------------------------
  // 同系列（fqapp RelatedSeriesSheet / _switchRelatedSeries）
  // ---------------------------------------------------------------------------

  /** 打开同系列列表（PC 详情侧边栏在场则内容页切换；横屏全屏走右侧边栏深色面板，其余底部半模态）。 */
  private openRelatedSeries(): void {
    this.loadRelatedSeries();
    if (this.pcSidebarOn()) {
      this.pcPanel = 'related';
      return;
    }
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.openSidePanel('related');
      return;
    }
    if (this.sidePanel.length > 0) {
      this.closeSidePanel();
    }
    if (this.fullScreen) {
      // 全屏（竖屏片源）sheet 打开期间暂停控件自动隐藏（关闭后恢复空闲计时）
      this.cancelFsHide();
    }
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.relatedSheetVisible = true;
    });
  }

  /** 加载同系列列表（/api/v1/series/{id}/related；失败落错误态可重试）。 */
  private async loadRelatedSeries(): Promise<void> {
    const seriesId: string = PlayerNavParams.contentId;
    if (seriesId.length === 0) {
      return;
    }
    const token: number = ++this.relatedLoadToken;
    this.relatedLoading = true;
    this.relatedErrorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const list: FqRelatedSeries[] = await FqBackend.get().relatedSeries(seriesId);
      if (token !== this.relatedLoadToken) {
        return;
      }
      this.relatedLoading = false;
      this.relatedList = list;
    } catch (error) {
      if (token !== this.relatedLoadToken) {
        return;
      }
      this.relatedLoading = false;
      this.relatedErrorMsg = fqErrorMessage(error);
    }
  }

  /**
   * 选中间系列剧 → 新剧详情页（fqapp _switchRelatedSeries 语义：旧剧暂停、
   * 进度已存、详情页之上再起播）。不可播（即将上线/内容不可播）不响应；
   * 全屏先退沉浸（窗口级方向/系统栏设置不带入详情页）。
   */
  private switchRelatedSeries(entry: FqRelatedSeries): void {
    if (entry.unavailable || entry.id.length === 0) {
      return;
    }
    if (this.fullScreen) {
      this.exitFullscreen();
    }
    this.closeRelatedSheet();
    this.closeSidePanel();
    this.pcPanel = '';
    this.player.pause();
    this.saveCurrentProgress();
    DetailNavParams.id = entry.id;
    DetailNavParams.kind = entry.kind;
    DetailNavParams.title = entry.title;
    DetailNavParams.cover = entry.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 关闭同系列半模态（延迟一拍置 isShow，同 closeSheet 语义）。 */
  private closeRelatedSheet(): void {
    const token: number = ++this.relatedCloseToken;
    setTimeout((): void => {
      if (token === this.relatedCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.relatedSheetVisible = false;
        });
        this.resumeFsAutoHide();
      }
    }, 0);
  }

  /** 全屏底部倍速按钮：公共 FqMenu 档位直选（0.5-2.0 步进 0.25，
   *  当前档尾勾标识；选中即提交 mpv，无需打开播放设置半模态）。
   *  菜单打开期间暂停控件自动隐藏（关闭后恢复空闲计时）。 */
  private openSpeedMenu(): void {
    const items: Array<FqMenuItem> = [];
    const steps: number[] = fqSpeedSteps();
    for (const step of steps) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = fqSpeedStepLabel(step);
      if (this.isCurrentSpeedStep(step)) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      item.onAction = (): void => {
        this.player.setSpeed(step);
      };
      items.push(item);
    }
    this.fsMenuOpen = true;
    this.cancelFsHide();
    FqMenu.open(this.getUIContext(), PLAYER_FS_SPEED_ANCHOR_ID, items, (): void => {
      this.fsMenuOpen = false;
      this.resumeFsAutoHide();
    });
  }

  /** 当前清晰度按钮文案：选中档显示档名；默认流显示「清晰度」。 */
  private qualityLabel(): string {
    if (this.qualityIndex >= 0 && this.qualityIndex < this.qualityVariants.length) {
      return this.qualityVariants[this.qualityIndex].name;
    }
    return '清晰度';
  }

  /** 全屏底部清晰度按钮：公共 FqMenu 档位直选（默认流 + variants 档位，
   *  当前档尾勾标识；选中即切流，mpv 按当前位置续播）。
   *  菜单打开期间暂停控件自动隐藏（关闭后恢复空闲计时）。 */
  private openQualityMenu(): void {
    const items: Array<FqMenuItem> = [];
    const defaultItem: FqMenuItem = new FqMenuItem();
    defaultItem.label = '默认';
    if (this.qualityIndex < 0) {
      defaultItem.endIcon = $r('sys.symbol.checkmark');
    }
    defaultItem.onAction = (): void => {
      this.switchQuality(-1);
    };
    items.push(defaultItem);
    for (let i: number = 0; i < this.qualityVariants.length; i++) {
      const variant: FqEpisodeVariant = this.qualityVariants[i];
      const item: FqMenuItem = new FqMenuItem();
      item.label = variant.name;
      if (this.qualityIndex === i) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      item.onAction = (): void => {
        this.switchQuality(i);
      };
      items.push(item);
    }
    this.fsMenuOpen = true;
    this.cancelFsHide();
    FqMenu.open(this.getUIContext(), PLAYER_FS_QUALITY_ANCHOR_ID, items, (): void => {
      this.fsMenuOpen = false;
      this.resumeFsAutoHide();
    });
  }

  /**
   * 切换清晰度档：后端按档重新取流下载解密（loopback /src/ 明文供 mpv），
   * 原位置续播；档名跨集记忆（后续集上游仍有该档则沿用）。
   * 下载模式 variant url 为上游密文流，mpv 无法直连，必须走重取流链路。
   */
  private switchQuality(index: number): void {
    if (this.loading || index === this.qualityIndex) {
      return;
    }
    const name: string = index >= 0 && index < this.qualityVariants.length
      ? this.qualityVariants[index].name : '';
    const position: number = this.player.state.position;
    this.qualityPreference = name;
    if (position > 0) {
      this.pendingResumeSec = position;
    }
    this.loadEpisode(this.index);
  }

  /**
   * 预热下一集心跳（fqapp _updateWarmNext，1s 心跳驱动）：
   * 剩 FQ_WARM_LEAD_SEC 秒时预取下一集流地址，切集免等取流。
   * 加载中/已预热/取流中不重复；离线缓存集不预热（本地秒开无需预热）。
   */
  private warmNextTick(): void {
    if (this.loading || this.warmInFlight || this.warmSource !== null || !this.player.state.playing) {
      return;
    }
    const next: FqChapter | undefined = this.episodes[this.index + 1];
    if (next === undefined || FqDramaCacheStore.has(next.itemId)) {
      return;
    }
    const duration: number = this.player.state.duration;
    const remain: number = duration - this.player.state.position;
    if (duration <= 0 || remain > FQ_WARM_LEAD_SEC) {
      return;
    }
    this.warmNextEpisode(next);
  }

  /** 预取下一集流（fqapp _updateWarmNext 取流段）：完成后仅当仍是邻集才存，失败静默。 */
  private async warmNextEpisode(episode: FqChapter): Promise<void> {
    const itemId: string = episode.itemId;
    const quality: string = this.qualityPreference;
    this.warmInFlight = true;
    try {
      await FqBackend.get().start(getContext(this));
      const source: FqEpisodeSource =
        await FqBackend.get().episodeSource(itemId, this.tab, quality);
      const current: FqChapter | undefined = this.episodes[this.index + 1];
      if (current !== undefined && current.itemId === itemId && this.qualityPreference === quality) {
        this.warmItemId = itemId;
        this.warmQuality = quality;
        this.warmSource = source;
      }
    } catch (error) {
      // 预热失败静默：切集时走常规取流
    } finally {
      this.warmInFlight = false;
    }
  }

  /** 领取预热流（fqapp _takeWarm）：itemId 且画质偏好一致才命中；否则作废返回 null。 */
  private takeWarmSource(itemId: string): FqEpisodeSource | null {
    const warm: FqEpisodeSource | null = this.warmSource;
    if (warm !== null && this.warmItemId === itemId && this.warmQuality === this.qualityPreference) {
      this.warmSource = null;
      return warm;
    }
    this.dropWarmSource();
    return null;
  }

  /** 丢弃预热（fqapp _dropWarm）。 */
  private dropWarmSource(): void {
    this.warmSource = null;
    this.warmItemId = '';
    this.warmQuality = '';
  }

  /** 关闭剧评半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
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
    this.settingsPage = '';
    const token: number = ++this.settingsCloseToken;
    setTimeout((): void => {
      if (token === this.settingsCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.settingsVisible = false;
        });
        this.resumeFsAutoHide();
      }
    }, 0);
  }

  /** 画面单击：锁定态只唤出锁按钮（官方 G6）；全屏切控件显隐，非全屏切播放。 */
  private onVideoTap(): void {
    // FqMenu 关闭点击穿透守卫：全屏档位菜单打开期间画面单击不切控件显隐
    if (this.fsMenuOpen) {
      return;
    }
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

  /**
   * 浮层（档位菜单/半模态/侧边栏等）关闭后恢复全屏控件显隐与空闲自动隐藏：
   * 亮出控制条，播放态重新计 3s（暂停态常驻不计时）。
   */
  private resumeFsAutoHide(): void {
    if (!this.fullScreen) {
      return;
    }
    this.fsControlsVisible = true;
    this.scheduleFsHide();
  }

  /**
   * 全屏顶/底控制条触摸：按下暂停自动隐藏，抬起/移出/取消恢复计时
   * （控制条本身的操作不触发自动隐藏，仅空闲超时隐藏）。
   */
  private onFsBarTouch(event: TouchEvent): void {
    if (!this.fullScreen) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.cancelFsHide();
    } else if (event.type === TouchType.Up || event.type === TouchType.Move ||
      event.type === TouchType.Cancel) {
      this.scheduleFsHide();
    }
  }

  /** 进入全屏沉浸：横屏片源锁横屏并隐藏系统栏（官方 _enterFullscreen）。 */
  private enterFullscreen(): void {
    this.fullScreen = true;
    this.fsControlsVisible = true;
    this.scheduleFsHide();
    this.applyImmersive(true);
  }

  /** 退出全屏沉浸：恢复方向与系统栏；离开横屏解除防误触锁（官方 _releaseLock）。
   *  windowFormSettled：窗口形态已被系统接管（PC 全屏中按 ESC 系统窗口化等），
   *  跳过 maximize/recover 还原，仅恢复应用内状态与系统栏。 */
  private exitFullscreen(windowFormSettled: boolean = false): void {
    this.fullScreen = false;
    this.fsLocked = false;
    this.lockVisible = false;
    this.cancelFsHide();
    this.cancelLockHide();
    this.fsControlsVisible = true;
    this.applyImmersive(false, windowFormSettled);
  }

  /** 沉浸全屏：进入隐藏系统栏（横屏片源同时锁 AUTO_ROTATION_LANDSCAPE），退出恢复。
   *  PC 侧边栏布局额外接管窗口：进入 maximize(ENTER_IMMERSIVE) 沉浸全屏（隐藏系统标题栏/Dock，
   *  PcMainLayout 同步隐藏应用内标题栏与侧边栏）；退出按进入前窗口状态还原
   *  （最大化 → maximize(EXIT_IMMERSIVE)，自由窗口 → recover() 恢复原尺寸位置）；
   *  windowFormSettled 为 true 时窗口形态已被系统接管（ESC 系统窗口化），跳过还原。 */
  private applyImmersive(enter: boolean, windowFormSettled: boolean = false): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      const pcLayout: boolean = useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp);
      if (enter) {
        if (pcLayout) {
          const status: window.WindowStatusType = win.getWindowStatus();
          this.pcFullscreenWasMaximized = status === window.WindowStatusType.MAXIMIZE;
          this.pcFullscreenWasFullscreen = status === window.WindowStatusType.FULL_SCREEN;
          appState.pcImmersiveFullscreen = true;
          win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE).catch((): void => {
            // 窗口沉浸全屏失败保持原窗口形态，仅应用内隐藏标题栏/侧边栏
          });
        }
        if (this.isLandscapeVideo()) {
          win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        }
        win.setWindowSystemBarEnable([]);
      } else {
        if (pcLayout) {
          appState.pcImmersiveFullscreen = false;
          if (windowFormSettled) {
            // 窗口形态已被系统接管（ESC 系统窗口化等）：保持用户所选形态，不 maximize/recover
          } else if (this.pcFullscreenWasFullscreen) {
            // 进入前已是沉浸全屏：保持全屏形态，仅恢复应用内标题栏/侧边栏
          } else if (this.pcFullscreenWasMaximized) {
            win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE).catch((): void => {
              // 还原失败保持现状，窗口形态由用户手动调整
            });
          } else {
            win.recover().catch((): void => {
              // 还原失败保持现状，窗口形态由用户手动调整
            });
          }
        }
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
    fqPushBookOrDetail(book.id, 'book', book.title, book.cover);
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
    // 预热作废（fqapp _dropWarm）：切到非预热目标集即丢弃，避免旧预热占位挡住新邻集预热
    if (episode.itemId !== this.warmItemId) {
      this.dropWarmSource();
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
    // 选集/切集立即停掉旧集播放（旧集声音即刻消失），不等新集取流完成
    this.player.stop();
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
    // 切集且剧评面板开着：bump 打开令牌让面板重置重载（顺带刷新最新评论）
    if (switched && this.commentSheetVisible) {
      this.commentOpenToken += 1;
    }
    try {
      let playUrl: string = '';
      // 清晰度档重置（离线缓存/取流失败回退均按默认流处理）
      this.qualityVariants = [];
      this.qualityIndex = -1;
      // 离线缓存命中：直接播本地文件，跳过在线取流（无网也可看已缓存集）
      if (FqDramaCacheStore.has(episode.itemId)) {
        playUrl = FqDramaCacheStore.filePath(episode.itemId);
      } else {
        await FqBackend.get().start(getContext(this));
        this.resolveCover();
        // 预热命中（fqapp _takeWarm）：免取流直接用预取地址
        let source: FqEpisodeSource | null = this.takeWarmSource(episode.itemId);
        if (source === null) {
          // quality 携带用户选定档：后端命中 variants 档时按该档取流，
          // 并以 quality 回显实际起播档（未命中为空 → 默认）
          source = await FqBackend.get().episodeSource(episode.itemId, this.tab, this.qualityPreference);
        }
        playUrl = source.url;
        this.qualityVariants = source.variants;
        if (source.quality.length > 0) {
          for (let i: number = 0; i < source.variants.length; i++) {
            if (source.variants[i].name === source.quality) {
              this.qualityIndex = i;
              break;
            }
          }
        }
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

  /** surface 挂载回调（PlayerConfig.onReady）：标记就绪并补播暂存的起播媒体。 */
  private onPlayerSurfaceReady(): void {
    this.surfaceReady = true;
    const pending: Media | null = this.pendingOpenMedia;
    if (pending !== null) {
      this.pendingOpenMedia = null;
      this.player.open(pending);
      this.loading = false;
    }
  }

  /**
   * 起播公共尾段（在线取流 / 离线缓存命中 / 取流失败回退缓存共用）：
   * 关听书、mpv open（含续播 start 偏移）、AVSession/后台任务、
   * 续播记录重置与弹幕整池作废。
   */
  private startEpisodePlayback(episode: FqChapter, url: string, startSec: number,
    wasDisplayed: boolean, switched: boolean, keepListenProgress: boolean): void {
    // surface 未就绪：暂存 Media 延到 onReady 回调补播（loading 保持 true 盖住空窗）；
    // 就绪则立即起播并关 loading
    if (this.surfaceReady) {
      this.loading = false;
      this.player.open(startSec > 0
        ? new Media(url, { start: startSec })
        : new Media(url));
    } else {
      this.pendingOpenMedia = startSec > 0
        ? new Media(url, { start: startSec })
        : new Media(url);
    }
    // 播放视频即停止听书（fqAudioSession 完整关闭链路：进度持久化、
    // 引擎释放、后台任务停止、AVSession 销毁、播控球消失）
    if (fqAudioSession.hasSession) {
      fqAudioSession.close();
    }
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
      this.progress = new FqWatchedProgress(episode.itemId, 0, 0, this.seriesPercent(0));
      FqWatchedStore.saveProgress(PlayerNavParams.contentId, this.progress);
    }
    // 弹幕整池作废（切集），按 0 起取新集首批
    this.resetDanmaku();
    // 边看边往后缓存：起播延时 2s 排后面 N 集（同集去重，切集作废旧定时器）
    this.scheduleAutoCache();
  }

  /**
   * 边看边往后缓存（fqapp _scheduleAutoCache 同款）：这一集起播后延时 2s 把
   * 后面 ahead 集排进离线下载队列（仅 Wi-Fi、只保留最近一段），断网也能接着看。
   * 同一集起播/换流/重试只排一次；切集/离页（loadToken 变化）后旧定时器作废。
   */
  private scheduleAutoCache(): void {
    if (FqAppSettingsStore.getDramaAutoCacheAhead() <= 0) {
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG, 'schedule skip: ahead=0 (off)');
      return;
    }
    if (this.autoCacheFor === this.index) {
      return;
    }
    if (this.autoCacheTimer !== 0 && this.autoCacheTimerIndex === this.index) {
      return;
    }
    if (this.autoCacheTimer !== 0) {
      clearTimeout(this.autoCacheTimer);
    }
    const token: number = this.loadToken;
    const index: number = this.index;
    this.autoCacheTimerIndex = index;
    this.autoCacheTimer = setTimeout((): void => {
      this.autoCacheTimer = 0;
      this.autoCacheTimerIndex = -1;
      // 切集/离页后旧定时器作废（fqapp 用播放器实例判活，这里用加载令牌等价）
      if (token !== this.loadToken) {
        hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
          `timer stale: token ${token} != ${this.loadToken}`);
        return;
      }
      this.autoCacheNext();
    }, FQ_AUTO_CACHE_DELAY_MS);
    hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
      `scheduled index=${index} token=${token} in ${FQ_AUTO_CACHE_DELAY_MS}ms`);
  }

  /**
   * 排后面 ahead 集自动缓存（fqapp autoCacheEpisodes 范围：index+1 .. index+ahead）。
   * 仅 Wi-Fi：测不出网络形态按「不是 Wi-Fi」处理——自动缓存没有流量确认兜底；
   * 排上了才算这一集处理过，早退不算，否则该集永远没机会再自动缓存。
   */
  private async autoCacheNext(): Promise<void> {
    const index: number = this.index;
    const ahead: number = FqAppSettingsStore.getDramaAutoCacheAhead();
    if (ahead <= 0) {
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG, 'next skip: ahead=0 (off)');
      return;
    }
    const start: number = index + 1;
    if (start <= 0 || start >= this.episodes.length) {
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
        `next skip: no upcoming (index=${index}, eps=${this.episodes.length})`);
      return;
    }
    if (FqAppSettingsStore.isDramaAutoCacheWifiOnly() && !(await this.isUnmeteredOnline())) {
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG, 'next skip: wifi-only gate blocked');
      return;
    }
    const end: number = Math.min(start + ahead, this.episodes.length);
    let enqueued: number = 0;
    for (let i: number = start; i < end; i++) {
      const episode: FqChapter | undefined = this.episodes[i];
      if (episode !== undefined) {
        this.dl.enqueue(PlayerNavParams.contentId, episode.itemId, episode.title,
          this.title, PlayerNavParams.cover, PlayerNavParams.kind, i + 1, true);
        enqueued++;
      }
    }
    hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
      `enqueued ${enqueued} auto episodes (index=${index}, ahead=${ahead})`);
    this.autoCacheFor = index;
    this.trimAutoCache(ahead);
  }

  /** 当前默认网络是否 Wi-Fi / 以太网承载（fqapp foldConnectivity 同款判据：
   *  按承载类型判定而非系统 metered 标志——部分设备把 Wi-Fi 网络标为计量，
   *  用 metered 标志会误拦自动缓存；探测失败按计量网络处理，fail-closed）。 */
  private async isUnmeteredOnline(): Promise<boolean> {
    try {
      const hasNet: boolean = await connection.hasDefaultNet();
      if (!hasNet) {
        hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG, 'net probe: no default net');
        return false;
      }
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(netHandle);
      let unmetered: boolean = false;
      const bearers: string[] = [];
      for (const bearer of caps.bearerTypes) {
        bearers.push(`${bearer}`);
        if (bearer === connection.NetBearType.BEARER_WIFI
          || bearer === connection.NetBearType.BEARER_ETHERNET) {
          unmetered = true;
        }
      }
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
        `net probe: bearers=${bearers.join('|')}, unmetered=${unmetered}`);
      return unmetered;
    } catch (error) {
      hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG, 'net probe: exception, treated as metered');
      return false;
    }
  }

  /**
   * 跟着播放进度丢掉自动缓存的旧集（fqapp _trimAutoCache）：只删 auto 记录，
   * 用户手动下的集一律不动；只留当前集之前 2×ahead 以后的。
   */
  private trimAutoCache(ahead: number): void {
    const cutoff: number = this.index - ahead * 2;
    if (cutoff <= 0) {
      return;
    }
    const doomed: string[] = [];
    for (const episode of FqDramaCacheStore.episodesOf(PlayerNavParams.contentId)) {
      if (episode.auto && episode.index - 1 < cutoff) {
        doomed.push(episode.itemId);
      }
    }
    for (const itemId of doomed) {
      FqDramaCacheStore.removeEpisode(itemId);
    }
    hilog.info(0x0001, FQ_AUTO_CACHE_LOG_TAG,
      `trim: cutoff=${cutoff}, removed=${doomed.length}`);
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
      this.player.state.position, this.player.state.duration,
      this.seriesPercent(this.episodeFraction()));
    FqWatchedStore.saveProgress(PlayerNavParams.contentId, this.progress);
  }

  /** 整剧百分比 0..100（书架角标）：(当前集下标 + 集内比例)/总集数；无效返回 -1。 */
  private seriesPercent(fraction: number): number {
    const total: number = this.episodes.length;
    if (total <= 0 || this.index < 0 || this.index >= total) {
      return -1;
    }
    const value: number = Math.round(((this.index + fraction) / total) * 100);
    return Math.min(100, Math.max(0, value));
  }

  /** 当前集内播放比例 0..1（时长未知 0）。 */
  private episodeFraction(): number {
    const duration: number = this.player.state.duration;
    if (duration <= 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.player.state.position / duration));
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

  /**
   * 视频区横滑快进/快退起始：记录起始播放位置并亮出中央时间浮层；
   * 锁定态只唤出锁按钮；半模态/侧边栏打开或未就绪（出错/无时长）时不响应。
   */
  private onSeekPanStart(event?: GestureEvent): void {
    if (this.fsLocked) {
      this.refreshLockVisibility();
      return;
    }
    if (this.errorMsg.length > 0 || this.player.state.duration <= 0 ||
      this.sheetVisible || this.settingsVisible || this.commentSheetVisible || this.sidePanel.length > 0) {
      return;
    }
    this.dragSeekFrom = this.player.state.position;
    this.seekPreview = this.dragSeekFrom;
  }

  /**
   * 横滑过程：offsetX 相对滑过屏宽的比例 × FQ_SEEK_FULL_SWIPE_SEC 得到偏移秒数，
   * 目标夹在 [0, 时长]；复用 seekPreview 驱动中央时间浮层与进度条预览（同拖动进度条）。
   */
  private onSeekPanUpdate(event?: GestureEvent): void {
    if (this.dragSeekFrom < 0 || event === undefined) {
      return;
    }
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const widthVp: number = displayData.width / density;
    const deltaSec: number = widthVp > 0 ? event.offsetX / widthVp * FQ_SEEK_FULL_SWIPE_SEC : 0;
    const duration: number = this.player.state.duration;
    let target: number = this.dragSeekFrom + deltaSec;
    if (target < 0) {
      target = 0;
    }
    if (duration > 0 && target > duration) {
      target = duration;
    }
    this.seekPreview = target;
  }

  /** 横滑结束/取消：松手落到目标位置（同步弹幕、续播进度与播放态，同 skipPosition）。 */
  private onSeekPanEnd(): void {
    if (this.dragSeekFrom < 0) {
      return;
    }
    const target: number = this.seekPreview;
    this.dragSeekFrom = -1;
    this.seekPreview = -1;
    if (target >= 0 && Math.abs(target - this.player.state.position) >= 0.5) {
      this.player.seek(target);
      this.seekDanmaku(target * 1000);
      this.saveCurrentProgress();
      this.syncMediaState(this.player.state.playing);
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

  /** 重建弹幕样式配置（设置实时生效，无需清在飞弹幕）。 */
  private applyDanmakuCfg(): void {
    this.danmakuCfg = new FqDanmakuViewConfig(this.danmakuFontSize(), this.danmakuAlphaPercent,
      FQ_DANMAKU_SPEED_MULTIPLIERS[this.danmakuSpeedTier - 1], this.danmakuBgTransparent);
  }

  /** 弹幕「显示区域」语义上下文：横屏片源全屏=单行/1/4屏/1/2屏/3/4屏；竖屏=1-4 行。 */
  private isLandscapeDanmaku(): boolean {
    return this.fullScreen && this.isLandscapeVideo();
  }

  /** 弹幕字号（fqapp 5 档 12-20sp，默认 16）。 */
  private danmakuFontSize(): number {
    const tier: number = Math.min(5, Math.max(1, this.danmakuSizeTier));
    return FQ_DANMAKU_TEXT_SIZES[tier - 1];
  }

  private setDanmakuAlpha(percent: number): void {
    this.danmakuAlphaPercent = Math.round(percent);
    FqAppSettingsStore.setDanmakuAlphaPercent(this.danmakuAlphaPercent);
    this.applyDanmakuCfg();
  }

  private setDanmakuSpeedTier(tier: number): void {
    this.danmakuSpeedTier = Math.min(5, Math.max(1, tier));
    FqAppSettingsStore.setDanmakuSpeedTier(this.danmakuSpeedTier);
    this.applyDanmakuCfg();
  }

  private setDanmakuLineCount(count: number): void {
    this.danmakuLineCount = Math.min(4, Math.max(1, count));
    FqAppSettingsStore.setDanmakuLineCount(this.danmakuLineCount);
  }

  private setDanmakuLineSpaceTier(tier: number): void {
    this.danmakuLineSpaceTier = Math.min(4, Math.max(1, tier));
    FqAppSettingsStore.setDanmakuLineSpaceTier(this.danmakuLineSpaceTier);
  }

  private setDanmakuSizeTier(tier: number): void {
    this.danmakuSizeTier = Math.min(5, Math.max(1, tier));
    FqAppSettingsStore.setDanmakuSizeTier(this.danmakuSizeTier);
    this.applyDanmakuCfg();
  }

  private setDanmakuBgTransparent(on: boolean): void {
    this.danmakuBgTransparent = on;
    FqAppSettingsStore.setDanmakuBgTransparent(on);
    this.applyDanmakuCfg();
  }

  /** 恢复默认弹幕设置（对齐 fqapp：落默认值 + Toast「设置成功」）。 */
  private resetDanmakuSettings(): void {
    FqAppSettingsStore.resetDanmakuSettings();
    this.danmakuAlphaPercent = FqAppSettingsStore.getDanmakuAlphaPercent();
    this.danmakuSpeedTier = FqAppSettingsStore.getDanmakuSpeedTier();
    this.danmakuLineCount = FqAppSettingsStore.getDanmakuLineCount();
    this.danmakuLineSpaceTier = FqAppSettingsStore.getDanmakuLineSpaceTier();
    this.danmakuSizeTier = FqAppSettingsStore.getDanmakuSizeTier();
    this.danmakuBgTransparent = FqAppSettingsStore.isDanmakuBgTransparent();
    this.applyDanmakuCfg();
    this.getUIContext().getPromptAction().showToast({ message: '设置成功', duration: 1200 });
  }

  /**
   * 弹幕层高（对齐 fqapp 显示区域档）：
   * 横屏全屏 = 档位屏高占比（单行=一条行高）；竖屏全屏 = 屏上 20%。
   */
  private danmakuLayerHeight(): Length {
    if (this.fullScreen && this.isLandscapeVideo()) {
      const laneH: number = this.danmakuFontSize() + 12;
      const tier: number = Math.min(4, Math.max(1, this.danmakuLineSpaceTier));
      if (tier === 1) {
        return laneH + 4;
      }
      const factor: number = FQ_DANMAKU_LINE_SPACE_FACTORS[tier - 1];
      return Math.max(laneH + 4, Math.round(this.pageH() * factor));
    }
    return '20%';
  }

  /** 弹幕最大车道（竖屏=设置行数 1-4；横屏=区域高度按行高折算，封顶 12）。 */
  private danmakuMaxLanes(): number {
    if (this.fullScreen && this.isLandscapeVideo()) {
      const laneH: number = this.danmakuFontSize() + 12;
      const heightVp: number = Number(this.danmakuLayerHeight());
      return Math.max(1, Math.min(12, Math.floor(heightVp / laneH)));
    }
    return this.danmakuLineCount;
  }

  /** 下一集（横屏控制条/自动连播共用）。 */
  private nextEpisode(): void {
    if (this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1);
    }
  }

  /**
   * 播完回调：实际播放过（hasDisplayed）才自动连播下一集。
   * mpv 打不开流同样触发 eof（加载失败）：未起播的 eof 出重试卡，
   * 不再黑屏半天后直接跳下一集；末集停在末帧。
   */
  private onEpisodeEnd(): void {
    // 取流中忽略（player.stop 后旧流残余事件；stop 本身不触发 eof）
    if (this.loading) {
      return;
    }
    if (!this.hasDisplayed) {
      this.loading = false;
      if (this.errorMsg.length === 0) {
        this.errorMsg = '视频加载失败，请重试';
      }
      return;
    }
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
    // PC 布局：选集点击呼出右侧详情侧边栏（收起则展开），定位到当前集，不开底部半模态
    if (this.pcSidebarOn()) {
      this.pcSidebarCollapsed = false;
      this.pcPanel = '';
      this.pcEpisodePage = Math.floor(this.index / FQ_CACHE_PAGE_SIZE);
      setTimeout((): void => {
        this.pcScroller.scrollToIndex(this.index, false, ScrollAlign.CENTER);
      }, 120);
      return;
    }
    // 横屏全屏走右侧边栏（少遮挡画面），其余走官方底部半模态
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.openSidePanel('episodes');
      return;
    }
    // 官方面板展开 200ms：视频区随面板撑满全屏（_positionVideo panelFraction）
    if (this.fullScreen) {
      // 全屏（竖屏片源）选集 sheet 打开期间暂停控件自动隐藏（关闭后恢复空闲计时）
      this.cancelFsHide();
    }
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sheetVisible = true;
    });
  }

  /** 横屏全屏右侧边栏打开：收控件、面板贴右滑入；选集滚到当前集竖直居中。 */
  private openSidePanel(kind: string): void {
    this.cancelFsHide();
    this.settingsPage = '';
    this.fsControlsVisible = false;
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sidePanel = kind;
    });
    if (kind === 'episodes' && this.episodes.length > 0) {
      this.cancelSideLocate();
      this.sideEpisodePage = Math.floor(this.index / FQ_CACHE_PAGE_SIZE);
      this.sideLocateTimer = setTimeout((): void => {
        this.sideLocateTimer = 0;
        this.sideScroller.scrollToIndex(this.index, false, ScrollAlign.CENTER);
      }, 120);
    }
  }

  /** 关闭横屏全屏右侧边栏：面板滑出，亮出全屏控件并重新计自动隐藏。 */
  private closeSidePanel(): void {
    this.cancelSideLocate();
    this.settingsPage = '';
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
        this.resumeFsAutoHide();
      }
    }, 0);
  }
}

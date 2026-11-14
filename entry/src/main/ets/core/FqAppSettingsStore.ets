/**
 * 应用设置持久化（设置页：深色模式 + 后台播放保活）。
 *
 * preferences 独立存储（fq_app_settings）：
 * - themeMode：0 跟随系统 / 1 浅色 / 2 深色（ApplicationContext.setColorMode 即时应用，
 *   EntryAbility onCreate 初始化时恢复）；
 * - themeColor：主题色 key（'' 跟随系统 / orange / gold / green / teal / blue / violet /
 *   pink / red / custom 自定义；预设默认 orange 番茄橙；预设色定义于资源 base/dark
 *   element/color.json 深浅自适应，appState.accentColor 全局引用，切换即时刷新；
 *   custom = 任意 hex 固定色，不随深浅切换）；
 * - themeCustomColor：自定义主题色 hex（themeColor=custom 时生效；经三方 HSB 取色器取色，
 *   默认番茄橙 #FF7A3D；themeColor=custom 时 appState.accentColor 即该值）；
 * - backgroundAudio：后台播放开关（开=支持后台播放：创建 AVSession（ENABLE_BACKGROUND_PLAY）
 *   + 申请 audioPlayback 长时任务；关=无法后台播放：不创建/销毁 AVSession（无胶囊/播控中心
 *   通知）+ 不申请/停掉长时任务，后台播放被系统停止）；
 * - pipVideo：画中画开关（开=视频播放页前台创建画中画控制器并开退后台自动小窗拉起；
 *   FqVideoMedia 后台门控按 后台播放或画中画任一开启 放行 AVSession/长时任务）；
 * - updateProxyDownload：更新包代理下载开关（关于页，仅用于下载更新软件包：
 *   开=经代理下载更新包，关=直连）；
 * - changelogShownVersion：更新日志已展示到的版本号（空 = 尚未记录，首次安装）；
 *   Index 冷启动比对当前版本号，不同则自动弹出更新日志 sheet；
 * - startupTabIndex：启动默认展示页（主 Tab 下标 0-3 = 首页/书架/我的/设置，默认 0 首页）；
 *   Index 冷启动按此初始化 HdsTabs/PC Tabs 与 appState.currTabsIndex；
 * - homeStyle：首页样式（0 今日焦点 / 1 排行榜立体书架 / 2 两者共存，默认 0 今日焦点）；
 *   首页按 appState.homeStyle 响应式切换顶部内容；
 * - mineSettingsStyle：我的、设置页面显示样式（0 我的含设置入口 / 1 设置含我的入口 /
 *   2 我的和设置单独显示，默认 2）：0 隐藏设置 Tab（我的页右上角设置按钮路由进设置），
 *   1 隐藏我的 Tab（设置页「用户」区入口路由进我的），2 保持双 Tab（我的页隐藏快捷入口）；
 * - chapterCacheLimitMb：章节自动缓存大小上限（MB，默认 80，1-102400 即 1MB-100GB；
 *   章节缓存页右上角调节，仅约束阅读自动缓存，整本下载 pin 在预算外不受限）；
 * - dramaAutoCacheAhead：剧集边看边往后缓存集数（对齐 fqapp DramaCachePreferences：
 *   默认 5，0 = 关，0-50；播放页缓存 sheet「边看边缓存」开关 + 3/5/10 档）；
 * - dramaAutoCacheWifiOnly：剧集自动缓存仅 Wi-Fi（默认开；计量网络不自动缓存，
 *   手动下载不受影响）；
 * - videoQualityPref：视频清晰度偏好档名（'' 跟随默认最高档 / 360P-4K 白名单；
 *   播放页清晰度菜单切换即写入，下次进页沿用；白名单见 FQ_VIDEO_QUALITY_PREF_WHITELIST）。
 */

import preferences from '@ohos.data.preferences';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../entryability/AppState';
import { fqThemeColorOf } from './FqThemeColors';

const FQ_APP_SETTINGS_NAME: string = 'fq_app_settings';
const FQ_SETTINGS_KEY_THEME: string = 'themeMode';
const FQ_SETTINGS_KEY_THEME_COLOR: string = 'themeColor';
const FQ_SETTINGS_KEY_THEME_CUSTOM_COLOR: string = 'themeCustomColor';
const FQ_SETTINGS_KEY_BG_AUDIO: string = 'backgroundAudio';
const FQ_SETTINGS_KEY_PIP_VIDEO: string = 'pipVideo';
const FQ_SETTINGS_KEY_DIRECT_READ: string = 'directRead';
const FQ_SETTINGS_KEY_UPDATE_PROXY: string = 'updateProxyDownload';
const FQ_SETTINGS_KEY_CHANGELOG_SHOWN: string = 'changelogShownVersion';
const FQ_SETTINGS_KEY_STARTUP_TAB: string = 'startupTabIndex';
const FQ_SETTINGS_KEY_HOME_STYLE: string = 'homeStyle';
const FQ_SETTINGS_KEY_MINE_SETTINGS_STYLE: string = 'mineSettingsStyle';
const FQ_SETTINGS_KEY_TTS_PERSON: string = 'ttsPerson';
const FQ_SETTINGS_KEY_TTS_RATE: string = 'ttsRate';
const FQ_SETTINGS_KEY_SMART_REACH: string = 'smartReach';
const FQ_SETTINGS_KEY_CHAPTER_CACHE_LIMIT: string = 'chapterCacheLimitMb';
const FQ_SETTINGS_KEY_DRAMA_AUTO_AHEAD: string = 'dramaAutoCacheAhead';
const FQ_SETTINGS_KEY_DRAMA_AUTO_WIFI: string = 'dramaAutoCacheWifiOnly';
const FQ_SETTINGS_KEY_LAN_SHARE: string = 'apiLanShare';
const FQ_SETTINGS_KEY_DANMAKU_ALPHA: string = 'danmakuAlphaPercent';
const FQ_SETTINGS_KEY_DANMAKU_SPEED: string = 'danmakuSpeedTier';
const FQ_SETTINGS_KEY_DANMAKU_LINE_COUNT: string = 'danmakuLineCount';
const FQ_SETTINGS_KEY_DANMAKU_LINE_SPACE: string = 'danmakuLineSpaceTier';
const FQ_SETTINGS_KEY_DANMAKU_SIZE: string = 'danmakuSizeTier';
const FQ_SETTINGS_KEY_DANMAKU_BG_TRANSPARENT: string = 'danmakuBgTransparent';
const FQ_SETTINGS_KEY_VIDEO_HWDEC: string = 'videoHwdec';
const FQ_SETTINGS_KEY_VIDEO_QUALITY_PREF: string = 'videoQualityPref';

/** 章节自动缓存大小上限默认值（MB）。 */
export const FQ_CHAPTER_CACHE_LIMIT_DEFAULT_MB: number = 80;
/** 章节自动缓存大小上限最小值（MB）。 */
export const FQ_CHAPTER_CACHE_LIMIT_MIN_MB: number = 1;
/** 章节自动缓存大小上限最大值（MB，100GB）。 */
export const FQ_CHAPTER_CACHE_LIMIT_MAX_MB: number = 102400;
/** 剧集边看边往后缓存默认集数（0 = 关；对齐 fqapp DramaCachePreferences.defaultAhead）。 */
export const FQ_DRAMA_AUTO_CACHE_AHEAD_DEFAULT: number = 5;
/** 剧集边看边往后缓存集数上限（对齐 fqapp clamp(0, 50)）。 */
export const FQ_DRAMA_AUTO_CACHE_AHEAD_MAX: number = 50;
/** 边看边往后缓存可选档位（fqapp presetAheads 除 0 = 关）。 */
export const FQ_DRAMA_AUTO_CACHE_AHEAD_PRESETS: number[] = [3, 5, 10];
/** 弹幕速度档位倍率（fqapp DanmakuSettings.speedMultipliers：慢..快 5 档，默认 3 = 适中 1.0）。 */
export const FQ_DANMAKU_SPEED_MULTIPLIERS: number[] = [0.5, 0.7, 1.0, 1.25, 1.5];
/** 弹幕速度档位文案。 */
export const FQ_DANMAKU_SPEED_LABELS: string[] = ['慢', '较慢', '适中', '较快', '快'];
/** 弹幕字号档位（sp；fqapp DanmakuSettings.textSizes 5 档，默认 3 = 16sp）。 */
export const FQ_DANMAKU_TEXT_SIZES: number[] = [12, 14, 16, 18, 20];
/** 弹幕字号档位文案。 */
export const FQ_DANMAKU_SIZE_LABELS: string[] = ['小', '较小', '适中', '较大', '大'];
/** 横屏弹幕显示区域档位屏高占比（fqapp DanmakuSettings.lineSpaceFactors：单行/1/4屏/1/2屏/3/4屏，默认 2 = 1/4屏）。 */
export const FQ_DANMAKU_LINE_SPACE_FACTORS: number[] = [1.0, 0.25, 0.5, 0.75];
/** 横屏弹幕显示区域档位文案。 */
export const FQ_DANMAKU_LINE_SPACE_LABELS: string[] = ['单行', '1/4屏', '1/2屏', '3/4屏'];
/** 弹幕不透明度下限（%；fqapp 面板 20%..100%）。 */
export const FQ_DANMAKU_ALPHA_MIN_PERCENT: number = 20;
/** 弹幕不透明度上限（%）。 */
export const FQ_DANMAKU_ALPHA_MAX_PERCENT: number = 100;
/**
 * 视频清晰度偏好档名白名单（'' = 跟随默认最高可用档）。
 * 与后端档名映射一致（短边像素映射 360P~4K）；decode 校验与 store 钳制共用。
 */
export const FQ_VIDEO_QUALITY_PREF_WHITELIST: string[] =
  ['', '360P', '480P', '540P', '720P', '1080P', '2K', '4K'];

/** 深色模式档位：跟随系统。 */
export const FQ_THEME_FOLLOW: number = 0;
/** 深色模式档位：浅色。 */
export const FQ_THEME_LIGHT: number = 1;
/** 深色模式档位：深色。 */
export const FQ_THEME_DARK: number = 2;
/** 启动默认展示页 Tab 下标上限（主 Tab 共 4 页：首页/书架/我的/设置）。 */
export const FQ_STARTUP_TAB_MAX_INDEX: number = 3;
/** 首页样式：今日焦点（默认）。 */
export const FQ_HOME_STYLE_SPOTLIGHT: number = 0;
/** 首页样式：排行榜立体书架。 */
export const FQ_HOME_STYLE_RANK: number = 1;
/** 首页样式：今日焦点和排行榜共存。 */
export const FQ_HOME_STYLE_BOTH: number = 2;
/** 首页样式档位上限。 */
export const FQ_HOME_STYLE_MAX: number = 2;
/** 我的、设置页面显示样式：我的含设置入口（隐藏设置 Tab）。 */
export const FQ_MINE_STYLE_MINE_WITH_SETTINGS: number = 0;
/** 我的、设置页面显示样式：设置含我的入口（隐藏我的 Tab）。 */
export const FQ_MINE_STYLE_SETTINGS_WITH_MINE: number = 1;
/** 我的、设置页面显示样式：我的和设置单独显示（默认，双 Tab 保留）。 */
export const FQ_MINE_STYLE_SEPARATE: number = 2;
/** 我的、设置页面显示样式档位上限。 */
export const FQ_MINE_STYLE_MAX: number = 2;

export class FqAppSettingsStore {
  private static pref: preferences.Preferences | null = null;
  private static context: common.Context | null = null;
  private static themeMode: number = FQ_THEME_FOLLOW;
  private static themeColor: string = 'orange';
  /** 自定义主题色 hex（themeColor=custom 时的 accentColor 值；默认番茄橙）。 */
  private static themeCustomColor: string = '#FF7A3D';
  private static backgroundAudio: boolean = true;
  /** 画中画开关（视频退后台自动小窗续播）。 */
  private static pipVideo: boolean = false;
  private static directRead: boolean = false;
  private static updateProxyDownload: boolean = false;
  private static changelogShownVersion: string = '';
  /** 启动默认展示页（主 Tab 下标 0-3；Index 冷启动初始化 Tab 用）。 */
  private static startupTabIndex: number = 0;
  /** 首页样式（0 今日焦点 / 1 排行榜 / 2 共存；appState.homeStyle 响应式联动）。 */
  private static homeStyle: number = FQ_HOME_STYLE_SPOTLIGHT;
  /** 我的、设置页面显示样式（0 我的含设置入口 / 1 设置含我的入口 / 2 单独显示；appState 响应式联动）。 */
  private static mineSettingsStyle: number = FQ_MINE_STYLE_SEPARATE;
  /** 离线朗读音色（textToSpeech person；0 默认女声聆小珊）。 */
  private static ttsPerson: number = 0;
  /** 离线朗读语速（0.5 ~ 2）。 */
  private static ttsRate: number = 1;
  /** 智感握姿开关。 */
  private static smartReach: boolean = false;
  /** 局域网共享开关（本地接口对局域网开放，对齐 fqapp LanSharePreferences）。 */
  private static apiLanShare: boolean = false;
  /** 章节自动缓存大小上限（MB）。 */
  private static chapterCacheLimitMb: number = FQ_CHAPTER_CACHE_LIMIT_DEFAULT_MB;
  /** 剧集边看边往后缓存集数（0 = 关；播放中自动续存后面 N 集，仅 Wi-Fi）。 */
  private static dramaAutoCacheAhead: number = FQ_DRAMA_AUTO_CACHE_AHEAD_DEFAULT;
  /** 剧集自动缓存仅 Wi-Fi（计量网络不自动缓存；手动下载不受影响）。 */
  private static dramaAutoCacheWifiOnly: boolean = true;
  /** 弹幕不透明度（%，20-100；fqapp key_alpha 默认 255 即 100%）。 */
  private static danmakuAlphaPercent: number = FQ_DANMAKU_ALPHA_MAX_PERCENT;
  /** 弹幕速度档位（1-5，默认 3 适中）。 */
  private static danmakuSpeedTier: number = 3;
  /** 竖屏弹幕行数（1-4，fqapp key_line_count 默认 4）。 */
  private static danmakuLineCount: number = 4;
  /** 横屏弹幕显示区域档位（1-4，fqapp key_line_space 默认 2 = 1/4屏）。 */
  private static danmakuLineSpaceTier: number = 2;
  /** 弹幕字号档位（1-5，fqapp key_text_size 默认 3 = 16sp）。 */
  private static danmakuSizeTier: number = 3;
  /** 弹幕背景透明（不画 40% 黑底气泡，只留文字与阴影；官方气泡底色写死，此为本地开关）。 */
  private static danmakuBgTransparent: boolean = false;
  /** 视频解码方式（true 硬解 ohcodec / false 软解 FFmpeg；播放页即时切换）。 */
  private static videoHwdec: boolean = true;
  /** 视频清晰度偏好档名（'' = 跟随默认最高可用档；白名单外值回退 ''）。 */
  private static videoQualityPref: string = '';

  public static init(context: common.Context): void {
    if (FqAppSettingsStore.pref !== null) {
      return;
    }
    FqAppSettingsStore.context = context;
    try {
      FqAppSettingsStore.pref =
        preferences.getPreferencesSync(context, { name: FQ_APP_SETTINGS_NAME });
    } catch (error) {
      FqAppSettingsStore.pref = null;
      return;
    }
    const pref: preferences.Preferences = FqAppSettingsStore.pref;
    try {
      const rawTheme: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_THEME, FQ_THEME_FOLLOW);
      if (typeof rawTheme === 'number') {
        FqAppSettingsStore.themeMode = rawTheme;
      }
      const rawThemeColor: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_THEME_COLOR, 'orange');
      if (typeof rawThemeColor === 'string') {
        FqAppSettingsStore.themeColor = rawThemeColor;
      }
      const rawCustomColor: preferences.ValueType =
        pref.getSync(FQ_SETTINGS_KEY_THEME_CUSTOM_COLOR, '#FF7A3D');
      if (typeof rawCustomColor === 'string') {
        FqAppSettingsStore.themeCustomColor = rawCustomColor;
      }
      const rawBg: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_BG_AUDIO, true);
      if (typeof rawBg === 'boolean') {
        FqAppSettingsStore.backgroundAudio = rawBg;
      }
      const rawPip: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_PIP_VIDEO, false);
      if (typeof rawPip === 'boolean') {
        FqAppSettingsStore.pipVideo = rawPip;
      }
      const rawDirectRead: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DIRECT_READ, false);
      if (typeof rawDirectRead === 'boolean') {
        FqAppSettingsStore.directRead = rawDirectRead;
      }
      const rawProxy: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_UPDATE_PROXY, false);
      if (typeof rawProxy === 'boolean') {
        FqAppSettingsStore.updateProxyDownload = rawProxy;
      }
      const rawShown: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_CHANGELOG_SHOWN, '');
      if (typeof rawShown === 'string') {
        FqAppSettingsStore.changelogShownVersion = rawShown;
      }
      const rawStartupTab: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_STARTUP_TAB, 0);
      if (typeof rawStartupTab === 'number' && rawStartupTab >= 0
        && rawStartupTab <= FQ_STARTUP_TAB_MAX_INDEX) {
        FqAppSettingsStore.startupTabIndex = Math.round(rawStartupTab);
      }
      const rawHomeStyle: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_HOME_STYLE,
        FQ_HOME_STYLE_SPOTLIGHT);
      if (typeof rawHomeStyle === 'number' && rawHomeStyle >= FQ_HOME_STYLE_SPOTLIGHT
        && rawHomeStyle <= FQ_HOME_STYLE_MAX) {
        FqAppSettingsStore.homeStyle = Math.round(rawHomeStyle);
      }
      const rawMineSettingsStyle: preferences.ValueType =
        pref.getSync(FQ_SETTINGS_KEY_MINE_SETTINGS_STYLE, FQ_MINE_STYLE_SEPARATE);
      if (typeof rawMineSettingsStyle === 'number' && rawMineSettingsStyle >= FQ_MINE_STYLE_MINE_WITH_SETTINGS
        && rawMineSettingsStyle <= FQ_MINE_STYLE_MAX) {
        FqAppSettingsStore.mineSettingsStyle = Math.round(rawMineSettingsStyle);
      }
      const rawTtsPerson: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_TTS_PERSON, 0);
      if (typeof rawTtsPerson === 'number' && rawTtsPerson >= 0) {
        FqAppSettingsStore.ttsPerson = rawTtsPerson;
      }
      const rawTtsRate: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_TTS_RATE, 1);
      if (typeof rawTtsRate === 'number' && rawTtsRate >= 0.5 && rawTtsRate <= 2) {
        FqAppSettingsStore.ttsRate = rawTtsRate;
      }
      const rawSmartReach: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_SMART_REACH, false);
      if (typeof rawSmartReach === 'boolean') {
        FqAppSettingsStore.smartReach = rawSmartReach;
      }
      const rawLanShare: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_LAN_SHARE, false);
      if (typeof rawLanShare === 'boolean') {
        FqAppSettingsStore.apiLanShare = rawLanShare;
      }
      const rawCacheLimit: preferences.ValueType =
        pref.getSync(FQ_SETTINGS_KEY_CHAPTER_CACHE_LIMIT, FQ_CHAPTER_CACHE_LIMIT_DEFAULT_MB);
      if (typeof rawCacheLimit === 'number' && rawCacheLimit >= FQ_CHAPTER_CACHE_LIMIT_MIN_MB
        && rawCacheLimit <= FQ_CHAPTER_CACHE_LIMIT_MAX_MB) {
        FqAppSettingsStore.chapterCacheLimitMb = rawCacheLimit;
      }
      const rawDramaAhead: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DRAMA_AUTO_AHEAD,
        FQ_DRAMA_AUTO_CACHE_AHEAD_DEFAULT);
      if (typeof rawDramaAhead === 'number' && rawDramaAhead >= 0
        && rawDramaAhead <= FQ_DRAMA_AUTO_CACHE_AHEAD_MAX) {
        FqAppSettingsStore.dramaAutoCacheAhead = Math.round(rawDramaAhead);
      }
      const rawDramaWifi: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DRAMA_AUTO_WIFI, true);
      if (typeof rawDramaWifi === 'boolean') {
        FqAppSettingsStore.dramaAutoCacheWifiOnly = rawDramaWifi;
      }
      const rawDmAlpha: preferences.ValueType =
        pref.getSync(FQ_SETTINGS_KEY_DANMAKU_ALPHA, FQ_DANMAKU_ALPHA_MAX_PERCENT);
      if (typeof rawDmAlpha === 'number' && rawDmAlpha >= FQ_DANMAKU_ALPHA_MIN_PERCENT
        && rawDmAlpha <= FQ_DANMAKU_ALPHA_MAX_PERCENT) {
        FqAppSettingsStore.danmakuAlphaPercent = Math.round(rawDmAlpha);
      }
      const rawDmSpeed: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DANMAKU_SPEED, 3);
      if (typeof rawDmSpeed === 'number' && rawDmSpeed >= 1 && rawDmSpeed <= 5) {
        FqAppSettingsStore.danmakuSpeedTier = Math.round(rawDmSpeed);
      }
      const rawDmLines: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DANMAKU_LINE_COUNT, 4);
      if (typeof rawDmLines === 'number' && rawDmLines >= 1 && rawDmLines <= 4) {
        FqAppSettingsStore.danmakuLineCount = Math.round(rawDmLines);
      }
      const rawDmSpace: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DANMAKU_LINE_SPACE, 2);
      if (typeof rawDmSpace === 'number' && rawDmSpace >= 1 && rawDmSpace <= 4) {
        FqAppSettingsStore.danmakuLineSpaceTier = Math.round(rawDmSpace);
      }
      const rawDmSize: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DANMAKU_SIZE, 3);
      if (typeof rawDmSize === 'number' && rawDmSize >= 1 && rawDmSize <= 5) {
        FqAppSettingsStore.danmakuSizeTier = Math.round(rawDmSize);
      }
      const rawDmBg: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_DANMAKU_BG_TRANSPARENT, false);
      if (typeof rawDmBg === 'boolean') {
        FqAppSettingsStore.danmakuBgTransparent = rawDmBg;
      }
      const rawHwdec: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_VIDEO_HWDEC, true);
      if (typeof rawHwdec === 'boolean') {
        FqAppSettingsStore.videoHwdec = rawHwdec;
      }
      const rawQualityPref: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_VIDEO_QUALITY_PREF, '');
      if (typeof rawQualityPref === 'string'
        && FQ_VIDEO_QUALITY_PREF_WHITELIST.indexOf(rawQualityPref) >= 0) {
        FqAppSettingsStore.videoQualityPref = rawQualityPref;
      }
    } catch (error) {
      // 损坏数据按默认值处理
    }
    FqAppSettingsStore.applyTheme();
    FqAppSettingsStore.applyThemeColor();
    appState.directReadEnabled = FqAppSettingsStore.directRead;
    appState.smartReachEnabled = FqAppSettingsStore.smartReach;
    appState.homeStyle = FqAppSettingsStore.homeStyle;
    appState.mineSettingsStyle = FqAppSettingsStore.mineSettingsStyle;
  }

  /** 当前深色模式档位（0 跟随系统 / 1 浅色 / 2 深色）。 */
  public static getThemeMode(): number {
    return FqAppSettingsStore.themeMode;
  }

  /** 切换深色模式：持久化 + ApplicationContext.setColorMode 即时应用。 */
  public static setThemeMode(mode: number): void {
    FqAppSettingsStore.themeMode = mode;
    FqAppSettingsStore.applyTheme();
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_THEME, mode);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 当前主题色 key（'' = 跟随系统强调色；'custom' = 自定义颜色）。 */
  public static getThemeColor(): string {
    return FqAppSettingsStore.themeColor;
  }

  /** 当前自定义主题色 hex（themeColor='custom' 时作为 accentColor）。 */
  public static getThemeCustomColor(): string {
    return FqAppSettingsStore.themeCustomColor;
  }

  /** 设置自定义主题色：持久化；若当前主题色即 custom 则 accentColor 即时刷新。 */
  public static setThemeCustomColor(hex: string): void {
    FqAppSettingsStore.themeCustomColor = hex;
    if (FqAppSettingsStore.themeColor === 'custom') {
      FqAppSettingsStore.applyThemeColor();
    }
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_THEME_CUSTOM_COLOR, hex);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 切换主题色：持久化 + appState.accentColor 即时刷新（全局高亮色联动）。 */
  public static setThemeColor(key: string): void {
    FqAppSettingsStore.themeColor = key;
    FqAppSettingsStore.applyThemeColor();
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_THEME_COLOR, key);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 主题色写入全局状态（init 恢复与 setThemeColor 共用；custom 走自定义 hex）。 */
  private static applyThemeColor(): void {
    appState.themeColorKey = FqAppSettingsStore.themeColor;
    if (FqAppSettingsStore.themeColor === 'custom') {
      appState.accentColor = FqAppSettingsStore.themeCustomColor;
    } else {
      appState.accentColor = fqThemeColorOf(FqAppSettingsStore.themeColor);
    }
  }

  /** 后台播放开关（听书/看视频：开=支持后台播放，关=无法后台播放）。 */
  public static isBackgroundAudio(): boolean {
    return FqAppSettingsStore.backgroundAudio;
  }

  public static setBackgroundAudio(enabled: boolean): void {
    FqAppSettingsStore.backgroundAudio = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_BG_AUDIO, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 画中画开关（开=视频退后台自动小窗续播；需系统设置「智慧多窗→自动启动画中画」开启）。 */
  public static isPipVideoEnabled(): boolean {
    return FqAppSettingsStore.pipVideo;
  }

  public static setPipVideoEnabled(enabled: boolean): void {
    FqAppSettingsStore.pipVideo = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_PIP_VIDEO, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 点击书籍直接进入阅读开关（开=点小说/漫画跳过详情页直接开读，关=先进详情页）。 */
  public static isDirectRead(): boolean {
    return FqAppSettingsStore.directRead;
  }

  public static setDirectRead(enabled: boolean): void {
    FqAppSettingsStore.directRead = enabled;
    appState.directReadEnabled = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_DIRECT_READ, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 智感握姿开关（开=识别握持手，播控球与底部标签栏随握持侧适配）。 */
  public static isSmartReachEnabled(): boolean {
    return FqAppSettingsStore.smartReach;
  }

  /** 章节自动缓存大小上限（MB；仅约束阅读自动缓存，整本下载不受限）。 */
  public static getChapterCacheLimitMb(): number {
    return FqAppSettingsStore.chapterCacheLimitMb;
  }

  /** 设置章节自动缓存大小上限（MB，范围外静默忽略；页面负责随后触发预算收敛）。 */
  public static setChapterCacheLimitMb(limitMb: number): void {
    if (!Number.isFinite(limitMb) || limitMb < FQ_CHAPTER_CACHE_LIMIT_MIN_MB
      || limitMb > FQ_CHAPTER_CACHE_LIMIT_MAX_MB) {
      return;
    }
    FqAppSettingsStore.chapterCacheLimitMb = Math.round(limitMb);
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_CHAPTER_CACHE_LIMIT, FqAppSettingsStore.chapterCacheLimitMb);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  public static setSmartReachEnabled(enabled: boolean): void {
    FqAppSettingsStore.smartReach = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_SMART_REACH, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 更新包代理下载开关（仅用于下载更新软件包：开=代理，关=直连）。 */
  public static isUpdateProxyDownload(): boolean {
    return FqAppSettingsStore.updateProxyDownload;
  }

  public static setUpdateProxyDownload(enabled: boolean): void {
    FqAppSettingsStore.updateProxyDownload = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_UPDATE_PROXY, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 更新日志已展示到的版本号（空 = 尚未记录，首次安装）。 */
  public static getChangelogShownVersion(): string {
    return FqAppSettingsStore.changelogShownVersion;
  }

  public static setChangelogShownVersion(version: string): void {
    FqAppSettingsStore.changelogShownVersion = version;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_CHANGELOG_SHOWN, version);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 启动默认展示页（主 Tab 下标 0-3 = 首页/书架/我的/设置；Index 冷启动初始化 Tab 用）。 */
  public static getStartupTabIndex(): number {
    return FqAppSettingsStore.startupTabIndex;
  }

  /** 设置启动默认展示页（范围外静默忽略）。 */
  public static setStartupTabIndex(index: number): void {
    if (!Number.isFinite(index) || index < 0 || index > FQ_STARTUP_TAB_MAX_INDEX) {
      return;
    }
    FqAppSettingsStore.startupTabIndex = Math.round(index);
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_STARTUP_TAB, FqAppSettingsStore.startupTabIndex);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 首页样式（0 今日焦点 / 1 排行榜 / 2 两者共存；首页顶部内容据此切换）。 */
  public static getHomeStyle(): number {
    return FqAppSettingsStore.homeStyle;
  }

  /** 设置首页样式（范围外静默忽略；appState.homeStyle 即时联动刷新首页）。 */
  public static setHomeStyle(style: number): void {
    if (!Number.isFinite(style) || style < FQ_HOME_STYLE_SPOTLIGHT
      || style > FQ_HOME_STYLE_MAX) {
      return;
    }
    FqAppSettingsStore.homeStyle = Math.round(style);
    appState.homeStyle = FqAppSettingsStore.homeStyle;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_HOME_STYLE, FqAppSettingsStore.homeStyle);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 我的、设置页面显示样式（0 我的含设置入口 / 1 设置含我的入口 / 2 单独显示）。 */
  public static getMineSettingsStyle(): number {
    return FqAppSettingsStore.mineSettingsStyle;
  }

  /** 设置我的、设置页面显示样式（范围外静默忽略；appState.mineSettingsStyle 即时联动主 Tab）。 */
  public static setMineSettingsStyle(style: number): void {
    if (!Number.isFinite(style) || style < FQ_MINE_STYLE_MINE_WITH_SETTINGS
      || style > FQ_MINE_STYLE_MAX) {
      return;
    }
    FqAppSettingsStore.mineSettingsStyle = Math.round(style);
    appState.mineSettingsStyle = FqAppSettingsStore.mineSettingsStyle;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_MINE_SETTINGS_STYLE, FqAppSettingsStore.mineSettingsStyle);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 离线朗读音色（textToSpeech person）。 */
  public static getTtsPerson(): number {
    return FqAppSettingsStore.ttsPerson;
  }

  public static setTtsPerson(person: number): void {
    FqAppSettingsStore.ttsPerson = person;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_TTS_PERSON, person);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 离线朗读语速（0.5 ~ 2）。 */
  public static getTtsRate(): number {
    return FqAppSettingsStore.ttsRate;
  }

  public static setTtsRate(rate: number): void {
    FqAppSettingsStore.ttsRate = rate;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_TTS_RATE, rate);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 局域网共享开关（对齐 fqapp LanSharePreferences：默认关，开=本地接口对局域网开放）。 */
  public static isLanShareEnabled(): boolean {
    return FqAppSettingsStore.apiLanShare;
  }

  /** 剧集边看边往后缓存集数（0 = 不自动缓存；对齐 fqapp DramaCachePreferences.ahead）。 */
  public static getDramaAutoCacheAhead(): number {
    return FqAppSettingsStore.dramaAutoCacheAhead;
  }

  /** 设置边看边往后缓存集数（范围外静默忽略）。 */
  public static setDramaAutoCacheAhead(ahead: number): void {
    if (!Number.isFinite(ahead) || ahead < 0 || ahead > FQ_DRAMA_AUTO_CACHE_AHEAD_MAX) {
      return;
    }
    FqAppSettingsStore.dramaAutoCacheAhead = Math.round(ahead);
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_DRAMA_AUTO_AHEAD, FqAppSettingsStore.dramaAutoCacheAhead);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 剧集自动缓存仅 Wi-Fi（默认开；测不出网络形态按不满足处理）。 */
  public static isDramaAutoCacheWifiOnly(): boolean {
    return FqAppSettingsStore.dramaAutoCacheWifiOnly;
  }

  public static setDramaAutoCacheWifiOnly(wifiOnly: boolean): void {
    FqAppSettingsStore.dramaAutoCacheWifiOnly = wifiOnly;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_DRAMA_AUTO_WIFI, wifiOnly);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 弹幕不透明度（%，20-100）。 */
  public static getDanmakuAlphaPercent(): number {
    return FqAppSettingsStore.danmakuAlphaPercent;
  }

  public static setDanmakuAlphaPercent(percent: number): void {
    if (!Number.isFinite(percent)) {
      return;
    }
    FqAppSettingsStore.danmakuAlphaPercent =
      Math.round(Math.min(FQ_DANMAKU_ALPHA_MAX_PERCENT, Math.max(FQ_DANMAKU_ALPHA_MIN_PERCENT, percent)));
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_ALPHA, FqAppSettingsStore.danmakuAlphaPercent);
  }

  /** 弹幕速度档位（1-5；倍率见 FQ_DANMAKU_SPEED_MULTIPLIERS）。 */
  public static getDanmakuSpeedTier(): number {
    return FqAppSettingsStore.danmakuSpeedTier;
  }

  public static setDanmakuSpeedTier(tier: number): void {
    FqAppSettingsStore.danmakuSpeedTier = FqAppSettingsStore.clampDanmakuTier(tier, 5, 3);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_SPEED, FqAppSettingsStore.danmakuSpeedTier);
  }

  /** 竖屏弹幕行数（1-4）。 */
  public static getDanmakuLineCount(): number {
    return FqAppSettingsStore.danmakuLineCount;
  }

  public static setDanmakuLineCount(count: number): void {
    FqAppSettingsStore.danmakuLineCount = FqAppSettingsStore.clampDanmakuTier(count, 4, 4);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_LINE_COUNT, FqAppSettingsStore.danmakuLineCount);
  }

  /** 横屏弹幕显示区域档位（1-4；占比见 FQ_DANMAKU_LINE_SPACE_FACTORS）。 */
  public static getDanmakuLineSpaceTier(): number {
    return FqAppSettingsStore.danmakuLineSpaceTier;
  }

  public static setDanmakuLineSpaceTier(tier: number): void {
    FqAppSettingsStore.danmakuLineSpaceTier = FqAppSettingsStore.clampDanmakuTier(tier, 4, 2);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_LINE_SPACE, FqAppSettingsStore.danmakuLineSpaceTier);
  }

  /** 弹幕字号档位（1-5；字号见 FQ_DANMAKU_TEXT_SIZES）。 */
  public static getDanmakuSizeTier(): number {
    return FqAppSettingsStore.danmakuSizeTier;
  }

  public static setDanmakuSizeTier(tier: number): void {
    FqAppSettingsStore.danmakuSizeTier = FqAppSettingsStore.clampDanmakuTier(tier, 5, 3);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_SIZE, FqAppSettingsStore.danmakuSizeTier);
  }

  /** 弹幕背景透明（不画黑底气泡，只留文字与阴影）。 */
  public static isDanmakuBgTransparent(): boolean {
    return FqAppSettingsStore.danmakuBgTransparent;
  }

  public static setDanmakuBgTransparent(transparent: boolean): void {
    FqAppSettingsStore.danmakuBgTransparent = transparent;
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_BG_TRANSPARENT, transparent);
  }

  /** 视频解码方式（true 硬解 ohcodec / false 软解 FFmpeg）。 */
  public static isVideoHwdec(): boolean {
    return FqAppSettingsStore.videoHwdec;
  }

  public static setVideoHwdec(enabled: boolean): void {
    FqAppSettingsStore.videoHwdec = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_VIDEO_HWDEC, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 视频清晰度偏好档名（'' = 跟随默认最高可用档；跨进页记忆）。 */
  public static getVideoQualityPref(): string {
    return FqAppSettingsStore.videoQualityPref;
  }

  public static setVideoQualityPref(quality: string): void {
    // 白名单外值一律回退 ''（跟随默认），与备份 decode 校验口径一致。
    FqAppSettingsStore.videoQualityPref =
      FQ_VIDEO_QUALITY_PREF_WHITELIST.indexOf(quality) >= 0 ? quality : '';
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_VIDEO_QUALITY_PREF, FqAppSettingsStore.videoQualityPref);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 弹幕设置恢复默认（fqapp 官方五键回出厂值；本地另含背景透明开关）。 */
  public static resetDanmakuSettings(): void {
    FqAppSettingsStore.danmakuAlphaPercent = FQ_DANMAKU_ALPHA_MAX_PERCENT;
    FqAppSettingsStore.danmakuSpeedTier = 3;
    FqAppSettingsStore.danmakuLineCount = 4;
    FqAppSettingsStore.danmakuLineSpaceTier = 2;
    FqAppSettingsStore.danmakuSizeTier = 3;
    FqAppSettingsStore.danmakuBgTransparent = false;
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_ALPHA, FqAppSettingsStore.danmakuAlphaPercent);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_SPEED, FqAppSettingsStore.danmakuSpeedTier);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_LINE_COUNT, FqAppSettingsStore.danmakuLineCount);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_LINE_SPACE, FqAppSettingsStore.danmakuLineSpaceTier);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_SIZE, FqAppSettingsStore.danmakuSizeTier);
    FqAppSettingsStore.putDanmaku(FQ_SETTINGS_KEY_DANMAKU_BG_TRANSPARENT,
      FqAppSettingsStore.danmakuBgTransparent);
  }

  /** 弹幕档位钳制（1..max，非法值回退 fallback）。 */
  private static clampDanmakuTier(tier: number, max: number, fallback: number): number {
    if (!Number.isFinite(tier)) {
      return fallback;
    }
    return Math.round(Math.min(max, Math.max(1, tier)));
  }

  /** 弹幕设置键落盘（失败静默）。 */
  private static putDanmaku(key: string, value: preferences.ValueType): void {
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(key, value);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  public static setLanShare(enabled: boolean): void {
    FqAppSettingsStore.apiLanShare = enabled;
    const pref: preferences.Preferences | null = FqAppSettingsStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(FQ_SETTINGS_KEY_LAN_SHARE, enabled);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  private static applyTheme(): void {
    const context: common.Context | null = FqAppSettingsStore.context;
    if (context === null) {
      return;
    }
    let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (FqAppSettingsStore.themeMode === FQ_THEME_DARK) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (FqAppSettingsStore.themeMode === FQ_THEME_LIGHT) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      context.getApplicationContext().setColorMode(mode);
    } catch (error) {
      // 应用失败保持当前模式
    }
  }
}

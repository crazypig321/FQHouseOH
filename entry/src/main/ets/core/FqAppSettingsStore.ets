/**
 * 应用设置持久化（设置页：深色模式 + 后台播放保活）。
 *
 * preferences 独立存储（fq_app_settings）：
 * - themeMode：0 跟随系统 / 1 浅色 / 2 深色（ApplicationContext.setColorMode 即时应用，
 *   EntryAbility onCreate 初始化时恢复）；
 * - backgroundAudio：后台播放开关（开=支持后台播放：创建 AVSession（ENABLE_BACKGROUND_PLAY）
 *   + 申请 audioPlayback 长时任务；关=无法后台播放：不创建/销毁 AVSession（无胶囊/播控中心
 *   通知）+ 不申请/停掉长时任务，后台播放被系统停止）；
 * - updateProxyDownload：更新包代理下载开关（关于页，仅用于下载更新软件包：
 *   开=经代理下载更新包，关=直连）。
 */

import preferences from '@ohos.data.preferences';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const FQ_APP_SETTINGS_NAME: string = 'fq_app_settings';
const FQ_SETTINGS_KEY_THEME: string = 'themeMode';
const FQ_SETTINGS_KEY_BG_AUDIO: string = 'backgroundAudio';
const FQ_SETTINGS_KEY_UPDATE_PROXY: string = 'updateProxyDownload';

/** 深色模式档位：跟随系统。 */
export const FQ_THEME_FOLLOW: number = 0;
/** 深色模式档位：浅色。 */
export const FQ_THEME_LIGHT: number = 1;
/** 深色模式档位：深色。 */
export const FQ_THEME_DARK: number = 2;

export class FqAppSettingsStore {
  private static pref: preferences.Preferences | null = null;
  private static context: common.Context | null = null;
  private static themeMode: number = FQ_THEME_FOLLOW;
  private static backgroundAudio: boolean = true;
  private static updateProxyDownload: boolean = false;

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
      const rawBg: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_BG_AUDIO, true);
      if (typeof rawBg === 'boolean') {
        FqAppSettingsStore.backgroundAudio = rawBg;
      }
      const rawProxy: preferences.ValueType = pref.getSync(FQ_SETTINGS_KEY_UPDATE_PROXY, false);
      if (typeof rawProxy === 'boolean') {
        FqAppSettingsStore.updateProxyDownload = rawProxy;
      }
    } catch (error) {
      // 损坏数据按默认值处理
    }
    FqAppSettingsStore.applyTheme();
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

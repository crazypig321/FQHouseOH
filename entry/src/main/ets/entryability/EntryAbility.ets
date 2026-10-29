/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import type { Configuration } from '@ohos.app.ability.Configuration';
import resourceManager from '@ohos.resourceManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, mediaquery, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqBackend } from '../core/FqBackend';
import { fqAudioSession } from '../core/FqAudioSession';
import { FqShelfStore } from '../core/FqShelfStore';
import { FqBrowseStore } from '../core/FqBrowseStore';
import { FqAudioHistory } from '../core/FqAudioHistory';
import { FqWatchedStore } from '../core/FqWatchedStore';
import { FqReaderStore } from '../core/FqReaderStore';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqLocalBookStore } from '../core/FqLocalBookStore';
import { FqAppSettingsStore } from '../core/FqAppSettingsStore';
import { FqChapterCacheStore } from '../core/FqChapterCacheStore';
import { FqDramaCacheStore } from '../core/FqDramaCacheStore';
import { fqDramaDownloader } from '../core/FqDramaDownloader';
import { FqAudioCacheStore } from '../core/FqAudioCacheStore';
import { fqAudioDownloader } from '../core/FqAudioDownloader';
import { FqComicCacheStore } from '../core/FqComicCacheStore';
import { fqComicDownloader } from '../core/FqComicDownloader';
import { FqWebDavConfigStore } from '../core/FqWebDavConfigStore';
import { FqWebDav } from '../core/FqWebDav';
import { appState } from './AppState';
import { themeUtils } from '../utils/ThemeUtils';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    appState.abilityContext = this.context;
    fqAudioSession.init(this.context);
    FqReadStatsStore.init(this.context);
    FqLocalBookStore.init(this.context);
    // 书架/浏览/听书/已看/阅读进度：启动即初始化（备份导出需枚举全量数据，
    // 此前仅子页面各自 init，直达备份页导出会因未初始化而漏采）
    FqShelfStore.init(this.context);
    FqBrowseStore.init(this.context);
    FqAudioHistory.init(this.context);
    FqWatchedStore.init(this.context);
    FqReaderStore.init(this.context);
    // 音量键翻页开关镜像到 AppState（设置页/小说/漫画三处开关共享）
    appState.volumeKeyPaging = FqReaderStore.getSettings().volumeKeyPaging;
    // 应用设置（深色模式恢复 + 后台保活开关）初始化
    FqAppSettingsStore.init(this.context);
    // 章节缓存/剧集缓存（阅读即缓存 + 离线播放）初始化
    FqChapterCacheStore.init(this.context);
    FqDramaCacheStore.init(this.context);
    fqDramaDownloader.init(this.context);
    // 听书音频缓存（离线播放 + 缓存下载）初始化
    FqAudioCacheStore.init(this.context);
    fqAudioDownloader.init(this.context);
    // 漫画离线缓存（图片列表秒开 + 整话离线）初始化
    FqComicCacheStore.init(this.context);
    fqComicDownloader.init(this.context);
    // WebDAV 备份配置（备份与恢复-WebDAV）初始化
    FqWebDavConfigStore.init(this.context);
    FqBackend.get().start(this.context).catch((error: Object): void => {
      hilog.error(DOMAIN, 'FqBackend', 'backend start failed: %{public}s', `${error}`);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 退出时自动备份（WebDAV 开关开启 + 已配置 + 可达时执行，静默失败）
    FqWebDav.backupOnExit();
    fqAudioSession.close();
  }

  /** 同步系统深浅色到全局状态（启动与配置变化时调用）。 */
  private applyColorMode(colorMode: ConfigurationConstant.ColorMode): void {
    appState.isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    themeUtils.colorModeChange(colorMode);
  }

  private syncColorMode(): void {
    try {
      const config: resourceManager.Configuration = this.context.resourceManager.getConfigurationSync();
      hilog.info(DOMAIN, 'testTag', 'config colorMode: %{public}s', `${config.colorMode}`);
      const isDark: boolean = config.colorMode === resourceManager.ColorMode.DARK;
      appState.isDark = isDark;
      themeUtils.colorModeChange(isDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (error) {
      // 读取失败保持默认浅色
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyColorMode(newConfig.colorMode !== undefined
      ? newConfig.colorMode : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }

  /** media query 监听实际生效的深浅色（跟随系统时 getConfigurationSync 可能返回 NOT_SET）。 */
  private watchColorMode(): void {
    try {
      const listener: mediaquery.MediaQueryListener =
        mediaquery.matchMediaSync('(dark-mode: true)');
      appState.isDark = listener.matches;
      hilog.info(DOMAIN, 'testTag', 'dark-mode matches: %{public}s', `${listener.matches}`);
      listener.on('change', (result: mediaquery.MediaQueryResult) => {
        const isDark: boolean = result.matches === true;
        hilog.info(DOMAIN, 'testTag', 'dark-mode change: %{public}s', `${isDark}`);
        this.applyColorMode(isDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      });
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'watchColorMode failed: %{public}s', JSON.stringify(error));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.syncColorMode();

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 沉浸式：页面铺满全屏（状态栏与底部手势区由组件自行避让）
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      this.watchColorMode();
      // 屏幕物理尺寸入全局状态（供阅读器排版视口等使用）
      const displayData: display.Display = display.getDefaultDisplaySync();
      appState.screenWidth = displayData.width;
      appState.screenHeight = displayData.height;
      hilog.info(DOMAIN, 'testTag', 'screen size: %{public}dx%{public}d', `${appState.screenWidth}`, `${appState.screenHeight}`);
      mainWindow.setWindowLayoutFullScreen(true).then(() => {
        // 全屏后跟踪系统避让区尺寸，供各页面 contentStartOffset/EndOffset 计算
        const uiContext = mainWindow.getUIContext();
        // PC/平板自由窗口：隐藏系统标题栏（页面扩展至标题栏区域，右上角仅保留系统三键
        // 下沉到页面内），与 PcTitleBar 合并为一条横栏；读取三键区宽度供右侧避让
        try {
          mainWindow.setWindowDecorVisible(false);
        } catch (error) {
          // 手机/全屏等无标题栏形态不支持，忽略
        }
        const syncDecorButtonWidth = (): void => {
          try {
            const buttonRect: window.TitleButtonRect = mainWindow.getTitleButtonRect();
            appState.decorButtonWidth = uiContext.px2vp(buttonRect.right + buttonRect.width);
          } catch (error) {
            appState.decorButtonWidth = 0;
          }
        };
        syncDecorButtonWidth();
        try {
          mainWindow.on('windowTitleButtonRectChange', (rect: window.TitleButtonRect): void => {
            appState.decorButtonWidth = uiContext.px2vp(rect.right + rect.width);
          });
        } catch (error) {
          // 不支持窗口三键区的设备忽略
        }
        const syncAvoidArea = (): void => {
          const topRectVp: number = uiContext.px2vp(
            mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
          appState.topRect = topRectVp;
          // 记录状态栏可见期间的最大避让高度：阅读页隐藏状态栏后仍需避让摄像头孔条
          appState.maxTopRect = Math.max(appState.maxTopRect, topRectVp);
          appState.bottomRect = uiContext.px2vp(
            mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
          hilog.info(DOMAIN, 'testTag',
            'avoidArea top=%{public}s maxTop=%{public}s bottom=%{public}s',
            `${appState.topRect}`, `${appState.maxTopRect}`, `${appState.bottomRect}`);
        };
        syncAvoidArea();
        mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            const topRectVp: number = uiContext.px2vp(data.area.topRect.height);
            appState.topRect = topRectVp;
            appState.maxTopRect = Math.max(appState.maxTopRect, topRectVp);
          } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            appState.bottomRect = uiContext.px2vp(data.area.bottomRect.height);
          }
        });

        /*断点及屏幕尺寸获取*/
        windowStage.getMainWindow().then((data: window.Window) => {
          let uiContext = data.getUIContext()
          // 启动即初始化窗口宽度与断点（此前仅 windowSizeChange 更新，首帧缺失）
          appState.displayWidthVp = uiContext.px2vp(displayData.width);
          const windowRect: window.Rect = data.getWindowProperties().windowRect;
          appState.windowWidthVp = uiContext.px2vp(windowRect.width);
          appState.WidthBp = uiContext.getWindowWidthBreakpoint();
          appState.HeightBp = uiContext.getWindowHeightBreakpoint();

          //监听屏幕改变
          data.on('windowSizeChange', (data) => {
            //获取屏幕宽高数值
            appState.screenWidth = data.width
            appState.screenHeight = data.height
            appState.windowWidthVp = uiContext!.px2vp(data.width)
            //获取横屏断点
            const widthBp: WidthBreakpoint = uiContext!.getWindowWidthBreakpoint()
            const heightBp: HeightBreakpoint = uiContext!.getWindowHeightBreakpoint()
            appState.WidthBp = widthBp
            appState.HeightBp = heightBp
            console.info(`#屏幕信息: 断点：${appState.WidthBp}  屏幕尺寸： 宽${ appState.screenWidth},高${appState.screenHeight}`)
          })
        }).catch((err: BusinessError) => {
          console.error(`Failed to obtain the main window. Cause code: ${err.code}, message: ${err.message}`);
        })
      }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(error));
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 关闭后台播放时：切后台主动暂停全部播放（状态/图标一致，回前台一键续播）
    if (!FqAppSettingsStore.isBackgroundAudio()) {
      fqAudioSession.pause();
      const handlers: Array<() => void> = appState.backgroundPauseHandlers.slice();
      for (const handler of handlers) {
        handler();
      }
    }
  }
}
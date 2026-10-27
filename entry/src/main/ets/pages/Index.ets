/**
 * 应用主入口（对齐 musicfreeOH Index 大框架）：
 * HdsNavigation + HdsTabs 悬浮底栏（barOverlap + barFloatingStyle），
 * 二级页经 .navDestination 集中页表路由。
 */

import { HdsAnimationMode, HdsNavigation, HdsNavigationTitleMode, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { CustomContentDialog } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';
import { AppState, appState } from '../entryability/AppState';
import { MainTabPagesBuilder, PageMapBuilder } from '../view/FqAppPages';
import { DialogManager } from '../utils/DialogUtils';
import { FqReaderSettingsHandler, fqReaderSettingsBus } from '../core/FqReaderSettingsBus';
import { fqEffectiveReaderTheme, ReaderSettingsDialogContent } from '../view/dialog/ReaderSettingsDialogContent';
import { FqComicSettingsHandler, fqComicSettingsBus } from '../core/FqComicSettingsBus';
import { ComicSettingsDialogContent } from '../view/dialog/ComicSettingsDialogContent';
import { WebDavBackupListDialogContent } from '../view/dialog/WebDavBackupListDialogContent';
import { WebDavBackupCountDialogContent } from '../view/dialog/WebDavBackupCountDialogContent';
import { FqPlaybackBall } from '../view/FqPlaybackBall';
import { FqSheetOptions } from '../view/sheet/CommonSheet';
import { FqChangelogSheet } from '../view/sheet/FqChangelogSheet';
import { FqAppSettingsStore } from '../core/FqAppSettingsStore';
import { HSBColorPicker, HSBColorPickerLayout } from '@keke/color-picker';

@Entry
@ComponentV2
struct Index {
  private tabsController: HdsTabsController = new HdsTabsController();

  @Local appStateUse: AppState = appState

  /** 首次启动 / 版本升级后自动弹出的更新日志半模态。 */
  @Local showChangelogSheet: boolean = false
  /** 当前包版本号（更新日志 sheet 默认展开版本）。 */
  @Local appVersionName: string = ''

  /** 监听 tabbar的显示和消失 */
  @Monitor('appStateUse.isBatchMode')
  isShowTabBar(){
    if (this.appStateUse.isBatchMode) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }else{
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }
  }

  aboutToAppear(): void {
    appState.switchMainTab = (index: number): void => {
      this.tabsController.changeIndex(index);
    };
    DialogManager.Register((): void => {
      if (DialogManager.dialogChangeKey === '阅读设置' || DialogManager.dialogChangeKey === '漫画设置') {
        this.settingsDialog.open()
      } else {
        this.dataDialog.open()
      }
    }, (message: string): void => {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 })
    }, (): void => {
      if (DialogManager.dialogChangeKey === '阅读设置' || DialogManager.dialogChangeKey === '漫画设置') {
        this.settingsDialog.close()
      } else {
        this.dataDialog.close()
      }
    })
    this.checkChangelogOnLaunch()
  }

  /**
   * 首次打开应用或版本更新后冷启动自动弹出更新日志 sheet（参考 musicfreeOH Index）：
   * 「已展示版本」与当前包版本不一致即弹出并记录（首次安装 pref 为空同样弹出）。
   */
  private checkChangelogOnLaunch(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      if (info.versionName.length === 0) {
        return
      }
      this.appVersionName = info.versionName
      if (FqAppSettingsStore.getChangelogShownVersion() === this.appVersionName) {
        return
      }
      FqAppSettingsStore.setChangelogShownVersion(this.appVersionName)
      // 延迟弹出，等待主页渲染完成
      setTimeout((): void => {
        this.showChangelogSheet = true
      }, 600)
    } catch (error) {
      // 版本号读取失败不弹
    }
  }

  /** 全局播控球显隐：播放器/听书页经 CommonNav onShown 置 hidePlaybackBall。 */
  @Computed
  get showPlaybackBall(): boolean {
    return !appState.hidePlaybackBall;
  }

  build() {
    Stack() {
      HdsNavigation(appState.pageInfos) {
        HdsTabs({ controller: this.tabsController }) {
          MainTabPagesBuilder()
        }
        .barOverlap(true)
        .vertical(false)
        .scrollable(false)
        .barPosition(BarPosition.End)
        // 批量多选模式下隐藏 tab 栏（对齐 musicfreeOH Index）
        .barHeight(56)
        .animationDuration(500)
        .barFloatingStyle({
          barBottomMargin: 28,
          systemMaterialEffect: {
            materialType: appState.materialType,
            materialLevel: appState.materialLevel
          },
          // 智感握姿：随设置开关 handedness 适配
          adaptToHandedness: appState.smartReachEnabled,
        })
        .onSelected((index: number) => {
          appState.currTabsIndex = index
        })
      }
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideTitleBar(true)
      .navDestination(this.pageMap)
      .width('100%')
      .height('100%')
      .foregroundBlurStyle(appState.isForegroundBlur ? BlurStyle.Thin : BlurStyle.NONE,
        { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT, scale: 0.3 })
      if (this.showPlaybackBall) {
        FqPlaybackBall()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showChangelogSheet, this.ChangelogSheetBuilder(),
      FqSheetOptions((): void => {
        this.showChangelogSheet = false
      }, 440))
  }

  /** 启动自动弹出的更新日志 sheet（与关于页同款，默认展开当前版本）。 */
  @Builder
  ChangelogSheetBuilder() {
    FqChangelogSheet({
      focusVersion: this.appVersionName,
      closeClick: (): void => {
        this.showChangelogSheet = false
      },
    })
  }

  /** 返回手势（导航栈空时到达，二级页出栈由 Navigation 处理，参考 musicfreeOH Index.onBackPress）：
   * 多选模式先退多选 → 非首页 tab 回首页 → 首页弹退出确认弹窗。 */
  onBackPress(): boolean {
    if (appState.isBatchMode) {
      this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
        appState.isBatchMode = false;
      });
      return true;
    }
    if (appState.currTabsIndex !== 0) {
      this.tabsController.changeIndex(0);
      return true;
    }
    this.showExitConfirm();
    return true;
  }

  /** 退出确认（共用确认弹窗）：确认后终止应用。 */
  private showExitConfirm(): void {
    DialogManager.ShowConfirm('退出应用', '是否确认退出应用？', '退出', (): void => {
      const context: common.UIAbilityContext | null = appState.abilityContext;
      if (context !== null) {
        context.terminateSelf().catch((): void => {
        });
      }
    });
  }

  @Builder
  pageMap(name: string) {
    PageMapBuilder(name)
  }

  /** 公共弹窗（居中：标题+内容+按钮，参考 musicfreeOH Index dataDialog：参数/按钮集中在 DialogManager）。 */
  private dataDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: DialogManager.DialogTitle(DialogManager.dialogChangeKey),
      contentBuilder: (): void => {
        this.DialogContentBuilder(DialogManager.dialogChangeKey)
      },
      buttons: DialogManager.DialogButtons(DialogManager.dialogChangeKey),
      contentAreaPadding: {
        top: 15,
        bottom: 15,
        left: 24,
        right: 24
      },
    }),
    onWillDismiss: (dialog: DismissDialogAction): void => {
      dialog.dismiss()
    },
    onWillDisappear: (): void => {
      DialogManager.DisappearDialog(DialogManager.dialogChangeKey)
    }
  });

  /** 「阅读设置」公共弹窗：内容组件在 view/dialog，无标题无按钮仅内容区，悬于工具条上方。 */
  private settingsDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      contentBuilder: (): void => {
        this.DialogContentBuilder(DialogManager.dialogChangeKey)
      },
      contentAreaPadding: { top: 20, bottom: 20, left: 24, right: 24 },
    }),
    alignment: DialogAlignment.Bottom,
    // 工具栏顶 = 窗口底 - (悬浮底边距28 + 栏高56)；弹窗 Bottom 基准为导航避让区底（比窗口底高 bottomRect）。
    // 窗口化时 bottomRect=0，动态计算保证弹窗始终贴工具栏上沿（手机全屏时 -84+bottomRect 仍为 -68）。
    offset: { dx: 0, dy: - appState.bottomRect - 84 },
    autoCancel: true,
    onWillDisappear: (): void => {
      DialogManager.DisappearDialog(DialogManager.dialogChangeKey);
    },
  });

  /** 弹窗中间自定义组件（按 DialogManager 标识分发）。 */
  @Builder
  DialogContentBuilder(key: string) {
    if (key === '通用确认') {
      Text(DialogManager.confirmMessage)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
    } else if (key === '阅读设置') {
      ReaderSettingsDialogContent({
        fontSize: fqReaderSettingsBus.fontSize,
        lineHeight: fqReaderSettingsBus.lineHeight,
        themeIndex: fqReaderSettingsBus.themeIndex,
        flipIndex: fqReaderSettingsBus.flipIndex,
        fontIndex: fqReaderSettingsBus.fontIndex,
        followThemeBg: fqEffectiveReaderTheme(fqReaderSettingsBus.themeIndex, appState.isDark).background,
        followThemeFont: fqEffectiveReaderTheme(fqReaderSettingsBus.themeIndex, appState.isDark).fontColor,
        fontSizeChange: (delta: number): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeFontSize(delta);
          }
        },
        lineHeightChange: (delta: number): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeLineHeight(delta);
          }
        },
        themeChange: (index: number): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeTheme(index);
          }
        },
        fontChange: (index: number): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeFont(index);
          }
        },
        flipChange: (index: number): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeFlip(index);
          }
        },
      })
    } else if (key === '漫画设置') {
      ComicSettingsDialogContent({
        comicFlipIndex: fqComicSettingsBus.comicFlipIndex,
        flipChange: (index: number): void => {
          const handler: FqComicSettingsHandler | null = fqComicSettingsBus.handler;
          if (handler !== null) {
            handler.changeFlip(index);
          }
        },
      })
    } else if (key === '自定义颜色') {
      HSBColorPicker({
        color: DialogManager.customColorInitial,
        layout: HSBColorPickerLayout.COLUMN,
        radius: 8,
        showAlpha: true,
        onChange: (value: string): void => {
          DialogManager.customColorPicked = value;
        },
      })
      .width('100%')
      .height(320)
    } else if (key === '选择WebDAV备份') {
      WebDavBackupListDialogContent()
    } else if (key === '备份保留数量') {
      WebDavBackupCountDialogContent()
    }
  }
}

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
import { ReaderThemeEditorContent } from '../view/dialog/ReaderThemeEditorContent';
import { FqComicSettingsHandler, fqComicSettingsBus } from '../core/FqComicSettingsBus';
import { ComicSettingsDialogContent } from '../view/dialog/ComicSettingsDialogContent';
import { WebDavBackupListDialogContent } from '../view/dialog/WebDavBackupListDialogContent';
import { WebDavBackupCountDialogContent } from '../view/dialog/WebDavBackupCountDialogContent';
import { ChapterCacheLimitDialogContent } from '../view/dialog/ChapterCacheLimitDialogContent';
import { GroupNameDialogContent } from '../view/dialog/GroupNameDialogContent';
import { SortJumpDialogContent } from '../view/dialog/SortJumpDialogContent';
import { HomeCategoryDialogContent } from '../view/dialog/HomeCategoryDialogContent';
import { FqPlaybackBall } from '../view/FqPlaybackBall';
import { FqSheetOptions } from '../view/sheet/CommonSheet';
import { FqChangelogSheet } from '../view/sheet/FqChangelogSheet';
import { FqAppSettingsStore, FQ_MINE_STYLE_MINE_WITH_SETTINGS } from '../core/FqAppSettingsStore';
import { FqReaderStore } from '../core/FqReaderStore';
import { HSBColorPicker, HSBColorPickerLayout } from '@keke/color-picker';
import { useSidebarLayout } from '../utils/BreakpointUtils';
import { PcMainLayout } from '../view/pcUI/PcMainLayout';
import { FqContinueKit } from '../utils/continue/FqContinueKit';
import { FqShareKit } from '../utils/share/FqShareKit';
import { fqPhysicalIndexOf, fqVisibleTabIndexes } from '../model/FqTabsModels';

@Entry
@ComponentV2
struct Index {
  private tabsController: HdsTabsController = new HdsTabsController();
  /** PC 侧边栏布局内容区 Tabs 控制器（barHeight 0 仅保活页面，切换经 PcSideBar） */
  private sideTabsController: TabsController = new TabsController();

  @Local appStateUse: AppState = appState

  /** 首次启动 / 版本升级后自动弹出的更新日志半模态。 */
  @Local showChangelogSheet: boolean = false
  /** 当前包版本号（更新日志 sheet 默认展开版本）。 */
  @Local appVersionName: string = ''
  /** 主 Tab 绑定下标（HdsTabs index 参数）：冷启动取「启动默认展示页」设置；
   *  之后仅在 onChange（切换动画完成后）同步为落定页签——提前/同帧赋值都会让 index 参数
   *  瞬时重放、吃掉 changeIndex 的切换动画；保持同步是为防返回主页时 index 重放回跳启动页。
   *  「我的、设置页面显示样式」下 Tab 数可变，此处为物理下标（可见列表内位置）。 */
  @Local mainTabIndex: number = 0
  /** 当前所在主 Tab 的逻辑下标（0 首页 / 1 书架 / 2 我的 / 3 设置）；样式切换 reconcile 用。 */
  @Local currentLogicalTab: number = 0

  /** 「我的、设置页面显示样式」变化：当前页签被隐藏时落到对方用户页，否则保持原页签物理位置。 */
  @Monitor('appStateUse.mineSettingsStyle')
  onMineSettingsStyleChange(): void {
    if (this.isPcLayout) {
      return; // PC 布局由 PcMainLayout 同步 pcTabIndex
    }
    const style: number = appState.mineSettingsStyle;
    const visible: number[] = fqVisibleTabIndexes(style);
    let target: number = this.currentLogicalTab;
    if (visible.indexOf(target) < 0) {
      // 隐藏设置 → 落我的；隐藏我的 → 落设置（合并样式下入口在对方页内）
      target = style === FQ_MINE_STYLE_MINE_WITH_SETTINGS ? 2 : 3;
    }
    this.currentLogicalTab = target;
    const physical: number = fqPhysicalIndexOf(target, style);
    this.mainTabIndex = physical;
    appState.currTabsIndex = physical;
  }

  /** 监听 tabbar的显示和消失 */
  @Monitor('appStateUse.isBatchMode')
  isShowTabBar(){
    // PC 侧边栏布局无 HdsTabs，控制器未挂载，跳过
    if (this.isPcLayout) {
      return;
    }
    if (this.appStateUse.isBatchMode) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }else{
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }
  }

  /** 是否 PC 侧边栏布局（2in1/平板恒开；手机恒关；其余设备自由窗口判定）。 */
  @Computed
  get isPcLayout(): boolean {
    return useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp);
  }

  aboutToAppear(): void {
    // 启动默认展示页（设置 → 外观「启动默认展示页」）：冷启动直接落在所选主 Tab
    // （所选 Tab 在「我的、设置页面显示样式」下被隐藏时回退首页）
    const startupTab: number = FqAppSettingsStore.getStartupTabIndex();
    this.mainTabIndex = fqPhysicalIndexOf(startupTab, appState.mineSettingsStyle);
    this.currentLogicalTab = fqVisibleTabIndexes(appState.mineSettingsStyle)[this.mainTabIndex] ?? 0;
    appState.currTabsIndex = this.mainTabIndex;
    appState.switchMainTab = (index: number): void => {
      // index 为逻辑下标（MENU_CONFIG 序），按当前显示样式映射为物理下标再切换
      const physical: number = fqPhysicalIndexOf(index, appState.mineSettingsStyle);
      if (this.isPcLayout) {
        this.sideTabsController.changeIndex(physical);
      } else {
        this.tabsController.changeIndex(physical);
      }
    };
    DialogManager.Register((): void => {
      if (DialogManager.dialogChangeKey === '阅读设置' || DialogManager.dialogChangeKey === '漫画设置') {
        this.settingsDialog.open()
      } else if (DialogManager.dialogChangeKey === '自定义主题编辑') {
        this.readerThemeEditorDialog.open()
      } else if (DialogManager.dialogChangeKey === '首页分类') {
        this.homeCategoryDialog.open()
      } else {
        this.dataDialog.open()
      }
    }, (message: string): void => {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 })
    }, (): void => {
      if (DialogManager.dialogChangeKey === '阅读设置' || DialogManager.dialogChangeKey === '漫画设置') {
        this.settingsDialog.close()
      } else if (DialogManager.dialogChangeKey === '自定义主题编辑') {
        this.readerThemeEditorDialog.close()
      } else if (DialogManager.dialogChangeKey === '首页分类') {
        this.homeCategoryDialog.close()
      } else {
        this.dataDialog.close()
      }
    })
    this.checkChangelogOnLaunch()
    // 应用流转目标端：待恢复接续载荷 → 延迟待 Navigation 挂载后推入对应场景页面
    if (FqContinueKit.hasPending()) {
      setTimeout((): void => {
        FqContinueKit.applyPending();
      }, 500);
    }
    // 分享链接冷启动：待处理分享载荷 → 延迟待 Navigation 挂载后直达对应页面 / 导入书架
    if (FqShareKit.hasPending()) {
      setTimeout((): void => {
        FqShareKit.applyPending();
      }, 500);
    }
    // 碰一碰 / 隔空手势（握拳）分享：进程内一次注册（按导航栈顶页面构建分享内容）
    FqShareKit.setupHarmonyShare();
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
      if (this.isPcLayout) {
        // PC 侧边栏布局：PcTitleBar + PcSideBar + 内容区 Navigation
        PcMainLayout({ tabsController: this.sideTabsController, initialTabIndex: this.mainTabIndex })
      } else {
        HdsNavigation(appState.pageInfos) {
          HdsTabs({ controller: this.tabsController, index: this.mainTabIndex }) {
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
          // 切换动画完成后才同步 index 绑定值，避免参数瞬时重放吃掉动画
          .onChange((index: number) => {
            this.mainTabIndex = index
            this.currentLogicalTab = fqVisibleTabIndexes(appState.mineSettingsStyle)[index] ?? 0
          })
        }
        .titleMode(HdsNavigationTitleMode.MINI)
        .mode(NavigationMode.Stack)
        // 画中画还原锚点（PiPController navigationId）
        .id('main_nav')
        .hideBackButton(true)
        .hideTitleBar(true)
        .navDestination(this.pageMap)
        .width('100%')
        .height('100%')
        .foregroundBlurStyle(appState.isForegroundBlur ? BlurStyle.Thin : BlurStyle.NONE,
          { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT, scale: 0.3 })
      }
      if (this.showPlaybackBall) {
        FqPlaybackBall({ ballAtRight: appState.holdingHand !== 'left' })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.showChangelogSheet, this.ChangelogSheetBuilder(), this.changelogSheetOptions())
  }

  /** 更新日志 sheet 的 bindSheet 参数（抽成方法，避免 @Entry build 根节点校验误报）。 */
  private changelogSheetOptions(): SheetOptions {
    return FqSheetOptions((): void => {
      this.showChangelogSheet = false
    }, 440);
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
      if (this.isPcLayout) {
        this.sideTabsController.changeIndex(0);
      } else {
        this.tabsController.changeIndex(0);
      }
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
    onWillAppear: (): void => {
      appState.pushForegroundBlur()
    },
    onWillDisappear: (): void => {
      appState.popForegroundBlur()
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
    // 「阅读设置」/「漫画设置」不触发前景模糊（阅读内容保持原样，规则见 AGENTS.md）
    onWillDisappear: (): void => {
      DialogManager.DisappearDialog(DialogManager.dialogChangeKey);
    },
  });

  /** 「自定义主题编辑」弹窗：叠加于「阅读设置」之上的独立宿主（保存/删除经 DialogManager 分发）。 */
  private readerThemeEditorDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: DialogManager.ReaderThemeEditorTitle(),
      contentBuilder: (): void => {
        this.DialogContentBuilder('自定义主题编辑')
      },
      buttons: DialogManager.DialogButtons('自定义主题编辑'),
      contentAreaPadding: { top: 18, bottom: 12, left: 22, right: 22 },
    }),
    onWillDismiss: (dialog: DismissDialogAction): void => {
      dialog.dismiss()
    },
    onWillAppear: (): void => {
      appState.pushForegroundBlur()
    },
    onWillDisappear: (): void => {
      appState.popForegroundBlur()
      DialogManager.ClearReaderThemeEditor();
    },
  });

  /** 「分类」弹窗（首页右上角分类按钮）：一级横向 tab + 左二级栏 + 右三级词网格。 */
  private homeCategoryDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      primaryTitle: '分类',
      contentBuilder: (): void => {
        this.DialogContentBuilder('首页分类')
      },
      contentAreaPadding: { top: 6, bottom: 10, left: 12, right: 12 },
    }),
    onWillDismiss: (dialog: DismissDialogAction): void => {
      dialog.dismiss()
    },
    onWillAppear: (): void => {
      appState.pushForegroundBlur()
    },
    onWillDisappear: (): void => {
      appState.popForegroundBlur()
      DialogManager.DisappearDialog('首页分类')
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
    } else if (key === '首页分类') {
      HomeCategoryDialogContent()
    } else if (key === '阅读设置') {
      ReaderSettingsDialogContent({
        fontSize: fqReaderSettingsBus.fontSize,
        lineHeight: fqReaderSettingsBus.lineHeight,
        themeIndex: fqReaderSettingsBus.themeIndex,
        flipIndex: fqReaderSettingsBus.flipIndex,
        fontIndex: fqReaderSettingsBus.fontIndex,
        showParagraphComment: fqReaderSettingsBus.showParagraphComment,
        dialogueHighlightColor: fqReaderSettingsBus.dialogueHighlightColor,
        volumeKeyPaging: appState.volumeKeyPaging,
        customThemes: fqReaderSettingsBus.customThemes,
        customThemeId: fqReaderSettingsBus.customThemeId,
        customFonts: fqReaderSettingsBus.customFonts,
        customFontId: fqReaderSettingsBus.customFontId,
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
        showParagraphCommentChange: (on: boolean): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeShowParagraphComment(on);
          }
        },
        dialogueHighlightColorChange: (color: string): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.changeDialogueHighlightColor(color);
          }
        },
        volumeKeyPagingChange: (on: boolean): void => {
          FqReaderStore.saveVolumeKeyPaging(on);
        },
        addCustomThemeChange: (): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.pickCustomTheme();
          }
        },
        selectCustomThemeChange: (id: string): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.selectCustomTheme(id);
          }
        },
        editCustomThemeChange: (id: string): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.editCustomTheme(id);
          }
        },
        addCustomFontChange: (): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.pickCustomFont();
          }
        },
        selectCustomFontChange: (id: string): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.selectCustomFont(id);
          }
        },
        removeCustomFontChange: (id: string): void => {
          const handler: FqReaderSettingsHandler | null = fqReaderSettingsBus.handler;
          if (handler !== null) {
            handler.removeCustomFont(id);
          }
        },
      })
    } else if (key === '自定义主题编辑') {
      ReaderThemeEditorContent()
    } else if (key === '漫画设置') {
      ComicSettingsDialogContent({
        comicFlipIndex: fqComicSettingsBus.comicFlipIndex,
        volumeKeyPaging: appState.volumeKeyPaging,
        flipChange: (index: number): void => {
          const handler: FqComicSettingsHandler | null = fqComicSettingsBus.handler;
          if (handler !== null) {
            handler.changeFlip(index);
          }
        },
        volumeKeyPagingChange: (on: boolean): void => {
          FqReaderStore.saveVolumeKeyPaging(on);
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
    } else if (key === '章节缓存限制') {
      ChapterCacheLimitDialogContent()
    } else if (key === '分组命名') {
      GroupNameDialogContent()
    } else if (key === '跳转排序') {
      SortJumpDialogContent()
    }
  }
}

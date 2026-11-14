import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { appState, AppState } from '../../entryability/AppState';
import { MainTabPagesBuilder, PageMapBuilder } from '../FqAppPages';
import { PcTitleBar } from './PcTitleBar';
import { PcSideBar } from './PcSideBar';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { FQ_MINE_STYLE_MINE_WITH_SETTINGS } from '../../core/FqAppSettingsStore';
import { fqPhysicalIndexOf, fqVisibleTabIndexes } from '../../model/FqTabsModels';

/**
 * PC 主布局（对齐 musicfreeOH PcMainLayout，2in1/平板使用）：
 * - 顶部标题栏（品牌 + 搜索入口，与窗口标题栏合一）
 * - 左侧导航栏（展开/收起）+ 右侧内容区（Navigation：主页面 Tabs 与二级路由页都在内容区切换，
 *   标题栏/侧边栏跨页面常驻；二级页经 NavPathUtils.push 的 replacePath 替换栈顶，返回恒回主内容）
 * - 全局播控球仍由 Index 悬浮承载（两种布局一致）
 */
@ComponentV2
export struct PcMainLayout {
  /** 主页面 Tabs 控制器（Index 持有：返回手势/主 Tab 切换用） */
  @Param tabsController: TabsController = new TabsController();
  /** 启动默认展示页（Index 冷启动传入；Tabs 初始 index，仅首次构建生效） */
  @Param initialTabIndex: number = 0;
  /** Tabs index 绑定值：初始取启动默认展示页，切页签后同步，防内容区重建时回跳启动页 */
  @Local pcTabIndex: number = 0;
  /** 当前所在主 Tab 的逻辑下标（0 首页 / 1 书架 / 2 我的 / 3 设置）；显示样式切换 reconcile 用。 */
  @Local currentLogicalTab: number = 0;
  @Local appStateUse: AppState = appState;

  aboutToAppear(): void {
    this.pcTabIndex = this.initialTabIndex;
    this.currentLogicalTab = fqVisibleTabIndexes(appState.mineSettingsStyle)[this.pcTabIndex] ?? 0;
  }

  /** 「我的、设置页面显示样式」变化：当前页签被隐藏时落到对方用户页，否则保持原页签物理位置。 */
  @Monitor('appStateUse.mineSettingsStyle')
  onMineSettingsStyleChange(): void {
    const style: number = appState.mineSettingsStyle;
    const visible: number[] = fqVisibleTabIndexes(style);
    let target: number = this.currentLogicalTab;
    if (visible.indexOf(target) < 0) {
      target = style === FQ_MINE_STYLE_MINE_WITH_SETTINGS ? 2 : 3;
    }
    this.currentLogicalTab = target;
    const physical: number = fqPhysicalIndexOf(target, style);
    this.pcTabIndex = physical;
    appState.currTabsIndex = physical;
    this.tabsController.changeIndex(physical);
  }

  /** 「启用短剧页」变化：关闭时正处短剧页签则回首页，否则保持原页签逻辑位置重映射物理下标。 */
  @Monitor('appStateUse.dramaPageEnabled')
  onDramaPageEnabledChange(): void {
    const style: number = appState.mineSettingsStyle;
    const visible: number[] = fqVisibleTabIndexes(style);
    let target: number = this.currentLogicalTab;
    if (visible.indexOf(target) < 0) {
      target = 0; // 短剧页签被隐藏 → 回首页
    }
    this.currentLogicalTab = target;
    const physical: number = fqPhysicalIndexOf(target, style);
    this.pcTabIndex = physical;
    appState.currTabsIndex = physical;
    this.tabsController.changeIndex(physical);
  }

  @Builder
  pageMap(name: string) {
    PageMapBuilder(name)
  }

  build() {
    Column() {
      // 视频「全屏观看」沉浸全屏（appState.pcImmersiveFullscreen）：隐藏应用标题栏与左侧导航栏，内容区铺满
      if (!appState.pcImmersiveFullscreen) {
        PcTitleBar()
      }

      Row() {
        // 播放页等沉浸内容页（appState.hidePcSideNav）隐藏左侧主导航，内容区铺满
        if (!appState.pcImmersiveFullscreen && !appState.hidePcSideNav) {
          PcSideBar({
            expanded: appState.sidebarExpanded,
            onSelect: (index: number): void => {
              NavPathUtils.pop()
              // index 为逻辑下标，按当前显示样式映射为物理下标再切换
              this.tabsController.changeIndex(fqPhysicalIndexOf(index, appState.mineSettingsStyle));
            },
            onToggle: (): void => {
              this.getUIContext().animateTo({ duration: 250, curve: Curve.Smooth }, (): void => {
                appState.sidebarExpanded = !appState.sidebarExpanded;
              });
            }
          })
        }

        // 内容区：二级页面（搜索/详情/阅读等）仅覆盖内容区，侧边栏保持可见
        HdsNavigation(appState.pageInfos) {
          Tabs({ controller: this.tabsController, index: this.pcTabIndex }) {
            MainTabPagesBuilder()
          }
          .barHeight(0)
          .vertical(false)
          .scrollable(false)
          // PC 侧边栏切换瞬切：500ms 横滑会与路由渐隐转场叠加，产生"左滑"观感（手机端 Tabs 不受影响）
          .animationDuration(0)
          .onChange((index: number): void => {
            this.pcTabIndex = index;
            appState.currTabsIndex = index;
            this.currentLogicalTab = fqVisibleTabIndexes(appState.mineSettingsStyle)[index] ?? 0;
          })
        }
        .titleMode(HdsNavigationTitleMode.MINI)
        .mode(NavigationMode.Stack)
        // 画中画还原锚点（PiPController navigationId，PC 布局专用，与手机端区分避免重名）
        .id('pc_main_nav')
        .hideBackButton(true)
        .hideTitleBar(true)
        .navDestination(this.pageMap)
        // PC 布局路由转场接管（仅本文件 = 仅 PC 布局生效）：
        // - 进场（push/replace）：返回 undefined，走 CommonNav 的 .transition(OPACITY) 渐显；
        // - 退场（pop）：自定义退场——退场页渐隐（OPACITY），NavBar 侧静止。
        //   必须 Navigation 级接管：NavDestination 级转场属性管不到 pop 的入场方 NavBar，此前退出一直滑动即此原因
        .customNavContentTransition((from: NavContentInfo, to: NavContentInfo,
          operation: NavigationOperation): NavigationAnimatedTransition | undefined => {
          if (operation !== NavigationOperation.POP) {
            appState.pcNavExitOpacity = 1
            return undefined
          }
          const exitAnim: NavigationAnimatedTransition = {
            timeout: 400,
            transition: (proxy: NavigationTransitionProxy): void => {
              this.getUIContext().animateTo({
                duration: 250,
                curve: Curve.Smooth,
                onFinish: (): void => {
                  proxy.finishTransition()
                  // 退场页已卸载，全局参数归位，避免残留 0 值影响后续绑定实例
                  appState.pcNavExitOpacity = 1
                }
              }, (): void => {
                appState.pcNavExitOpacity = 0
              })
            }
          }
          return exitAnim
        })
        .layoutWeight(1)
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .foregroundBlurStyle(appState.isForegroundBlur ? BlurStyle.Thin : BlurStyle.NONE,
          { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT, scale: 0.3 })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}

import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { appState } from '../../entryability/AppState';
import { MainTabPagesBuilder, PageMapBuilder } from '../FqAppPages';
import { PcTitleBar } from './PcTitleBar';
import { PcSideBar } from './PcSideBar';
import { NavPathUtils } from '../../utils/NavPathUtils';

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
        if (!appState.pcImmersiveFullscreen) {
          PcSideBar({
            expanded: appState.sidebarExpanded,
            onSelect: (index: number): void => {
              NavPathUtils.pop()
              this.tabsController.changeIndex(index);
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
          Tabs({ controller: this.tabsController }) {
            MainTabPagesBuilder()
          }
          .barHeight(0)
          .vertical(false)
          .scrollable(false)
          // PC 侧边栏切换瞬切：500ms 横滑会与路由渐隐转场叠加，产生"左滑"观感（手机端 Tabs 不受影响）
          .animationDuration(0)
          .onChange((index: number): void => {
            appState.currTabsIndex = index;
          })
        }
        .titleMode(HdsNavigationTitleMode.MINI)
        .mode(NavigationMode.Stack)
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

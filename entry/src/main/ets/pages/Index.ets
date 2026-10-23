/**
 * 应用主入口（对齐 musicfreeOH Index 大框架）：
 * HdsNavigation + HdsTabs 悬浮底栏（barOverlap + barFloatingStyle），
 * 二级页经 .navDestination 集中页表路由。
 */

import { HdsAnimationMode, HdsNavigation, HdsNavigationTitleMode, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { AppState, appState } from '../entryability/AppState';
import { MainTabPagesBuilder, PageMapBuilder } from '../view/FqAppPages';

@Entry
@ComponentV2
struct Index {
  private tabsController: HdsTabsController = new HdsTabsController();

  @Local appStateUse: AppState = appState

  @Monitor('appStateUse.isBatchMode')
  isShowTabBar(){
    if (this.appStateUse.isBatchMode) {
      this.tabsController.applyHideAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }else{
      this.tabsController.applyShowAnimation(HdsAnimationMode.CLICK_ANIMATION)
    }
  }

  build() {
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
  }

  @Builder
  pageMap(name: string) {
    PageMapBuilder(name)
  }
}

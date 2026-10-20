/**
 * 全局应用状态：NavPathStack 与当前 Tab 索引统一持于此单例
 * （对齐 musicfreeOH AppState 模式，页面通过 appState.pageInfos 路由）。
 */

@ObservedV2
class AppState {
  /** 全局导航栈（Navigation 根节点使用） */
  @Trace pageInfos: NavPathStack = new NavPathStack();
  @Trace currTabsIndex: number = 0;
  /** 状态栏避让高度（vp，全屏沉浸模式下由 EntryAbility 跟踪） */
  @Trace topRect: number = 0;
  /** 底部手势区避让高度（vp） */
  @Trace bottomRect: number = 0;
}

export const appState: AppState = new AppState();

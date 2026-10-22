/**
 * 全局应用状态：NavPathStack 与当前 Tab 索引统一持于此单例
 * （对齐 musicfreeOH AppState 模式，页面通过 appState.pageInfos 路由）。
 */
import { hdsMaterial } from "@kit.UIDesignKit";

@ObservedV2
class AppState {
  /** 全局导航栈（Navigation 根节点使用） */
  @Trace pageInfos: NavPathStack = new NavPathStack();
  @Trace currTabsIndex: number = 0;
  /** 状态栏避让高度（vp，全屏沉浸模式下由 EntryAbility 跟踪） */
  @Trace topRect: number = 0;
  /** 状态栏可见期间的最大避让高度（vp）：阅读页隐藏状态栏后仍覆盖摄像头孔条，眉页定位用 */
  @Trace maxTopRect: number = 0;
  /** 底部手势区避让高度（vp） */
  @Trace bottomRect: number = 0;
  /** 屏幕物理宽度（px，启动时由 EntryAbility 同步） */
  @Trace screenWidth: number = 0;
  /** 屏幕物理高度（px，启动时由 EntryAbility 同步） */
  @Trace screenHeight: number = 0;

  /*设备断点获取*/
  @Trace WidthBp: number = 1
  @Trace HeightBp: number = 1

  // 沉浸光感参数
  @Trace materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @Trace materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;

  // 智感握姿开关（持久化设置，启动时由 Bootstrap 恢复，设置页切换时更新）
  @Trace smartReachEnabled: boolean = false;

  /** 系统当前是否深色模式（EntryAbility 启动与 onConfigurationUpdate 同步） */
  @Trace isDark: boolean = false;
}

export const appState: AppState = new AppState();

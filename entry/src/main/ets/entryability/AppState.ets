/**
 * 全局应用状态：NavPathStack 与当前 Tab 索引统一持于此单例
 * （对齐 musicfreeOH AppState 模式，页面通过 appState.pageInfos 路由）。
 */
import { hdsMaterial } from "@kit.UIDesignKit";
import { common } from '@kit.AbilityKit';

@ObservedV2
export class AppState {
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
  // 是否开启模糊
  @Trace isForegroundBlur: boolean = false;
  /*设备断点获取*/
  @Trace WidthBp: number = 1
  @Trace HeightBp: number = 1

  // 沉浸光感参数
  @Trace materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @Trace materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;

  // 智感握姿开关（持久化设置，启动时由 Bootstrap 恢复，设置页切换时更新）
  @Trace smartReachEnabled: boolean = false;

  /** 批量多选模式（书架页长按进入）：主 TabBar 随之隐藏（barHeight 0/56，参考阅读页底栏模式） */
  @Trace isBatchMode: boolean = false;

  /** 全局悬浮播控球隐藏标记：播放器/听书页经 CommonNav onShown 声明，Index 据此显隐球体。 */
  @Trace hidePlaybackBall: boolean = false;

  /** 系统当前是否深色模式（EntryAbility 启动与 onConfigurationUpdate 同步） */
  @Trace isDark: boolean = false;

  /** 主题色 key（外观设置；'' = 跟随系统，默认 'orange' 番茄橙；持久化于 FqAppSettingsStore） */
  @Trace themeColorKey: string = 'orange';

  /** 全局主题色（所有高亮 / 选中 / 强调色统一引用；资源定义深浅自适应，
   *  半透明变体经 FqColorUtils.withOpacity(appState.accentColor, x) 派生） */
  @Trace accentColor: ResourceColor = $r('app.color.theme_color_orange');

  /** 音量键翻页开关（设置页/小说阅读/漫画阅读三处开关实时同步；
   *  持久化于 FqReaderStore，EntryAbility 启动时初始化，写入统一走 FqReaderStore.saveVolumeKeyPaging）。 */
  @Trace volumeKeyPaging: boolean = false;

  /** 点击书籍直接进入阅读（点小说/漫画跳过详情页，从上次进度直接开读；
   *  持久化于 FqAppSettingsStore，开关写入统一走 FqAppSettingsStore.setDirectRead）。 */
  @Trace directReadEnabled: boolean = false;

  /** 主 Ability 上下文（EntryAbility 注入：退出应用 terminateSelf 用）。 */
  public abilityContext: common.UIAbilityContext | null = null;

  /** 切后台主动暂停回调列表（关闭后台播放时 EntryAbility onBackground 调用；
   * 播放页 aboutToAppear 注册、aboutToDisappear 注销）。 */
  public backgroundPauseHandlers: Array<() => void> = [];

  /** 主 Tab 切换回调（Index 注入 tabsController.changeIndex；页面内跳转一级 Tab 用，如我的-应用设置）。 */
  public switchMainTab: ((index: number) => void) | null = null;
}

export const appState: AppState = new AppState();

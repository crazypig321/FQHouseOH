/**
 * 播放页公共右侧侧边栏壳（CommonNav/HdsNavDestination 包裹）：
 * 统一 HDS 标题栏（标题 + 可选返回按钮/「同系列」文本按钮/「恢复默认」/设置/关闭按钮）
 * 与按钮样式，内容经 content 插槽传入。横屏全屏侧边栏（选集/缓存/同系列/播放设置/
 * 弹幕设置）与 PC 详情侧边栏（目录/同系列）共用；深色面板 dark 固定白色前景。
 */
import {
  HdsNavigationMenuItemOptions,
  TextStyleMode,
  TitleBarContentOptions,
} from '@kit.UIDesignKit';
import { CommonNav } from '../CommonNav';

@ComponentV2
export struct FqPlayerSidebar {
  /** 标题栏主标题。 */
  @Param title: string = '';
  /** 深色面板（固定白色标题栏前景）；浅色面板为 false。 */
  @Param dark: boolean = true;
  /** HDS 标题栏返回按钮（二级页返回上一级）。 */
  @Param showBack: boolean = false;
  /** 右上「同系列」文本按钮（选集面板入口，fqapp story_player_panel 抽屉形态）。 */
  @Param showRelated: boolean = false;
  /** 右上「恢复默认」按钮（弹幕设置页，fqapp 语义：落默认值 + Toast「设置成功」）。 */
  @Param showReset: boolean = false;
  /** 右上设置按钮（dot_grid_2x2，PC 目录页：顶栏原设置按钮移入）。 */
  @Param showSettings: boolean = false;
  /** 右上关闭按钮（收起侧边栏）。 */
  @Param showClose: boolean = false;
  /** 面板背景色（与宿主容器底色一致，避免 CommonNav 默认页面底色透出）。 */
  @Param panelBgColor: ResourceColor = '#F0141414';
  @Event backClick: () => void = (): void => {};
  @Event relatedClick: () => void = (): void => {};
  @Event resetClick: () => void = (): void => {};
  @Event settingsClick: () => void = (): void => {};
  @Event closeClick: () => void = (): void => {};
  @BuilderParam content: () => void;

  build() {
    // 同 FqPlayerSettingsSheet：HDS 标题栏挂载后动态变化的按钮（返回/恢复默认/标题）
    // action 不被重新绑定；showBack 翻转（主设置页↔弹幕设置页）经 if/else 分支互换
    // 整树重建 CommonNav，使标题栏配置始终为挂载期静态配置
    if (this.showBack) {
      this.SidebarHost()
    } else {
      this.SidebarHost()
    }
  }

  /** CommonNav 宿主（两分支同构：靠 if/else 分支互换强制整树重建）。 */
  @Builder
  private SidebarHost() {
    CommonNav({
      titleBarOp: this.sidebarTitleBar(),
      isHideBackButton: !this.showBack,
      embedded: true,
      barForegroundColor: this.dark ? Color.White : undefined,
      pageBackgroundColor: this.panelBgColor,
      showBrandGradient: false,
      showPlaybackBall: false,
      doubleTapToTop: false,
      // 兜底：backIcon.action 未触发时，默认返回钮走 CommonNav onBackPressed
      backPressed: (): boolean => {
        if (this.showBack) {
          this.backClick();
          return true;
        }
        return false;
      },
      content: (): void => {
        this.content();
      },
    })
  }

  /** 侧边栏标题栏：标题 + 可选 backIcon/菜单（同系列文本钮、恢复默认、设置、关闭）。 */
  private sidebarTitleBar(): TitleBarContentOptions {
    const options: TitleBarContentOptions = {
      title: { mainTitle: this.title },
    };
    if (this.showBack) {
      options.backIcon = {
        action: (): void => {
          this.backClick();
        },
      };
    }
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.showRelated) {
      menus.push({
        content: {
          label: '同系列',
          type: TextStyleMode.NORMAL,
          action: (): void => {
            this.relatedClick();
          },
        },
      });
    }
    if (this.showReset) {
      menus.push({
        content: {
          icon: $r('sys.symbol.arrow_counterclockwise'),
          label: '恢复默认',
          action: (): void => {
            this.resetClick();
          },
        },
      });
    }
    if (this.showSettings) {
      menus.push({
        content: {
          icon: $r('sys.symbol.dot_grid_2x2'),
          label: '播放设置',
          action: (): void => {
            this.settingsClick();
          },
        },
      });
    }
    if (this.showClose) {
      menus.push({
        content: {
          icon: $r('sys.symbol.xmark'),
          label: '关闭',
          action: (): void => {
            this.closeClick();
          },
        },
      });
    }
    if (menus.length > 0) {
      options.menu = { value: menus };
    }
    return options;
  }
}

/**
 * 应用设置页（主 Tab 第四页 + 我的-应用设置入口共用，@Param isTab 区分）：
 * - 外观：深色模式（跟随系统/浅色/深色，FqMenu 档位直选，即时生效）；
 *   启动默认展示页（首页/书架/我的/设置，FqMenu 直选，下次冷启动生效）；
 * - 播放：开启后台播放开关（开=支持后台播放，关=无法后台播放）；
 * - 数据：缓存与管理入口、备份与恢复入口、清除所有数据（确认弹窗提示重启，清全部 KV/缓存/设置后 restartApp）；
 * - 服务：本地接口入口（状态/自测、地址与局域网共享、可用端点，ApiServicePage）+ 运行日志入口；
 * - 关于：关于我们入口。
 */

import { CommonNav } from '../view/CommonNav';
import { FqMenu, FqMenuItem } from '../view/CommonMenu';
import { common, Want } from '@kit.AbilityKit';
import { FqTitleBarOptions, ROUTE_ABOUT, ROUTE_API_SERVICE, ROUTE_CACHE_MANAGE, ROUTE_LOGS, ROUTE_BACKUP, ROUTE_TTS_SETTINGS } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import {
  FQ_THEME_DARK,
  FQ_THEME_FOLLOW,
  FQ_THEME_LIGHT,
  FQ_HOME_STYLE_SPOTLIGHT,
  FQ_HOME_STYLE_RANK,
  FQ_HOME_STYLE_BOTH,
  FQ_HOME_STYLE_MAX,
  FqAppSettingsStore,
} from '../core/FqAppSettingsStore';
import { FqReaderStore } from '../core/FqReaderStore';
import { FQ_THEME_COLOR_OPTIONS, fqThemeColorOf, fqThemeColorNameOf } from '../core/FqThemeColors';
import { FqDataCleaner } from '../core/FqDataCleaner';
import { FqUpdateChecker } from '../core/FqUpdateChecker';
import { DialogManager } from '../utils/DialogUtils';
import { FqSmartReach } from '../utils/FqSmartReach';
import { FqColorUtils } from '../utils/FqColorUtils';
import { MENU_CONFIG } from '../model/FqTabsModels';
import { appState } from '../entryability/AppState';

const FQ_HOME_TOP_INSET: number = 56;
/** 滚动内容末尾偏移：悬浮底栏 56 + 底部悬浮边距 28。 */
const FQ_SETTINGS_BOTTOM_INSET: number = 84;
const FQ_THEME_ANCHOR_ID: string = 'settings_theme_anchor';
const FQ_THEME_COLOR_ANCHOR_ID: string = 'settings_theme_color_anchor';
const FQ_STARTUP_TAB_ANCHOR_ID: string = 'settings_startup_tab_anchor';
const FQ_HOME_STYLE_ANCHOR_ID: string = 'settings_home_style_anchor';
/** 行内分割线左右避让：左侧行 padding 14 + 图标块 34 + 间距 12，右侧对称一致。 */
const FQ_ROW_DIVIDER_INSET: number = 60;
/** 深色模式档位文案（下标即档位值）。 */
const FQ_THEME_LABELS: string[] = ['跟随系统', '浅色', '深色'];
/** 首页样式档位文案（下标即档位值）。 */
const FQ_HOME_STYLE_LABELS: string[] = ['今日焦点', '排行榜', '今日焦点和排行榜共存'];

@Builder
function fqSettingsEmptyContent() {
}

/** 设置分组卡片壳（ProfilePage 卡片体系：comp_background_list_card + 深色描边）。 */
@ComponentV2
struct FqSettingsCard {
  @BuilderParam content: () => void = fqSettingsEmptyContent;

  build() {
    Column() {
      this.content()
    }
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }
}

@ComponentV2
export struct SettingsPage {
  /** Tab 模式（主 Tab 第四页）：隐藏返回、双击回顶；路由推入时默认 false（带返回）。 */
  @Param isTab: boolean = false;
  private scroller: Scroller = new Scroller();
  @Local themeMode: number = FQ_THEME_FOLLOW;
  @Local backgroundAudio: boolean = true;
  @Local pipVideo: boolean = false;
  @Local startupTab: number = 0;
  @Local homeStyle: number = FQ_HOME_STYLE_SPOTLIGHT;

  aboutToAppear(): void {
    this.themeMode = FqAppSettingsStore.getThemeMode();
    this.backgroundAudio = FqAppSettingsStore.isBackgroundAudio();
    this.pipVideo = FqAppSettingsStore.isPipVideoEnabled();
    this.startupTab = FqAppSettingsStore.getStartupTabIndex();
    this.homeStyle = FqAppSettingsStore.getHomeStyle();
    // 进入设置页静默检查更新（会话内节流，与关于页共用）：
    // 发现新版本时「关于」条目显示红点，无新版本时清空红点
    FqUpdateChecker.checkLatestSilently();
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('应用设置', false),
      embedded: this.isTab,
      isHideBackButton: this.isTab,
      scroller: this.scroller,
      doubleTapToTop: this.isTab,
      scrollToTopYOffset: - appState.topRect - FQ_HOME_TOP_INSET,
    }) {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          this.SectionHeader('外观')
          FqSettingsCard() {
            this.ThemeRow()
            this.RowDivider()
            this.ThemeColorRow()
            this.RowDivider()
            this.SmartReachRow()
            this.RowDivider()
            this.StartupTabRow()
            this.RowDivider()
            this.HomeStyleRow()
          }

          this.SectionHeader('阅读与播放')
          FqSettingsCard() {
            this.DirectReadRow()
            this.RowDivider()
            this.VolumeKeyPagingRow()
            this.RowDivider()
            this.BackgroundAudioRow()
            this.RowDivider()
            this.PipVideoRow()
            this.RowDivider()
            this.SettingRow($r('sys.symbol.waveform_headphones'), '#FF8B5CF6', '离线朗读',
              '朗读音色下载与语速设置', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_TTS_SETTINGS);
              })
          }

          this.SectionHeader('数据')
          FqSettingsCard() {
            this.SettingRow($r('sys.symbol.externaldrive'), '#FF3B82F6', '缓存与管理', '章节 / 剧集 / 听书 / 漫画离线缓存', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_CACHE_MANAGE);
              })
            this.RowDivider()
            this.SettingRow($r('sys.symbol.archivebox'), '#FFF59E0B', '备份与恢复', '导出或恢复收藏、进度与已看剧集', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_BACKUP);
              })
            this.RowDivider()
            this.SettingRow($r('sys.symbol.trash'), '#FFF43F5E', '清除所有数据', '清空全部记录、缓存与设置，完成后重启应用', '', true,
              (): void => {
                this.confirmClearAllData();
              })
          }

          this.SectionHeader('服务')
          FqSettingsCard() {
            this.SettingRow($r('sys.symbol.scope'), '#FF0EA5E9', '本地接口',
              '本地接口地址与可用端点', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_API_SERVICE);
              })
            this.RowDivider()
            this.SettingRow($r('sys.symbol.list_bullet'), '#FF8B5CF6', '日志', '查看应用与核心运行日志', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_LOGS);
              })
          }

          this.SectionHeader('关于')
          FqSettingsCard() {
            this.AboutEntryRow()
          }
        }
        .padding({ left: 16, right: 16, top: 10, bottom: 40 })
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_HOME_TOP_INSET)
      .contentEndOffset(appState.bottomRect + FQ_SETTINGS_BOTTOM_INSET)
      .width('100%')
      .height('100%')
    }
  }

  /** 启动默认展示页菜单：首页/书架/我的/设置 四选项（主 Tab 同名），选中打勾，下次冷启动生效。 */
  private openStartupTabMenu(): void {
    const items: FqMenuItem[] = [];
    for (let index: number = 0; index < MENU_CONFIG.length; index++) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = MENU_CONFIG[index].label;
      if (index === this.startupTab) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      const picked: number = index;
      item.onAction = (): void => {
        this.applyStartupTab(picked);
      };
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), FQ_STARTUP_TAB_ANCHOR_ID, items);
  }

  private applyStartupTab(index: number): void {
    this.startupTab = index;
    FqAppSettingsStore.setStartupTabIndex(index);
  }

  /** 首页样式菜单：今日焦点/排行榜/共存 三选项（当前档尾勾，点击即时切换）。 */
  private openHomeStyleMenu(): void {
    const items: FqMenuItem[] = [];
    const styles: number[] = [FQ_HOME_STYLE_SPOTLIGHT, FQ_HOME_STYLE_RANK, FQ_HOME_STYLE_BOTH];
    for (const style of styles) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = FQ_HOME_STYLE_LABELS[style];
      if (style === this.homeStyle) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      const picked: number = style;
      item.onAction = (): void => {
        this.applyHomeStyle(picked);
      };
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), FQ_HOME_STYLE_ANCHOR_ID, items);
  }

  private applyHomeStyle(style: number): void {
    if (style < 0 || style > FQ_HOME_STYLE_MAX) {
      return;
    }
    this.homeStyle = style;
    FqAppSettingsStore.setHomeStyle(style);
  }

  private openThemeMenu(): void {
    const items: FqMenuItem[] = [];
    const modes: number[] = [FQ_THEME_FOLLOW, FQ_THEME_LIGHT, FQ_THEME_DARK];
    for (const mode of modes) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = FQ_THEME_LABELS[mode];
      if (mode === this.themeMode) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      const picked: number = mode;
      item.onAction = (): void => {
        this.applyThemeMode(picked);
      };
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), FQ_THEME_ANCHOR_ID, items);
  }

  private applyThemeMode(mode: number): void {
    this.themeMode = mode;
    FqAppSettingsStore.setThemeMode(mode);
  }

  /** 主题色菜单：色板 + 名称 + 选中勾（点击即时切换全局高亮色；自定义颜色开 HSB 取色器）。 */
  private openThemeColorMenu(): void {
    const items: FqMenuItem[] = [];
    for (const option of FQ_THEME_COLOR_OPTIONS) {
      const item: FqMenuItem = new FqMenuItem();
      item.label = option.name;
      if (option.key === 'custom') {
        item.swatch = FqAppSettingsStore.getThemeCustomColor();
        item.onAction = (): void => {
          this.openCustomColorPicker();
        };
      } else {
        item.swatch = fqThemeColorOf(option.key);
        const picked: string = option.key;
        item.onAction = (): void => {
          FqAppSettingsStore.setThemeColor(picked);
        };
      }
      if (option.key === FqAppSettingsStore.getThemeColor()) {
        item.endIcon = $r('sys.symbol.checkmark');
      }
      items.push(item);
    }
    FqMenu.open(this.getUIContext(), FQ_THEME_COLOR_ANCHOR_ID, items);
  }

  /** 打开自定义颜色取色器（公共弹窗：底部确认/取消，确认后应用所选颜色）。 */
  private openCustomColorPicker(): void {
    DialogManager.ShowCustomColorPicker(FqAppSettingsStore.getThemeCustomColor(),
      (hex: string): void => {
        FqAppSettingsStore.setThemeCustomColor(hex);
        FqAppSettingsStore.setThemeColor('custom');
      });
  }

  private confirmClearAllData(): void {
    DialogManager.ShowConfirm('清除所有数据',
      '将清空浏览 / 收听 / 观看记录、阅读统计与进度、书架收藏、本地书籍及全部离线缓存，并重置应用设置；已导出到「Download/应用包名」文件夹的文件不受影响；完成后应用将自动重启',
      '清除', (): void => {
        this.performClearAllData();
      });
  }

  /** 执行清除：清空全部 KV 与数据目录后 restartApp 重启（主线程 + 应用获焦时调用）。 */
  private async performClearAllData(): Promise<void> {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      this.toast('清除失败，请稍后重试');
      return;
    }
    this.toast('正在清除数据…');
    const ok: boolean = await FqDataCleaner.clearAll(context);
    if (!ok) {
      this.toast('部分数据清除失败，将在重启后重试清理');
    }
    try {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
      };
      context.getApplicationContext().restartApp(want);
    } catch (error) {
      this.toast('清除完成，请手动重启应用');
    }
  }

  @Builder
  private SectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(3.5)
        .height(15)
        .borderRadius(2)
        .backgroundColor(appState.accentColor)
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
    }
    .width('100%')
  }

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: FQ_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 通用设置行：彩色图标块 + 标题/副标题 + 右侧文案与箭头。 */
  @Builder
  private SettingRow(icon: Resource, tint: string, title: string, subtitle: string,
    rightText: string, showChevron: boolean, onTap: () => void) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([tint])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(tint, 0.12))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (rightText.length > 0) {
        Text(rightText)
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      if (showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick(onTap)
  }

  /** 关于条目行：静默检查发现新版本时「关于」右侧显示红点（颜色同关于页「检查更新」标记）。 */
  @Builder
  private AboutEntryRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.person_fill'))
          .fontSize(17)
          .fontColor(['#FF8B5CF6'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF8B5CF6', 0.12))

      Column({ space: 3 }) {
        Text('关于')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('版本与开源信息')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (appState.latestVersion.length > 0) {
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor('#FFE5484D')
          .transition(TransitionEffect.OPACITY)
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      NavPathUtils.push(ROUTE_ABOUT);
    })
  }

  /** 深色模式行（锚点 FqMenu 三档直选）。 */
  @Builder
  private ThemeRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.moon'))
          .fontSize(17)
          .fontColor(['#FF8B5CF6'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF8B5CF6', 0.12))

      Column({ space: 3 }) {
        Text('深色模式')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('切换应用外观，即时生效')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(FQ_THEME_LABELS[this.themeMode])
        .fontSize(12.5)
        .fontColor($r('sys.color.font_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .id(FQ_THEME_ANCHOR_ID)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.openThemeMenu();
    })
  }

  /** 主题色行（锚点 FqMenu 色板直选：跟随系统/番茄橙/琥珀金/松石绿/青碧/蔚蓝/紫罗兰/樱花粉/绯红）。 */
  @Builder
  private ThemeColorRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.paintpalette'))
          .fontSize(17)
          .fontColor([appState.accentColor])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))

      Column({ space: 3 }) {
        Text('主题色')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('高亮与选中颜色，即时生效')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 6 }) {
        Row()
          .width(12)
          .height(12)
          .borderRadius(6)
          .backgroundColor(appState.accentColor)
        Text(fqThemeColorNameOf(appState.themeColorKey))
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(VerticalAlign.Center)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .id(FQ_THEME_COLOR_ANCHOR_ID)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.openThemeColorMenu();
    })
  }

  /** 智感握姿行（Toggle：开=识别握持手，播控球与底部标签栏随握持侧换边）。 */
  @Builder
  private SmartReachRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.hand_thumbsup'))
          .fontSize(17)
          .fontColor(['#FF14B8A6'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF14B8A6', 0.12))

      Column({ space: 3 }) {
        Text('智感握姿')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('识别握持手，播控球与底部标签栏随拇指可达区域换边')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: appState.smartReachEnabled })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          FqAppSettingsStore.setSmartReachEnabled(isOn);
          FqSmartReach.setEnabled(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 启动默认展示页行（锚点 FqMenu 四选项：首页/书架/我的/设置；选中项下次冷启动生效）。 */
  @Builder
  private StartupTabRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.house_fill_1'))
          .fontSize(17)
          .fontColor(['#FF22C55E'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF22C55E', 0.12))

      Column({ space: 3 }) {
        Text('启动默认展示页')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('冷启动默认打开的页面，选择后下次启动生效')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.startupTab >= 0 && this.startupTab < MENU_CONFIG.length
        ? MENU_CONFIG[this.startupTab].label : '')
        .fontSize(12.5)
        .fontColor($r('sys.color.font_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .id(FQ_STARTUP_TAB_ANCHOR_ID)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.openStartupTabMenu();
    })
  }

  /** 首页样式行（锚点 FqMenu 三选项：今日焦点/排行榜/共存；首页顶部区块即时切换）。 */
  @Builder
  private HomeStyleRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(17)
          .fontColor(['#FF0EA5E9'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF0EA5E9', 0.12))

      Column({ space: 3 }) {
        Text('首页样式')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('首页顶部展示今日焦点还是排行榜立体书架，即时生效')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.homeStyle >= 0 && this.homeStyle < FQ_HOME_STYLE_LABELS.length
        ? FQ_HOME_STYLE_LABELS[this.homeStyle] : '')
        .fontSize(12.5)
        .fontColor($r('sys.color.font_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .id(FQ_HOME_STYLE_ANCHOR_ID)
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.openHomeStyleMenu();
    })
  }

  /** 点击书籍直接进入阅读行（Toggle：开=点小说/漫画跳过详情页从进度直接开读）。 */
  @Builder
  private DirectReadRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.book_open_fill'))
          .fontSize(17)
          .fontColor(['#FFF59E0B'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FFF59E0B', 0.12))

      Column({ space: 3 }) {
        Text('点击书籍直接进入阅读')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('开启后点小说和漫画跳过详情页，从上次进度继续阅读')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: appState.directReadEnabled })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          FqAppSettingsStore.setDirectRead(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 音量键翻页行（Toggle：与小说/漫画阅读设置弹窗内开关同源同步，全局共用）。 */
  @Builder
  private VolumeKeyPagingRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.speaker_wave_2_fill'))
          .fontSize(17)
          .fontColor(['#FF0EA5E9'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF0EA5E9', 0.12))

      Column({ space: 3 }) {
        Text('音量键翻页')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('分页模式音量上/下键代替翻页，与阅读页设置内开关同步')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: appState.volumeKeyPaging })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          FqReaderStore.saveVolumeKeyPaging(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 开启后台播放行（Toggle 开关：开=支持后台播放，关=无法后台播放）。 */
  @Builder
  private BackgroundAudioRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(17)
          .fontColor(['#FF10B981'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF10B981', 0.12))

      Column({ space: 3 }) {
        Text('开启后台播放')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('开启后支持后台播放，支持播控中心和实况窗显示')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.backgroundAudio })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          this.backgroundAudio = isOn;
          FqAppSettingsStore.setBackgroundAudio(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 画中画播放行（Toggle 开关：开=视频退后台自动小窗续播，需系统智慧多窗开关配合）。 */
  @Builder
  private PipVideoRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.film'))
          .fontSize(17)
          .fontColor(['#FF06B6D4'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF06B6D4', 0.12))

      Column({ space: 3 }) {
        Text('画中画播放')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('开启后视频退后台自动小窗续播（需系统「智慧多窗」开关）')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.pipVideo })
        .selectedColor(appState.accentColor)
        .onChange((isOn: boolean): void => {
          this.pipVideo = isOn;
          FqAppSettingsStore.setPipVideoEnabled(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 页面内统一 toast。 */
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }
}

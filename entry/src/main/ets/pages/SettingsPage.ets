/**
 * 应用设置页（主 Tab 第四页 + 我的-应用设置入口共用，@Param isTab 区分）：
 * - 外观：深色模式（跟随系统/浅色/深色，FqMenu 档位直选，即时生效）；
 * - 播放：开启后台播放开关（开=支持后台播放，关=无法后台播放）；
 * - 数据：缓存与管理入口、备份与恢复入口、清除所有数据（确认弹窗提示重启，清全部 KV/缓存/设置后 restartApp）；
 * - 服务：本地后端地址展示（点击浏览器打开 + 刷新按钮）；
 * - 关于：关于我们入口。
 */

import { CommonNav } from '../view/CommonNav';
import { FqMenu, FqMenuItem } from '../view/CommonMenu';
import { CommonLoading } from '../view/CommonCom';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqTitleBarOptions, ROUTE_ABOUT, ROUTE_CACHE_MANAGE, ROUTE_LOGS, ROUTE_BACKUP } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import {
  FQ_THEME_DARK,
  FQ_THEME_FOLLOW,
  FQ_THEME_LIGHT,
  FqAppSettingsStore,
} from '../core/FqAppSettingsStore';
import { FqReaderStore } from '../core/FqReaderStore';
import { FQ_THEME_COLOR_OPTIONS, fqThemeColorOf, fqThemeColorNameOf } from '../core/FqThemeColors';
import { FqDataCleaner } from '../core/FqDataCleaner';
import { FqBackend } from '../core/FqBackend';
import { DialogManager } from '../utils/DialogUtils';
import { FqColorUtils } from '../utils/FqColorUtils';
import { appState } from '../entryability/AppState';

const FQ_HOME_TOP_INSET: number = 56;
/** 滚动内容末尾偏移：悬浮底栏 56 + 底部悬浮边距 28。 */
const FQ_SETTINGS_BOTTOM_INSET: number = 84;
const FQ_THEME_ANCHOR_ID: string = 'settings_theme_anchor';
const FQ_THEME_COLOR_ANCHOR_ID: string = 'settings_theme_color_anchor';
/** 行内分割线左右避让：左侧行 padding 14 + 图标块 34 + 间距 12，右侧对称一致。 */
const FQ_ROW_DIVIDER_INSET: number = 60;
/** 深色模式档位文案（下标即档位值）。 */
const FQ_THEME_LABELS: string[] = ['跟随系统', '浅色', '深色'];

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
  @Local backendUrl: string = '';
  @Local backendRefreshing: boolean = false;

  aboutToAppear(): void {
    this.themeMode = FqAppSettingsStore.getThemeMode();
    this.backgroundAudio = FqAppSettingsStore.isBackgroundAudio();
    this.backendUrl = FqBackend.get().baseUrl;
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('应用设置', false),
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
          }

          this.SectionHeader('阅读与播放')
          FqSettingsCard() {
            this.DirectReadRow()
            this.RowDivider()
            this.VolumeKeyPagingRow()
            this.RowDivider()
            this.BackgroundAudioRow()
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
            this.BackendRow()
            this.RowDivider()
            this.SettingRow($r('sys.symbol.list_bullet'), '#FF8B5CF6', '日志', '查看应用与核心运行日志', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_LOGS);
              })
          }

          this.SectionHeader('关于')
          FqSettingsCard() {
            this.SettingRow($r('sys.symbol.person_fill'), '#FF8B5CF6', '关于', '版本与开源信息', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_ABOUT);
              })
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

  /** 本地后端地址行：点击打开浏览器访问后端地址，右侧刷新按钮重读地址。 */
  @Builder
  private BackendRow() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.scope'))
          .fontSize(17)
          .fontColor(['#FF0EA5E9'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF0EA5E9', 0.12))

      Column({ space: 3 }) {
        Text('本地后端')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (this.backendUrl.length > 0) {
          Text(this.backendUrl)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text('未启动')
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Stack() {
        if (this.backendRefreshing) {
          CommonLoading({ sizeValue: 15, loadColor: $r('sys.color.font_secondary') })
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(15)
            .fontColor([$r('sys.color.font_secondary')])
        }
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick((): void => {
        this.refreshBackendUrl();
      })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.openBackendInBrowser();
    })
  }

  /** 打开浏览器访问内置 Web UI 入口（携带 capability，未启动时提示）。 */
  private openBackendInBrowser(): void {
    const url: string = FqBackend.get().webUiEntryUrl;
    if (this.backendUrl.length === 0 || url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '本地后端未启动', duration: 1500 });
      return;
    }
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return;
    }
    context.openLink(url, { appLinkingOnly: false }).catch((_error: BusinessError): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打开浏览器失败', duration: 1500 });
    });
  }

  /** 刷新本地后端地址（后端启动幂等：未启动/失败时重试拉起，期间按钮转 Loading）。 */
  private refreshBackendUrl(): void {
    if (this.backendRefreshing) {
      return;
    }
    this.backendRefreshing = true;
    this.backendUrl = FqBackend.get().baseUrl;
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      this.backendRefreshing = false;
      return;
    }
    const begin: number = Date.now();
    FqBackend.get().start(context)
      .then((): void => {
        this.backendUrl = FqBackend.get().baseUrl;
        this.finishBackendRefresh(begin, '');
      })
      .catch((): void => {
        // 启动失败保持原值
        this.finishBackendRefresh(begin, '本地后端启动失败');
      });
  }

  /**
   * 收尾刷新：start 命中缓存 Promise 时微任务内即完成，Loading 一帧都渲染
   * 不到（表现为“点了没反应”），故保证最少转 500ms，并给出结果 toast。
   */
  private finishBackendRefresh(begin: number, failedMessage: string): void {
    const elapsed: number = Date.now() - begin;
    const remainMs: number = elapsed >= 500 ? 0 : 500 - elapsed;
    setTimeout((): void => {
      this.backendRefreshing = false;
      if (failedMessage.length > 0) {
        this.toast(failedMessage);
      } else {
        this.toast('已刷新');
      }
    }, remainMs);
  }

  /** 页面内统一 toast。 */
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }
}

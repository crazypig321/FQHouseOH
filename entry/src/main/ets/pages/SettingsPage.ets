/**
 * 应用设置页（主 Tab 第四页 + 我的-应用设置入口共用，@Param isTab 区分）：
 * - 外观：深色模式（跟随系统/浅色/深色，FqMenu 档位直选，即时生效）；
 * - 播放：开启后台播放开关（开=支持后台播放，关=无法后台播放）；
 * - 数据：章节缓存/剧集缓存入口、清空历史（确认弹窗，清浏览+收听+观看+统计）；
 * - 服务：本地后端地址展示；
 * - 关于：关于我们入口。
 */

import { CommonNav } from '../view/CommonNav';
import { FqMenu, FqMenuItem } from '../view/CommonMenu';
import { FQ_ACCENT } from '../view/CommonCom';
import { FqTitleBarOptions, ROUTE_ABOUT, ROUTE_CACHED_BOOKS, ROUTE_CACHED_DRAMAS } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import {
  FQ_THEME_DARK,
  FQ_THEME_FOLLOW,
  FQ_THEME_LIGHT,
  FqAppSettingsStore,
} from '../core/FqAppSettingsStore';
import { FqAudioHistory } from '../core/FqAudioHistory';
import { FqBrowseStore } from '../core/FqBrowseStore';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqWatchedStore } from '../core/FqWatchedStore';
import { FqBackend } from '../core/FqBackend';
import { DialogManager } from '../utils/DialogUtils';
import { FqColorUtils } from '../utils/FqColorUtils';
import { appState } from '../entryability/AppState';

const FQ_HOME_TOP_INSET: number = 56;
/** 滚动内容末尾偏移：悬浮底栏 56 + 底部悬浮边距 28。 */
const FQ_SETTINGS_BOTTOM_INSET: number = 84;
const FQ_THEME_ANCHOR_ID: string = 'settings_theme_anchor';
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
          }

          this.SectionHeader('播放')
          FqSettingsCard() {
            this.BackgroundAudioRow()
          }

          this.SectionHeader('数据')
          FqSettingsCard() {
            this.SettingRow($r('sys.symbol.book'), '#FF3B82F6', '章节缓存', '已下载的书籍章节', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_CACHED_BOOKS);
              })
            this.RowDivider()
            this.SettingRow($r('sys.symbol.film'), '#FFEF5038', '剧集缓存', '已下载的剧集视频', '', true,
              (): void => {
                NavPathUtils.push(ROUTE_CACHED_DRAMAS);
              })
            this.RowDivider()
            this.SettingRow($r('sys.symbol.trash'), '#FFF43F5E', '清空历史', '浏览、收听、观看与统计记录', '', true,
              (): void => {
                this.confirmClearHistory();
              })
          }

          this.SectionHeader('服务')
          FqSettingsCard() {
            this.BackendRow()
          }

          this.SectionHeader('关于')
          FqSettingsCard() {
            this.SettingRow($r('sys.symbol.person_fill'), '#FF8B5CF6', '关于我们', '版本与开源信息', '', true,
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
        item.endIcon = $r('sys.symbol.checkmark_circle_fill');
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

  private confirmClearHistory(): void {
    DialogManager.ShowConfirm('清空历史', '将清空浏览、收听、观看与统计记录，且不可恢复', '清空', (): void => {
      FqBrowseStore.clear();
      FqAudioHistory.clear();
      FqWatchedStore.clear();
      FqReadStatsStore.clear();
      this.getUIContext().getPromptAction().showToast({ message: '已清空历史记录', duration: 1500 });
    });
  }

  @Builder
  private SectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(3.5)
        .height(15)
        .borderRadius(2)
        .backgroundColor(FQ_ACCENT)
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
        .selectedColor(FQ_ACCENT)
        .onChange((isOn: boolean): void => {
          this.backgroundAudio = isOn;
          FqAppSettingsStore.setBackgroundAudio(isOn);
        })
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }

  /** 本地后端地址行（只读展示）。 */
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
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
  }
}

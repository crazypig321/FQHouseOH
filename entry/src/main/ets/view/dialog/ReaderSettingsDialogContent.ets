/**
 * 「阅读设置」弹窗内容（经 utils/DialogUtils 的 DialogManager.OpenDialog('阅读设置') 打开，
 * 由宿主页 CustomContentDialog 装配：无标题无按钮仅内容区，悬于工具条上方居中）：
 * 字号/行距/主题/字体/翻页五行；当前值经 @Param 注入、变更经 @Event 回调宿主页；
 * 配色跟随系统深浅色（弹窗卡片为系统色），阅读主题常量集中于此导出供宿主页共用。
 */
import { FQ_ACCENT } from '../CommonCom';
import { FQ_FONT_OPTIONS, FqFontOption } from '../../core/FqOnlineParser';
import { appState } from '../../entryability/AppState';
import { themeUtils } from '../../utils/ThemeUtils';

/** 阅读主题：themeColor 仅支持 6 位色值（无透明度）。 */
export interface FqReaderTheme {
  readonly fontColor: string;
  readonly background: string;
  readonly night: boolean;
  readonly label: string;
}

/** 阅读主题档位（下标与 themeIndex 对应，-1 为跟随系统）。 */
export const FQ_READER_THEMES: FqReaderTheme[] = [
  { fontColor: '#1F2329', background: '#F6F4EF', night: false, label: '纸白' },
  { fontColor: '#3E2F1C', background: '#F0E4C8', night: false, label: '米黄' },
  { fontColor: '#9AA0A6', background: '#151719', night: true, label: '夜间' },
];

/** 翻页模式标签（下标与 flipIndex 对应）。 */
export const FQ_READER_FLIP_LABELS: string[] = ['仿真', '横滑'];

/** 生效阅读主题（-1 跟随系统：深色→夜间，浅色→纸白；供弹窗宿主计算跟随色卡预览）。 */
export function fqEffectiveReaderTheme(themeIndex: number, systemDark: boolean): FqReaderTheme {
  const index: number = themeIndex === -1 ? (systemDark ? 2 : 0) : themeIndex;
  return FQ_READER_THEMES[index] ?? FQ_READER_THEMES[0];
}

@ComponentV2
export struct ReaderSettingsDialogContent {
  @Param fontSize: number = 19;
  @Param lineHeight: number = 1.9;
  @Param themeIndex: number = 0;
  @Param flipIndex: number = 0;
  @Param fontIndex: number = 0;
  /** 「跟随系统」色卡预览背景（当前生效主题背景）。 */
  @Param followThemeBg: string = '#F6F4EF';
  /** 「跟随系统」色卡预览字色（当前生效主题字色）。 */
  @Param followThemeFont: string = '#1F2329';
  @Event fontSizeChange: (delta: number) => void = (_delta: number): void => {};
  @Event lineHeightChange: (delta: number) => void = (_delta: number): void => {};
  @Event themeChange: (index: number) => void = (_index: number): void => {};
  @Event fontChange: (index: number) => void = (_index: number): void => {};
  @Event flipChange: (index: number) => void = (_index: number): void => {};

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('字号')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        this.SettingChip('A-', (): void => {
          this.fontSizeChange(-1);
        })
        Text(`${this.fontSize}`)
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(32)
          .textAlign(TextAlign.Center)
        this.SettingChip('A+', (): void => {
          this.fontSizeChange(1);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('行距')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        this.SettingChip('-', (): void => {
          this.lineHeightChange(-0.1);
        })
        Text(`${this.lineHeight.toFixed(1)}`)
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(32)
          .textAlign(TextAlign.Center)
        this.SettingChip('+', (): void => {
          this.lineHeightChange(0.1);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('主题')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Column({ space: 4 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.sun_max'))
              .fontSize(18)
              .fontColor([this.followThemeFont])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.followThemeBg)
          .border({
            width: this.themeIndex === -1 ? 2 : 1,
            color: this.themeIndex === -1 ? FQ_ACCENT : themeUtils.terTextColor,
          })
          .justifyContent(FlexAlign.Center)
          Text('跟随')
            .fontSize(10)
            .fontColor(themeUtils.textColor)
            .opacity(this.themeIndex === -1 ? 1 : 0.6)
        }
        .alignItems(HorizontalAlign.Center)
        .onClick((): void => {
          this.themeChange(-1);
        })
        ForEach(FQ_READER_THEMES, (theme: FqReaderTheme, index: number) => {
          Column({ space: 4 }) {
            Column()
              .width(34)
              .height(34)
              .borderRadius(17)
              .backgroundColor(theme.background)
              .border({
                width: this.themeIndex === index ? 2 : 1,
                color: this.themeIndex === index ? FQ_ACCENT : themeUtils.terTextColor,
              })
            Text(theme.label)
              .fontSize(10)
              .fontColor(themeUtils.textColor)
              .opacity(this.themeIndex === index ? 1 : 0.6)
          }
          .alignItems(HorizontalAlign.Center)
          .onClick((): void => {
            this.themeChange(index);
          })
        }, (theme: FqReaderTheme): string => theme.label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('字体')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        ForEach(FQ_FONT_OPTIONS, (option: FqFontOption, index: number) => {
          Text(option.label)
            .fontSize(12)
            .fontColor(this.fontIndex === index ? '#FFFFFF' : themeUtils.textColor)
            .backgroundColor(this.fontIndex === index ? FQ_ACCENT : 'transparent')
            .borderRadius(13)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.fontChange(index);
            })
        }, (option: FqFontOption): string => option.label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('翻页')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        ForEach(FQ_READER_FLIP_LABELS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontColor(this.flipIndex === index ? '#FFFFFF' : themeUtils.textColor)
            .backgroundColor(this.flipIndex === index ? FQ_ACCENT : 'transparent')
            .borderRadius(13)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.flipChange(index);
            })
        }, (label: string): string => label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 设置圆形按钮（字号/行距增减），背景随系统深浅色。 */
  @Builder
  private SettingChip(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(themeUtils.textColor)
      .width(34)
      .height(34)
      .borderRadius(17)
      .textAlign(TextAlign.Center)
      .backgroundColor(appState.isDark ? '#2A2D30' : '#E8E2D4')
      .onClick((): void => {
        action();
      })
  }
}

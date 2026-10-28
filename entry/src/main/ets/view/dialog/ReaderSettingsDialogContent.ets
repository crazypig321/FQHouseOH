/**
 * 「阅读设置」弹窗内容（经 utils/DialogUtils 的 DialogManager.OpenDialog('阅读设置') 打开，
 * 由宿主页 CustomContentDialog 装配：无标题无按钮仅内容区，悬于工具条上方居中）：
 * 字号/行距/主题/字体/翻页/段评六行；当前值经 @Param 注入、变更经 @Event 回调宿主页；
 * 主题行为「添加」固定卡片 + 横向滚动 List + ForEach（@Computed 选项，键含名称/图路径，改名换图即重建）：
 * 预设档 + 自定义主题列表（缩略图按应生效模式取图）；添加卡片固定在前，滑动主题时不随滚动划走；
 * 配色跟随系统深浅色（弹窗卡片为系统色），阅读主题常量集中于此导出供宿主页共用。
 */
import { FQ_FONT_OPTIONS, FqFontOption } from '../../core/FqOnlineParser';
import { FqCustomReaderTheme, fqCustomThemeUseDark } from '../../core/FqReaderStore';
import { FqAppSettingsStore, FQ_THEME_DARK, FQ_THEME_LIGHT } from '../../core/FqAppSettingsStore';
import { appState } from '../../entryability/AppState';
import { themeUtils } from '../../utils/ThemeUtils';
import { SettingChip } from '../CommonCom';

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
export const FQ_READER_FLIP_LABELS: string[] = ['仿真', '横滑', '上下'];

/** 生效阅读主题（-1 跟随系统：深色→夜间，浅色→纸白；3 自定义背景图：字色随系统；供弹窗宿主计算跟随色卡预览）。 */
export function fqEffectiveReaderTheme(themeIndex: number, systemDark: boolean): FqReaderTheme {
  const index: number = themeIndex === -1 || themeIndex === 3 ? (systemDark ? 2 : 0) : themeIndex;
  return FQ_READER_THEMES[index] ?? FQ_READER_THEMES[0];
}

/** 主题行选项：预设档 / 自定义主题。 */
export class FqThemeOption {
  /** 'preset' 预设档 / 'custom' 自定义主题。 */
  kind: string = 'preset';
  /** 预设档主题下标（-1 跟随 / 0 纸白 / 1 米黄 / 2 夜间）。 */
  presetIndex: number = 0;
  /** 自定义主题条目（kind='custom' 时非空）。 */
  custom: FqCustomReaderTheme | null = null;
}

@ComponentV2
export struct ReaderSettingsDialogContent {
  @Param fontSize: number = 19;
  @Param lineHeight: number = 1.9;
  @Param themeIndex: number = 0;
  @Param flipIndex: number = 0;
  @Param fontIndex: number = 0;
  /** 段评显示开关（关闭后不显示段评气泡与计数）。 */
  @Param showParagraphComment: boolean = true;
  /** 自定义阅读主题列表（数组整体替换，经 @Monitor 同步数据源）。 */
  @Param customThemes: FqCustomReaderTheme[] = [];
  /** 当前选中的自定义主题 id（themeIndex=3 时生效）。 */
  @Param customThemeId: string = '';
  /** 「跟随系统」色卡预览背景（当前生效主题背景）。 */
  @Param followThemeBg: string = '#F6F4EF';
  /** 「跟随系统」色卡预览字色（当前生效主题字色）。 */
  @Param followThemeFont: string = '#1F2329';
  @Event fontSizeChange: (delta: number) => void = (_delta: number): void => {};
  @Event lineHeightChange: (delta: number) => void = (_delta: number): void => {};
  @Event themeChange: (index: number) => void = (_index: number): void => {};
  @Event fontChange: (index: number) => void = (_index: number): void => {};
  @Event flipChange: (index: number) => void = (_index: number): void => {};
  @Event showParagraphCommentChange: (on: boolean) => void = (_on: boolean): void => {};
  /** 图库选图新增自定义主题。 */
  @Event addCustomThemeChange: () => void = (): void => {};
  /** 选中指定自定义主题。 */
  @Event selectCustomThemeChange: (id: string) => void = (_id: string): void => {};
  /** 长按自定义主题：编辑参数（名称/字色/字号/字体/行距）。 */
  @Event editCustomThemeChange: (id: string) => void = (_id: string): void => {};

  /** 主题行滚动选项（预设 4 项 + 自定义主题列表；key 含名称/图路径，改名即重建项）。「添加」卡片固定在列表前端不随滚动。 */
  @Computed
  get themeOptions(): FqThemeOption[] {
    const options: FqThemeOption[] = [];
    const presetIndexes: number[] = [-1, 0, 1, 2];
    for (const presetIndex of presetIndexes) {
      const option: FqThemeOption = new FqThemeOption();
      option.kind = 'preset';
      option.presetIndex = presetIndex;
      options.push(option);
    }
    for (const theme of this.customThemes) {
      const option: FqThemeOption = new FqThemeOption();
      option.kind = 'custom';
      option.custom = theme;
      options.push(option);
    }
    return options;
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('字号')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        SettingChip($r('sys.symbol.minus'), (): void => {
          this.fontSizeChange(-1);
        })
        Text(`${this.fontSize}`)
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(20)
          .textAlign(TextAlign.Center)
        SettingChip($r('sys.symbol.plus'), (): void => {
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
        SettingChip($r('sys.symbol.minus'), (): void => {
          this.lineHeightChange(-0.1);
        })
        Text(`${this.lineHeight.toFixed(1)}`)
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(20)
          .textAlign(TextAlign.Center)
        SettingChip($r('sys.symbol.plus'), (): void => {
          this.lineHeightChange(0.1);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('主题')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        this.AddThemeCard()
        List({ space: 12 }) {
          ForEach(this.themeOptions, (option: FqThemeOption) => {
            ListItem() {
              this.ThemeOptionView(option)
            }
          }, (option: FqThemeOption): string => this.optionKeyOf(option))
        }
        .listDirection(Axis.Horizontal)
        .layoutWeight(1)
        .height(54)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .alignListItem(ListItemAlign.Center)
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
            .backgroundColor(this.fontIndex === index ? appState.accentColor : 'transparent')
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
            .backgroundColor(this.flipIndex === index ? appState.accentColor : 'transparent')
            .borderRadius(13)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick((): void => {
              this.flipChange(index);
            })
        }, (label: string): string => label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Text('段评')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Text(this.showParagraphComment ? '显示段评气泡与评论数' : '不显示段评气泡与评论数')
          .fontSize(12)
          .fontColor(themeUtils.terTextColor)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.showParagraphComment })
          .selectedColor(appState.accentColor)
          .switchPointColor(Color.White)
          .onChange((isOn: boolean): void => {
            this.showParagraphCommentChange(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 主题行选项键（ForEach 稳定键：自定义主题键含名称/双模式图路径，改名或换图即重建该项）。 */
  private optionKeyOf(option: FqThemeOption): string {
    if (option.kind === 'custom' && option.custom !== null) {
      return `c_${option.custom.id}_${option.custom.name}_${option.custom.lightBgPath}_${option.custom.darkBgPath}`;
    }
    return `p_${option.presetIndex}`;
  }

  /** 自定义主题缩略图：按当前应生效模式（应用强制深/浅或系统深浅）取背景图。 */
  private thumbPathOf(theme: FqCustomReaderTheme): string {
    const mode: number = FqAppSettingsStore.getThemeMode();
    const baseDark: boolean = mode === FQ_THEME_DARK ? true
      : (mode === FQ_THEME_LIGHT ? false : appState.isDark);
    return fqCustomThemeUseDark(theme, baseDark) ? theme.darkBgPath : theme.lightBgPath;
  }

  /** 主题行选项卡片：34 色位 + 名称标签（自定义主题显示背景图缩略图，长按编辑）。 */
  @Builder
  private ThemeOptionView(option: FqThemeOption) {
    if (option.kind === 'preset') {
      Column({ space: 4 }) {
        if (option.presetIndex === -1) {
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
            color: this.themeIndex === -1 ? appState.accentColor : themeUtils.terTextColor,
          })
          .justifyContent(FlexAlign.Center)
        } else {
          Column()
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor(FQ_READER_THEMES[option.presetIndex].background)
            .border({
              width: this.themeIndex === option.presetIndex ? 2 : 1,
              color: this.themeIndex === option.presetIndex ? appState.accentColor : themeUtils.terTextColor,
            })
        }
        Text(option.presetIndex === -1 ? '跟随' : FQ_READER_THEMES[option.presetIndex].label)
          .fontSize(10)
          .fontColor(themeUtils.textColor)
          .opacity(this.themeIndex === option.presetIndex ? 1 : 0.6)
      }
      .alignItems(HorizontalAlign.Center)
      .onClick((): void => {
        this.themeChange(option.presetIndex);
      })
    } else if (option.kind === 'custom' && option.custom !== null) {
      Column({ space: 4 }) {
        Stack() {
          Image(`file://${this.thumbPathOf(option.custom)}`)
            .objectFit(ImageFit.Cover)
            .width(34)
            .height(34)
            .draggable(false)
          if (this.themeIndex === 3 && this.customThemeId === option.custom.id) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontColor([appState.accentColor])
          }
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .clip(true)
        .border({
          width: this.themeIndex === 3 && this.customThemeId === option.custom.id ? 2 : 1,
          color: this.themeIndex === 3 && this.customThemeId === option.custom.id
            ? appState.accentColor : themeUtils.terTextColor,
        })
        Text(option.custom.name)
          .fontSize(10)
          .fontColor(themeUtils.textColor)
          .opacity(this.themeIndex === 3 && this.customThemeId === option.custom.id ? 1 : 0.6)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 44 })
      }
      .alignItems(HorizontalAlign.Center)
      .onClick((): void => {
        this.selectCustomThemeChange(option.custom !== null ? option.custom.id : '');
      })
      .gesture(LongPressGesture()
        .onAction((): void => {
          this.editCustomThemeChange(option.custom !== null ? option.custom.id : '');
        }))
    }
  }

  /** 「添加」固定卡片：置于主题滚动列表前端，滑动主题时不随滚动划走。 */
  @Builder
  private AddThemeCard() {
    Column({ space: 4 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([themeUtils.terTextColor])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor($r('app.color.reader_chip_bg'))
      .border({
        width: 1,
        color: themeUtils.terTextColor,
        style: BorderStyle.Dashed,
      })
      .justifyContent(FlexAlign.Center)
      Text('添加')
        .fontSize(10)
        .fontColor(themeUtils.textColor)
        .opacity(0.6)
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ right: 4 })
    .onClick((): void => {
      this.addCustomThemeChange();
    })
  }
}

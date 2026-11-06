/**
 * 弹幕设置面板（对齐 fqapp playlet_danmaku_settings：不透明度/速度/显示区域/字号
 * 四滑杆 + 弹幕背景透明开关）：设置 sheet（浅色）与横屏/PC 侧边栏（深色）共用，
 * dark 控配色；「恢复默认」由宿主标题栏按钮触发（CommonSheet showReset /
 * FqPlayerSidebar showReset），不在面板内。
 */
import {
  FQ_DANMAKU_ALPHA_MIN_PERCENT,
  FQ_DANMAKU_ALPHA_MAX_PERCENT,
  FQ_DANMAKU_SPEED_LABELS,
  FQ_DANMAKU_SIZE_LABELS,
  FQ_DANMAKU_LINE_SPACE_LABELS,
} from '../../core/FqAppSettingsStore';
import { appState } from '../../entryability/AppState';

/** 官方短剧橙（滑杆 block/选中/当前值文本）。 */
const FQ_STORY_ORANGE: string = '#FFFA6725';
/** 深色宿主卡片底。 */
const FQ_DARK_CARD_BG: string = '#26FFFFFF';
/** 深色宿主分隔线。 */
const FQ_DARK_DIVIDER: string = '#1FFFFFFF';
/** 深色宿主滑杆轨道。 */
const FQ_DARK_TRACK: string = '#33FFFFFF';
/** 深色宿主次级文本。 */
const FQ_DARK_TERTIARY_TEXT: string = '#99FFFFFF';

@ComponentV2
export struct FqDanmakuSettingsPanel {
  /** 深色宿主（横屏全屏/PC 侧边栏）配色开关；浅色（设置 sheet）为 false。 */
  @Param dark: boolean = false;
  /** 「显示区域」行语义：true 横屏片源（单行/1/4屏/1/2屏/3/4屏）；false 竖屏片源（1-4 行）。 */
  @Param isLandscape: boolean = false;
  /** 弹幕不透明度（%，20-100，fqapp 默认 100）。 */
  @Param alphaPercent: number = 100;
  /** 弹幕速度档（1-5，fqapp 默认 3）。 */
  @Param speedTier: number = 3;
  /** 竖屏弹幕行数（1-4 行，fqapp 默认 4）。 */
  @Param lineCount: number = 4;
  /** 横屏弹幕显示区域档（1-4，fqapp 默认 2）。 */
  @Param lineSpaceTier: number = 2;
  /** 弹幕字号档（1-5，fqapp 默认 3）。 */
  @Param sizeTier: number = 3;
  /** 弹幕背景透明（不画官方 40% 黑底气泡）。 */
  @Param bgTransparent: boolean = false;
  @Event alphaChange: (value: number) => void = (_value: number): void => {};
  @Event speedTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event lineCountChange: (count: number) => void = (_count: number): void => {};
  @Event lineSpaceTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event sizeTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event bgTransparentChange: (on: boolean) => void = (_on: boolean): void => {};

  build() {
    Column() {
      List() {
        ListItemGroup() {
          // 不透明度（20-100% 连续滑杆，实时生效）
          ListItem() {
            FqDanmakuSliderRow({
              dark: this.dark,
              label: '不透明度',
              sliderValue: this.alphaPercent,
              minValue: FQ_DANMAKU_ALPHA_MIN_PERCENT,
              maxValue: FQ_DANMAKU_ALPHA_MAX_PERCENT,
              stepValue: 1,
              showTicks: false,
              valueLabel: `${this.alphaPercent}%`,
              tickLabels: [],
              commit: (value: number): void => {
                this.alphaChange(value);
              },
            })
          }

          // 弹幕速度（5 档：慢/较慢/适中/较快/快）
          ListItem() {
            FqDanmakuSliderRow({
              dark: this.dark,
              label: '弹幕速度',
              sliderValue: this.speedTier - 1,
              minValue: 0,
              maxValue: 4,
              stepValue: 1,
              showTicks: true,
              valueLabel: FQ_DANMAKU_SPEED_LABELS[this.speedTier - 1],
              tickLabels: FQ_DANMAKU_SPEED_LABELS,
              commit: (value: number): void => {
                this.speedTierChange(value + 1);
              },
            })
          }

          if (this.isLandscape) {
            // 显示区域（横屏片源全屏：单行/1/4屏/1/2屏/3/4屏）
            ListItem() {
              FqDanmakuSliderRow({
                dark: this.dark,
                label: '显示区域',
                sliderValue: this.lineSpaceTier - 1,
                minValue: 0,
                maxValue: 3,
                stepValue: 1,
                showTicks: true,
                valueLabel: FQ_DANMAKU_LINE_SPACE_LABELS[this.lineSpaceTier - 1],
                tickLabels: FQ_DANMAKU_LINE_SPACE_LABELS,
                commit: (value: number): void => {
                  this.lineSpaceTierChange(value + 1);
                },
              })
            }
          } else {
            // 显示区域（竖屏片源全屏：1-4 行）
            ListItem() {
              FqDanmakuSliderRow({
                dark: this.dark,
                label: '显示区域',
                sliderValue: this.lineCount - 1,
                minValue: 0,
                maxValue: 3,
                stepValue: 1,
                showTicks: true,
                valueLabel: `${this.lineCount}行`,
                tickLabels: ['1行', '2行', '3行', '4行'],
                commit: (value: number): void => {
                  this.lineCountChange(value + 1);
                },
              })
            }
          }

          // 字号（5 档：小/较小/适中/较大/大）
          ListItem() {
            FqDanmakuSliderRow({
              dark: this.dark,
              label: '字号',
              sliderValue: this.sizeTier - 1,
              minValue: 0,
              maxValue: 4,
              stepValue: 1,
              showTicks: true,
              valueLabel: FQ_DANMAKU_SIZE_LABELS[this.sizeTier - 1],
              tickLabels: FQ_DANMAKU_SIZE_LABELS,
              commit: (value: number): void => {
                this.sizeTierChange(value + 1);
              },
            })
          }

          // 弹幕背景透明（本地开关：不画官方 40% 黑底气泡）
          ListItem() {
            Row() {
              Text('弹幕背景透明')
                .fontSize(15)
                .fontColor(this.dark ? Color.White : $r('sys.color.font'))
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.bgTransparent })
                .selectedColor(FQ_STORY_ORANGE)
                .onChange((isOn: boolean): void => {
                  this.bgTransparentChange(isOn);
                })
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)
          }
        }
        .borderRadius(14)
        .backgroundColor(this.dark ? FQ_DARK_CARD_BG : $r('sys.color.comp_background_list_card'))
        .divider({
          strokeWidth: 0.5,
          color: this.dark ? FQ_DARK_DIVIDER : $r('sys.color.comp_divider'),
          startMargin: 16,
          endMargin: 16
        })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .padding({ left: 20, right: 20 })
      // 深色侧边栏：内容避让状态栏 + 标题栏（浅色 sheet 由 CommonSheet 已 padding 66）
      .contentStartOffset(this.dark ? appState.topRect + 56 : 0)
      .contentEndOffset(appState.bottomRect === 0 ? 16 : appState.bottomRect)
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 弹幕设置滑杆行：标题 + 当前值（左标题右值）+ 步进滑杆 +（可选）档位刻度文本行。
 * 松手/点按提交 commit（对齐 fqapp 拖动结束生效语义）。
 * 独立 @ComponentV2（@Param 响应链）：@Builder 按值传参不随状态刷新
 * （「恢复默认」落新值后滑杆/文案不更新），组件化后 @Param 变化即时重渲染。
 */
@ComponentV2
struct FqDanmakuSliderRow {
  /** 深色宿主配色开关。 */
  @Param dark: boolean = false;
  /** 行标题。 */
  @Param label: string = '';
  /** 滑杆当前值。 */
  @Param sliderValue: number = 0;
  /** 滑杆最小值。 */
  @Param minValue: number = 0;
  /** 滑杆最大值。 */
  @Param maxValue: number = 100;
  /** 步进。 */
  @Param stepValue: number = 1;
  /** 是否绘制步进刻度点。 */
  @Param showTicks: boolean = false;
  /** 当前值文案（标题行右侧）。 */
  @Param valueLabel: string = '';
  /** 档位刻度文本行（空数组不显示）。 */
  @Param tickLabels: string[] = [];
  /** 松手/点按提交。 */
  @Event commit: (value: number) => void = (_value: number): void => {};

  build() {
    Column({ space: 2 }) {
      Row() {
        Text(this.label)
          .fontSize(15)
          .fontColor(this.dark ? Color.White : $r('sys.color.font'))

        Text(this.valueLabel)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(FQ_STORY_ORANGE)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Slider({
        value: this.sliderValue,
        min: this.minValue,
        max: this.maxValue,
        step: this.stepValue,
        style: SliderStyle.InSet
      })
        .width('100%')
        .height(30)
        .showSteps(this.showTicks)
        .stepColor(this.dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
        .blockColor(FQ_STORY_ORANGE)
        .selectedColor('#33FA6725')
        .trackColor(this.dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
        .onChange((sliderValue: number, mode: SliderChangeMode): void => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.commit(sliderValue);
          }
        })

      if (this.tickLabels.length > 0) {
        Row() {
          ForEach(this.tickLabels, (tick: string) => {
            Text(tick)
              .fontSize(7)
              .fontColor(this.dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_tertiary'))
          }, (tick: string) => tick)
        }
        .justifyContent(FlexAlign.SpaceBetween)
        .width('100%')
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 8 })
  }
}

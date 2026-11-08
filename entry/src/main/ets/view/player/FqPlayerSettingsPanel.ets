/**
 * 播放设置面板（公共 FqSettingRow 设置行 List：倍速滑杆/解码方式菜单/离线缓存/听视频/
 * 弹幕开关/弹幕设置）：设置 sheet（浅色）与横屏全屏侧边栏（深色）共用，dark 控配色。
 * 行点击/滑杆/开关经 @Event 回调宿主（PlayerPage 持有播放器与业务状态）。
 */
import { FqSettingRow } from '../FqSettingRow';
import { FqMenu, FqMenuItem } from '../CommonMenu';
import { appState } from '../../entryability/AppState';

/** 官方短剧橙（当前倍速/滑杆 block/选中轨道）。 */
const FQ_STORY_ORANGE: string = '#FFFA6725';
/** 解码方式菜单锚点（右侧当前值 + 箭头触发）。 */
const FQ_SETTINGS_HWDEC_ANCHOR_ID: string = 'player_settings_hwdec_anchor';
/** 播放设置倍速滑杆范围与步进（0.5-2.0、步进 0.25）。 */
const FQ_SPEED_MIN: number = 0.5;
const FQ_SPEED_MAX: number = 2.0;
const FQ_SPEED_STEP: number = 0.25;
/** 倍速滑杆断点档数（0.5-2.0 步进 0.25，共 7 档）。 */
const FQ_SPEED_STEP_COUNT: number = 7;
/** 深色宿主卡片底/分隔线/滑杆轨道/次级文本。 */
const FQ_DARK_CARD_BG: string = '#26FFFFFF';
const FQ_DARK_DIVIDER: string = '#1FFFFFFF';
const FQ_DARK_TRACK: string = '#33FFFFFF';
const FQ_DARK_TERTIARY_TEXT: string = '#99FFFFFF';

/** 倍速滑杆断点值（0.5 → 2.0 步进 0.25）。 */
function fqSpeedSteps(): number[] {
  const steps: number[] = [];
  for (let i: number = 0; i < FQ_SPEED_STEP_COUNT; i++) {
    steps.push(FQ_SPEED_MIN + i * FQ_SPEED_STEP);
  }
  return steps;
}

/** 倍速断点显示文案（去尾零，如 0.75× / 1× / 1.5×）。 */
function fqSpeedStepLabel(step: number): string {
  const rounded: number = Math.round(step * 100) / 100;
  return `${rounded}×`;
}

/** 播放设置行描述（key 决定右侧控件：speed 滑杆 / cache、listen、danmakuSettings 箭头 / danmaku 开关）。 */
class FqSettingItem {
  readonly key: string;
  readonly title: string;
  readonly icon: Resource;

  constructor(key: string, title: string, icon: Resource) {
    this.key = key;
    this.title = title;
    this.icon = icon;
  }
}

@ComponentV2
export struct FqPlayerSettingsPanel {
  /** 深色宿主（横屏全屏侧边栏）配色开关；浅色（设置 sheet）为 false。 */
  @Param dark: boolean = false;
  /** mpv 当前倍速。 */
  @Param speed: number = 1;
  /** 倍速滑杆拖动预览值（-1 未拖动；拖动中文案实时跟随，松手提交 mpv）。 */
  @Param speedPreview: number = -1;
  /** 弹幕开关。 */
  @Param danmakuOn: boolean = true;
  /** 解码方式（true 硬解 ohcodec / false 软解 FFmpeg）。 */
  @Param hwdecOn: boolean = true;
  /** 倍速松手/点按提交（宿主调 mpv setSpeed）。 */
  @Event speedCommit: (value: number) => void = (_value: number): void => {};
  /** 倍速拖动预览（宿主更新 speedPreview 驱动文案高亮）。 */
  @Event speedPreviewChange: (value: number) => void = (_value: number): void => {};
  /** 弹幕开关切换（宿主 toggleDanmaku，含官方 Toast 文案）。 */
  @Event danmakuToggle: (on: boolean) => void = (_on: boolean): void => {};
  /** 解码方式切换（宿主 setHwDecode：mpv 运行时切 hwdec + 持久化）。 */
  @Event hwdecToggle: (on: boolean) => void = (_on: boolean): void => {};
  /** 设置行点击（cache/listen/share/danmakuSettings；倍速/弹幕行右侧控件自理）。 */
  @Event rowClick: (key: string) => void = (_key: string): void => {};

  build() {
    List() {
      ListItemGroup() {
        ForEach(this.settingItems(), (item: FqSettingItem) => {
          ListItem() {
            FqSettingRow({
              icon: item.icon,
              title: item.title,
              tintColor: this.dark ? Color.White : $r('sys.color.font'),
              click: (): void => {
                this.rowClick(item.key);
              }
            }) {
              if (item.key === 'speed') {
                // 倍速：滑杆切换（轨道分段刻度 + 断点倍速文本标识；拖动实时预览，松手提交 mpv）
                Column({ space: 2 }) {
                  Slider({
                    value: this.speed,
                    min: FQ_SPEED_MIN,
                    max: FQ_SPEED_MAX,
                    step: FQ_SPEED_STEP,
                    style: SliderStyle.InSet
                  })
                    .width('100%')
                    .height(30)
                    .showSteps(true)
                    .stepColor(this.dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
                    .blockColor(FQ_STORY_ORANGE)
                    .selectedColor('#33FA6725')
                    .trackColor(this.dark ? FQ_DARK_TRACK : $r('sys.color.comp_background_tertiary'))
                    .onChange((value: number, mode: SliderChangeMode): void => {
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.speedCommit(value);
                      } else {
                        this.speedPreviewChange(value);
                      }
                    })

                  // 断点倍速文本标识：第 i 档锚定在 i/(档数-1)*100% 处，与滑杆刻度两端对齐
                  Row() {
                    ForEach(fqSpeedSteps(), (step: number) => {
                      Text(fqSpeedStepLabel(step))
                        .fontSize(7)
                        .fontWeight(this.isCurrentSpeedStep(step) ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(this.isCurrentSpeedStep(step) ? FQ_STORY_ORANGE :
                          (this.dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_tertiary')))
                    }, (step: number) => `${step}`)
                  }
                  .justifyContent(FlexAlign.SpaceBetween)
                  .width('100%')
                  .hitTestBehavior(HitTestMode.None)
                }.layoutWeight(1)
              } else if (item.key === 'hwdec') {
                // 解码方式：当前值 + 公共 FqMenu 直选（硬件解码/软件解码，当前方式尾勾；
                // 选中即切 mpv 运行时 hwdec + 持久化，同全屏底栏解码菜单）
                Row({ space: 3 }) {
                  Text(this.hwdecOn ? '硬解' : '软解')
                    .fontSize(12.5)
                    .fontColor(this.dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_secondary'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(13)
                    .fontColor([this.dark ? FQ_DARK_TERTIARY_TEXT : $r('sys.color.font_tertiary')])
                }
                .id(FQ_SETTINGS_HWDEC_ANCHOR_ID)
                .onClick((): void => {
                  this.openHwdecMenu();
                })
              } else if (item.key === 'danmaku') {
                // 弹幕开关：Switch（宿主 toggleDanmaku，含官方 Toast 文案）
                Toggle({ type: ToggleType.Switch, isOn: this.danmakuOn })
                  .selectedColor(FQ_STORY_ORANGE)
                  .onChange((isOn: boolean): void => {
                    if (isOn !== this.danmakuOn) {
                      this.danmakuToggle(isOn);
                    }
                  })
              } else {
                // 离线缓存/听视频/弹幕设置：跳转箭头
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([this.dark ? '#99FFFFFF' : $r('sys.color.font_tertiary')])
              }
            }
          }
        }, (item: FqSettingItem) => item.key)
      }
      .borderRadius(14)
      .backgroundColor(this.dark ? FQ_DARK_CARD_BG : $r('sys.color.comp_background_list_card'))
      .divider({
        strokeWidth: 0.5,
        color: this.dark ? FQ_DARK_DIVIDER : $r('sys.color.comp_divider'),
        startMargin: 48,
        endMargin: 14
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .padding({ right: 20, left: 20 })
    // 深色侧边栏：内容避让状态栏 + 标题栏（浅色 sheet 由 CommonSheet 已 padding 66）
    .contentStartOffset(this.dark ? appState.topRect + 56 : 0)
    .contentEndOffset(appState.bottomRect === 0 ? 16 : appState.bottomRect)
  }

  /** 播放设置行描述（key 决定右侧控件：speed 滑杆 / cache、listen、danmakuSettings 箭头 / danmaku 开关）。 */
  private settingItems(): FqSettingItem[] {
    const items: FqSettingItem[] = [
      new FqSettingItem('speed', '倍速', $r('sys.symbol.speed_multiple')),
      new FqSettingItem('hwdec', '解码方式', $r('sys.symbol.video')),
      new FqSettingItem('cache', '离线缓存', $r('sys.symbol.download')),
      new FqSettingItem('listen', '听视频', $r('sys.symbol.waveform_tv')),
      new FqSettingItem('share', '分享', $r('sys.symbol.share')),
      new FqSettingItem('continue', '流转', $r('sys.symbol.superdevice')),
      new FqSettingItem('danmaku', '弹幕开关', $r('sys.symbol.ellipsis_bubble')),
      new FqSettingItem('danmakuSettings', '弹幕设置', $r('sys.symbol.textformat'))
    ];
    return items;
  }

  /** 解码方式菜单：公共 FqMenu 档位直选（硬件解码/软件解码，当前方式尾勾）。
   *  选中即经宿主 setHwDecode 切 mpv 运行时 hwdec + 偏好持久化。 */
  private openHwdecMenu(): void {
    const items: Array<FqMenuItem> = [];
    const hwItem: FqMenuItem = new FqMenuItem();
    hwItem.label = '硬件解码';
    if (this.hwdecOn) {
      hwItem.endIcon = $r('sys.symbol.checkmark');
    }
    hwItem.onAction = (): void => {
      this.hwdecToggle(true);
    };
    items.push(hwItem);
    const swItem: FqMenuItem = new FqMenuItem();
    swItem.label = '软件解码';
    if (!this.hwdecOn) {
      swItem.endIcon = $r('sys.symbol.checkmark');
    }
    swItem.onAction = (): void => {
      this.hwdecToggle(false);
    };
    items.push(swItem);
    FqMenu.open(this.getUIContext(), FQ_SETTINGS_HWDEC_ANCHOR_ID, items);
  }

  /** 断点倍速高亮判定（当前值取拖动预览优先；半步容差内视为命中该断点）。 */
  private isCurrentSpeedStep(step: number): boolean {
    const value: number = this.speedPreview >= 0 ? this.speedPreview : this.speed;
    return Math.abs(value - step) < FQ_SPEED_STEP / 2;
  }
}

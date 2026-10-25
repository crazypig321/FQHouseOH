/**
 * 听视频页（播放页「听视频」进入的听剧模式，对齐 fqapp listen_mode_page.dart）：
 * 独立 mpv 实例只听不看（无 PlayerSurface），视频页进页前已暂停让路；
 * 大框架与听书页（ListenPage）一致，去掉音色/试读/相关作品等书籍专属组件：
 * 封面卡（集名/剧名，整卡开目录）/ 状态行 / 进度排（-15s/拖动条/+15s）/
 * 控制排（目录/上一集/播放/下一集/定时）。
 * 语速调节移至标题栏右上角菜单（speed_multiple 图标），sheet 样式对齐
 * 视频页播放设置（FqSettingRow + 滑杆 0.5-2.0 步进 0.25 + 档位标签）。
 * 定时关闭（分钟档/播完本集）页面级实现，复用 1s tick 倒计时，
 * 「播完本集」在 onEpisodeEnd 拦截自动连播。
 * 已看与续播直接写 FqWatchedStore（与播放页同键，退出后播放页按听到的
 * 集/位置续看）；退出回传结果（ListenVideoNavParams.result*），mpv 销毁停播。
 * AVSession（通知栏播控中心/胶囊）+ 后台 audioPlayback 长时任务由
 * core/FqVideoMedia 承载（离页 release，通知栏让回播放页会话）。
 */

import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../../view/CommonSheet';
import { FqCatalogSheet } from '../../view/FqCatalogSheet';
import { FqSettingRow } from '../../view/FqSettingRow';
import { FqTitleBarMenuOptions, ListenVideoNavParams } from '../../model/FqNavModels';
import { FqChapter } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqVideoMedia } from '../../core/FqVideoMedia';
import { FqWatchedStore, FqWatchedProgress } from '../../core/FqWatchedStore';
import { FqReadStatsStore } from '../../core/FqReadStatsStore';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';
import { Player, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';

/** 定时分钟档（对齐听书页 -1/15/30/60）。 */
const FQ_SLEEP_MINUTES: number[] = [15, 30, 60];

/** 语速滑杆范围与步进（对齐视频页设置 sheet：0.5-2.0、步进 0.25）。 */
const FQ_SPEED_MIN: number = 0.5;
const FQ_SPEED_MAX: number = 2.0;
const FQ_SPEED_STEP: number = 0.25;
/** 语速滑杆断点档数（0.5-2.0 步进 0.25，共 7 档）。 */
const FQ_SPEED_STEP_COUNT: number = 7;

/** 标题栏高度（对齐听书页避让）。 */
const FQ_LISTEN_TOP_INSET: number = 56;

/** 听视频页半模态种类（单 bindSheet 内切换内容）。 */
enum FqListenVideoSheetKind {
  none = 0,
  catalog = 1,
  rates = 2,
  sleep = 3,
}

/** mm:ss 播放时间。 */
function fqFormatClock(seconds: number): string {
  let value: number = seconds;
  if (!Number.isFinite(value) || value < 0) {
    value = 0;
  }
  const total: number = Math.floor(value);
  const minutes: number = Math.floor(total / 60);
  const rest: number = total % 60;
  return `${minutes}:${rest < 10 ? '0' : ''}${rest}`;
}

/** 语速滑杆断点值（0.5 → 2.0 步进 0.25）。 */
function fqSpeedSteps(): number[] {
  const steps: number[] = [];
  for (let i: number = 0; i < FQ_SPEED_STEP_COUNT; i++) {
    steps.push(FQ_SPEED_MIN + i * FQ_SPEED_STEP);
  }
  return steps;
}

/** 语速断点显示文案（去尾零，如 0.75× / 1× / 1.5×）。 */
function fqSpeedStepLabel(step: number): string {
  const rounded: number = Math.round(step * 100) / 100;
  return `${rounded}×`;
}

@ComponentV2
export struct ListenVideoPage {
  /** mpv 播放器（@ObservedV2；state 经 @Trace 驱动本页渲染；无 surface 纯听）。 */
  private player: Player = new Player(new PlayerConfig());
  /** 剧集目录（播放页预载）。 */
  @Local episodes: FqChapter[] = [];
  /** 当前集下标。 */
  @Local index: number = 0;
  /** 集流加载中（episodeSource 取流）。 */
  @Local loading: boolean = true;
  @Local errorMsg: string = '';
  /** 进度条拖动预览（-1 未拖动）。 */
  @Local seekPreview: number = -1;
  /** 当前半模态种类。 */
  @Local activeSheet: FqListenVideoSheetKind = FqListenVideoSheetKind.none;
  /** bindSheet 显隐（独立于 activeSheet：关闭时内容保留至动画结束）。 */
  @Local sheetVisible: boolean = false;
  /** 关闭令牌：新开/新关使旧的延迟关闭失效。 */
  private sheetCloseToken: number = 0;
  @Local catalogOpenToken: number = 0;
  /** 自动连播下一集（播放设置开关）。 */
  @Local autoAdvance: boolean = true;
  /** 封面绝对地址（backend start 后锚定）。 */
  @Local coverUrl: string = '';
  /** 语速滑杆拖动预览（-1 未拖动；拖动中文案实时跟随，松手提交 mpv）。 */
  @Local speedPreview: number = -1;
  /** 睡眠定时截止时间戳（0 未设）。 */
  private sleepDeadline: number = 0;
  /** 睡眠剩余秒（-1 未设）。 */
  @Local sleepRemainingSec: number = -1;
  /** 播完本集停止。 */
  @Local sleepAtEpisodeEnd: boolean = false;
  /** 定时关闭所选分钟档（0 = 未选分钟档）。 */
  @Local sleepMinutesChoice: number = 0;
  private scroller: Scroller = new Scroller();
  /** 取流 tab（fqKindToTab：短剧/漫剧）。 */
  private tab: string = '短剧';
  /** 异步加载令牌（切集/销毁后旧请求作废）。 */
  private loadToken: number = 0;
  /** 当前集已实际播放（position > 0；切集重置，已看标记 guard）。 */
  private hasDisplayed: boolean = false;
  /** 周期保存计数（5s 一存，仅播放中）。 */
  private progressTick: number = 0;
  /** 周期保存定时器（0 无任务）。 */
  private tickTimer: number = 0;
  /** AVSession/后台播放助手（通知栏播控中心/胶囊 + 后台 audioPlayback 长时任务）。 */
  private media: FqVideoMedia = new FqVideoMedia('FqListenVideo');
  /** AVSession 元数据已同步时长（切集重置 -1；时长事件到达后补发元数据）。 */
  private mediaDurationSynced: number = -1;
  /** 视听统计累计秒（播放中每满 15s 落一次按书统计）。 */
  private statsSec: number = 0;

  aboutToAppear(): void {
    this.episodes = ListenVideoNavParams.chapters;
    this.tab = ListenVideoNavParams.kind === 'manju' ? '漫剧' : '短剧';
    let start: number = ListenVideoNavParams.startIndex;
    if (start < 0 || start >= this.episodes.length) {
      start = 0;
    }
    this.index = start;
    FqWatchedStore.init(getContext(this));
    this.player.stream.eof.listen((eof: boolean): void => {
      if (eof) {
        this.onEpisodeEnd();
      }
    });
    this.player.stream.position.listen((pos: number): void => {
      if (pos > 0 && !this.loading) {
        this.hasDisplayed = true;
      }
    });
    this.tickTimer = setInterval((): void => {
      this.progressTickFn();
    }, 1000);
    // AVSession（通知栏播控中心/胶囊）播控命令 + 后台播放长时任务
    const mediaContext: common.UIAbilityContext | null = appState.abilityContext;
    if (mediaContext !== null) {
      this.media.init(mediaContext);
    }
    this.media.onPlay = (): void => {
      if (this.errorMsg.length > 0) {
        return;
      }
      this.player.play();
      this.syncMediaState(true);
    };
    this.media.onPause = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    this.media.onStop = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
      this.syncMediaState(false);
    };
    this.media.onPrevious = (): void => {
      if (this.player.state.position > 3) {
        this.player.seek(0);
        return;
      }
      if (this.index > 0) {
        this.loadEpisode(this.index - 1, -1);
      } else {
        this.player.seek(0);
      }
    };
    this.media.onNext = (): void => {
      if (this.index + 1 < this.episodes.length) {
        this.loadEpisode(this.index + 1, -1);
      }
    };
    this.media.onSeek = (sec: number): void => {
      this.player.seek(sec);
      this.saveCurrentProgress();
      this.syncMediaState(this.player.state.playing);
    };
    const startSec: number = ListenVideoNavParams.startPositionSec > 0
      ? ListenVideoNavParams.startPositionSec : -1;
    this.loadEpisode(start, startSec);
  }

  aboutToDisappear(): void {
    this.loadToken += 1;
    if (this.tickTimer !== 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = 0;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
    // 退出回传：听到的集 + 位置（播放页 onShown 消费后按此续看）
    ListenVideoNavParams.resultIndex = this.index;
    ListenVideoNavParams.resultPositionSec = this.player.state.position;
    this.media.release();
    this.player.destroy();
  }

  /** 进度排显示值（拖动预览优先）。 */
  private displayPosition(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.player.state.position;
  }

  /** 当前集（无目录时 null）。 */
  private episode(): FqChapter | null {
    const episode: FqChapter | undefined = this.episodes[this.index];
    return episode !== undefined ? episode : null;
  }

  /** 当前集标题（空目录回退空串）。 */
  private currentEpisodeTitle(): string {
    const episode: FqChapter | null = this.episode();
    return episode !== null ? episode.title : '';
  }

  /** 定时生效中（分钟档倒计时或播完本集）。 */
  private sleepActive(): boolean {
    return this.sleepDeadline > 0 || this.sleepAtEpisodeEnd;
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarMenuOptions('听视频', $r('sys.symbol.speed_multiple'), 'speed',
        (): void => {
          this.openSheet(FqListenVideoSheetKind.rates);
        }),
      scroller: this.scroller,
      showPlaybackBall: false,
    }) {
      Scroll(this.scroller) {
        Column() {
          Column(){
            this.CoverCard()
            this.StatusLine()
          }.padding({ bottom: '10%' })
          Blank()
          this.ProgressRow()
          this.TransportRow()
        }
        .justifyContent(FlexAlign.Start)
        .width('100%')
        .padding({
          top: appState.topRect + FQ_LISTEN_TOP_INSET,
          bottom: appState.bottomRect + 24,
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .bindSheet(this.sheetVisible, this.ActiveSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, this.sheetHeight()))
    }
  }

  // ---------------------------------------------------------------------------
  // 主内容
  // ---------------------------------------------------------------------------

  /** 封面卡：集名 + 剧名贴底，整卡开目录，剧名行点击回播放页。 */
  @Builder
  private CoverCard() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(this.coverUrl)
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .autoResize(true)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .draggable(false)
        Column() {
          Blank()
        }
        .width('100%')
        .height(150)
        .linearGradient({
          angle: 180,
          colors: [['rgba(0,0,0,0)', 0.0], ['rgba(0,0,0,0.72)', 1.0]],
        })
        Column() {
          Blank()
          Text(this.currentEpisodeTitle())
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .lineHeight(19.5)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 14, right: 14, bottom: 4 })

          Row() {
            Text(ListenVideoNavParams.title)
              .fontSize(12.5)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor(['rgba(255,255,255,0.7)'])
          }
          .width('100%')
          .height(35)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .onClick((): void => {
            NavPathUtils.pop();
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .aspectRatio(1)
      .constraintSize({ maxWidth: 293 })
      .borderRadius(10)
      .clip(true)
      .onClick((): void => {
        this.openCatalog();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 16, right: 16, top: 10 })
  }

  /** 状态行：错误（带重试）/ 加载中 / 缓冲中 / 播完 / 播放 / 暂停。 */
  @Builder
  private StatusLine() {
    Column({ space: 6 }) {
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
        Button('重试')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(FQ_ACCENT)
          .padding({ left: 16, right: 16, top: 5, bottom: 5 })
          .onClick((): void => {
            this.loadEpisode(this.index, -1);
          })
      } else if (this.loading) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color(FQ_ACCENT)
          Text('正在加载音频…')
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      } else if (this.player.state.buffering) {
        Text('正在缓冲…')
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      } else if (this.player.state.eof) {
        Text('本集已播完')
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      } else if (this.player.state.playing) {
        Text('正在播放')
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      } else {
        Text('已暂停')
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8, left: 20, right: 20 })
  }

  /** 进度排：-15s / 拖动条 / +15s + 时间标签。 */
  @Builder
  private ProgressRow() {
    Column({ space: 2 }) {
      Row() {
        Text('-15s')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick((): void => {
            this.player.seek(Math.max(0, this.player.state.position - 15));
          })
        Slider({
          value: this.displayPosition(),
          min: 0,
          max: this.player.state.duration > 0 ? this.player.state.duration : 1,
          step: 1,
        })
          .layoutWeight(1)
          .trackThickness(3)
          .blockSize({ width: 14, height: 14 })
          .selectedColor(FQ_ACCENT)
          .trackColor($r('sys.color.comp_divider'))
          .blockColor(FQ_ACCENT)
          .enabled(this.player.state.duration > 0)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.End) {
              this.seekPreview = -1;
              this.player.seek(value);
            } else {
              this.seekPreview = value;
            }
          })
        Text('+15s')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 8, right: 8, top: 10, bottom: 10 })
          .onClick((): void => {
            this.player.seek(this.player.state.position + 15);
          })
      }
      .width('100%')
      Text(`${fqFormatClock(this.displayPosition())}/${fqFormatClock(this.player.state.duration)}`)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 控制排单键。 */
  @Builder
  private TransportItem(icon: Resource, label: string, active: boolean, enabled: boolean,
    onTap: () => void) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(26)
        .fontColor([active ? FQ_ACCENT : $r('sys.color.font_primary')])
    }
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .opacity(enabled ? 1 : 0.3)
    .onClick((): void => {
      if (enabled) {
        onTap();
      }
    })
    .accessibilityText(label)
  }

  /** 控制排：目录 / 上一集 / 播放暂停 / 下一集 / 定时。 */
  @Builder
  private TransportRow() {
    Row({ space: 0 }) {
      this.TransportItem($r('sys.symbol.list_bullet'), '目录', false, true, (): void => {
        this.openCatalog();
      })
      this.TransportItem($r('sys.symbol.backward_end_fill'), '上一集', false, this.index > 0,
        (): void => {
          this.loadEpisode(this.index - 1, -1);
        })
      SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(38)
        .fontColor([$r('sys.color.font_primary')])
        .padding(11)
        .onClick((): void => {
          this.togglePlay();
        })
        .accessibilityText(this.player.state.playing ? '暂停' : '播放')
      this.TransportItem($r('sys.symbol.forward_end_fill'), '下一集', false,
        this.index + 1 < this.episodes.length, (): void => {
          this.loadEpisode(this.index + 1, -1);
        })
      this.TransportItem($r('sys.symbol.stopwatch_1'), '定时', this.sleepActive(), true,
        (): void => {
          this.openSheet(FqListenVideoSheetKind.sleep);
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .padding({ top: 6 })
  }

  // ---------------------------------------------------------------------------
  // 半模态
  // ---------------------------------------------------------------------------

  /** 目录：公共 FqCatalogSheet，点击集切播。 */
  @Builder
  private CatalogSheetBuilder() {
    FqCatalogSheet({
      chapters: this.episodes,
      fontColor: $r('sys.color.font_primary'),
      currentChapterIndex: this.index,
      progressOf: (index: number): string => this.catalogProgressOf(index),
      openToken: this.catalogOpenToken,
      contentEndExtra: appState.bottomRect,
      chapterClick: (index: number): void => {
        this.closeSheet();
        this.loadEpisode(index, -1);
      },
    })
  }

  /**
   * 语速调节（样式对齐视频页播放设置 sheet：公共 FqSettingRow +
   * 滑杆 0.5-2.0 步进 0.25 + 断点档位标签；拖动实时预览，松手提交 mpv）。
   */
  @Builder
  private RatesSheetBuilder() {
    CommonSheet({
      sheetTitle: '语速调节',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      Column() {
        List() {
          ListItemGroup() {
            ListItem() {
              FqSettingRow({
                icon: $r('sys.symbol.speed_multiple'),
                title: '倍速',
                tintColor: $r('sys.color.font'),
                click: (): void => {
                },
              }) {
                Column({ space: 2 }) {
                  Slider({
                    value: this.player.state.speed,
                    min: FQ_SPEED_MIN,
                    max: FQ_SPEED_MAX,
                    step: FQ_SPEED_STEP,
                    style: SliderStyle.InSet,
                  })
                    .width('100%')
                    .height(30)
                    .showSteps(true)
                    .stepColor($r('sys.color.comp_background_tertiary'))
                    .blockColor(FQ_ACCENT)
                    .selectedColor('#33FF7A3D')
                    .trackColor($r('sys.color.comp_background_tertiary'))
                    .onChange((value: number, mode: SliderChangeMode): void => {
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.player.setSpeed(value);
                        this.speedPreview = -1;
                        this.syncMediaState(this.player.state.playing);
                      } else {
                        this.speedPreview = value;
                      }
                    })

                  // 断点倍速文本标识：第 i 档锚定在 i/(档数-1)*100% 处，与滑杆刻度两端对齐
                  Row() {
                    ForEach(fqSpeedSteps(), (step: number) => {
                      Text(fqSpeedStepLabel(step))
                        .fontSize(7)
                        .fontWeight(this.isCurrentSpeedStep(step) ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(this.isCurrentSpeedStep(step) ? FQ_ACCENT
                          : $r('sys.color.font_tertiary'))
                    }, (step: number) => `${step}`)
                  }
                  .justifyContent(FlexAlign.SpaceBetween)
                  .width('100%')
                  .hitTestBehavior(HitTestMode.None)
                }
                .layoutWeight(1)
              }
            }
          }
          .borderRadius(14)
          .backgroundColor($r('sys.color.comp_background_list_card'))
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .padding({ top: 4 })
    }
  }

  /** 定时关闭：分钟档 / 播完本集 / 关闭定时。 */
  @Builder
  private SleepSheetBuilder() {
    CommonSheet({
      sheetTitle: '定时关闭',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      Column({ space: 0 }) {
        ForEach(FQ_SLEEP_MINUTES, (minutes: number) => {
          Row() {
            Text(`${minutes} 分钟后`)
              .fontSize(15)
              .fontColor(this.sleepMinutesChoice === minutes ? FQ_ACCENT
                : $r('sys.color.font_primary'))
            Blank()
            if (this.sleepMinutesChoice === minutes) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([FQ_ACCENT])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 10, right: 10 })
          .borderRadius(8)
          .backgroundColor(this.sleepMinutesChoice === minutes
            ? '#1AFF7A3D' : Color.Transparent)
          .onClick((): void => {
            this.setSleepMinutes(minutes);
            this.closeSheet();
            promptAction.showToast({ message: `将在 ${minutes} 分钟后停止播放`, duration: 1500 });
          })
        }, (minutes: number) => `sleep_${minutes}`)
        Row() {
          Text('播完本集')
            .fontSize(15)
            .fontColor(this.sleepAtEpisodeEnd ? FQ_ACCENT
              : $r('sys.color.font_primary'))
          Blank()
          if (this.sleepAtEpisodeEnd) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([FQ_ACCENT])
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 10, right: 10 })
        .borderRadius(8)
        .backgroundColor(this.sleepAtEpisodeEnd ? '#1AFF7A3D' : Color.Transparent)
        .onClick((): void => {
          this.setSleepAtEpisodeEnd();
          this.closeSheet();
          promptAction.showToast({ message: '将在播完本集后停止', duration: 1500 });
        })
        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ top: 6, bottom: 6, left: 10, right: 10 })
        Row() {
          Text('关闭定时')
            .fontSize(15)
            .fontColor(!this.sleepActive() ? FQ_ACCENT
              : $r('sys.color.font_primary'))
          Blank()
          if (!this.sleepActive()) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([FQ_ACCENT])
          }
        }
        .width('100%')
        .height(48)
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .backgroundColor(!this.sleepActive() ? '#1AFF7A3D' : Color.Transparent)
        .onClick((): void => {
          this.clearSleep();
          this.closeSheet();
          promptAction.showToast({ message: '已关闭定时', duration: 1500 });
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  /** 单 bindSheet：按 activeSheet 切换半模态内容。 */
  @Builder
  private ActiveSheetBuilder() {
    if (this.activeSheet === FqListenVideoSheetKind.catalog) {
      this.CatalogSheetBuilder()
    } else if (this.activeSheet === FqListenVideoSheetKind.rates) {
      this.RatesSheetBuilder()
    } else if (this.activeSheet === FqListenVideoSheetKind.sleep) {
      this.SleepSheetBuilder()
    }
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  private openCatalog(): void {
    if (this.episodes.length === 0) {
      return;
    }
    this.catalogOpenToken += 1;
    this.openSheet(FqListenVideoSheetKind.catalog);
  }

  /** 打开半模态：切换内容并置 isShow（使旧延迟关闭失效）。 */
  private openSheet(kind: FqListenVideoSheetKind): void {
    this.sheetCloseToken += 1;
    if (kind === FqListenVideoSheetKind.rates) {
      this.speedPreview = -1;
    }
    this.activeSheet = kind;
    this.sheetVisible = true;
  }

  /** 关闭半模态：仅切 isShow，内容保留到下次 openSheet 再切换。 */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.sheetVisible = false;
      }
    }, 0);
  }

  /** 各半模态高度。 */
  private sheetHeight(): SheetSize | Length {
    switch (this.activeSheet) {
      case FqListenVideoSheetKind.rates:
        return 320;
      case FqListenVideoSheetKind.sleep:
        return 420;
      default:
        return 600;
    }
  }

  /** 断点倍速高亮判定（当前值取拖动预览优先；半步容差内视为命中该断点）。 */
  private isCurrentSpeedStep(step: number): boolean {
    const value: number = this.speedPreview >= 0 ? this.speedPreview : this.player.state.speed;
    return Math.abs(value - step) < FQ_SPEED_STEP / 2;
  }

  /** 加载并起播一集（episodeSource 取流 → mpv open；startSec > 0 偏移起播）。 */
  private async loadEpisode(index: number, startSec: number): Promise<void> {
    const episode: FqChapter | undefined = this.episodes[index];
    if (episode === undefined) {
      return;
    }
    // 离开的旧集：实际播放过才标已看/存续播进度（this.index 尚未切换）
    this.markCurrentWatched();
    this.saveCurrentProgress();
    const token: number = ++this.loadToken;
    this.index = index;
    // 退出回传实时同步：pop 转场中本页 aboutToDisappear 晚于播放页 onShown 消费，
    // 静态参数须持续保持最新（集,位置），切集即时写、位置由 1s tick 每秒刷新
    ListenVideoNavParams.resultIndex = this.index;
    ListenVideoNavParams.resultPositionSec = startSec > 0 ? startSec : 0;
    this.loading = true;
    this.errorMsg = '';
    this.seekPreview = -1;
    try {
      await FqBackend.get().start(getContext(this));
      this.resolveCover();
      const source = await FqBackend.get().episodeSource(episode.itemId, this.tab);
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.player.open(startSec > 0
        ? new Media(source.url, { start: startSec })
        : new Media(source.url));
      // 新集起播：重置「实际播放」guard
      this.hasDisplayed = false;
      // AVSession/后台长时任务：会话确保 + 元数据（时长随 1s tick 补发）
      this.mediaDurationSynced = -1;
      this.media.ensureSession('audio');
      this.media.startBackground();
      this.pushMediaMetadata();
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.errorMsg = fqErrorMessage(error);
    }
  }

  /** 封面锚定（backend start 后 resourceUrl；绝对 URL 原样返回）。 */
  private resolveCover(): void {
    if (this.coverUrl.length === 0 && ListenVideoNavParams.cover.length > 0) {
      this.coverUrl = FqBackend.get().resourceUrl(ListenVideoNavParams.cover);
    }
  }

  /** 播放暂停切换：mpv 状态异步更新，判定以切换意图为准；暂停即存续播进度。 */
  private togglePlay(): void {
    if (this.errorMsg.length > 0) {
      return;
    }
    const wasPlaying: boolean = this.player.state.playing;
    if (this.player.state.eof) {
      this.player.play();
    } else {
      this.player.playOrPause();
    }
    // AVSession 播放态立即同步（意图优先，绕过 mpv 状态异步）
    this.syncMediaState(!wasPlaying);
    if (wasPlaying) {
      this.saveCurrentProgress();
    }
  }

  /** 播完回调：播完本集定时拦截连播；自动连播下一集；末集/关闭连播停在末尾并落进度。 */
  private onEpisodeEnd(): void {
    if (this.sleepAtEpisodeEnd) {
      this.sleepAtEpisodeEnd = false;
      this.markCurrentWatched();
      this.saveCurrentProgress();
      this.syncMediaState(false);
      return;
    }
    if (this.autoAdvance && this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1, -1);
      return;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
  }

  /** 周期任务：退出回传刷新 + AVSession 同步 + 睡眠倒计时 + 5s 周期保存续播进度。 */
  private progressTickFn(): void {
    // 退出回传（集,位置）每秒刷新：播放页 onShown 在本页销毁前即消费
    ListenVideoNavParams.resultIndex = this.index;
    ListenVideoNavParams.resultPositionSec = this.player.state.position;
    this.mediaTick();
    // 播放中累计视听统计（每 15s 落一次按书+全局）
    if (this.player.state.playing) {
      this.statsSec += 1;
      if (this.statsSec >= 15) {
        this.statsSec = 0;
        FqReadStatsStore.addBookSeconds(ListenVideoNavParams.contentId, 15);
      }
    } else {
      this.statsSec = 0;
    }
    if (this.sleepDeadline > 0) {
      const remainSec: number = (this.sleepDeadline - Date.now()) / 1000;
      this.sleepRemainingSec = Math.max(0, Math.ceil(remainSec));
      if (remainSec <= 0) {
        this.sleepDeadline = 0;
        this.sleepRemainingSec = -1;
        this.player.pause();
        this.saveCurrentProgress();
        this.syncMediaState(false);
      }
    }
    this.progressTick += 1;
    if (this.progressTick < 5) {
      return;
    }
    this.progressTick = 0;
    if (this.player.state.playing) {
      this.saveCurrentProgress();
    }
  }

  /** AVSession 元数据推送（剧名/集名/时长/封面）。 */
  private pushMediaMetadata(): void {
    const episode: FqChapter | undefined = this.episodes[this.index];
    this.media.updateMetadata(
      `${ListenVideoNavParams.contentId}:${episode !== undefined ? episode.itemId : this.index}`,
      ListenVideoNavParams.title,
      episode !== undefined ? episode.title : '',
      this.player.state.duration,
      this.coverUrl);
  }

  /** AVSession 播放态立即同步（播放意图优先，绕过 mpv 状态异步）。 */
  private syncMediaState(playing: boolean): void {
    this.media.syncPlayback(true, playing, this.player.state.speed, this.player.state.position);
  }

  /** AVSession 周期同步（1s 节流内含；时长事件到达后补发元数据）。 */
  private mediaTick(): void {
    const duration: number = this.player.state.duration;
    if (duration > 0 && Math.abs(duration - this.mediaDurationSynced) > 0.5) {
      this.mediaDurationSynced = duration;
      this.pushMediaMetadata();
    }
    this.media.syncPlayback(false, this.player.state.playing, this.player.state.speed,
      this.player.state.position);
  }

  /** 定时分钟档（覆盖既有定时）。 */
  private setSleepMinutes(minutes: number): void {
    this.sleepAtEpisodeEnd = false;
    this.sleepMinutesChoice = minutes;
    this.sleepDeadline = Date.now() + minutes * 60000;
    this.sleepRemainingSec = minutes * 60;
  }

  /** 播完本集停止。 */
  private setSleepAtEpisodeEnd(): void {
    this.sleepAtEpisodeEnd = true;
    this.sleepMinutesChoice = 0;
    this.sleepDeadline = 0;
    this.sleepRemainingSec = -1;
  }

  /** 关闭定时。 */
  private clearSleep(): void {
    this.sleepDeadline = 0;
    this.sleepRemainingSec = -1;
    this.sleepAtEpisodeEnd = false;
    this.sleepMinutesChoice = 0;
  }

  /** 标记当前集已看（实际播放过才标，对齐播放页 markCurrentWatched）。 */
  private markCurrentWatched(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    FqWatchedStore.mark(ListenVideoNavParams.contentId, episode.itemId);
  }

  /** 保存当前集续播进度（与播放页同键：FqWatchedStore，按集 itemId 记录）。 */
  private saveCurrentProgress(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const episode: FqChapter | undefined = this.episodes[this.index];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    FqWatchedStore.saveProgress(ListenVideoNavParams.contentId,
      new FqWatchedProgress(episode.itemId,
        this.player.state.position, this.player.state.duration));
  }

  /** 目录进度列：当前集显示百分比。 */
  private catalogProgressOf(index: number): string {
    if (index !== this.index || this.player.state.duration <= 0) {
      return '';
    }
    const percent: number = Math.min(100,
      Math.round((this.player.state.position / this.player.state.duration) * 100));
    return `${percent}%`;
  }
}

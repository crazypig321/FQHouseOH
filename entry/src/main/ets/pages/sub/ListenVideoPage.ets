/**
 * 听视频页（播放页「听视频」进入的听剧模式，对齐 fqapp listen_mode_page.dart）：
 * 独立 mpv 实例只听不看（无 PlayerSurface），视频页进页前已暂停让路；
 * 大框架与听书页（ListenPage）一致，去掉音色/试读/相关作品等书籍专属组件：
 * 封面卡（集名/剧名，整卡开目录）/ 状态行 / 动作排（语速/更多）/
 * 进度排（-15s/拖动条/+15s）/ 控制排（目录/上一集/播放/下一集）。
 * 已看与续播直接写 FqWatchedStore（与播放页同键，退出后播放页按听到的
 * 集/位置续看）；退出回传结果（ListenVideoNavParams.result*），mpv 销毁停播。
 */

import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../../view/CommonSheet';
import { FqCatalogSheet } from '../../view/FqCatalogSheet';
import { FqTitleBarOptions, ListenVideoNavParams } from '../../model/FqNavModels';
import { FqChapter } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqWatchedStore, FqWatchedProgress } from '../../core/FqWatchedStore';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';
import { Player, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';

/** 播放倍速档（mpv 0.75 ~ 2，对齐听书页档位）。 */
const FQ_RATES: number[] = [0.75, 1, 1.25, 1.5, 1.75, 2];

/** 标题栏高度（对齐听书页避让）。 */
const FQ_LISTEN_TOP_INSET: number = 56;

/** 听视频页半模态种类（单 bindSheet 内切换内容）。 */
enum FqListenVideoSheetKind {
  none = 0,
  catalog = 1,
  rates = 2,
  more = 3,
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

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('听视频', false),
      scroller: this.scroller,
      showPlaybackBall: false,
    }) {
      Scroll(this.scroller) {
        Column() {
          this.CoverCard()
          this.StatusLine()
          this.ActionRow()
          this.ProgressRow()
          this.TransportRow()
        }
        .constraintSize({ maxWidth: 560 })
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
          .height('100%')
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
      .aspectRatio(0.75)
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

  /** 动作排单键。 */
  @Builder
  private ActionItem(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 5 }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([$r('sys.color.font_primary')])
      Text(label)
        .fontSize(11)
        .maxLines(1)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width(96)
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      onTap();
    })
  }

  /** 动作排：语速 / 更多。 */
  @Builder
  private ActionRow() {
    Row({ space: 24 }) {
      this.ActionItem($r('sys.symbol.timer'), '语速', (): void => {
        this.openSheet(FqListenVideoSheetKind.rates);
      })
      this.ActionItem($r('sys.symbol.ellipsis_circle'), '更多', (): void => {
        this.openSheet(FqListenVideoSheetKind.more);
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8 })
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
  private TransportItem(icon: Resource, label: string, enabled: boolean,
    onTap: () => void) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(26)
        .fontColor([$r('sys.color.font_primary')])
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

  /** 控制排：目录 / 上一集 / 播放暂停 / 下一集。 */
  @Builder
  private TransportRow() {
    Row({ space: 0 }) {
      this.TransportItem($r('sys.symbol.list_bullet'), '目录', true, (): void => {
        this.openCatalog();
      })
      this.TransportItem($r('sys.symbol.backward_end_fill'), '上一集', this.index > 0,
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
      this.TransportItem($r('sys.symbol.forward_end_fill'), '下一集',
        this.index + 1 < this.episodes.length, (): void => {
          this.loadEpisode(this.index + 1, -1);
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
      contentEndExtra: 0,
      chapterClick: (index: number): void => {
        this.closeSheet();
        this.loadEpisode(index, -1);
      },
    })
  }

  /** 播放倍速。 */
  @Builder
  private RatesSheetBuilder() {
    CommonSheet({
      sheetTitle: '播放倍速',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      Column({ space: 0 }) {
        ForEach(FQ_RATES, (rate: number) => {
          Row() {
            Text(`${rate}x`)
              .fontSize(15)
              .fontColor(rate === this.player.state.speed ? FQ_ACCENT
                : $r('sys.color.font_primary'))
            Blank()
            if (rate === this.player.state.speed) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([FQ_ACCENT])
            }
          }
          .width('100%')
          .height(48)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .backgroundColor(rate === this.player.state.speed ? '#1AFF7A3D' : Color.Transparent)
          .onClick((): void => {
            this.player.setSpeed(rate);
            this.closeSheet();
          })
        }, (rate: number) => `rate_${rate}`)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  /** 更多（播放设置）：剧集目录 / 自动连播。 */
  @Builder
  private MoreSheetBuilder() {
    CommonSheet({
      sheetTitle: '播放设置',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      Column() {
        Row({ space: 12 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(20)
              .fontColor(['#FF10B981'])
          }
          .width(38)
          .height(38)
          .borderRadius(10)
          .backgroundColor('#1A10B981')
          .justifyContent(FlexAlign.Center)
          Column({ space: 2 }) {
            Text('剧集目录')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text(`共 ${this.episodes.length} 集`)
              .fontSize(12.5)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick((): void => {
          this.openCatalog();
        })

        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 68, right: 16 })

        Row({ space: 12 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(20)
              .fontColor(['#FFF59E0B'])
          }
          .width(38)
          .height(38)
          .borderRadius(10)
          .backgroundColor('#1AF59E0B')
          .justifyContent(FlexAlign.Center)
          Column({ space: 2 }) {
            Text('自动下一集')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text('当前集播完后自动连播')
              .fontSize(12.5)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoAdvance })
            .onChange((isOn: boolean): void => {
              this.autoAdvance = isOn;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      .width('100%')
      .borderRadius(18)
      .backgroundColor($r('sys.color.comp_background_secondary'))
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 20 })
    }
  }

  /** 单 bindSheet：按 activeSheet 切换半模态内容。 */
  @Builder
  private ActiveSheetBuilder() {
    if (this.activeSheet === FqListenVideoSheetKind.catalog) {
      this.CatalogSheetBuilder()
    } else if (this.activeSheet === FqListenVideoSheetKind.rates) {
      this.RatesSheetBuilder()
    } else if (this.activeSheet === FqListenVideoSheetKind.more) {
      this.MoreSheetBuilder()
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
        return 380;
      case FqListenVideoSheetKind.more:
        return 300;
      default:
        return 600;
    }
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
    if (wasPlaying) {
      this.saveCurrentProgress();
    }
  }

  /** 播完回调：自动连播下一集；末集/关闭连播停在末尾并落进度。 */
  private onEpisodeEnd(): void {
    if (this.autoAdvance && this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1, -1);
      return;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
  }

  /** 周期保存续播进度（5s 一存，仅播放中）。 */
  private progressTickFn(): void {
    this.progressTick += 1;
    if (this.progressTick < 5) {
      return;
    }
    this.progressTick = 0;
    if (this.player.state.playing) {
      this.saveCurrentProgress();
    }
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

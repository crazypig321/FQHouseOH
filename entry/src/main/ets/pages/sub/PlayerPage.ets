/**
 * 视频播放页（PlayerPage，mpv 播放器）：
 * - 取流对齐 fqapp ohos 语义：/api/content 不带 mode → 后端 c1 整集下载解密后
 *   loopback /src/ Range 供流，mpv 拉明文（无需 key_hex CENC 解密）；
 * - 全屏 PlayerSurface + 单击切换控制层（播放中 4s 自动隐藏）：
 *   顶栏（返回/标题/集数）、中央排（上/下一集、播放暂停）、
 *   底栏（进度 Slider + 选集半模态）；
 * - 播完自动连播；aboutToDisappear 销毁 mpv 实例。
 */

import { display } from '@kit.ArkUI';
import { Player, PlayerSurface, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';
import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { FqSheetOptions } from '../../view/CommonSheet';
import { FqCatalogSheet } from '../../view/FqCatalogSheet';
import { PlayerNavParams } from '../../model/FqNavModels';
import { FqChapter, FqEpisodeSource, fqKindToTab } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';

/** 控制层自动隐藏延时（ms）。 */
const FQ_CONTROLS_HIDE_MS: number = 4000;

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

/** 选集半模态高度（屏高 62%，vp）。 */
function fqPlayerSheetHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  const height: number = Math.round((screenHeight / density) * 0.62);
  return height > 0 ? height : 600;
}

@ComponentV2
export struct PlayerPage {
  /** mpv 播放器（@ObservedV2；state 经 @Trace 驱动本页渲染）。 */
  private player: Player = new Player(new PlayerConfig());
  /** 剧集目录（详情页预载；为空则本页拉目录）。 */
  @Local episodes: FqChapter[] = [];
  /** 当前集下标。 */
  @Local index: number = 0;
  /** 集流加载中（/api/content 取流）。 */
  @Local loading: boolean = true;
  @Local errorMsg: string = '';
  /** 控制层显隐（单击画面切换）。 */
  @Local controlsVisible: boolean = true;
  /** 选集半模态。 */
  @Local sheetVisible: boolean = false;
  @Local catalogOpenToken: number = 0;
  /** 进度条拖动预览（-1 未拖动）。 */
  @Local seekPreview: number = -1;

  private title: string = '';
  private tab: string = '短剧';
  /** 异步加载令牌（页面销毁/切集后旧请求作废）。 */
  private loadToken: number = 0;
  /** 半模态关闭令牌。 */
  private sheetCloseToken: number = 0;
  /** 控制层隐藏定时器。 */
  private hideTimer: number = 0;

  aboutToAppear(): void {
    this.title = PlayerNavParams.title;
    this.tab = fqKindToTab(PlayerNavParams.kind);
    this.episodes = PlayerNavParams.chapters;
    let start: number = PlayerNavParams.startIndex;
    if (start < 0 || start >= this.episodes.length) {
      start = 0;
    }
    this.index = start;
    this.player.stream.eof.listen((eof: boolean): void => {
      if (eof) {
        this.onEpisodeEnd();
      }
    });
    if (this.episodes.length === 0) {
      this.loadEpisodes();
    } else {
      this.loadEpisode(start);
    }
  }

  aboutToDisappear(): void {
    this.loadToken += 1;
    this.cancelControlsHide();
    this.player.destroy();
  }

  build() {
    CommonNav({
      hideTitleBar: true,
      showBrandGradient: false,
      pageBackgroundColor: Color.Black,
    }) {
      Stack() {
        PlayerSurface({ player: this.player })

        // 加载/缓冲指示（控制层显示时下移避开中央控制排）
        if (this.errorMsg.length === 0 && (this.loading || this.player.state.buffering)) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(42)
              .height(42)
              .color(Color.White)
            Text(this.loading ? '加载中…' : '缓冲中…')
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.85)')
          }
          .offset({ y: this.controlsVisible ? 84 : 0 })
        }

        if (this.errorMsg.length > 0) {
          this.ErrorOverlay()
        }

        if (this.controlsVisible) {
          Column() {
            this.TopBar()
            Blank()
            this.CenterTransport()
            Blank()
            this.BottomBar()
          }
          .width('100%')
          .height('100%')
          .padding({
            top: appState.topRect + 8,
            bottom: appState.bottomRect + 14,
            left: 16,
            right: 16,
          })
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .onClick((): void => {
        this.toggleControls();
      })
      .bindSheet(this.sheetVisible, this.EpisodeSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, fqPlayerSheetHeightVp()))
    }
  }

  // ---------------------------------------------------------------------------
  // 控制层
  // ---------------------------------------------------------------------------

  /** 顶栏：返回 / 剧名 / 集数。 */
  @Builder
  private TopBar() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor([Color.White])
        .onClick((): void => {
          NavPathUtils.pop();
        })
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.episodes.length > 0 ? `${this.index + 1}/${this.episodes.length}` : '')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.8)')
    }
    .width('100%')
  }

  /** 中央控制排：上一集 / 播放暂停 / 下一集。 */
  @Builder
  private CenterTransport() {
    Row({ space: 44 }) {
      SymbolGlyph($r('sys.symbol.backward_end_fill'))
        .fontSize(30)
        .fontColor([Color.White])
        .opacity(this.index > 0 ? 1 : 0.35)
        .onClick((): void => {
          this.stepEpisode(-1);
        })
      SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(46)
        .fontColor([Color.White])
        .onClick((): void => {
          this.togglePlay();
        })
      SymbolGlyph($r('sys.symbol.forward_end_fill'))
        .fontSize(30)
        .fontColor([Color.White])
        .opacity(this.index + 1 < this.episodes.length ? 1 : 0.35)
        .onClick((): void => {
          this.stepEpisode(1);
        })
    }
  }

  /** 底栏：进度 Slider + 时间 + 选集。 */
  @Builder
  private BottomBar() {
    Row({ space: 10 }) {
      Text(fqFormatClock(this.displayPosition()))
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.85)')
      Slider({
        value: this.displayPosition(),
        min: 0,
        max: this.displayDuration(),
        step: 1,
      })
        .layoutWeight(1)
        .trackColor('rgba(255,255,255,0.3)')
        .selectedColor(FQ_ACCENT)
        .blockColor(Color.White)
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.seekPreview = value;
          } else {
            this.seekPreview = -1;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.player.seek(value);
              this.scheduleControlsHide();
            }
          }
        })
      Text(fqFormatClock(this.player.state.duration))
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.85)')
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(16)
          .fontColor([Color.White])
        Text('选集')
          .fontSize(13)
          .fontColor(Color.White)
      }
      .onClick((): void => {
        this.openCatalog();
      })
    }
    .width('100%')
  }

  /** 加载/取流失败重试卡。 */
  @Builder
  private ErrorOverlay() {
    Column({ space: 14 }) {
      Text(this.errorMsg)
        .fontSize(14)
        .fontColor('rgba(255,255,255,0.9)')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('重试')
        .type(ButtonType.Capsule)
        .height(34)
        .fontSize(14)
        .backgroundColor(FQ_ACCENT)
        .onClick((): void => {
          this.retry();
        })
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 26, right: 26, top: 22, bottom: 22 })
    .borderRadius(16)
    .backgroundColor('rgba(0,0,0,0.7)')
    .onClick((): void => {
    })
  }

  /** 选集半模态（公共目录组件）。 */
  @Builder
  private EpisodeSheetBuilder() {
    FqCatalogSheet({
      chapters: this.episodes,
      fontColor: $r('sys.color.font_primary'),
      currentChapterIndex: this.index,
      openToken: this.catalogOpenToken,
      contentEndExtra: 0,
      chapterClick: (i: number): void => {
        this.closeSheet();
        this.loadEpisode(i);
      },
    })
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  /** 进度条显示值（拖动预览优先）。 */
  private displayPosition(): number {
    return this.seekPreview >= 0 ? this.seekPreview : this.player.state.position;
  }

  /** 进度条最大值（时长未知时占位 1，避免 max<=min）。 */
  private displayDuration(): number {
    const duration: number = this.player.state.duration;
    return duration > 0 ? duration : 1;
  }

  /** 目录为空时先拉剧集目录（tab 由 kind 映射：短剧/漫剧）。 */
  private async loadEpisodes(): Promise<void> {
    const token: number = ++this.loadToken;
    this.loading = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const episodes: FqChapter[] =
        await FqBackend.get().directoryChapters(PlayerNavParams.contentId, this.tab);
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      if (episodes.length === 0) {
        this.errorMsg = '暂无剧集';
        return;
      }
      this.episodes = episodes;
      this.loadEpisode(0);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.errorMsg = fqErrorMessage(error);
    }
  }

  /** 加载并起播一集（/api/content 取流 → mpv open）。 */
  private async loadEpisode(index: number): Promise<void> {
    const episode: FqChapter | undefined = this.episodes[index];
    if (episode === undefined) {
      return;
    }
    const token: number = ++this.loadToken;
    this.index = index;
    this.loading = true;
    this.errorMsg = '';
    this.seekPreview = -1;
    this.scheduleControlsHide();
    try {
      await FqBackend.get().start(getContext(this));
      const source: FqEpisodeSource =
        await FqBackend.get().episodeSource(episode.itemId, this.tab);
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.player.open(new Media(source.url));
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.loading = false;
      this.errorMsg = fqErrorMessage(error);
    }
  }

  /** 上/下一集。 */
  private stepEpisode(delta: number): void {
    const target: number = this.index + delta;
    if (target < 0 || target >= this.episodes.length) {
      return;
    }
    this.loadEpisode(target);
  }

  /** 播放暂停切换；播完暂停态重播当前集。 */
  private togglePlay(): void {
    if (this.errorMsg.length > 0) {
      return;
    }
    if (this.player.state.eof) {
      this.player.play();
    } else {
      this.player.playOrPause();
    }
    this.scheduleControlsHide();
  }

  /** 播完回调：自动连播下一集；末集停在末帧并亮出控制层。 */
  private onEpisodeEnd(): void {
    if (this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1);
      return;
    }
    this.cancelControlsHide();
    this.controlsVisible = true;
  }

  /** 失败重试：无目录先拉目录，否则重取当前集。 */
  private retry(): void {
    if (this.episodes.length === 0) {
      this.loadEpisodes();
    } else {
      this.loadEpisode(this.index);
    }
  }

  /** 单击画面切换控制层。 */
  private toggleControls(): void {
    if (this.errorMsg.length > 0) {
      return;
    }
    if (this.controlsVisible) {
      this.cancelControlsHide();
      this.controlsVisible = false;
    } else {
      this.controlsVisible = true;
      this.scheduleControlsHide();
    }
  }

  /** 播放中 4s 后隐藏控制层。 */
  private scheduleControlsHide(): void {
    this.cancelControlsHide();
    this.hideTimer = setTimeout((): void => {
      this.hideTimer = 0;
      if (this.player.state.playing) {
        this.controlsVisible = false;
      }
    }, FQ_CONTROLS_HIDE_MS);
  }

  private cancelControlsHide(): void {
    if (this.hideTimer !== 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = 0;
    }
  }

  private openCatalog(): void {
    if (this.episodes.length === 0) {
      return;
    }
    this.catalogOpenToken += 1;
    this.sheetVisible = true;
  }

  /** 关闭半模态：延迟一拍置 isShow（标题栏事件内同步改 isShow 会被框架丢弃）。 */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.sheetVisible = false;
      }
    }, 0);
  }
}

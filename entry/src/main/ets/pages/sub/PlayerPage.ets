/**
 * 视频播放页（PlayerPage，mpv 播放器，对齐 fqapp 官方短剧竖屏播放页布局）：
 * - 竖屏（fqapp video_player_chrome.dart catalog 样式）：
 *   顶栏（返回 + 「第N集」+ 播放设置菜单）、视频区 contain（底部预留 163vp 信息区）、
 *   「全屏观看」药丸 + 右侧评论按钮跟随播放区域下方（videoBottom+30）、
 *   底部信息区（自上而下：剧名行 → 细进度线（#FFFA6725、4vp）→
 *   「选集 · 已完结 · 全N集」胶囊（#E6222222、圆角 8））；
 *   控件常驻（官方竖屏无自动收起）；画面中央播放/暂停按钮点击才出现
 *   （暂停时常驻、播放 3s 后自动隐藏，单击画面切播放）。
 * - 全屏（fqapp _landscapeBar / _fullscreenPill）：
 *   横屏片源（videoParams.dw > dh）进入沉浸横屏（AUTO_ROTATION_LANDSCAPE +
 *   隐藏系统栏），底部控制条（播放/下一集/时间/进度/倍速/选集）3s 自动隐藏，
 *   单击画面切控件显隐；竖屏片源全屏保持竖屏沉浸。
 * - 选集半模态 FqStoryPanel（官方 StoryPlayerPanel 白底样式）；剧名行与
 *   「全屏观看」药丸层锚定底部信息区，恒在进度线与选集胶囊上方。
 * - 半模态均走公共框架 FqSheetOptions，只是不触发前景光感模糊；
 *   右上角菜单呼出「播放设置」半模态（倍速档位）。
 * - 播完自动连播；aboutToDisappear 销毁 mpv 实例并恢复沉浸前的系统 UI。
 */

import { display, window } from '@kit.ArkUI';
import { Player, PlayerSurface, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';
import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { FqSheetOptions } from '../../view/CommonSheet';
import { FqStoryPanel } from '../../view/FqStoryPanel';
import { PlayerNavParams } from '../../model/FqNavModels';
import { FqChapter, FqEpisodeSource, fqKindToTab } from '../../model/FqModels';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';

/** 官方竖屏播放页底部信息/进度/选集区高度（PlayerVideoLayout bottom 163）。 */
const FQ_STORY_BOTTOM_INSET: number = 163;
/** 官方短剧橙（#FFFA6725：进度线/当前集/角标）。 */
const FQ_STORY_ORANGE: string = '#FFFA6725';
/** 全屏控件自动隐藏延时（官方横屏 3s，_scheduleHide）。 */
const FQ_FS_HIDE_MS: number = 3000;
/** 倍速档位（官方 speed 菜单）。 */
const FQ_SPEEDS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

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

/** 选集半模态高度（官方竖屏面板 55% 屏高，PlayerVideoLayout.panelFractionFor）。 */
function fqPlayerSheetHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  let screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  // 沉浸横屏（全屏横屏片源）时屏高取短边，避免面板超出横屏可视区
  if (displayData.rotation % 2 === 1 && appState.screenWidth > 0) {
    screenHeight = Math.min(screenHeight, appState.screenWidth);
  }
  const height: number = Math.round((screenHeight / density) * 0.55);
  return height > 0 ? height : 480;
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
  /** 选集半模态（打开时视频区撑满全屏、chrome 隐藏）。 */
  @Local sheetVisible: boolean = false;
  /** 播放设置半模态（右上角菜单呼出：倍速档位；公共框架、不触发前景模糊）。 */
  @Local settingsVisible: boolean = false;
  /** 全屏沉浸态（「全屏观看」进入；横屏片源锁横屏 + 隐藏系统栏）。 */
  @Local fullScreen: boolean = false;
  /** 全屏控件显隐（横片源 3s 自动隐藏，单击画面切换）。 */
  @Local fsControlsVisible: boolean = true;
  /** 中央播放按钮显隐（点击才出现；暂停时常驻，播放 3s 后自动隐藏）。 */
  @Local centerBtnVisible: boolean = false;
  /** 进度条拖动预览（-1 未拖动；拖动时画面中央出时间浮层）。 */
  @Local seekPreview: number = -1;
  /** 封面绝对地址（加载占位图/面板头部；start 后由 resourceUrl 锚定）。 */
  @Local coverUrl: string = '';

  private title: string = '';
  private tab: string = '短剧';
  /** 剧集状态（0 完结 / 1 连载中 / -1 未知）。 */
  private creationStatus: number = -1;
  /** 异步加载令牌（页面销毁/切集后旧请求作废）。 */
  private loadToken: number = 0;
  /** 半模态关闭令牌。 */
  private sheetCloseToken: number = 0;
  /** 播放设置半模态关闭令牌。 */
  private settingsCloseToken: number = 0;
  /** 全屏控件自动隐藏定时器（0 无任务）。 */
  private fsHideTimer: number = 0;
  /** 中央播放按钮 3s 自动隐藏定时器（0 无任务）。 */
  private centerHideTimer: number = 0;
  /** 屏幕尺寸（vp，布局定位用）。 */
  private screenW: number = 0;
  private screenH: number = 0;

  aboutToAppear(): void {
    this.title = PlayerNavParams.title;
    this.tab = fqKindToTab(PlayerNavParams.kind);
    this.creationStatus = PlayerNavParams.creationStatus;
    this.episodes = PlayerNavParams.chapters;
    let start: number = PlayerNavParams.startIndex;
    if (start < 0 || start >= this.episodes.length) {
      start = 0;
    }
    this.index = start;
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    this.screenW = displayData.width / density;
    this.screenH = displayData.height / density;
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
    this.cancelFsHide();
    this.cancelCenterHide();
    if (this.fullScreen) {
      this.applyImmersive(false);
    }
    this.player.destroy();
  }

  build() {
    CommonNav({
      hideTitleBar: true,
      showBrandGradient: false,
      pageBackgroundColor: Color.Black,
      backPressed: (): boolean => {
        // 全屏沉浸态先退全屏（官方返回语义），再返回上一页
        if (this.fullScreen) {
          this.exitFullscreen();
          return true;
        }
        return false;
      },
    }) {
      Stack() {
        // 视频区（contain；mpv 内部保持比例留黑边；面板展开/全屏时撑满全屏）
        Stack() {
          PlayerSurface({ player: this.player, ignoreSafeArea: false })

          if (this.errorMsg.length === 0 && this.loading) {
            this.LoadingOverlay()
          }

          if (this.errorMsg.length === 0 && !this.loading && this.player.state.buffering) {
            this.BufferingOverlay()
          }

          // 拖动进度时的中央时间浮层（官方 _seeking 覆盖层，24sp）
          if (this.seekPreview >= 0) {
            Text(`${fqFormatClock(this.seekPreview)} / ${fqFormatClock(this.player.state.duration)}`)
              .fontSize(24)
              .fontColor(Color.White)
          }

          if (this.errorMsg.length > 0) {
            this.ErrorOverlay()
          }
        }
        .width('100%')
        .height(this.fullScreen ? '100%' : this.videoRegionHeight())
        .position({ x: 0, y: this.fullScreen ? 0 : this.videoTopAbs() })
        .backgroundColor(Color.Black)
        .onClick((): void => {
          this.onVideoTap();
        })
        // 右上角菜单呼出的播放设置半模态（公共框架，不触发前景模糊）
        .bindSheet(this.settingsVisible, this.SettingsSheetBuilder(),
          FqSheetOptions((): void => {
            this.closeSettings();
          }, 320, false))

        // 中央播放/暂停按钮（点击才出现：暂停时常驻、播放 3s 后隐藏；
        // 横屏片源全屏走底部控制条不渲染）
        if (this.errorMsg.length === 0 && !this.loading && !this.sheetVisible &&
          (!this.fullScreen || !this.isLandscapeVideo()) &&
          (!this.player.state.playing || this.centerBtnVisible)) {
          this.CenterPlayButton()
        }

        if (!this.fullScreen) {
          this.TopBar()
          this.FullscreenPill()
          this.CatalogBar()
        }

        if (this.fullScreen && !this.sheetVisible && this.fsControlsVisible) {
          this.FsTopBar()
          if (this.isLandscapeVideo()) {
            this.FsBottomBar()
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .bindSheet(this.sheetVisible, this.EpisodeSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, fqPlayerSheetHeightVp(), false))
    }
  }

  // ---------------------------------------------------------------------------
  // 控件层（官方竖屏常驻：顶栏 / 剧名行 / 全屏药丸+评论 / 细进度线 / 选集胶囊）
  // ---------------------------------------------------------------------------

  /** 顶栏：渐变底、返回 + 「第N集」+ 倍速菜单（官方竖屏顶栏标题就是集数）。 */
  @Builder
  private TopBar() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          NavPathUtils.pop();
        })

        Text(`第${this.episodes.length > 0 ? this.index + 1 : 1}集`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .padding({ left: 4 })

        Row() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openSettings();
        })
      }
      .height(44)
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: appState.topRect, left: 8, right: 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.54)', 0.0], ['rgba(0,0,0,0.0)', 1.0]],
    })
    .position({ x: 0, y: 0 })
  }

  /** 剧名行：锚定底部信息区顶（恒在进度线/选集胶囊上方），点击回剧集详情。 */
  @Builder
  private SeriesTitleRow() {
    Row() {
      Row({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([Color.White])
          .opacity(0.85)
      }
      .constraintSize({ maxWidth: '100%' })
      .onClick((): void => {
        NavPathUtils.pop();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /**
   * 「全屏观看」药丸（官方 _fullscreenPill）：水平居中，纵向在画面下沿与
   * 底部信息区之间的空带居中（不与剧名行/进度线/选集胶囊重叠）。
   */
  @Builder
  private FullscreenPill() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
        .fontSize(16)
        .fontColor([Color.White])
      Text('全屏观看')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .borderRadius(8)
    .backgroundColor('#B3262626')
    .alignItems(VerticalAlign.Center)
    .position({ x: this.screenW / 2, y: this.videoBottom() + 8 })
    .markAnchor({ x: '50%', y: 0 })
    .onClick((): void => {
      this.enterFullscreen();
    })
  }

  /** 中央播放/暂停按钮（暂停态实心、播放态半透明提示可暂停）。 */
  @Builder
  private CenterPlayButton() {
    Row() {
      SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(30)
        .fontColor([Color.White])
    }
    .width(64)
    .height(64)
    .borderRadius(32)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.28)')
    .opacity(this.player.state.playing ? 0.45 : 1)
    .position({
      x: this.screenW / 2,
      y: this.videoTopAbs() + this.videoRegionHeight() / 2,
    })
    .markAnchor({ x: '50%', y: '50%' })
    .onClick((): void => {
      this.togglePlay();
      this.scheduleFsHide();
    })
  }

  /** 细进度线：4vp 轨道、官方橙进度、白拖点；拖动时中央出时间浮层。 */
  @Builder
  private SeekBar() {
    Row() {
      this.SeekSlider()
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .height(30)
  }

  /** 进度滑杆（竖屏进度线与横屏控制条共用）。 */
  @Builder
  private SeekSlider() {
    Slider({
      value: this.displayPosition(),
      min: 0,
      max: this.displayDuration(),
      step: 1,
    })
      .layoutWeight(1)
      .height(30)
      .trackThickness(4)
      .trackColor('rgba(255,255,255,0.3)')
      .selectedColor(FQ_STORY_ORANGE)
      .blockColor(Color.White)
      .blockSize({ width: 14, height: 14 })
      .onChange((value: number, mode: SliderChangeMode) => {
        if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
          this.seekPreview = value;
        } else {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.player.seek(value);
          }
          this.seekPreview = -1;
          this.scheduleFsHide();
        }
      })
  }

  /** 选集胶囊：深灰条「选集 · 已完结 · 全82集 ↑」（官方 player-catalog-bar）。 */
  @Builder
  private CatalogBar() {
    Column({ space: 12 }){
      this.SeriesTitleRow()

      this.SeekBar()

      Row() {
        Row() {
          Text(this.catalogLabel())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          // 官方 keyboard_arrow_up：本地用已验证的 chevron_right 旋转 -90° 等价
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(20)
            .fontColor([Color.White])
            .rotate({ angle: -90 })
        }
        .height(40)
        .padding({ left: 16, right: 12 })
        .borderRadius(8)
        .backgroundColor('#E6222222')
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)
        .onClick((): void => {
          this.openCatalog();
        })

        // 评论入口：并入选集行右端（官方评论区入口占位），能力待后端支持
        Column({ space: 1 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(22)
            .fontColor([Color.White])
            .opacity(0.9)
          Text('评论')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('rgba(255,255,255,0.9)')
        }
        .width(44)
        .height(40)
        .margin({ left: 8 })
        .borderRadius(8)
        .backgroundColor('#E6222222')
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.getUIContext().getPromptAction()
            .showToast({ message: '评论功能即将上线', duration: 1500 });
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }.layoutGravity(LocalizedAlignment.BOTTOM_END)// stack组件中子组件对齐位置
    .offset({ bottom: appState.bottomRect })
  }

  // ---------------------------------------------------------------------------
  // 全屏控件层（官方 _landscapeBar：顶栏 + 底部控制条，3s 自动隐藏）
  // ---------------------------------------------------------------------------

  /** 全屏顶栏：渐变底、返回（退全屏）+「剧名(粗) 第N集」+ 倍速菜单。 */
  @Builder
  private FsTopBar() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.exitFullscreen();
        })

        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .padding({ left: 4 })

        Text(`第${this.episodes.length > 0 ? this.index + 1 : 1}集`)
          .fontSize(16)
          .fontColor(Color.White)
          .maxLines(1)
          .padding({ left: 6, right: 4 })

        Row() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(22)
            .fontColor([Color.White])
        }
        .width(40)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.openSettings();
        })
      }
      .height(44)
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: appState.topRect, left: 8, right: 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.54)', 0.0], ['rgba(0,0,0,0.0)', 1.0]],
    })
    .position({ x: 0, y: 0 })
  }

  /** 全屏底部控制条（官方 _landscapeBar）：播放/下一集/时间/进度/总时长 + 倍速/选集。 */
  @Builder
  private FsBottomBar() {
    Column() {
      Row() {
        SymbolGlyph(this.player.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(26)
          .fontColor([Color.White])
          .onClick((): void => {
            this.togglePlay();
            this.scheduleFsHide();
          })

        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(24)
          .fontColor([Color.White])
          .margin({ left: 18 })
          .onClick((): void => {
            this.nextEpisode();
            this.scheduleFsHide();
          })

        Text(fqFormatClock(this.displayPosition()))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ left: 18, right: 10 })

        this.SeekSlider()

        Text(fqFormatClock(this.player.state.duration))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ left: 10 })
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)

      Row({ space: 24 }) {
        Text(`${this.player.state.speed}×`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .onClick((): void => {
            this.openSettings();
          })

        Text('选集')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .onClick((): void => {
            this.openCatalog();
          })
      }
      .width('100%')
      .height(36)
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: appState.bottomRect > 0 ? appState.bottomRect : 8 })
    .linearGradient({
      angle: 180,
      colors: [['rgba(0,0,0,0.0)', 0.0], ['rgba(0,0,0,0.5)', 1.0]],
    })
    .position({ x: 0, y: '100%' })
    .markAnchor({ x: 0, y: '100%' })
  }

  /** 加载占位：封面 contain + spinner（官方 PlayerCover/PlayerLoadingFeedback）。 */
  @Builder
  private LoadingOverlay() {
    Stack() {
      if (this.coverUrl.length > 0) {
        Image(this.coverUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Black)
          .autoResize(true)
      }
      Column({ space: 10 }) {
        LoadingProgress()
          .width(42)
          .height(42)
          .color(Color.White)
        Text(`正在加载第 ${this.index + 1} 集`)
          .fontSize(13)
          .fontColor('rgba(255,255,255,0.85)')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 缓冲指示（起播后 mpv buffering，不遮画面只出 spinner）。 */
  @Builder
  private BufferingOverlay() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(42)
        .height(42)
        .color(Color.White)
      Text('缓冲中…')
        .fontSize(13)
        .fontColor('rgba(255,255,255,0.85)')
    }
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

  /** 选集半模态（官方 StoryPlayerPanel 白底样式）。 */
  @Builder
  private EpisodeSheetBuilder() {
    FqStoryPanel({
      episodes: this.episodes,
      currentIndex: this.index,
      seriesTitle: this.title,
      seriesCover: this.coverUrl,
      seriesIntro: PlayerNavParams.intro,
      episodeLabel: this.episodeLabel(),
      onSelectEpisode: (index: number): void => {
        this.closeSheet();
        this.loadEpisode(index);
      },
    })
  }

  /** 播放设置半模态（右上角菜单）：白底面板，倍速档位 3×2 格子，当前档位橙底高亮。 */
  @Builder
  private SettingsSheetBuilder() {
    Column() {
      Column().height(12)

      Row() {
        Text('播放设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(48)
      .padding({ left: 20, right: 16 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Text('倍速')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')
      .height(36)
      .padding({ left: 20 })
      .alignItems(VerticalAlign.Center)

      Grid() {
        ForEach(FQ_SPEEDS, (speed: number) => {
          GridItem() {
            Column() {
              Text(`${speed}×`)
                .fontSize(15)
                .fontWeight(this.isCurrentSpeed(speed) ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.isCurrentSpeed(speed) ? '#FFFA6725' : $r('sys.color.font'))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(8)
            .backgroundColor(this.isCurrentSpeed(speed) ? '#1AFA6725' : $r('sys.color.comp_background_list_card'))
            .onClick((): void => {
              this.player.setSpeed(speed);
              this.closeSettings();
            })
          }
        }, (speed: number) => `${speed}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .padding({ left: 16, right: 16, top: 4, bottom: 16 + appState.bottomRect })
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  // ---------------------------------------------------------------------------
  // 布局几何（官方 PlayerVideoLayout 竖屏语义）
  // ---------------------------------------------------------------------------

  /** 视频区顶：全屏贴顶；面板展开态撑满全屏（官方 _positionVideo 语义，避免余屏不对称下移）；常驻态顶栏 44 + 状态栏。 */
  private videoTopAbs(): number {
    if (this.fullScreen || this.sheetVisible) {
      return 0;
    }
    return appState.topRect + 44;
  }

  /** 视频区高：全屏/面板展开态撑满全屏；常驻态 = 屏高 − 顶栏 − 底部 163 信息区。 */
  private videoRegionHeight(): number {
    if (this.fullScreen || this.sheetVisible) {
      return this.screenH;
    }
    return Math.max(0,
      this.screenH - (appState.topRect + 44) - appState.bottomRect - FQ_STORY_BOTTOM_INSET);
  }

  /**
   * 底部信息区顶（官方 163 信息区）：剧名行锚点，
   * 恒在细进度线与选集胶囊上方（自上而下：剧名行 → 进度线 → 选集胶囊）。
   */
  private infoTop(): number {
    return this.screenH - appState.bottomRect - FQ_STORY_BOTTOM_INSET;
  }

  /**
   * 画面（contain 矩形）下沿：「全屏观看」药丸 + 评论按钮跟随播放区域下方
   * （官方 _PortraitControlsLayout videoBottom + 20；未知尺寸回退 9:16 预览）。
   */
  private videoBottom(): number {
    const regionH: number = this.videoRegionHeight();
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    let videoH: number = 0;
    if (dw > 0 && dh > 0) {
      videoH = Math.min(regionH, this.screenW / dw * dh);
    } else {
      videoH = Math.min(regionH, this.screenW * 16 / 9);
    }
    return this.videoTopAbs() + (regionH + videoH) / 2;
  }

  // ---------------------------------------------------------------------------
  // 文案
  // ---------------------------------------------------------------------------

  /** 选集胶囊文案：官方「选集 · ${状态} · 全N集」（e6r/ag_/agb）。 */
  private catalogLabel(): string {
    const count: number = this.episodes.length;
    if (this.creationStatus === 0) {
      return `选集 · 已完结 · 全${count}集`;
    }
    if (this.creationStatus === 1) {
      return `选集 · 连载中 · 全${count}集`;
    }
    return `选集 · 全${count}集`;
  }

  /** 面板头部集数/状态文案（官方 seriesEpisodeLabel：更新至N/已完结 共N）。 */
  private episodeLabel(): string {
    const count: number = this.episodes.length;
    if (this.creationStatus === 1) {
      return `更新至${count}集`;
    }
    if (this.creationStatus === 0) {
      return `已完结 共${count}集`;
    }
    return `共${count}集`;
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

  /** 横屏片源判定（官方 videoParams.dw > dh；加载前按竖屏处理）。 */
  private isLandscapeVideo(): boolean {
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    return dw > 0 && dh > 0 && dw > dh;
  }

  /** 当前倍速档位判定（浮点容差比较）。 */
  private isCurrentSpeed(speed: number): boolean {
    return Math.abs(this.player.state.speed - speed) < 0.01;
  }

  /** 打开播放设置半模态（右上角菜单 / 全屏控制条倍速入口）。 */
  private openSettings(): void {
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.settingsVisible = true;
    });
    if (this.fullScreen) {
      this.scheduleFsHide();
    }
  }

  /** 关闭播放设置半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeSettings(): void {
    const token: number = ++this.settingsCloseToken;
    setTimeout((): void => {
      if (token === this.settingsCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.settingsVisible = false;
        });
      }
    }, 0);
  }

  /** 画面单击：横屏全屏切控件显隐，其余切播放（官方 tapTogglesPlayback）。 */
  private onVideoTap(): void {
    if (this.fullScreen && this.isLandscapeVideo()) {
      this.toggleFsControls();
    } else {
      this.togglePlay();
    }
  }

  /** 全屏控件显隐切换（显示时重新计时自动隐藏）。 */
  private toggleFsControls(): void {
    if (this.fsControlsVisible) {
      this.fsControlsVisible = false;
      this.cancelFsHide();
    } else {
      this.fsControlsVisible = true;
      this.scheduleFsHide();
    }
  }

  /** 全屏控件 3s 自动隐藏计时。 */
  private scheduleFsHide(): void {
    this.cancelFsHide();
    this.fsHideTimer = setTimeout((): void => {
      this.fsHideTimer = 0;
      this.fsControlsVisible = false;
    }, FQ_FS_HIDE_MS);
  }

  private cancelFsHide(): void {
    if (this.fsHideTimer !== 0) {
      clearTimeout(this.fsHideTimer);
      this.fsHideTimer = 0;
    }
  }

  /** 进入全屏沉浸：横屏片源锁横屏并隐藏系统栏（官方 _enterFullscreen）。 */
  private enterFullscreen(): void {
    this.fullScreen = true;
    this.fsControlsVisible = true;
    this.scheduleFsHide();
    this.applyImmersive(true);
  }

  /** 退出全屏沉浸：恢复方向与系统栏。 */
  private exitFullscreen(): void {
    this.fullScreen = false;
    this.cancelFsHide();
    this.fsControlsVisible = true;
    this.applyImmersive(false);
  }

  /** 沉浸全屏：进入隐藏系统栏（横屏片源同时锁 AUTO_ROTATION_LANDSCAPE），退出恢复。 */
  private applyImmersive(enter: boolean): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      if (enter) {
        if (this.isLandscapeVideo()) {
          win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
        }
        win.setWindowSystemBarEnable([]);
      } else {
        win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
        win.setWindowSystemBarEnable(['status', 'navigation']);
      }
    }).catch((): void => {
      // 沉浸设置失败保持系统默认 UI，不影响播放
    });
  }

  /** 封面锚定（start 后 baseUrl 就绪；官方面板头/加载占位同源）。 */
  private resolveCover(): void {
    if (this.coverUrl.length === 0 && PlayerNavParams.cover.length > 0) {
      this.coverUrl = FqBackend.get().resourceUrl(PlayerNavParams.cover);
    }
  }

  /** 目录为空时先拉剧集目录（tab 由 kind 映射：短剧/漫剧）。 */
  private async loadEpisodes(): Promise<void> {
    const token: number = ++this.loadToken;
    this.loading = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      this.resolveCover();
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
    try {
      await FqBackend.get().start(getContext(this));
      this.resolveCover();
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

  /** 播放暂停切换；播完暂停态重播当前集；中央按钮点击才出现（暂停常驻/播放 3s 隐藏）。 */
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
    this.centerBtnVisible = true;
    if (wasPlaying) {
      // 点击后进入暂停：按钮常驻
      this.cancelCenterHide();
    } else {
      // 点击后进入播放：3s 后自动隐藏
      this.scheduleCenterHide();
    }
  }

  /** 中央播放按钮 3s 自动隐藏计时。 */
  private scheduleCenterHide(): void {
    this.cancelCenterHide();
    this.centerHideTimer = setTimeout((): void => {
      this.centerHideTimer = 0;
      this.centerBtnVisible = false;
    }, FQ_FS_HIDE_MS);
  }

  private cancelCenterHide(): void {
    if (this.centerHideTimer !== 0) {
      clearTimeout(this.centerHideTimer);
      this.centerHideTimer = 0;
    }
  }

  /** 下一集（横屏控制条/自动连播共用）。 */
  private nextEpisode(): void {
    if (this.index + 1 < this.episodes.length) {
      this.loadEpisode(this.index + 1);
    }
  }

  /** 播完回调：自动连播下一集；末集停在末帧。 */
  private onEpisodeEnd(): void {
    this.nextEpisode();
  }

  /** 失败重试：无目录先拉目录，否则重取当前集。 */
  private retry(): void {
    if (this.episodes.length === 0) {
      this.loadEpisodes();
    } else {
      this.loadEpisode(this.index);
    }
  }

  private openCatalog(): void {
    if (this.episodes.length === 0) {
      return;
    }
    // 官方面板展开 200ms：视频区随面板撑满全屏（_positionVideo panelFraction）
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.sheetVisible = true;
    });
  }

  /** 关闭半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.sheetVisible = false;
        });
      }
    }, 0);
  }
}

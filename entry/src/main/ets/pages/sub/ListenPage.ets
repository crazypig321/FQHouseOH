/**
 * 听书页（对齐 fqapp audio_page.dart + audio_sections.dart + voice_settings_sheet.dart）。
 *
 * 播放会话为应用级单例（core/FqAudioSession）：页面 pop 不停播，重进续播。
 * 本页只做展示与操作转发：封面卡（章名/书名/切音色/开目录）/ 章节试读 /
 * 状态行 / 动作排（语速/书架/下载/章评/更多）/ 进度排 / 控制排（目录/上下章/
 * 播放暂停/定时）/ 音色区 + 边听边读 / 相关作品，半模态：声音设置/目录/
 * 倍速/定时/播放设置/试读全文/同步字幕/章评。
 */

import { promptAction, display } from '@kit.ArkUI';
import { FQ_ACCENT } from '../../view/CommonCom';
import { CommonNav } from '../../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../../view/CommonSheet';
import { FqCatalogSheet } from '../../view/FqCatalogSheet';
import { FqCommentSheet, fqCommentSheetHeightVp } from '../../view/FqCommentSheet';
import {
  DetailNavParams,
  FqTitleBarOptions,
  ListenNavParams,
  ReaderNavParams,
  ROUTE_DETAIL,
  ROUTE_READER2,
} from '../../model/FqNavModels';
import { fqAudioSession, FqChapterOpenOptions } from '../../core/FqAudioSession';
import { FqAudioTone, FqRelatedWork } from '../../model/FqAudioModels';
import { FqChapter } from '../../model/FqModels';
import { FqShelfItem, FqShelfStore } from '../../core/FqShelfStore';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';

/** 播放倍速档（avPlayer 0.75 ~ 2）。 */
const FQ_RATES: number[] = [0.75, 1, 1.25, 1.5, 1.75, 2];

/** 定时分钟档（对齐 fqapp -1/15/30/60）。 */
const FQ_SLEEP_MINUTES: number[] = [15, 30, 60];

/** 听书页半模态种类（单 bindSheet 内切换内容，规避同节点多 bindSheet 互斥闪关）。 */
enum FqListenSheetKind {
  none = 0,
  voices = 1,
  catalog = 2,
  rates = 3,
  sleep = 4,
  more = 5,
  excerpt = 6,
  comments = 7,
}

/** 标题栏高度（对齐详情页避让）。 */
const FQ_LISTEN_TOP_INSET: number = 56;

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

/** 屏高比例（vp）：Sheet 高度用，异常回退 600。 */
function fqRatioScreenHeightVp(ratio: number): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  const height: number = Math.round((screenHeight / density) * ratio);
  return height > 0 ? height : 600;
}

@ComponentV2
export struct ListenPage {
  @Local seekPreview: number = -1;
  /** 当前半模态种类（内容与高度选择器）。 */
  @Local activeSheet: FqListenSheetKind = FqListenSheetKind.none;
  /** bindSheet 显隐（独立于 activeSheet：关闭时内容保留至关闭动画结束，避免标题栏事件内同步改 isShow 被框架丢弃）。 */
  @Local sheetVisible: boolean = false;
  /** 关闭令牌：新开/新关使旧的延迟关闭失效。 */
  private sheetCloseToken: number = 0;
  @Local catalogOpenToken: number = 0;
  /** 章评打开令牌：每次打开 +1（公共 FqCommentSheet 据此重拉当前章章评）。 */
  @Local commentsOpenToken: number = 0;
  /** 书架态刷新令牌（toggle 后驱动 @Computed 重算）。 */
  @Local shelfRefresh: number = 0;
  private scroller: Scroller = new Scroller();
  /** 音色条横向列表滚动器（定位选中项）。 */
  private toneChipScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    FqShelfStore.init(getContext(this));
    fqAudioSession.open(ListenNavParams.bookId, ListenNavParams.tab,
      ListenNavParams.title, ListenNavParams.cover, ListenNavParams.chapters);
  }

  /** 当前书是否在书架（依赖 bookId 与刷新令牌）。 */
  @Computed
  get inShelf(): boolean {
    const tick: number = this.shelfRefresh;
    return tick >= 0 && FqShelfStore.contains(fqAudioSession.bookId);
  }

  /** 播放中（控制排图标）。 */
  @Computed
  get playing(): boolean {
    return fqAudioSession.wantPlay && !fqAudioSession.completed;
  }

  /** 进度排显示值（拖动预览优先）。 */
  @Computed
  get displayPositionSec(): number {
    return this.seekPreview >= 0 ? this.seekPreview : fqAudioSession.positionSec;
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('听书', false),
      scroller: this.scroller,
    }) {
      Scroll(this.scroller) {
        Column() {
          this.CoverCard()
          this.ExcerptBlock()
          this.StatusLine()
          this.ActionRow()
          this.ProgressRow()
          this.TransportRow()
          this.ToneSection()
        //  this.RelatedRow()
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

  /** 封面卡：章名 + 书名贴底，整卡开目录，右上角切音色。 */
  @Builder
  private CoverCard() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(fqAudioSession.cover)
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
          Text(fqAudioSession.chapter !== null ? fqAudioSession.chapter.title : '')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .lineHeight(19.5)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 14, right: 14, bottom: 4 })

          Row() {
            Text(fqAudioSession.title)
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
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)

        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.waveform_headphones'))
              .fontSize(14)
              .fontColor([Color.White])
          }
          .width(26)
          .height(26)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(0,0,0,0.28)')
          .borderRadius(13)
          .onClick((): void => {
            this.openVoices();
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: 8, right: 8 })
        .alignItems(HorizontalAlign.End)
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

  /** 章节试读（两行，点击看全文）。 */
  @Builder
  private ExcerptBlock() {
    if (fqAudioSession.excerpt.length > 0) {
      Text(fqAudioSession.excerpt)
        .fontSize(15)
        .lineHeight(22.5)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 20, right: 20, top: 12 })
        .alignSelf(ItemAlign.Start)
        .onClick((): void => {
          this.openSheet(FqListenSheetKind.excerpt);
        })
    }
  }

  /** 状态行：错误（带重试）/ 加载中 / 播完 / 播放 / 暂停。 */
  @Builder
  private StatusLine() {
    Column({ space: 6 }) {
      if (fqAudioSession.errorMessage.length > 0) {
        Text(fqAudioSession.errorMessage)
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
            fqAudioSession.openChapter(fqAudioSession.index,
              new FqChapterOpenOptions(fqAudioSession.toneId, fqAudioSession.positionSec, true, false));
          })
      } else if (fqAudioSession.loading) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color(FQ_ACCENT)
          Text('正在加载音频…')
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      } else if (fqAudioSession.completed) {
        Text('本章已播完')
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
      } else if (fqAudioSession.wantPlay) {
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
  private ActionItem(icon: Resource, label: string, active: boolean, onTap: () => void) {
    Column({ space: 5 }) {
      SymbolGlyph(icon)
        .fontSize(21)
        .fontColor([active ? FQ_ACCENT : $r('sys.color.font_primary')])
      Text(label)
        .fontSize(11)
        .maxLines(1)
        .fontColor(active ? FQ_ACCENT : $r('sys.color.font_secondary'))
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      onTap();
    })
  }

  /** 书架动作键（图标/文案随 inShelf 实时刷新，不走按值传参）。 */
  @Builder
  private ShelfActionItem() {
    Column({ space: 5 }) {
      SymbolGlyph(this.inShelf ? $r('sys.symbol.bookshelf_badge_checkmark_fill')
        : $r('sys.symbol.bookshelf_badge_plus'))
        .fontSize(21)
        .fontColor([this.inShelf ? FQ_ACCENT : $r('sys.color.font_primary')])
      Text(this.inShelf ? '已在书架' : '加入书架')
        .fontSize(11)
        .maxLines(1)
        .fontColor(this.inShelf ? FQ_ACCENT : $r('sys.color.font_secondary'))
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .onClick((): void => {
      this.toggleShelf();
    })
  }

  /** 动作排：语速 / 书架 / 下载 / 章评 / 更多。 */
  @Builder
  private ActionRow() {
    Row() {
     this.ActionItem($r('sys.symbol.timer'), '语速', false, (): void => {
        this.openSheet(FqListenSheetKind.rates);
      })
      this.ShelfActionItem()
      this.ActionItem($r('sys.symbol.download'), '下载', false, (): void => {
        promptAction.showToast({ message: '下载功能即将上线', duration: 1500 });
      })
      this.ActionItem($r('sys.symbol.message'), '章评', false, (): void => {
        this.commentsOpenToken += 1;
        this.openSheet(FqListenSheetKind.comments);
      })
      this.ActionItem($r('sys.symbol.ellipsis_circle'), '更多', false, (): void => {
        this.openSheet(FqListenSheetKind.more);
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8 })
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
            fqAudioSession.seekTo(fqAudioSession.positionSec - 15);
          })
        Slider({
          value: this.displayPositionSec,
          min: 0,
          max: fqAudioSession.durationSec > 0 ? fqAudioSession.durationSec : 1,
          step: 1,
        })
          .layoutWeight(1)
          .trackThickness(3)
          .blockSize({ width: 14, height: 14 })
          .selectedColor(FQ_ACCENT)
          .trackColor($r('sys.color.comp_divider'))
          .blockColor(FQ_ACCENT)
          .enabled(fqAudioSession.durationSec > 0)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.End) {
              this.seekPreview = -1;
              fqAudioSession.seekTo(value);
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
            fqAudioSession.seekTo(fqAudioSession.positionSec + 15);
          })
      }
      .width('100%')
      Text(`${fqFormatClock(this.displayPositionSec)}/${fqFormatClock(fqAudioSession.durationSec)}`)
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

  /** 控制排：目录 / 上一章 / 播放暂停 / 下一章 / 定时。 */
  @Builder
  private TransportRow() {
    Row({ space: 0 }) {
      this.TransportItem($r('sys.symbol.list_bullet'), '目录', false, true, (): void => {
        this.openCatalog();
      })
      this.TransportItem($r('sys.symbol.backward_end_fill'), '上一章', false,
        fqAudioSession.index > 0, (): void => {
          fqAudioSession.previous();
        })
      SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(38)
        .fontColor([$r('sys.color.font_primary')])
        .padding(11)
        .onClick((): void => {
          fqAudioSession.togglePlayPause();
        })
        .accessibilityText(this.playing ? '暂停' : '播放')
      this.TransportItem($r('sys.symbol.forward_end_fill'), '下一章', false,
        fqAudioSession.hasNextChapter, (): void => {
          fqAudioSession.next();
        })
      this.TransportItem($r('sys.symbol.stopwatch_1'), '定时', fqAudioSession.sleepActive, true,
        (): void => {
          this.openSheet(FqListenSheetKind.sleep);
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceEvenly)
    .padding({ top: 6 })
  }

  /** 音色条（选中优先）。 */
  @Builder
  private ToneChip(tone: FqAudioTone) {
    Column({ space: 4 }) {
      Text(tone.title)
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.toneChipSelected(tone) ? FQ_ACCENT : $r('sys.color.font_primary'))
      if (tone.description.length > 0) {
        Text(tone.description)
          .fontSize(11)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.font_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .constraintSize({ minWidth: 96, maxWidth: 120 })
    .height('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.toneChipSelected(tone) ? '#1AFF7A3D'
      : $r('sys.color.comp_background_list_card'))
    .border({
      width: this.toneChipSelected(tone) ? 1.2 : 0,
      color: this.toneChipSelected(tone) ? '#52FF7A3D' : Color.Transparent,
    })
    .onClick((): void => {
      if (fqAudioSession.hasFixedTone) {
        fqAudioSession.selectNarrator(tone);
      } else {
        fqAudioSession.selectTone(tone);
      }
      this.scrollToneChipsToSelected();
    })
    .accessibilityText(`选择音色 ${tone.title}`)
  }

  /** 音色区：左音色卡 + 右边听边读卡。 */
  @Builder
  private ToneSection() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Row({ space: 4 }) {
          Text(fqAudioSession.hasFixedTone ? '真人讲书' : '智能朗读')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .padding({ left: 8, right: 8 })

        if (this.toneChips().length === 0) {
          Text('暂无可选音色')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 8 })
            .layoutWeight(1)
        } else {
          List({ space: 6, scroller: this.toneChipScroller }) {
            ForEach(this.toneChips(), (tone: FqAudioTone) => {
              ListItem(){
                this.ToneChip(tone)
              }
            }, (tone: FqAudioTone) => tone.id)
          }
          .height('100%')
          .padding({ left: 8, right: 8 })
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .onAppear((): void => {
            this.scrollToneChipsToSelected();
          })
        }
      }
      .layoutWeight(237)
      .height(116)
      .padding({ left: 4, right: 4, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .alignItems(HorizontalAlign.Start)
      .onClick((): void => {
        this.openVoices();
      })

      Column({ space: 8 }) {
        Row({ space: 4 }) {
          Text('边听边读')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .padding({ left: 8, right: 8 })

        Text(fqAudioSession.chapter !== null ? fqAudioSession.chapter.title : '')
          .fontSize(13)
          .lineHeight(17.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })
          .layoutWeight(1)
      }
      .layoutWeight(133)
      .height(116)
      .padding({ left: 4, right: 4, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .alignItems(HorizontalAlign.Start)
      .onClick((): void => {
        this.openReadAlong();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, top: 16 })

  }

  /** 相关作品卡。 */
  @Builder
  private RelatedCard(work: FqRelatedWork) {
    Row({ space: 9 }) {
      if (work.cover.length > 0) {
        Image(work.cover)
          .width(44)
          .height(58)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .autoResize(true)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .draggable(false)
      } else {
        Column() {
          SymbolGlyph(work.kind === 'video' ? $r('sys.symbol.video') : $r('sys.symbol.book'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(44)
        .height(58)
        .borderRadius(6)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .justifyContent(FlexAlign.Center)
      }
      Column({ space: 5 }) {
        Text(work.title)
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .lineHeight(16.9)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(work.label)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width(218)
    .padding(8)
    .borderRadius(12)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .border({ width: 0.8, color: $r('sys.color.comp_divider') })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.openRelated(work);
    })
  }

  /** 相关作品横排。 */
  @Builder
  private RelatedRow() {
    if (fqAudioSession.relatedWorks.length > 0) {
      Scroll() {
        Row({ space: 10 }) {
          ForEach(fqAudioSession.relatedWorks, (work: FqRelatedWork) => {
            this.RelatedCard(work)
          }, (work: FqRelatedWork) => `${work.kind}_${work.id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ left: 12, right: 12, top: 18 })
    }
  }

  // ---------------------------------------------------------------------------
  // 半模态
  // ---------------------------------------------------------------------------

  /** 声音设置：真人讲书行 + 智能朗读双列卡。 */
  @Builder
  private VoicesSheetBuilder() {
    CommonSheet({
      sheetTitle: '声音设置',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List({ space: 16 }) {
        if (fqAudioSession.toneSet.narratorTones.length > 0) {
          ListItem(){
            Column({ space: 10 }){
              Text('真人讲书')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_tertiary'))
                .alignSelf(ItemAlign.Start)


              ForEach(fqAudioSession.toneSet.narratorTones, (voice: FqAudioTone) => {
                Text(voice.title)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(this.voiceSelected(voice) ? FQ_ACCENT : $r('sys.color.font_primary'))
                  .width('100%')
                  .height(48)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(8)
                  .backgroundColor(this.voiceSelected(voice) ? '#1AFF7A3D'
                    : $r('sys.color.comp_background_list_card'))
                  .border({
                    width: this.voiceSelected(voice) ? 1 : 0,
                    color: this.voiceSelected(voice) ? '#52FF7A3D' : Color.Transparent,
                  })
                  .onClick((): void => {
                    fqAudioSession.selectNarrator(voice);
                    this.closeSheet();
                    this.scrollToneChipsToSelected();
                  })
              }, (voice: FqAudioTone) => voice.id)
            }.width('100%')
          }
        }
        if (fqAudioSession.onlineToneOptions().length > 0) {
          ListItem() {
            Column({ space: 10 }){
              Text('智能朗读')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_tertiary'))
                .alignSelf(ItemAlign.Start)

              GridRow({ columns: 2, gutter: { x: 12, y: 12 } }) {
                ForEach(fqAudioSession.onlineToneOptions(), (voice: FqAudioTone) => {
                  GridCol() {
                    this.VoiceCard(voice)
                  }
                }, (voice: FqAudioTone) => voice.id)
              }.width('100%')
            }
          }.width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
      .contentEndOffset(appState.bottomRect)
    }
  }

  /** 智能朗读音色卡（双列网格单元）。 */
  @Builder
  private VoiceCard(voice: FqAudioTone) {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        Text(voice.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.voiceSelected(voice) ? FQ_ACCENT : $r('sys.color.font_primary'))
          .layoutWeight(1)
        if (this.voiceSelected(voice)) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(14)
            .fontColor([FQ_ACCENT])
        }
      }
      .width('100%')
      if (voice.description.length > 0) {
        Text(voice.description)
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('sys.color.font_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height(64)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(8)
    .backgroundColor(this.voiceSelected(voice) ? '#1AFF7A3D'
      : $r('sys.color.comp_background_list_card'))
    .border({
      width: this.voiceSelected(voice) ? 1 : 0,
      color: this.voiceSelected(voice) ? '#52FF7A3D' : Color.Transparent,
    })
    .onClick((): void => {
      fqAudioSession.selectTone(voice);
      this.closeSheet();
      this.scrollToneChipsToSelected();
    })
  }

  /** 目录：公共 FqCatalogSheet，点击章节切播。 */
  @Builder
  private CatalogSheetBuilder() {
    FqCatalogSheet({
      chapters: fqAudioSession.chapters,
      fontColor: $r('sys.color.font_primary'),
      currentChapterIndex: fqAudioSession.index,
      progressOf: (index: number): string => this.catalogProgressOf(index),
      openToken: this.catalogOpenToken,
      contentEndExtra: 0,
      chapterClick: (index: number): void => {
        this.closeSheet();
        fqAudioSession.openChapter(index,
          new FqChapterOpenOptions(fqAudioSession.toneId, 0, true, false));
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
              .fontColor(rate === fqAudioSession.rate ? FQ_ACCENT
                : $r('sys.color.font_primary'))
            Blank()
            if (rate === fqAudioSession.rate) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([FQ_ACCENT])
            }
          }
          .width('100%')
          .height(48)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .backgroundColor(rate === fqAudioSession.rate ? '#1AFF7A3D' : Color.Transparent)
          .onClick((): void => {
            fqAudioSession.setRate(rate);
            this.closeSheet();
          })
        }, (rate: number) => `rate_${rate}`)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  /** 定时关闭：分钟档 / 播完本章 / 关闭定时。 */
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
              .fontColor(fqAudioSession.sleepMinutesChoice === minutes ? FQ_ACCENT
                : $r('sys.color.font_primary'))
            Blank()
            if (fqAudioSession.sleepMinutesChoice === minutes) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([FQ_ACCENT])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 10, right: 10 })
          .borderRadius(8)
          .backgroundColor(fqAudioSession.sleepMinutesChoice === minutes
            ? '#1AFF7A3D' : Color.Transparent)
          .onClick((): void => {
            fqAudioSession.setSleepMinutes(minutes);
            this.closeSheet();
            promptAction.showToast({ message: `将在 ${minutes} 分钟后停止播放`, duration: 1500 });
          })
        }, (minutes: number) => `sleep_${minutes}`)
        Row() {
          Text('播完本章')
            .fontSize(15)
            .fontColor(fqAudioSession.sleepAtChapterEnd ? FQ_ACCENT
              : $r('sys.color.font_primary'))
          Blank()
          if (fqAudioSession.sleepAtChapterEnd) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([FQ_ACCENT])
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 10, right: 10 })
        .borderRadius(8)
        .backgroundColor(fqAudioSession.sleepAtChapterEnd ? '#1AFF7A3D' : Color.Transparent)
        .onClick((): void => {
          fqAudioSession.setSleepAtChapterEnd();
          this.closeSheet();
          promptAction.showToast({ message: '将在播完本章后停止', duration: 1500 });
        })
        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ top: 6, bottom: 6, left: 10, right: 10 })
        Row() {
          Text('关闭定时')
            .fontSize(15)
            .fontColor(!fqAudioSession.sleepActive ? FQ_ACCENT
              : $r('sys.color.font_primary'))
          Blank()
          if (!fqAudioSession.sleepActive) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([FQ_ACCENT])
          }
        }
        .width('100%')
        .height(48)
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .backgroundColor(!fqAudioSession.sleepActive ? '#1AFF7A3D' : Color.Transparent)
        .onClick((): void => {
          fqAudioSession.clearSleep();
          this.closeSheet();
          promptAction.showToast({ message: '已关闭定时', duration: 1500 });
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  /** 更多（播放设置）：定时 / 目录 / 自动连播。 */
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
        Column() {
        Row({ space: 12 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.timer'))
              .fontSize(20)
              .fontColor(['#FF3B82F6'])
          }
          .width(38)
          .height(38)
          .borderRadius(10)
          .backgroundColor('#1A3B82F6')
          .justifyContent(FlexAlign.Center)
          Column({ space: 2 }) {
            Text('定时关闭')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text(this.sleepSummary())
              .fontSize(12.5)
              .fontColor(fqAudioSession.sleepActive ? '#FF3B82F6'
                : $r('sys.color.font_secondary'))
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
          this.openSheet(FqListenSheetKind.sleep);
        })

        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 68, right: 16 })

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
            Text('书籍目录')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text(`共 ${fqAudioSession.chapters.length} 章`)
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
            Text('自动下一章')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
            Text('当前章节播完后自动连播')
              .fontSize(12.5)
              .fontColor($r('sys.color.font_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: fqAudioSession.autoAdvance })
            .onChange((isOn: boolean): void => {
              fqAudioSession.setAutoAdvance(isOn);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      .width('100%')
      .borderRadius(18)
      .backgroundColor($r('sys.color.comp_background_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 20 })
    }
  }

  /** 章节试读全文。 */
  @Builder
  private ExcerptSheetBuilder() {
    CommonSheet({
      sheetTitle: '章节试读',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      Scroll() {
        Text(fqAudioSession.excerpt)
          .fontSize(15)
          .lineHeight(25.5)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
    }
  }

  /** 章评：公共 FqCommentSheet（当前章章末聚合桶）。 */
  @Builder
  private CommentsSheetBuilder() {
    FqCommentSheet({
      bookId: fqAudioSession.bookId,
      fontColor: $r('sys.color.font_primary'),
      commentLabel: '章评',
      chapterItemId: this.currentChapterItemId(),
      chapterVersion: this.currentChapterVersion(),
      openToken: this.commentsOpenToken,
    })
  }

  /** 当前播章 itemId（章评入口；无章节时空串回退书评）。 */
  private currentChapterItemId(): string {
    const chapter: FqChapter | null = fqAudioSession.chapter;
    return chapter !== null ? chapter.itemId : '';
  }

  /** 当前播章内容版本（章评接口必传）。 */
  private currentChapterVersion(): string {
    const chapter: FqChapter | null = fqAudioSession.chapter;
    return chapter !== null ? chapter.version : '';
  }

  /** 单 bindSheet：按 activeSheet 切换半模态内容。 */
  @Builder
  private ActiveSheetBuilder() {
    if (this.activeSheet === FqListenSheetKind.voices) {
      this.VoicesSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.catalog) {
      this.CatalogSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.rates) {
      this.RatesSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.sleep) {
      this.SleepSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.more) {
      this.MoreSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.excerpt) {
      this.ExcerptSheetBuilder()
    } else if (this.activeSheet === FqListenSheetKind.comments) {
      this.CommentsSheetBuilder()
    }
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  private openCatalog(): void {
    this.catalogOpenToken += 1;
    this.openSheet(FqListenSheetKind.catalog);
  }

  private openVoices(): void {
    this.openSheet(FqListenSheetKind.voices);
  }

  /** 打开半模态：切换内容并置 isShow（使旧延迟关闭失效）。 */
  private openSheet(kind: FqListenSheetKind): void {
    this.sheetCloseToken += 1;
    this.activeSheet = kind;
    this.sheetVisible = true;
  }

  /**
   * 关闭半模态：仅切 isShow，内容（activeSheet）保留到下次 openSheet 再切换。
   * 标题栏（HDS menu）事件回调内同步改 isShow 会因重入渲染被丢弃，故延迟一拍；
   * 关闭时同步清空 builder 内容（activeSheet=none）同样会导致面板残留，故不清理。
   */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.sheetVisible = false;
      }
    }, 0);
  }

  /** 各半模态高度（对齐原分挂 bindSheet 时 FqSheetOptions 的高度）。 */
  private sheetHeight(): SheetSize | Length {
    switch (this.activeSheet) {
      case FqListenSheetKind.voices:
        return fqRatioScreenHeightVp(0.72);
      case FqListenSheetKind.rates:
        return 380;
      case FqListenSheetKind.sleep:
        return 420;
      case FqListenSheetKind.more:
        return 400;
      case FqListenSheetKind.excerpt:
        return 460;
      case FqListenSheetKind.comments:
        return fqCommentSheetHeightVp();
      default:
        return 600;
    }
  }

  private toggleShelf(): void {
    const added: boolean = FqShelfStore.toggle(
      new FqShelfItem(fqAudioSession.bookId, 'audio', fqAudioSession.title, fqAudioSession.cover));
    this.shelfRefresh += 1;
    promptAction.showToast({ message: added ? '已加入书架' : '已移出书架', duration: 1500 });
  }

  private openRelated(work: FqRelatedWork): void {
    if (work.id.length === 0) {
      return;
    }
    DetailNavParams.id = work.id;
    DetailNavParams.kind = work.kind === 'video' ? 'video' : 'book';
    DetailNavParams.title = work.title;
    DetailNavParams.cover = work.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  /** 边听边读：进阅读页跟读（播放不停，阅读页高亮朗读段落并自动翻页/跟章）。 */
  private openReadAlong(): void {
    if (fqAudioSession.bookId.length === 0) {
      return;
    }
    ReaderNavParams.id = fqAudioSession.bookId;
    ReaderNavParams.kind = fqAudioSession.tab === '小说' ? 'book' : 'audio';
    ReaderNavParams.title = fqAudioSession.title;
    ReaderNavParams.chapterIndex = fqAudioSession.index;
    ReaderNavParams.listenAlong = true;
    NavPathUtils.push(ROUTE_READER2);
  }

  /** 音色条显示列表（保持原始顺序，滚动定位到选中项）。 */
  private toneChips(): FqAudioTone[] {
    return fqAudioSession.hasFixedTone
      ? fqAudioSession.toneSet.narratorTones : fqAudioSession.toneSet.ttsTones;
  }

  /** 音色条滚动到选中项（不排序，仅定位）。 */
  private scrollToneChipsToSelected(): void {
    const chips: FqAudioTone[] = this.toneChips();
    for (let i = 0; i < chips.length; i++) {
      if (this.toneChipSelected(chips[i])) {
        this.toneChipScroller.scrollToIndex(i, false);
        return;
      }
    }
  }

  private toneChipSelected(tone: FqAudioTone): boolean {
    return fqAudioSession.hasFixedTone
      ? tone.id === fqAudioSession.bookId : tone.id === fqAudioSession.toneId;
  }

  /** 声音设置面板选中态。 */
  private voiceSelected(voice: FqAudioTone): boolean {
    return fqAudioSession.hasFixedTone
      ? voice.id === fqAudioSession.bookId : voice.id === fqAudioSession.toneId;
  }

  /** 目录进度列：当前章显示百分比。 */
  private catalogProgressOf(index: number): string {
    if (index !== fqAudioSession.index || fqAudioSession.durationSec <= 0) {
      return '';
    }
    const percent: number = Math.min(100,
      Math.round((fqAudioSession.positionSec / fqAudioSession.durationSec) * 100));
    return `${percent}%`;
  }

  /** 更多面板的定时副标题。 */
  private sleepSummary(): string {
    if (fqAudioSession.sleepAtChapterEnd) {
      return '播完本章后停止';
    }
    if (fqAudioSession.sleepRemainingSec > 0) {
      return `剩余 ${Math.ceil(fqAudioSession.sleepRemainingSec / 60)} 分钟`;
    }
    return '未开启';
  }
}

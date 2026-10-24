/**
 * 官方短剧选集面板（对齐 fqapp widgets/player/story_player_panel.dart）：
 * 白底、grabber 36×4、剧信息头（封面 64×86 + 标题 + 集数文案）、
 * 「选集」tab（14sp 粗体 #FF1B1B1B、左 20）、>30 集分页条「1-30」、
 * 6 列格子（官方 bbw.xml + hj3/r0.java + colors.xml）：
 * 当前集 文字 #FFFA6725、底 #1AFA6725、粗体 + 右上播放角标；
 * 已看 #66000000；普通 #FF000000；格底 #08000000、圆角 8。
 * 打开时当前集滚动到视口竖直居中（官方 gj3/o.java:237-272）。
 */

import { FqChapter } from '../model/FqModels';
import { appState } from '../entryability/AppState';

/** 官方长剧分页粒度（gj3/o.java:731 setGroupByCount(30)）。 */
const FQ_STORY_PAGE_SIZE: number = 30;

@ComponentV2
export struct FqStoryPanel {
  /** 剧集目录。 */
  @Param episodes: FqChapter[] = [];
  /** 当前集下标。 */
  @Param currentIndex: number = 0;
  /** 剧名（头部）。 */
  @Param seriesTitle: string = '';
  /** 剧封面（头部 64×86）。 */
  @Param seriesCover: string = '';
  /** 集数/状态文案（头部，如「已完结 共82集」）。 */
  @Param episodeLabel: string = '';
  /** 选集回调。 */
  @Param onSelectEpisode: (index: number) => void = (index: number): void => {
  };

  /** 分页条选中页（可视区顶部所在段）。 */
  @Local page: number = 0;
  private scroller: Scroller = new Scroller();
  private locateTimer: number = 0;

  aboutToAppear(): void {
    this.page = Math.floor(this.currentIndex / FQ_STORY_PAGE_SIZE);
    // 打开面板把当前集滚到视口竖直居中（官方 gj3/o.java:237-272）。
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = 0;
      this.scroller.scrollToIndex(this.currentIndex, false, ScrollAlign.CENTER);
    }, 100);
  }

  aboutToDisappear(): void {
    if (this.locateTimer !== 0) {
      clearTimeout(this.locateTimer);
      this.locateTimer = 0;
    }
  }

  build() {
    Column() {
      // grabber：36×4、#1A000000、圆角 2（官方 aa8.xml:6）
      Column() {
        Column()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor('#1A000000')
      }
      .width('100%')
      .height(12)
      .justifyContent(FlexAlign.Center)

      this.SeriesHeader()

      // 官方单 tab「选集」：14sp 粗体 #FF1B1B1B、padding 左 20（hj3/p.java:97-124）
      Row() {
        Text('选集')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FF1B1B1B')
          .padding({ left: 20 })
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)

      if (this.episodes.length > FQ_STORY_PAGE_SIZE) {
        this.PagingStrip()
      }

      if (this.episodes.length === 0) {
        Column() {
          Text('暂无剧集')
            .fontSize(14)
            .fontColor('#FF9499A0')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid(this.scroller) {
          ForEach(this.episodes, (episode: FqChapter, index: number) => {
            GridItem() {
              Stack({ alignContent: Alignment.TopEnd }) {
                // 序号居中（badge 独立 TopEnd 叠放）
                Row({ space: 2 }) {
                  Text(`${index + 1}`)
                    .fontSize(14)
                    .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(this.tileTextColor(index))

                  if (index === this.currentIndex) {
                    // 当前集右上 12×12 播放角标（官方 video_playing_orange.json，
                    // 本地以静态三角替代）
                    SymbolGlyph($r('sys.symbol.play_fill'))
                      .fontSize(11)
                      .fontColor(['#FFFA6725'])
                      .margin(4)
                  }
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .aspectRatio(53 / 52)
              .borderRadius(8)
              .backgroundColor(index === this.currentIndex ? '#1AFA6725' : '#08000000')
              .onClick((): void => {
                this.onSelectEpisode(index);
              })
            }
          }, (episode: FqChapter, index: number) => `${episode.itemId}-${index}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .scrollBar(BarState.Off)
        .padding({ left: 12, right: 12, top: 4, bottom: 16 + appState.bottomRect })
        .width('100%')
        .layoutWeight(1)
        .onScrollIndex((first: number, last: number): void => {
          const page: number = Math.floor(first / FQ_STORY_PAGE_SIZE);
          if (page !== this.page && page >= 0 && page <= this.lastPage()) {
            this.page = page;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 官方剧信息头（aa8.xml:7-15）：封面 + 标题行（右箭头）+ 集数/状态文案。 */
  @Builder
  private SeriesHeader() {
    if (this.seriesTitle.length > 0 || this.episodeLabel.length > 0) {
      Row({ space: 12 }) {
        if (this.seriesCover.length > 0) {
          Image(this.seriesCover)
            .width(64)
            .height(86)
            .borderRadius(6)
            .objectFit(ImageFit.Cover)
            .autoResize(true)
        } else {
          // 官方封面占位：剧集首帧同款深色块
          Column() {
            SymbolGlyph($r('sys.symbol.film'))
              .fontSize(24)
              .fontColor(['#FF9499A0'])
          }
          .width(64)
          .height(86)
          .borderRadius(6)
          .backgroundColor('#FFEDEDF0')
          .justifyContent(FlexAlign.Center)
        }
        Column({ space: 6 }) {
          Row({ space: 2 }) {
            Text(this.seriesTitle.length > 0 ? this.seriesTitle : '短剧')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FF1B1B1B')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor(['#FF9499A0'])
          }
          .width('100%')

          if (this.episodeLabel.length > 0) {
            Text(this.episodeLabel)
              .fontSize(13)
              .fontColor('#FF9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 官方 >30 集分页条：横向「1-30/31-60/…」，滚动联动（view/f.java:669-739）。 */
  @Builder
  private PagingStrip() {
    Scroll() {
      Row({ space: 20 }) {
        ForEach(this.pageLabels(), (label: string, page: number) => {
          Text(label)
            .fontSize(14)
            .fontWeight(page === this.page ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(page === this.page ? '#FF1B1B1B' : '#66000000')
            .onClick((): void => {
              this.page = page;
              this.scroller.scrollToIndex(page * FQ_STORY_PAGE_SIZE, false, ScrollAlign.START);
            })
        }, (label: string) => label)
      }
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height(36)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
  }

  /** 格子文字色：当前集橙、已看（当前集之前）灰、普通黑。 */
  private tileTextColor(index: number): string {
    if (index === this.currentIndex) {
      return '#FFFA6725';
    }
    if (index < this.currentIndex) {
      return '#66000000';
    }
    return '#FF000000';
  }

  private lastPage(): number {
    return Math.max(0, Math.ceil(this.episodes.length / FQ_STORY_PAGE_SIZE) - 1);
  }

  private pageLabels(): string[] {
    const labels: string[] = [];
    const pages: number = this.lastPage() + 1;
    for (let page: number = 0; page < pages; page++) {
      const start: number = page * FQ_STORY_PAGE_SIZE + 1;
      const end: number = Math.min((page + 1) * FQ_STORY_PAGE_SIZE, this.episodes.length);
      labels.push(`${start}-${end}`);
    }
    return labels;
  }
}

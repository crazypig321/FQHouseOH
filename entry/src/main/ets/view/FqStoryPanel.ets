/**
 * 官方短剧选集面板（对齐 fqapp widgets/player/story_player_panel.dart）：
 * 剧信息头（封面 64×86 + 标题 + 集数文案 + 简介小字 2 行省略）、
 * 「选集」tab（14sp 粗体、左 20）、>30 集分页条「1-30」、
 * 6 列格子（官方 bbw.xml + hj3/r0.java + colors.xml）：
 * 当前集 文字 #FFFA6725、底 #1AFA6725、粗体 + 右上播放角标；
 * 已看（按集 itemId 持久化记录，跳集不误标）#66000000；普通 #FF000000；
 * 格底 #08000000、圆角 8。
 * 打开时当前集滚动到视口竖直居中（官方 gj3/o.java:237-272）。
 */

import { FqChapter, FqChapterDataSource } from '../model/FqModels';
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
  /** 剧简介（头部小字，最多 2 行不全部显示）。 */
  @Param seriesIntro: string = '';
  /** 已看集 itemId 集合（FqWatchedStore 持久化记录；与下标无关，跳集不误标）。 */
  @Param watchedIds: Set<string> = new Set<string>();
  /** 选集回调。 */
  @Param onSelectEpisode: (index: number) => void = (index: number): void => {
  };
  /** 同系列入口（选集 tab 行右端「同系列」按钮；null 不显示，官方 StoryPlayerPanel）。 */
  @Param onOpenRelatedSeries: (() => void) | null = null;
  /** 剧名行点击进剧集详情（官方 onOpenSeries；null 不响应）。 */
  @Param onOpenSeries: (() => void) | null = null;
  /** 「选集」行收藏按钮（一键加入/移出书架；定位图标之前；false 不显示）。 */
  @Param showFavorite: boolean = false;
  /** 收藏状态（已在书架时 checkmark 实心 + 官方橙高亮）。 */
  @Param favoriteActive: boolean = false;
  /** 收藏按钮点击（宿主负责 toggle 与 toast）。 */
  @Param onToggleFavorite: (() => void) | null = null;

  /** 分页条选中页（可视区顶部所在段）。 */
  @Local page: number = 0;
  /** LazyForEach 目录数据源（episodes 引用替换时 reload）。 */
  private source: FqChapterDataSource = new FqChapterDataSource();
  private scroller: Scroller = new Scroller();
  private locateTimer: number = 0;

  aboutToAppear(): void {
    this.source.reload(this.episodes);
    this.page = Math.floor(this.currentIndex / FQ_STORY_PAGE_SIZE);
    // 打开面板把当前集滚到视口竖直居中（官方 gj3/o.java:237-272）。
    this.locateTimer = setTimeout((): void => {
      this.locateTimer = 0;
      this.scroller.scrollToIndex(this.currentIndex, false, ScrollAlign.CENTER);
    }, 100);
  }

  @Monitor('episodes')
  onEpisodesChange(): void {
    this.source.reload(this.episodes);
  }

  aboutToDisappear(): void {
    if (this.locateTimer !== 0) {
      clearTimeout(this.locateTimer);
      this.locateTimer = 0;
    }
  }

  build() {
    Column() {
      Column().width('100%').height(12)

      this.SeriesHeader()

      // 官方单 tab「选集」：14sp 粗体 #FF1B1B1B、padding 左 20（hj3/p.java:97-124）
      Row() {
        Text('选集')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .padding({ left: 20 })
          .layoutWeight(1)

        // 收藏（一键加入/移出书架；定位图标之前）
        if (this.showFavorite) {
          SymbolGlyph(this.favoriteActive
            ? $r('sys.symbol.bookshelf_badge_checkmark_fill')
            : $r('sys.symbol.bookshelf_badge_plus'))
            .fontSize(20)
            // 未在架颜色跟随系统字色（深色模式写死 #FF1B1B1B 会看不见）；在架保持官方橙
            .fontColor([this.favoriteActive ? '#FFFA6725' : $r('sys.color.font_tertiary')])
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick((): void => {
              const toggle: (() => void) | null = this.onToggleFavorite;
              if (toggle !== null) {
                toggle();
              }
            })
        }

        // 定位当前集（scope 图标，滚动当前集竖直居中；同系列入口之前）
        SymbolGlyph($r('sys.symbol.scope'))
          .fontSize(18)
          .fontColor(['#FFFA6725'])
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .onClick((): void => {
            this.scroller.scrollToIndex(this.currentIndex, false, ScrollAlign.CENTER);
          })

        // 官方同系列入口（story_player_panel.dart：tab 行右端 TextButton）
        if (this.onOpenRelatedSeries !== null) {
          Text('同系列')
            .fontSize(14)
            .fontColor('#FFFA6725')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick((): void => {
              const open: (() => void) | null = this.onOpenRelatedSeries;
              if (open !== null) {
                open();
              }
            })
        }
      }
      .width('100%')
      // 无同系列按钮时补 8vp 右内边距：定位图标与屏幕右缘保持 16vp 避让
      // （有同系列按钮时其自带 16vp 右内边距已避让，不叠加）
      .padding({ bottom: 10, right: this.onOpenRelatedSeries !== null ? 0 : 8 })
      .alignItems(VerticalAlign.Center)

      if (this.episodes.length > FQ_STORY_PAGE_SIZE) {
        this.PagingStrip()
      }

      if (this.episodes.length === 0) {
        Column() {
          Text('暂无剧集')
            .fontSize(14)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid(this.scroller) {
          // LazyForEach 按需构建：上千集仅构建可视区格子；Repeat.virtualScroll
          // 复用节点会渲染错位（滚动后格子文案复用成旧集数），弃用
          LazyForEach(this.source, (episode: FqChapter, index: number) => {
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
              .backgroundColor(index === this.currentIndex ? '#1AFA6725' : $r('sys.color.comp_background_list_card'))
              .onClick((): void => {
                this.onSelectEpisode(index);
              })
            }
          })
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
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor(['#FF9499A0'])
          }
          .width('100%')
          .onClick((): void => {
            const open: (() => void) | null = this.onOpenSeries;
            if (open !== null) {
              open();
            }
          })

          if (this.episodeLabel.length > 0) {
            Text(this.episodeLabel)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          // 剧简介小字：不全部显示（最多 2 行，末尾省略）
          if (this.seriesIntro.length > 0) {
            Text(this.seriesIntro)
              .fontSize(12)
              .lineHeight(17)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(2)
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
            .fontColor(page === this.page ? $r('sys.color.font_secondary') : $r('sys.color.font_tertiary'))
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
    // Scroll 内容小于视口时默认 Alignment.Center 整行居中（fqapp 为左对齐 12），显式左对齐
    .align(Alignment.Start)
  }

  /** 格子文字色：当前集橙、已看（按集 itemId 记录，与下标无关）灰、普通黑。 */
  private tileTextColor(index: number): ResourceColor {
    if (index === this.currentIndex) {
      return '#FFFA6725';
    }
    const episode: FqChapter | undefined = this.episodes[index];
    if (episode !== undefined && this.watchedIds.has(episode.itemId)) {
      return $r('sys.color.font_fourth');
    }
    return $r('sys.color.font');
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

/**
 * 同系列剧面板（fqapp widgets/player/related_series_sheet.dart）：
 * - FqRelatedList：内容块——加载（CommonLoading）/错误重试/空态 + 双列卡片网格
 *   （封面 3:4 圆角 8 + 标题最多 2 行 + 「共 N 集」/「暂不可播放」；
 *   不可播条目仍展示但点击不响应，官方 disable_play/1002/1007 语义）。
 * - FqRelatedSheet：亮色半模态宿主（CommonSheet 承载，标题「同系列剧」+ 关闭）。
 * 双宿主形态：亮色走半模态；深色（dark=true，文字翻白、占位块压暗）贴
 * 播放页横屏全屏右侧边栏（与选集抽屉/播放设置同款几何）。
 */

import { appState } from '../../entryability/AppState';
import { FqRelatedSeries } from '../../model/FqModels';
import { FqBackend } from '../../core/FqBackend';
import { CommonLoading } from '../CommonCom';
import { CommonSheet } from './CommonSheet';

@ComponentV2
export struct FqRelatedList {
  /** 同系列条目（宿主经 /api/v1/series/{id}/related 加载）。 */
  @Param items: FqRelatedSeries[] = [];
  /** 加载中。 */
  @Param loading: boolean = false;
  /** 加载错误文案（空串无错；展示重试按钮）。 */
  @Param errorMsg: string = '';
  /** 深色皮肤（播放页横屏右侧边栏）：文字翻白、占位块压暗。 */
  @Param dark: boolean = false;
  @Event retryClick: () => void = (): void => {};
  @Event itemClick: (entry: FqRelatedSeries) => void =
    (_entry: FqRelatedSeries): void => {};

  build() {
    Column() {
      if (this.loading) {
        Column() {
          CommonLoading({ loadColor: this.dark ? Color.White : $r('sys.color.icon') })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 24, bottom: 24 })
      } else if (this.errorMsg.length > 0) {
        Column({ space: 12 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor(this.subColor())
            .textAlign(TextAlign.Center)

          Text('重试')
            .fontSize(14)
            .fontColor(this.dark ? Color.White : '#FFFA6725')
            .borderRadius(16)
            .border({
              width: 1,
              color: this.dark ? Color.White : '#FFFA6725',
            })
            .padding({ left: 20, right: 20, top: 6, bottom: 6 })
            .onClick((): void => {
              this.retryClick();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32, top: 16, bottom: 16 })
      } else if (this.items.length === 0) {
        Column() {
          Text('暂无可切换的同系列剧')
            .fontSize(14)
            .fontColor(this.subColor())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 24, bottom: 24 })
      } else {
        Grid() {
          ForEach(this.items, (entry: FqRelatedSeries) => {
            GridItem() {
              this.Card(entry)
            }
          }, (entry: FqRelatedSeries) => entry.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(12)
        .rowsGap(14)
        .scrollBar(BarState.Off)
        .padding({ left: 16, right: 16, top: 4, bottom: 16 + appState.bottomRect })
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 同系列卡片：封面（3:4，圆角 8）+ 标题 2 行 + 集数/暂不可播放。 */
  @Builder
  private Card(entry: FqRelatedSeries) {
    Column({ space: 6 }) {
      if (this.coverUrlOf(entry).length > 0) {
        Image(this.coverUrlOf(entry))
          .width('100%')
          .aspectRatio(3 / 4)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .autoResize(true)
          .draggable(false)
      } else {
        // 官方封面占位：深色块 + 片源图标（fqapp LucideIcons.clapperboard）
        Column() {
          SymbolGlyph($r('sys.symbol.film'))
            .fontSize(24)
            .fontColor([this.dark ? '#8CFFFFFF' : '#FF9499A0'])
        }
        .width('100%')
        .aspectRatio(3 / 4)
        .borderRadius(8)
        .backgroundColor(this.dark ? '#FF2A2A2A' : '#FFEDEDF0')
        .justifyContent(FlexAlign.Center)
      }

      Text(entry.title)
        .fontSize(14)
        .fontColor(this.dark ? Color.White : $r('sys.color.font_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(this.countLabel(entry))
        .fontSize(12)
        .fontColor(this.subColor())
        .maxLines(1)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      // 不可播（即将上线/内容不可播/disable_play）不响应，仍展示
      if (!entry.unavailable) {
        this.itemClick(entry);
      }
    })
  }

  /** 封面绝对地址（后端资源锚定；无封面走占位块）。 */
  private coverUrlOf(entry: FqRelatedSeries): string {
    return entry.cover.length > 0 ? FqBackend.get().resourceUrl(entry.cover) : '';
  }

  /** 集数/状态文案（官方：共 N 集 / 查看剧集 / 暂不可播放）。 */
  private countLabel(entry: FqRelatedSeries): string {
    if (entry.unavailable) {
      return '暂不可播放';
    }
    return entry.episodeCount > 0 ? `共 ${entry.episodeCount} 集` : '查看剧集';
  }

  /** 次级文字色（深色翻白 70%，亮色跟随系统次级色）。 */
  private subColor(): ResourceColor {
    return this.dark ? '#B3FFFFFF' : $r('sys.color.font_secondary');
  }
}

/** 同系列亮色半模态（CommonSheet 承载：标题「同系列剧」+ 右上关闭）。 */
@ComponentV2
export struct FqRelatedSheet {
  @Param items: FqRelatedSeries[] = [];
  @Param loading: boolean = false;
  @Param errorMsg: string = '';
  @Event closeClick: () => void = (): void => {};
  @Event retryClick: () => void = (): void => {};
  @Event itemClick: (entry: FqRelatedSeries) => void =
    (_entry: FqRelatedSeries): void => {};

  build() {
    CommonSheet({
      sheetTitle: '同系列剧',
      showClose: true,
      closeClick: (): void => {
        this.closeClick();
      },
    }) {
      Column() {
        FqRelatedList({
          items: this.items,
          loading: this.loading,
          errorMsg: this.errorMsg,
          retryClick: (): void => {
            this.retryClick();
          },
          itemClick: (entry: FqRelatedSeries): void => {
            this.itemClick(entry);
          },
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
  }
}

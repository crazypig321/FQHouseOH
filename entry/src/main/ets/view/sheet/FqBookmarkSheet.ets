/**
 * 阅读书签公共半模态（阅读页/漫画页标题栏「书签」呼出）：
 * - 条目：章节名 + 摘录预览 + 保存时间，点击跳转（宿主负责关 sheet 与定位）；
 * - 标题栏「+」添加当前位置书签（宿主采集锚点）；
 * - 空态：暂无书签提示（含添加引导）。
 */

import { CommonSheet } from './CommonSheet';
import { FqReaderBookmark } from '../../core/FqReaderBookmarkStore';

/** 下拉书签判定阈值（vp，对齐 fqapp 80 逻辑像素）。 */
export const FQ_BOOKMARK_PULL_THRESHOLD_VP: number = 80;
/** 下拉书签显示阻尼（对齐 fqapp 0.7）。 */
export const FQ_BOOKMARK_PULL_DAMPING: number = 0.7;
/** 下拉书签最大跟手距离（vp，对齐 fqapp 240）。 */
export const FQ_BOOKMARK_PULL_MAX_VP: number = 240;

@ComponentV2
export struct FqBookmarkSheet {
  /** 单书书签条目（宿主持有，增删后刷新传入）。 */
  @Param items: FqReaderBookmark[] = [];
  /** 字体色随宿主主题（阅读页墨色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 条目点击（跳转，宿主负责关 sheet 与定位）。 */
  @Event itemClick: (item: FqReaderBookmark) => void = (_item: FqReaderBookmark): void => {};
  /** 标题栏「+」：添加当前位置书签。 */
  @Event addClick: () => void = (): void => {};
  /** 条目删除键（宿主弹确认后删除并刷新列表）。 */
  @Event itemRemove: (item: FqReaderBookmark) => void = (_item: FqReaderBookmark): void => {};
  private scroller: Scroller = new Scroller();

  build() {
    CommonSheet({
      sheetTitle: this.items.length > 0 ? `书签 · ${this.items.length}` : '书签',
      showAdd: true,
      addClick: (): void => {
        this.addClick();
      },
    }) {
      if (this.items.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.bookmark'))
            .fontSize(34)
            .fontColor([$r('sys.color.font_tertiary')])
          Text('暂无书签')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
          Text('点右上角「+」把当前位置加入书签')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 60 })
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.items, (item: FqReaderBookmark) => {
            ListItem() {
              this.BookmarkRow(item)
            }
          }, (item: FqReaderBookmark): string => item.key)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.5,
          color: $r('sys.color.comp_divider'),
          startMargin: 20,
          endMargin: 20,
        })
      }
    }
  }

  /** 单条书签行：章节名 + 摘录两行预览 + 时间；点击跳转，尾随删除键。 */
  @Builder
  private BookmarkRow(item: FqReaderBookmark) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(item.chapterTitle.length > 0 ? item.chapterTitle : `第${item.chapterIndex + 1}章`)
          .fontSize(14)
          .fontColor(this.fontColor)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.excerpt.length > 0) {
          Text(item.excerpt)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.timeLabel(item.createdAt))
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick((): void => {
        this.itemClick(item);
      })

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(17)
        .fontColor([$r('sys.color.font_tertiary')])
        .padding({ left: 8, top: 8, right: 4, bottom: 8 })
        .onClick((): void => {
          this.itemRemove(item);
        })
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 20, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** 保存时间文案（当天显示时分，其余显示月日）。 */
  private timeLabel(createdAt: number): string {
    if (createdAt <= 0) {
      return '';
    }
    const date: Date = new Date(createdAt);
    const now: Date = new Date();
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()
      && date.getDate() === now.getDate()) {
      return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
    }
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
}

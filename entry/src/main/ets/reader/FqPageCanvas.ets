import { FqPageFragment, FqReaderLayoutMetrics, FqReaderPageData } from './ReaderTypes';
import { drawing } from '@kit.ArkGraphics2D';

/**
 * 仿真/覆盖翻页正文画布：引擎切好的行逐行 Text 呈现（maxLines(1)，行数与装页记账
 * 零分歧——章中页填满、页底不裁不空）；满行行尾空隙按引擎 lineSpaceFp 以 letterSpacing
 * 补齐右边（段末末行/章题行不拉伸，同上下滚动 JUSTIFY 视觉：左边齐、右边满行齐右边）。
 */
@ComponentV2
export struct FqPageCanvas {
  @Param page: FqReaderPageData | null = null;
  @Param metrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
  @Param fontColor: string = '#1F2329';
  @Param pageBgColor: string = '#F6F4EF';
  @Param commentCounts: number[] = [];
  @Param fontFamily: string = '';
  @Param highlightParaIndex: number = -1;
  /** 段落高亮底色（主题色 10% 透明派生，阅读页传入）。 */
  @Param highlightColor: ResourceColor = Color.Transparent;
  /** 气泡命中段评（paraIndex）：行内气泡可点部分（计数 Span）触发。 */
  @Event onBubbleTap: (paraIndex: number) => void

  private paraHighlighted(frag: FqPageFragment): boolean {
    return this.highlightParaIndex >= 0 && frag.paraIndex === this.highlightParaIndex;
  }

  private bubbleCount(frag: FqPageFragment): number {
    if (this.commentCounts.length > frag.paraIndex) {
      return this.commentCounts[frag.paraIndex];
    }
    return 0;
  }

  private topMarginVp(frag: FqPageFragment): number {
    if (frag.startChar > 0) {
      return 0;
    }
    return frag.isTitle ? this.metrics.titleTopVp : this.metrics.paraGapVp;
  }

  /** 行内段评气泡：只挂片段末行（引擎气泡行高记账与渲染一致）。 */
  private lineHasBubble(frag: FqPageFragment, lineIdx: number): boolean {
    return frag.showBubble && this.bubbleCount(frag) > 0 && lineIdx === frag.lines.length - 1;
  }

  /** 行尾拉伸字符串（带显式 fp 单位，规避 number 的 fp/vp 歧义；越界回退 '0fp'）。 */
  private lineStretchText(frag: FqPageFragment, lineIdx: number): string {
    if (lineIdx >= 0 && lineIdx < frag.lineSpaceFp.length) {
      return `${frag.lineSpaceFp[lineIdx]}fp`;
    }
    return '0fp';
  }

  build() {
    Flex({ direction: FlexDirection.Column, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      if (this.page !== null) {
        ForEach(this.page.fragments, (frag: FqPageFragment) => {
          Column() {
            ForEach(frag.lines, (line: string, lineIdx: number) => {
              Text() {
                Span(line)
                if (this.lineHasBubble(frag, lineIdx)) {
                  ImageSpan($r('app.media.ellipsis_message'))
                    .width(this.metrics.bubbleIconFp)
                    .height(this.metrics.bubbleIconFp)
                    .supportSvg2(true)
                    .colorFilter(drawing.ColorFilter.createBlendModeColorFilter(
                      drawing.Tool.makeColorFromResourceColor($r('sys.color.icon_tertiary')), drawing.BlendMode.SRC_IN))
                    .onClick(() => {
                      this.onBubbleTap(frag.paraIndex);
                    })
                  Span(` ${this.bubbleCount(frag)}`)
                    .fontSize(this.metrics.bubbleTextFp)
                    .fontColor($r('sys.color.icon_tertiary'))
                    .fontFamily(this.fontFamily)
                    .onClick(() => {
                      this.onBubbleTap(frag.paraIndex);
                    })
                }
              }
              .fontSize(frag.isTitle ? this.metrics.titleFontFp : this.metrics.fontSizeFp)
              .fontWeight(frag.isTitle ? FontWeight.Bold : FontWeight.Normal)
              .lineHeight(frag.isTitle ? this.metrics.titleLineFp : this.metrics.lineHeightFp)
              .fontColor(this.fontColor)
              .fontFamily(this.fontFamily)
              // 行尾空隙由引擎逐行预算的 letterSpacing 补齐（满行贴右边，段末行自然收尾）
              .letterSpacing(this.lineStretchText(frag, lineIdx))
              .textAlign(TextAlign.Start)
              .maxLines(this.lineHasBubble(frag, lineIdx) ? 2 : 1)
              .width('100%')
            }, (line: string, lineIdx: number): string => `${lineIdx}_${line.length}_${line}`)
          }
          .width('100%')
          .margin({ top: this.topMarginVp(frag), bottom: frag.isTitle ? this.metrics.titleBottomVp : 0 })
          .borderRadius(this.paraHighlighted(frag) ? 6 : 0)
          .backgroundColor(this.paraHighlighted(frag) ? this.highlightColor : 'transparent')
        }, (frag: FqPageFragment): string =>
          `f_${frag.paraIndex}_${frag.startChar}_${frag.endChar}_${frag.showBubble ? 1 : 0}_${this.bubbleCount(frag)}_${frag.lines.length}_${frag.text.length}_${this.metrics.fontSizeFp}_${this.metrics.contentWidthPx}_${this.metrics.textDensity}`)
      }
    }
    .padding({
      left: this.metrics.sidePaddingVp,
      right: this.metrics.sidePaddingVp,
      top: this.metrics.contentTopVp,
      bottom: this.metrics.contentBottomVp,
    })
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBgColor)
    .clip(true)
  }
}

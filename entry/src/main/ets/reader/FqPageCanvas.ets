import { FqPageFragment, FqReaderLayoutMetrics, FqReaderPageData } from './ReaderTypes';
import { drawing } from '@kit.ArkGraphics2D';

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

  build() {
    Column() {
      if (this.page !== null) {
        ForEach(this.page.fragments, (frag: FqPageFragment) => {
          Column() {
            Text(){
              Span(frag.text)
              if (frag.showBubble && this.bubbleCount(frag) > 0) {
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
              }
            }
            .fontSize(frag.isTitle ? this.metrics.titleFontFp : this.metrics.fontSizeFp)
            .fontWeight(frag.isTitle ? FontWeight.Bold : FontWeight.Normal)
            .lineHeight(frag.isTitle ? this.metrics.titleLineFp : this.metrics.lineHeightFp)
            .fontColor(this.fontColor)
            .fontFamily(this.fontFamily)
            .textAlign(TextAlign.JUSTIFY)
            .width('100%')
            .margin({ top: this.topMarginVp(frag), bottom: frag.isTitle ? this.metrics.titleBottomVp : 0 })
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .backgroundColor(this.paraHighlighted(frag) ? this.highlightColor : 'transparent')
          .borderRadius(this.paraHighlighted(frag) ? 6 : 0)
        }, (frag: FqPageFragment): string =>
          `f_${frag.paraIndex}_${frag.startChar}_${frag.endChar}_${frag.showBubble ? 1 : 0}_${this.bubbleCount(frag)}_${frag.text.length}`)
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
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.pageBgColor)
    .clip(true)
  }
}

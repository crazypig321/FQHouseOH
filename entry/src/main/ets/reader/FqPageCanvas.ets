import { FqPageFragment, FqReaderLayoutMetrics, FqReaderPageData } from './ReaderTypes';
import { hilog } from '@kit.PerformanceAnalysisKit';

@ComponentV2
export struct FqPageCanvas {
  @Param page: FqReaderPageData | null = null;
  @Param metrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
  @Param fontColor: string = '#1F2329';
  @Param pageBgColor: string = '#F6F4EF';
  @Param bubbleBgColor: ResourceColor = $r('sys.color.comp_background_tertiary');
  @Param bubbleFontColor: ResourceColor = $r('sys.color.icon_tertiary');
  @Param commentCounts: number[] = [];
  @Param fontFamily: string = '';
  @Param highlightParaIndex: number = -1;
  @Param highlightColor: string = '#1AFF7A3D';

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

  @Builder
  private bubbleCapsule(frag: FqPageFragment) {
    Row({ space: this.metrics.bubbleSpaceVp }) {
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(this.metrics.bubbleIconFp)
        .fontColor([this.bubbleFontColor])
      Text(`${this.bubbleCount(frag)}`)
        .fontSize(this.metrics.bubbleTextFp)
        .fontColor(this.bubbleFontColor)
        .fontFamily(this.fontFamily)
        .maxLines(1)
    }
    .padding({
      left: this.metrics.bubblePadHVp,
      right: this.metrics.bubblePadHVp,
      top: this.metrics.bubblePadVVp,
      bottom: this.metrics.bubblePadVVp,
    })
    .borderRadius(this.metrics.bubbleRadiusVp)
    .backgroundColor(this.bubbleBgColor)
    .hitTestBehavior(HitTestMode.None)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      if (this.page !== null) {
        ForEach(this.page.fragments, (frag: FqPageFragment) => {
          Column() {
            Text(frag.text)
              .fontSize(frag.isTitle ? this.metrics.titleFontFp : this.metrics.fontSizeFp)
              .fontWeight(frag.isTitle ? FontWeight.Bold : FontWeight.Normal)
              .lineHeight(frag.isTitle ? this.metrics.titleLineFp : this.metrics.lineHeightFp)
              .fontColor(this.fontColor)
              .fontFamily(this.fontFamily)
              .textAlign(TextAlign.JUSTIFY)
              .width('100%')
              .margin({ top: this.topMarginVp(frag), bottom: frag.isTitle ? this.metrics.titleBottomVp : 0 })
              .onAreaChange((_old: Area, newArea: Area) => {
                const h: number = typeof newArea.height === 'number' ? newArea.height : 0;
                hilog.info(0x0001, 'FqC', `frag=${frag.paraIndex} textH=${h}`);
              })
            if (frag.showBubble && this.bubbleCount(frag) > 0) {
              Row() {
                this.bubbleCapsule(frag)
              }.width('100%')
              .justifyContent(FlexAlign.Start)
              .margin({ top: this.metrics.bubbleMarginTopVp })
            }
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

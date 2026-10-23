/**
 * 自定义阅读页单页渲染（ReaderPage2 专用）：
 * 逐行独立 Text（引擎已断行，.maxLines(1) 锁断行，无渲染/测量分歧），
 * 章题段加大加粗；段尾段评气泡优先行内化（末行文本与胶囊同 Row，
 * 引擎已按气泡宽窄列重排末行），放不下时回退独立气泡行；
 * 点击命中由 FqReaderFlip 顶层触区按引擎输出的气泡 rect 代理，本组件不绑点击。
 */

import { FqPageFragment, FqReaderLayoutMetrics, FqReaderPageData } from './ReaderTypes';

@ComponentV2
export struct FqPageCanvas {
  /** 当前页数据（null 渲染空占位）。 */
  @Param page: FqReaderPageData | null = null;
  /** 排版几何（vp/fp 字段供渲染）。 */
  @Param metrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
  /** 正文字色 / 页底色。 */
  @Param fontColor: string = '#1F2329';
  @Param pageBgColor: string = '#F6F4EF';
  /** 段评气泡配色。 */
  @Param bubbleBgColor: string = '#E9E3D5';
  @Param bubbleFontColor: string = '#8A8578';
  /** 每段段评数（气泡计数）。 */
  @Param commentCounts: number[] = [];
  /** 阅读字体族（空串回退系统默认）。 */
  @Param fontFamily: string = '';

  private effectiveFontFamily(): string {
    return this.fontFamily.length > 0 ? this.fontFamily : 'HarmonyOS Sans';
  }

  /** 段评计数（越界返回 0）。 */
  private bubbleCount(frag: FqPageFragment): number {
    if (this.commentCounts.length > frag.paraIndex) {
      return this.commentCounts[frag.paraIndex];
    }
    return 0;
  }

  /** 该行是否为行内气泡行（引擎行内化成功的末行）。 */
  private inlineBubbleAt(frag: FqPageFragment, idx: number): boolean {
    return frag.bubbleInline && frag.showBubble && idx === frag.lines.length - 1
      && this.bubbleCount(frag) > 0;
  }

  /** 是否渲染独立气泡行（行内化失败兜底）。 */
  private ownBubbleRow(frag: FqPageFragment): boolean {
    return frag.showBubble && !frag.bubbleInline && this.bubbleCount(frag) > 0;
  }

  /** 行上边距（段首行：章题上距/段前距）。
   * 跨页续排片段（startChar > 0）引擎未计 blockTop，渲染补 margin 会令页底溢出切行，须返回 0。 */
  private lineTopMarginVp(frag: FqPageFragment, idx: number): number {
    if (idx !== 0) {
      return 0;
    }
    if (frag.startChar > 0) {
      return 0;
    }
    return frag.isTitle ? this.metrics.titleTopVp : this.metrics.paraGapVp;
  }

  /** 单行文本（含样式；上边距由调用方传入）。 */
  @Builder
  private lineText(frag: FqPageFragment, line: string, topMarginVp: number) {
    Text(line)
      .fontSize(frag.isTitle ? this.metrics.titleFontFp : this.metrics.fontSizeFp)
      .fontWeight(frag.isTitle ? FontWeight.Bold : FontWeight.Normal)
      .lineHeight(frag.isTitle ? this.metrics.titleLineFp : this.metrics.lineHeightFp)
      .fontColor(this.fontColor)
      .fontFamily(this.effectiveFontFamily())
      .maxLines(1)
      .margin({ top: topMarginVp })
  }

  /** 段评胶囊（行内/独立两态共用；尺寸随正文字号等比缩放）。 */
  @Builder
  private bubbleCapsule(frag: FqPageFragment) {
    Row({ space: this.metrics.bubbleSpaceVp }) {
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(this.metrics.bubbleIconFp)
        .fontColor([this.bubbleFontColor])
      Text(`${this.bubbleCount(frag)}`)
        .fontSize(this.metrics.bubbleTextFp)
        .fontColor(this.bubbleFontColor)
        .fontFamily(this.effectiveFontFamily())
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
  }

  build() {
    Column() {
      if (this.page !== null) {
        ForEach(this.page.fragments, (frag: FqPageFragment) => {
          Column() {
            ForEach(frag.lines, (line: string, idx: number) => {
              if (this.inlineBubbleAt(frag, idx)) {
                Row({ space: this.metrics.bubbleGapVp }) {
                  this.lineText(frag, line, 0)
                  this.bubbleCapsule(frag)
                }
                .alignItems(VerticalAlign.Center)
                .width('100%')
                .margin({ top: this.lineTopMarginVp(frag, idx) })
              } else {
                this.lineText(frag, line, this.lineTopMarginVp(frag, idx))
              }
            }, (line: string, idx: number): string =>
              `${frag.paraIndex}_${frag.startChar}_${idx}_${this.inlineBubbleAt(frag, idx) ? 1 : 0}_${line}`)
            if (this.ownBubbleRow(frag)) {
              Row() {
                this.bubbleCapsule(frag)
              }
              .margin({ top: this.metrics.bubbleMarginTopVp })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }, (frag: FqPageFragment): string =>
          `f_${frag.paraIndex}_${frag.startChar}_${frag.endChar}_${frag.showBubble ? 1 : 0}_${frag.bubbleInline ? 1 : 0}_${this.bubbleCount(frag)}_${frag.lines.map((l: string): string => String(l.length)).join('.')}`)
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

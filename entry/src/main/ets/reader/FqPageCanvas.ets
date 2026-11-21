import { FqPageFragment, FqReaderLayoutMetrics, FqReaderPageData } from './ReaderTypes';
import { FqDialogueSegment, fqDialogueRanges, fqDialogueSegments } from './FqDialogue';
import { drawing } from '@kit.ArkGraphics2D';
import { fqBubbleIcon } from '../utils/FqBubbleIcon';
import { FqColorUtils } from '../utils/FqColorUtils';

/**
 * 仿真/覆盖翻页正文画布：引擎切好的行逐行 Text 呈现（maxLines(1)，行数与装页记账
 * 零分歧——章中页填满、页底不裁不空）；满行行尾空隙按引擎 lineSpaceFp 以 letterSpacing
 * 补齐右边（段末末行/章题行不拉伸，同上下滚动 JUSTIFY 视觉：左边齐、右边满行齐右边）。
 * 双页模式（metrics.columns > 1）：左 Row 双栏 + 栏间 1vp 分隔线（文字色 8% 透明），
 * 片段按 frag.column 分栏渲染，间距/栏宽与引擎记账一致；单栏路径维持原渲染不动。
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
  /** 段落文本（对话高亮区间检测用；行/片段为段落的连续子串）。 */
  @Param paragraphs: string[] = [];
  /** 对话高亮色（空 = 关闭；#RRGGBB / #AARRGGBB，应用于引号内文本底色）。 */
  @Param dialogueHighlightColor: string = '';

  /** 双页模式取指定栏的片段（单栏路径不经此，渲染与引擎装页同序）。 */
  private fragsOfColumn(column: number): FqPageFragment[] {
    const frags: FqPageFragment[] = [];
    if (this.page !== null) {
      for (const frag of this.page.fragments) {
        if (frag.column === column) {
          frags.push(frag);
        }
      }
    }
    return frags;
  }

  build() {
    if (this.page !== null && this.metrics.columns > 1) {
      // 双页：Row space = (栏间距 - 分隔线 1vp) / 2，两栏 layoutWeight 均分，宽度与引擎栏宽一致
      Row({
        space: (this.metrics.columnGapPx / this.metrics.density - 1) / 2,
      }) {
        FqPageColumnCanvas({
          frags: this.fragsOfColumn(0),
          metrics: this.metrics,
          fontColor: this.fontColor,
          commentCounts: this.commentCounts,
          fontFamily: this.fontFamily,
          highlightParaIndex: this.highlightParaIndex,
          highlightColor: this.highlightColor,
          paragraphs: this.paragraphs,
          dialogueHighlightColor: this.dialogueHighlightColor,
          onBubbleTap: (paraIndex: number): void => {
            this.onBubbleTap(paraIndex);
          },
        })
          .layoutWeight(1)
          .height('100%')
        Column()
          .width(1)
          .height('100%')
          .backgroundColor(FqColorUtils.withOpacity(this.fontColor, 0.08))
        FqPageColumnCanvas({
          frags: this.fragsOfColumn(1),
          metrics: this.metrics,
          fontColor: this.fontColor,
          commentCounts: this.commentCounts,
          fontFamily: this.fontFamily,
          highlightParaIndex: this.highlightParaIndex,
          highlightColor: this.highlightColor,
          paragraphs: this.paragraphs,
          dialogueHighlightColor: this.dialogueHighlightColor,
          onBubbleTap: (paraIndex: number): void => {
            this.onBubbleTap(paraIndex);
          },
        })
          .layoutWeight(1)
          .height('100%')
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
    } else {
      Flex({ direction: FlexDirection.Column, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
        if (this.page !== null) {
          ForEach(this.page.fragments, (frag: FqPageFragment) => {
            Column() {
              ForEach(frag.lines, (line: string, lineIdx: number) => {
                Text() {
                  if (this.dialogueHighlightColor.length > 0 && !frag.isTitle) {
                    ForEach(this.lineSegments(frag, line, lineIdx), (seg: FqDialogueSegment) => {
                      if (seg.dialogue) {
                        Span(seg.text)
                          .textBackgroundStyle({ color: this.dialogueHighlightColor, radius: 4 })
                      } else {
                        Span(seg.text)
                      }
                    }, (seg: FqDialogueSegment): string => `${seg.dialogue ? 1 : 0}_${seg.text}`)
                  } else {
                    Span(line)
                  }
                  if (this.lineHasBubble(frag, lineIdx)) {
                    ImageSpan(fqBubbleIcon(this.bubbleCount(frag)))
                      .width(this.metrics.bubbleIconFp)
                      .height(this.metrics.bubbleIconFp)
                      .supportSvg2(true)
                      .colorFilter(drawing.ColorFilter.createBlendModeColorFilter(
                        drawing.Tool.makeColorFromResourceColor($r('sys.color.icon_tertiary')), drawing.BlendMode.SRC_IN))
                      .onClick(() => {
                        this.onBubbleTap(frag.paraIndex);
                      })
                /*   Span(` ${this.bubbleCount(frag)}`)
                     .fontSize(this.metrics.bubbleTextFp)
                     .fontColor($r('sys.color.icon_tertiary'))
                     .fontFamily(this.fontFamily)
                     .onClick(() => {
                       this.onBubbleTap(frag.paraIndex);
                     })*/
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
              }, (line: string, lineIdx: number): string => `${lineIdx}_${line.length}_${line}_${this.lineStretchText(frag, lineIdx)}_${this.fontFamily}_${this.dialogueHighlightColor}`)
              // 引擎判定末行放不下气泡：图标独立成行（行高与装页记账同为一行行高，零分歧）
              if (frag.showBubble && frag.bubbleOwnRow && this.bubbleCount(frag) > 0) {
                Text() {
                  ImageSpan(fqBubbleIcon(this.bubbleCount(frag)))
                    .width(this.metrics.bubbleIconFp)
                    .height(this.metrics.bubbleIconFp)
                    .supportSvg2(true)
                    .colorFilter(drawing.ColorFilter.createBlendModeColorFilter(
                      drawing.Tool.makeColorFromResourceColor($r('sys.color.icon_tertiary')), drawing.BlendMode.SRC_IN))
                    .onClick(() => {
                      this.onBubbleTap(frag.paraIndex);
                    })
                }
                .lineHeight(this.metrics.lineHeightFp)
                .maxLines(1)
                .width('100%')
              }
            }
            .width('100%')
            .margin({ top: this.topMarginVp(frag), bottom: frag.isTitle ? this.metrics.titleBottomVp : 0 })
            .borderRadius(this.paraHighlighted(frag) ? 6 : 0)
            .backgroundColor(this.paraHighlighted(frag) ? this.highlightColor : 'transparent')
          }, (frag: FqPageFragment): string =>
            `f_${frag.paraIndex}_${frag.startChar}_${frag.endChar}_${frag.showBubble ? 1 : 0}_${frag.bubbleOwnRow ? 1 : 0}_${this.bubbleCount(frag)}_${frag.lines.length}_${frag.text.length}_${this.metrics.fontSizeFp}_${this.metrics.contentWidthPx}_${this.metrics.textDensity}_${this.fontFamily}`)
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

  private paraHighlighted(frag: FqPageFragment): boolean {
    return this.highlightParaIndex >= 0 && frag.paraIndex === this.highlightParaIndex;
  }

  /** 行在段内的起始字符（含缩进前缀；行是段落连续子串，前序行长求和 + 片段起始）。 */
  private lineBaseOffset(frag: FqPageFragment, lineIdx: number): number {
    let offset: number = frag.startChar;
    for (let i: number = 0; i < lineIdx; i++) {
      offset += frag.lines[i].length;
    }
    return offset;
  }

  /** 行文本按对话区间分段（高亮关闭或无段落数据时回退单个普通段）。 */
  private lineSegments(frag: FqPageFragment, line: string, lineIdx: number): FqDialogueSegment[] {
    if (this.dialogueHighlightColor.length === 0 || frag.isTitle
      || frag.paraIndex >= this.paragraphs.length) {
      return [new FqDialogueSegment(line, false)];
    }
    const paragraph: string = this.paragraphs[frag.paraIndex];
    return fqDialogueSegments(line, this.lineBaseOffset(frag, lineIdx), fqDialogueRanges(paragraph));
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

  /** 行内段评气泡：只挂片段末行且引擎判定可内联（独立成行时走片段尾部独立行）。 */
  private lineHasBubble(frag: FqPageFragment, lineIdx: number): boolean {
    return frag.showBubble && !frag.bubbleOwnRow && this.bubbleCount(frag) > 0
      && lineIdx === frag.lines.length - 1;
  }

  /** 行尾拉伸字符串（带显式 fp 单位，规避 number 的 fp/vp 歧义；越界回退 '0fp'）。 */
  private lineStretchText(frag: FqPageFragment, lineIdx: number): string {
    if (lineIdx >= 0 && lineIdx < frag.lineSpaceFp.length) {
      return `${frag.lineSpaceFp[lineIdx]}fp`;
    }
    return '0fp';
  }
}

/**
 * 双页单栏画布（FqPageCanvas 双页分支专用）：渲染引擎按栏切好的片段，
 * 片段渲染逻辑与单栏路径一致（逐行 Text maxLines(1) + 行尾拉伸 + 段评气泡）；
 * 外层 FqPageCanvas Row 负责左右边距/栏宽均分，本组件不再加 padding。
 */
@ComponentV2
struct FqPageColumnCanvas {
  @Param frags: FqPageFragment[] = [];
  @Param metrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
  @Param fontColor: string = '#1F2329';
  @Param commentCounts: number[] = [];
  @Param fontFamily: string = '';
  @Param highlightParaIndex: number = -1;
  @Param highlightColor: ResourceColor = Color.Transparent;
  @Param paragraphs: string[] = [];
  @Param dialogueHighlightColor: string = '';
  @Event onBubbleTap: (paraIndex: number) => void = (_paraIndex: number): void => {};

  build() {
    Flex({ direction: FlexDirection.Column, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      ForEach(this.frags, (frag: FqPageFragment) => {
        Column() {
          ForEach(frag.lines, (line: string, lineIdx: number) => {
            Text() {
              if (this.dialogueHighlightColor.length > 0 && !frag.isTitle) {
                ForEach(this.lineSegments(frag, line, lineIdx), (seg: FqDialogueSegment) => {
                  if (seg.dialogue) {
                    Span(seg.text)
                      .textBackgroundStyle({ color: this.dialogueHighlightColor, radius: 4 })
                  } else {
                    Span(seg.text)
                  }
                }, (seg: FqDialogueSegment): string => `${seg.dialogue ? 1 : 0}_${seg.text}`)
              } else {
                Span(line)
              }
              if (this.lineHasBubble(frag, lineIdx)) {
                ImageSpan(fqBubbleIcon(this.bubbleCount(frag)))
                  .width(this.metrics.bubbleIconFp)
                  .height(this.metrics.bubbleIconFp)
                  .supportSvg2(true)
                  .colorFilter(drawing.ColorFilter.createBlendModeColorFilter(
                    drawing.Tool.makeColorFromResourceColor($r('sys.color.icon_tertiary')), drawing.BlendMode.SRC_IN))
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
          }, (line: string, lineIdx: number): string => `${lineIdx}_${line.length}_${line}_${this.lineStretchText(frag, lineIdx)}_${this.fontFamily}_${this.dialogueHighlightColor}`)
          // 引擎判定末行放不下气泡：图标独立成行（行高与装页记账同为一行行高，零分歧）
          if (frag.showBubble && frag.bubbleOwnRow && this.bubbleCount(frag) > 0) {
            Text() {
              ImageSpan(fqBubbleIcon(this.bubbleCount(frag)))
                .width(this.metrics.bubbleIconFp)
                .height(this.metrics.bubbleIconFp)
                .supportSvg2(true)
                .colorFilter(drawing.ColorFilter.createBlendModeColorFilter(
                  drawing.Tool.makeColorFromResourceColor($r('sys.color.icon_tertiary')), drawing.BlendMode.SRC_IN))
                .onClick(() => {
                  this.onBubbleTap(frag.paraIndex);
                })
            }
            .lineHeight(this.metrics.lineHeightFp)
            .maxLines(1)
            .width('100%')
          }
        }
        .width('100%')
        .margin({ top: this.topMarginVp(frag), bottom: frag.isTitle ? this.metrics.titleBottomVp : 0 })
        .borderRadius(this.paraHighlighted(frag) ? 6 : 0)
        .backgroundColor(this.paraHighlighted(frag) ? this.highlightColor : 'transparent')
      }, (frag: FqPageFragment): string =>
        `f_${frag.paraIndex}_${frag.startChar}_${frag.endChar}_${frag.showBubble ? 1 : 0}_${frag.bubbleOwnRow ? 1 : 0}_${this.bubbleCount(frag)}_${frag.lines.length}_${frag.text.length}_${this.metrics.fontSizeFp}_${this.metrics.columnWidthPx}_${this.metrics.textDensity}_${this.fontFamily}`)
    }
    .width('100%')
    .height('100%')
  }

  private paraHighlighted(frag: FqPageFragment): boolean {
    return this.highlightParaIndex >= 0 && frag.paraIndex === this.highlightParaIndex;
  }

  /** 行在段内的起始字符（含缩进前缀；行是段落连续子串，前序行长求和 + 片段起始）。 */
  private lineBaseOffset(frag: FqPageFragment, lineIdx: number): number {
    let offset: number = frag.startChar;
    for (let i: number = 0; i < lineIdx; i++) {
      offset += frag.lines[i].length;
    }
    return offset;
  }

  /** 行文本按对话区间分段（高亮关闭或无段落数据时回退单个普通段）。 */
  private lineSegments(frag: FqPageFragment, line: string, lineIdx: number): FqDialogueSegment[] {
    if (this.dialogueHighlightColor.length === 0 || frag.isTitle
      || frag.paraIndex >= this.paragraphs.length) {
      return [new FqDialogueSegment(line, false)];
    }
    const paragraph: string = this.paragraphs[frag.paraIndex];
    return fqDialogueSegments(line, this.lineBaseOffset(frag, lineIdx), fqDialogueRanges(paragraph));
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

  /** 行内段评气泡：只挂片段末行且引擎判定可内联（独立成行时走片段尾部独立行）。 */
  private lineHasBubble(frag: FqPageFragment, lineIdx: number): boolean {
    return frag.showBubble && !frag.bubbleOwnRow && this.bubbleCount(frag) > 0
      && lineIdx === frag.lines.length - 1;
  }

  /** 行尾拉伸字符串（带显式 fp 单位，规避 number 的 fp/vp 歧义；越界回退 '0fp'）。 */
  private lineStretchText(frag: FqPageFragment, lineIdx: number): string {
    if (lineIdx >= 0 && lineIdx < frag.lineSpaceFp.length) {
      return `${frag.lineSpaceFp[lineIdx]}fp`;
    }
    return '0fp';
  }
}

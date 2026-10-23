/**
 * 自定义阅读页（ReaderPage）数据模型与段评数据源。
 *
 * 单位约定（分页几何与渲染分离，避免 fp/vp/px 混算错位）：
 * - FqReaderLayoutMetrics 中 *Px / *Fp 后缀字段为物理 px / fp 数值（fp * scaledDensity = px），
 *   供分页引擎装页计算（measure.measureText 返回 px）；
 * - *Vp 后缀字段为 vp 数值，供渲染组件布局（padding/margin/高度）。
 *
 * 段落文本进入分页引擎前已带 '\u3000\u3000' 首行缩进前缀（非标题段），
 * 行切分与渲染共用同一字符串，测量与显示天然一致。
 */

/** 页片段：一段在某页上的可见部分（段可能跨页，一页可能含多段片段）。 */
export class FqPageFragment {
  /** 段落下标（0 = 章题段）。 */
  readonly paraIndex: number;
  /** 是否章题段（加大加粗样式）。 */
  readonly isTitle: boolean;
  /** 片段行集合（引擎已断行，渲染逐行独立 Text，无换行分歧）。 */
  lines: string[] = [];
  /** 段内起始字符（含缩进前缀）。 */
  startChar: number = 0;
  /** 段内结束字符（不含）。 */
  endChar: number = 0;
  /** 片段是否包含段落最后一行。 */
  isParaEnd: boolean = false;
  /** 是否在片段末尾渲染段评气泡。 */
  showBubble: boolean = false;
  /** 气泡行内化：true = 气泡拼在末行文本后（不占行高）；false = 独立气泡行。 */
  bubbleInline: boolean = false;

  constructor(paraIndex: number, isTitle: boolean) {
    this.paraIndex = paraIndex;
    this.isTitle = isTitle;
  }
}

/** 段评气泡：视觉随页文档流渲染，点击命中由翻页容器触区按 rect 代理仲裁。 */
export class FqPageBubble {
  /** 气泡对应段落下标。 */
  readonly paraIndex: number;
  /** 气泡页面级 top（vp，已含眉页区与内容区顶距）。 */
  readonly topVp: number;
  /** 气泡行高（vp）。 */
  readonly heightVp: number;
  /** 气泡左缘 x（vp，相对页容器，含左右边距）。 */
  readonly xVp: number;
  /** 气泡宽（vp）。 */
  readonly widthVp: number;

  constructor(paraIndex: number, topVp: number, heightVp: number, xVp: number, widthVp: number) {
    this.paraIndex = paraIndex;
    this.topVp = topVp;
    this.heightVp = heightVp;
    this.xVp = xVp;
    this.widthVp = widthVp;
  }
}

/** 行内气泡与末行文本的水平间距（vp，分页引擎与渲染共享）。 */
export const FQ_BUBBLE_GAP_VP: number = 6;

/** 单页数据：片段集合 + 页首位置（进度保存/重排定位用）。 */
export class FqReaderPageData {
  fragments: FqPageFragment[] = [];
  /** 页内段评气泡命中区（当前页触区点击仲裁用）。 */
  bubbles: FqPageBubble[] = [];
  /** 页首段落下标（-1 表示空页哨兵）。 */
  startPara: number = -1;
  /** 页首段内字符。 */
  startChar: number = 0;
}

/** 一章的分页结果。 */
export class FqChapterLayout {
  chapterIndex: number = 0;
  /** 段落数组（首段章题；非标题段带缩进前缀）。 */
  paragraphs: string[] = [];
  /** 每段段评数（气泡计数）。 */
  commentCounts: number[] = [];
  /** 分页结果。 */
  pages: FqReaderPageData[] = [];

  constructor(chapterIndex: number) {
    this.chapterIndex = chapterIndex;
  }
}

/** 排版几何（px 供引擎装页；vp/fp 供渲染组件布局）。 */
export class FqReaderLayoutMetrics {
  /** densityPixels（vp → px 换算基准，不含字体缩放）。 */
  density: number = 1;
  /** 页宽/高（px）。 */
  pageWidthPx: number = 0;
  pageHeightPx: number = 0;
  /** 正文可用区（px）。 */
  contentWidthPx: number = 0;
  contentHeightPx: number = 0;
  /** 正文字号（fp）与行高（fp）。 */
  fontSizeFp: number = 19;
  lineHeightFp: number = 36.1;
  /** 正文字号（px）与行高（px）：fp 文本实际渲染 px（× scaledDensity，含字体缩放）。 */
  fontSizePx: number = 0;
  lineHeightPx: number = 0;
  /** 段前距（px / vp）。 */
  paraGapPx: number = 0;
  paraGapVp: number = 0;
  /** 章题字号/行高（fp）/ 行高（px，含字体缩放）。 */
  titleFontFp: number = 24;
  titleLineFp: number = 33;
  titleLinePx: number = 0;
  /** 章题上/下边距（px / vp）。 */
  titleTopPx: number = 0;
  titleTopVp: number = 0;
  titleBottomPx: number = 0;
  titleBottomVp: number = 0;
  /** 段评气泡行高（px / vp，随字号缩放的胶囊实际高度 + 行上边距）。 */
  bubbleRowPx: number = 0;
  bubbleRowVp: number = 0;
  /** 气泡随正文字号缩放系数（基准字号 19fp 时为 1）。 */
  bubbleScale: number = 1;
  /** fp 文本渲染换算密度（scaledDensity = densityPixels × fontScale）。 */
  textDensity: number = 1;
  /** 气泡图标 / 计数字号（fp，随 bubbleScale 缩放）。 */
  bubbleIconFp: number = 13;
  bubbleTextFp: number = 11;
  /** 气泡左右/上下内边距、圆角、图标与计数间距（vp，随 bubbleScale 缩放）。 */
  bubblePadHVp: number = 9;
  bubblePadVVp: number = 3;
  bubbleRadiusVp: number = 11;
  bubbleSpaceVp: number = 4;
  /** 气泡与末行文本水平间距 / 独立气泡行上边距（vp，随 bubbleScale 缩放）。 */
  bubbleGapVp: number = FQ_BUBBLE_GAP_VP;
  bubbleMarginTopVp: number = 4;
  /** 气泡胶囊估算高度（px：fp 部分随系统字体缩放，vp 内边距不随）。 */
  bubbleCapsulePx: number = 0;
  /** 渲染布局：左右边距 / 内容区上 / 下（vp）。 */
  sidePaddingVp: number = 20;
  contentTopVp: number = 0;
  contentBottomVp: number = 0;
  /** 眉页 / 眉脚区高（vp，FqReaderFlip 槽位三区布局用）。 */
  headerZoneVp: number = 20;
  footerZoneVp: number = 20;
}

/** 段评条目（/api/v1/books/{bookId}/reviews 段评配方：data.data_list[i].comment）。 */
export class FqParagraphComment {
  id: string = '';
  userName: string = '';
  userAvatar: string = '';
  text: string = '';
  diggCount: number = 0;
  createdAtMs: number = 0;
  isAuthor: boolean = false;
}

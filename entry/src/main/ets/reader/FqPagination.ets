/**
 * 自定义阅读页分页排版引擎（ReaderPage 专用，不依赖 Reader Kit）：
 *
 * 输入：段落数组（首段章题；非标题段已带 '\u3000\u3000' 缩进前缀）+
 *       排版几何（FqReaderLayoutMetrics，px 基准）+ 每段段评数。
 * 流程：逐段逐字符测量断行（字符宽度缓存 + 行首/行尾禁则回退）→
 *       按页高装页（行高/段前距/章题上下距计入；段评气泡优先行内化拼在末行后，
 *       放不下时窄列重排末行或回退独立气泡行）→
 *       输出 FqReaderPageData[]（片段 + 行集合 + 气泡命中区 + 页首位置）。
 * 渲染约定：渲染端逐行独立 Text（.maxLines(1)），行内容即引擎切好的行，
 * 断行零分歧；measureText 仅支持 HarmonyOS Sans（自定义字体名会被忽略），
 * 自定义阅读字体时测量回调由 ReaderPage 以「全角 1em 步进 + 半角系统测量」
 * 合成，使满行测量与渲染一致，杜绝满行末字被 maxLines(1) 裁掉。
 */

import { FqChapterLayout, FqPageBubble, FqPageFragment, FqReaderLayoutMetrics,
  FqReaderPageData } from './ReaderTypes';

/** 文本宽度测量回调：(文本, 字号fp, 字重) → 宽度 px（UIContext.getMeasureUtils().measureText 包装）。 */
export type FqMeasureFn = (text: string, fontSizeFp: number, fontWeight: string) => number;

/** 行首禁则字符（收尾标点不可居行首）。 */
const FQ_LINE_HEAD_BAN: string = '，。！？；：、…—～·”’』」）］｝》〉';

/** 行尾禁则字符（起始标点不可居行尾）。 */
const FQ_LINE_TAIL_BAN: string = '‘“『「（［｛《〈';

export class FqPaginationEngine {
  private readonly measureFn: FqMeasureFn;
  /** 单字符宽度缓存（key: char|size|weight）。 */
  private readonly widthCache: Map<string, number> = new Map<string, number>();

  constructor(measureFn: FqMeasureFn) {
    this.measureFn = measureFn;
  }

  /** 单字符宽度（缓存）。 */
  private charWidth(ch: string, fontFp: number, weight: string): number {
    const key: string = `${ch}|${fontFp}|${weight}`;
    const cached: number | undefined = this.widthCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const width: number = this.measureFn(ch, fontFp, weight);
    this.widthCache.set(key, width);
    return width;
  }

  /** 段落断行：单字符宽度缓存累加（O(N) 快，调字号重排不卡顿），累加超宽时整行实测验证
   * （含标点压缩），使断行行数与 Text 自然换行一致（减少页底留空）；禁则回退。 */
  private splitLines(text: string, firstMaxW: number, restMaxW: number,
    fontFp: number, weight: string): string[] {
    // 码点切字符（代理对合并，emoji 安全）
    const chars: string[] = [];
    for (let pos: number = 0; pos < text.length; pos++) {
      const code: number = text.charCodeAt(pos);
      if (code >= 0xd800 && code <= 0xdbff && pos + 1 < text.length) {
        const low: number = text.charCodeAt(pos + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          chars.push(text.substring(pos, pos + 2));
          pos += 1;
          continue;
        }
      }
      chars.push(text.charAt(pos));
    }
    const lines: string[] = [];
    let cur: string = '';
    let curW: number = 0;
    let maxW: number = firstMaxW;
    for (let index: number = 0; index < chars.length; index++) {
      const ch: string = chars[index];
      const w: number = this.charWidth(ch, fontFp, weight);
      if (cur.length > 0 && curW + w > maxW) {
        // 累加超宽：整行实测验证（含标点压缩），若整行仍 <= maxW 则继续放（标点压缩省空间）
        if (this.measureFn(cur + ch, fontFp, weight) <= maxW) {
          cur += ch;
          curW += w;
          continue;
        }
        let cut: number = cur.length;
        // 行尾禁则：切点前字符为起始标点 → 一并下移
        if (cut > 1 && FQ_LINE_TAIL_BAN.indexOf(cur.charAt(cut - 1)) >= 0) {
          cut -= 1;
        }
        // 行首禁则：下行首字符为收尾标点 → 行尾再下移一个字符（至多回退 2 次）
        let nextFirst: string = cut < cur.length ? cur.charAt(cut) : ch;
        let retreat: number = 0;
        while (retreat < 2 && cut > 1 && FQ_LINE_HEAD_BAN.indexOf(nextFirst) >= 0) {
          cut -= 1;
          retreat += 1;
          nextFirst = cut < cur.length ? cur.charAt(cut) : ch;
        }
        lines.push(cur.substring(0, cut));
        cur = cur.substring(cut) + ch;
        curW = this.measureFn(cur, fontFp, weight);
        maxW = restMaxW;
      } else {
        cur += ch;
        curW += w;
      }
    }
    if (cur.length > 0) {
      lines.push(cur);
    }
    return lines;
  }

  /** 气泡宽度（px）：内边距/间距随字号缩放，图标按 fp 实高换算，计数文本实测 + 安全余量。 */
  private bubbleWidthPx(metrics: FqReaderLayoutMetrics, count: number): number {
    const chromePx: number = (metrics.bubblePadHVp * 2 + metrics.bubbleSpaceVp) * metrics.density
      + metrics.bubbleIconFp * metrics.textDensity * 1.2;
    return chromePx + this.measureFn(`${count}`, metrics.bubbleTextFp, '400') + 2 * metrics.density;
  }

  /** 章节装页：返回带片段/行/页首位置的完整分页结果。 */
  public layout(chapterIndex: number, paragraphs: string[], metrics: FqReaderLayoutMetrics,
    commentCounts: number[]): FqChapterLayout {
    const result: FqChapterLayout = new FqChapterLayout(chapterIndex);
    result.paragraphs = paragraphs.slice();
    result.commentCounts = commentCounts.slice();
    const pages: FqReaderPageData[] = [];
    let page: FqReaderPageData = new FqReaderPageData();
    let used: number = 0;
    let frag: FqPageFragment | null = null;
    const contentH: number = metrics.contentHeightPx;
    for (let para: number = 0; para < paragraphs.length; para++) {
      const text: string = paragraphs[para];
      if (text.length === 0) {
        continue;
      }
      const isTitle: boolean = para === 0;
      const fontFp: number = isTitle ? metrics.titleFontFp : metrics.fontSizeFp;
      const weight: string = isTitle ? 'bold' : '400';
      const lineH: number = isTitle ? metrics.titleLinePx : metrics.lineHeightPx;
      // 段落文本已含 '\u3000\u3000' 缩进前缀：首行预算即内容区全宽。
      // 再扣 indentPx 属双扣缩进，会导致每段首行提前 ~2 字换行、整页文字挤向左侧。
      const lines: string[] = this.splitLines(text, metrics.contentWidthPx, metrics.contentWidthPx,
        fontFp, weight);
      let charIdx: number = 0;
      for (let li: number = 0; li < lines.length; li++) {
        const blockTop: number = li === 0 ? (isTitle ? metrics.titleTopPx : metrics.paraGapPx) : 0;
        const need: number = blockTop + lineH;
        if (page.fragments.length > 0 && used + need > contentH) {
          // 收页：页片段已满，开新页继续装当前段剩余行
          pages.push(page);
          page = new FqReaderPageData();
          used = 0;
          frag = null;
        }
        if (frag === null || frag.paraIndex !== para) {
          frag = new FqPageFragment(para, isTitle);
          frag.startChar = charIdx;
          page.fragments.push(frag);
          if (page.startPara < 0) {
            page.startPara = para;
            page.startChar = charIdx;
          }
        }
        frag.text += lines[li];
        charIdx += lines[li].length;
        frag.endChar = charIdx;
        used += need;
      }
      if (frag !== null) {
        frag.isParaEnd = true;
      }
      if (isTitle) {
        used += metrics.titleBottomPx;
      } else if (commentCounts.length > para && commentCounts[para] > 0) {
        // 段评气泡行内渲染在段尾 Text 内（FqPageCanvas：ImageSpan+计数 Span 拼在末行后）：
        // 末行剩余宽度放得下 → 0 额外行高；放不下气泡随 Text 换行 → 计一行行高；
        // 连该行也放不下 → 收页，气泡独立片段开新页（同计一行行高）。
        // bubbleWidthPx 为胶囊全宽估算（略大于实际行内渲染宽），判inline偏保守：
        // 宁可多计一行（页底略空）也不少计（页底溢出裁切）。
        const count: number = commentCounts[para];
        const bubbleW: number = this.bubbleWidthPx(metrics, count);
        const lastLineW: number = this.measureFn(lines[lines.length - 1], fontFp, weight);
        const inline: boolean = lastLineW + bubbleW <= metrics.contentWidthPx;
        const charge: number = inline ? 0 : lineH;
        if (!inline && page.fragments.length > 0 && used + charge > contentH) {
          pages.push(page);
          page = new FqReaderPageData();
          used = 0;
          const bubbleFrag: FqPageFragment = new FqPageFragment(para, false);
          bubbleFrag.startChar = text.length;
          bubbleFrag.endChar = text.length;
          bubbleFrag.isParaEnd = true;
          bubbleFrag.showBubble = true;
          page.fragments.push(bubbleFrag);
          page.startPara = para;
          page.startChar = text.length;
          frag = bubbleFrag;
          page.bubbles.push(new FqPageBubble(para,
            metrics.headerZoneVp + metrics.contentTopVp,
            metrics.bubbleRowPx / metrics.density,
            metrics.sidePaddingVp,
            bubbleW / metrics.density));
        } else if (frag !== null) {
          frag.showBubble = true;
          page.bubbles.push(new FqPageBubble(para,
            metrics.headerZoneVp + metrics.contentTopVp + (used - (inline ? lineH : 0)) / metrics.density,
            metrics.bubbleRowPx / metrics.density,
            metrics.sidePaddingVp,
            bubbleW / metrics.density));
        }
        used += charge;
      }
    }
    if (page.fragments.length > 0) {
      pages.push(page);
    }
    result.pages = pages;
    return result;
  }
}

/** 页首位置 → 页下标（进度恢复/重排定位）：返回最后一个起始位置 ≤ 目标位置的页。 */
export function fqPageIndexForPosition(pages: FqReaderPageData[], para: number, char: number): number {
  let result: number = 0;
  for (let index: number = 0; index < pages.length; index++) {
    const page: FqReaderPageData = pages[index];
    if (page.startPara < 0) {
      continue;
    }
    if (page.startPara < para || (page.startPara === para && page.startChar <= char)) {
      result = index;
    } else {
      break;
    }
  }
  return result;
}

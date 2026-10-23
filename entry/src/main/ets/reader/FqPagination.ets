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

  /** 段落断行：贪心逐字符累加，禁则回退（行尾起始标点下移、行首收尾标点再下移至多 2 字符）。 */
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

  /** 行内气泡登记：气泡拼在末行文本后，行高按 max(行高, 胶囊高) 预留；命中区为页面级坐标。 */
  private recordInlineBubble(page: FqReaderPageData, frag: FqPageFragment,
    metrics: FqReaderLayoutMetrics, para: number, usedPx: number, rowH: number,
    lastLineW: number, bubbleW: number): void {
    frag.showBubble = true;
    frag.bubbleInline = true;
    page.bubbles.push(new FqPageBubble(para,
      metrics.headerZoneVp + metrics.contentTopVp + (usedPx - rowH) / metrics.density,
      rowH / metrics.density,
      metrics.sidePaddingVp + lastLineW / metrics.density + metrics.bubbleGapVp,
      bubbleW / metrics.density));
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
        frag.lines.push(lines[li]);
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
        // 段评气泡：优先行内化（拼在末行文本后，不占行高）；
        // 末行放不下时按「预留气泡宽」窄列重排末行；仍不行回退独立气泡行。
        const count: number = commentCounts[para];
        const bubbleW: number = this.bubbleWidthPx(metrics, count);
        const reservePx: number = bubbleW + metrics.bubbleGapVp * metrics.density;
        // 行内气泡所在行高按 max(行高, 胶囊高) 预留：胶囊高于行高（小字号/系统字体放大）
        // 时不再挤占后续行空间，杜绝页底溢出切行
        const inlineRowPx: number = Math.max(lineH, metrics.bubbleCapsulePx);
        const capsuleExtraPx: number = Math.max(0, metrics.bubbleCapsulePx - lineH);
        let inlined: boolean = false;
        if (frag !== null && frag.lines.length > 0
          && metrics.contentWidthPx - reservePx >= metrics.fontSizePx * 3) {
          const lastIdx: number = frag.lines.length - 1;
          const lastLine: string = frag.lines[lastIdx];
          const lastW: number = this.measureFn(lastLine, fontFp, weight);
          if (lastW + reservePx <= metrics.contentWidthPx) {
            used += capsuleExtraPx;
            this.recordInlineBubble(page, frag, metrics, para, used, inlineRowPx, lastW, bubbleW);
            inlined = true;
          } else {
            // 窄列重排末行（首/续行同宽）；多出的行与胶囊增高需装得下当前页
            const narrowMax: number = metrics.contentWidthPx - reservePx;
            const reSplit: string[] = this.splitLines(lastLine, narrowMax, narrowMax, fontFp, weight);
            if (reSplit.length >= 2 && used + inlineRowPx <= contentH) {
              frag.lines.splice(lastIdx, 1);
              for (let ri: number = 0; ri < reSplit.length; ri++) {
                frag.lines.push(reSplit[ri]);
              }
              used += lineH + capsuleExtraPx;
              const newLastW: number = this.measureFn(reSplit[reSplit.length - 1], fontFp, weight);
              this.recordInlineBubble(page, frag, metrics, para, used, inlineRowPx, newLastW, bubbleW);
              inlined = true;
            }
          }
        }
        if (!inlined) {
          // 独立气泡行兜底：装不下则气泡片段独立开新页（气泡永远与段尾逻辑同章同段）
          if (page.fragments.length > 0 && used + metrics.bubbleRowPx > contentH) {
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
          } else if (frag !== null) {
            frag.showBubble = true;
          }
          page.bubbles.push(new FqPageBubble(para,
            metrics.headerZoneVp + metrics.contentTopVp + used / metrics.density,
            metrics.bubbleRowPx / metrics.density,
            metrics.sidePaddingVp,
            bubbleW / metrics.density));
          used += metrics.bubbleRowPx;
        }
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

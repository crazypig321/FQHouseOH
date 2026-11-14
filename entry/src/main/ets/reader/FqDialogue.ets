/**
 * 对话高亮：配对引号区间检测（对齐 fqapp readerDialogueRanges）+ 可见子串分段。
 * - 区间坐标为段内 UTF-16 code unit（start 含 / end 不含），与 Span 子串切割同一坐标系；
 * - 配对引号："" '' 「」 『』 与 "，反斜杠转义的 " 跳过，未闭合引号不染色，
 *   完成的内层配对照常计入，重叠/相邻区间合并；
 * - fqDialogueRanges 含段文本级记忆化缓存（容量上限 256 段，超出整体清空），
 *   返回数组与缓存实例共享，调用方只读不得修改。
 */

/** 对话区间（段内 UTF-16 code unit 坐标，start 含 / end 不含）。 */
export class FqDialogueRange {
  readonly start: number;
  readonly end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

/** 分段结果：dialogue=true 的段应用高亮底色。 */
export class FqDialogueSegment {
  readonly text: string;
  readonly dialogue: boolean;

  constructor(text: string, dialogue: boolean) {
    this.text = text;
    this.dialogue = dialogue;
  }
}

/** 开引号栈帧（配对检测中间态：start 为开引号位置，close 为对应闭引号 code unit）。 */
class FqDialogueOpen {
  readonly start: number;
  readonly close: number;

  constructor(start: number, close: number) {
    this.start = start;
    this.close = close;
  }
}

/** 引号闭合表：开引号 code unit → 对应闭引号 code unit。 */
const FQ_DIALOGUE_CLOSING: Map<number, number> = new Map<number, number>();
FQ_DIALOGUE_CLOSING.set(0x201C, 0x201D);
FQ_DIALOGUE_CLOSING.set(0x2018, 0x2019);
FQ_DIALOGUE_CLOSING.set(0x300C, 0x300D);
FQ_DIALOGUE_CLOSING.set(0x300E, 0x300F);
FQ_DIALOGUE_CLOSING.set(0x0022, 0x0022);

/** 段文本 → 对话区间记忆化缓存（键为整段文本）。 */
const FQ_DIALOGUE_CACHE: Map<string, FqDialogueRange[]> = new Map<string, FqDialogueRange[]>();
const FQ_DIALOGUE_CACHE_MAX: number = 256;
/** 空区间共享实例（无引号段落共用，避免重复分配）。 */
const FQ_DIALOGUE_EMPTY: FqDialogueRange[] = [];

/** 段落对话区间（配对引号；转义跳过、未闭合不染色、重叠/相邻区间合并；记忆化）。 */
export function fqDialogueRanges(text: string): FqDialogueRange[] {
  const cached: FqDialogueRange[] | undefined = FQ_DIALOGUE_CACHE.get(text);
  if (cached !== undefined) {
    return cached;
  }
  const open: FqDialogueOpen[] = [];
  const pairs: FqDialogueRange[] = [];
  let escaped: boolean = false;
  for (let index: number = 0; index < text.length; index++) {
    const unit: number = text.charCodeAt(index);
    if (unit === 0x005C) {
      escaped = !escaped;
      continue;
    }
    const escapedQuote: boolean = escaped && unit === 0x0022;
    escaped = false;
    if (escapedQuote) {
      continue;
    }
    if (open.length > 0) {
      const frame: FqDialogueOpen = open[open.length - 1];
      if (unit === frame.close) {
        open.pop();
        pairs.push(new FqDialogueRange(frame.start, index + 1));
        continue;
      }
    }
    const close: number | undefined = FQ_DIALOGUE_CLOSING.get(unit);
    if (close !== undefined) {
      open.push(new FqDialogueOpen(index, close));
    }
  }
  if (pairs.length === 0) {
    FQ_DIALOGUE_CACHE.set(text, FQ_DIALOGUE_EMPTY);
    return FQ_DIALOGUE_EMPTY;
  }
  pairs.sort((a: FqDialogueRange, b: FqDialogueRange): number => a.start - b.start);
  const ranges: FqDialogueRange[] = [];
  for (const pair of pairs) {
    if (ranges.length === 0) {
      ranges.push(pair);
      continue;
    }
    const last: FqDialogueRange = ranges[ranges.length - 1];
    if (pair.start > last.end) {
      ranges.push(pair);
    } else if (pair.end > last.end) {
      ranges[ranges.length - 1] = new FqDialogueRange(last.start, pair.end);
    }
  }
  if (FQ_DIALOGUE_CACHE.size >= FQ_DIALOGUE_CACHE_MAX) {
    FQ_DIALOGUE_CACHE.clear();
  }
  FQ_DIALOGUE_CACHE.set(text, ranges);
  return ranges;
}

/**
 * 文本按对话区间分段：text 为段落的可见子串（起于段内 baseOffset，UTF-16 code unit）。
 * 无交集时返回单个普通段（text 整体、dialogue=false），保证调用方恒有可渲染内容。
 */
export function fqDialogueSegments(text: string, baseOffset: number,
  ranges: FqDialogueRange[]): FqDialogueSegment[] {
  const segments: FqDialogueSegment[] = [];
  const textEnd: number = baseOffset + text.length;
  let cursor: number = 0;
  for (const range of ranges) {
    if (range.start >= textEnd) {
      break;
    }
    const localStart: number = Math.max(range.start - baseOffset, 0);
    const localEnd: number = Math.min(range.end - baseOffset, text.length);
    if (localEnd <= localStart) {
      continue;
    }
    if (localStart > cursor) {
      segments.push(new FqDialogueSegment(text.substring(cursor, localStart), false));
    }
    segments.push(new FqDialogueSegment(text.substring(localStart, localEnd), true));
    cursor = localEnd;
    if (cursor >= text.length) {
      break;
    }
  }
  if (cursor < text.length) {
    segments.push(new FqDialogueSegment(text.substring(cursor), false));
  }
  return segments;
}

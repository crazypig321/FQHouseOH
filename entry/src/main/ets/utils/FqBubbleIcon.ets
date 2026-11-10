/**
 * 数值气泡图标工具（rawfile bubble 系列，共 100 张）：
 * - 1 ~ 99 → bubble/bubble-XX.svg（两位补零，图标即数值气泡）；
 * - > 99（≥100）→ bubble/bubble_99plus.svg（统一 99+）；
 * - ≤ 0 无对应图标，钳到 bubble-01.svg。
 * 返回路径可直接用于 Image($rawfile(path))，或用 fqBubbleIcon() 一步取 Resource。
 */

/** 气泡图标 rawfile 子目录。 */
const FQ_BUBBLE_DIR: string = 'bubble';
/** 数值气泡上限（超过统一显示 99+ 图标）。 */
const FQ_BUBBLE_MAX: number = 99;

/** 数值 → 气泡图标 rawfile 路径（bubble/bubble-01.svg … bubble-99.svg / bubble_99plus.svg）。 */
export function fqBubbleIconPath(value: number): string {
  const n: number = Math.trunc(value);
  if (n > FQ_BUBBLE_MAX) {
    return `${FQ_BUBBLE_DIR}/bubble_99plus.svg`;
  }
  const clamped: number = n < 1 ? 1 : n;
  const pad: string = clamped < 10 ? '0' : '';
  return `${FQ_BUBBLE_DIR}/${FQ_BUBBLE_DIR}-${pad}${clamped}.svg`;
}

/** 数值 → 气泡图标资源（直接用于 Image(fqBubbleIcon(n))）。 */
export function fqBubbleIcon(value: number): Resource {
  return $rawfile(fqBubbleIconPath(value));
}

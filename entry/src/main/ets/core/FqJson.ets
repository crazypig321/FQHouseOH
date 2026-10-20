/**
 * JSON 动态载荷访问工具。
 *
 * 后端业务 JSON 结构深且字段名随内容类型变化（小说/短剧/漫画/听书各不相同），
 * 无法用静态模型完整描述。所有对 JSON 的 Record 导航、类型收窄与 `as` 收口
 * 集中在本文件，业务解析层（FqParser）保持无类型断言。
 */

export function fqAsRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (Array.isArray(value)) {
    return null;
  }
  if (typeof value !== 'object') {
    return null;
  }
  return value as Record<string, Object>;
}

export function fqAsArray(value: Object | null | undefined): Object[] | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (Array.isArray(value)) {
    return value as Object[];
  }
  return null;
}

export function fqStr(rec: Record<string, Object>, key: string): string {
  const v: Object | undefined = rec[key];
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number') {
    return v.toString();
  }
  return '';
}

export function fqNum(rec: Record<string, Object>, key: string): number {
  const v: Object | undefined = rec[key];
  if (typeof v === 'number') {
    return v;
  }
  return 0;
}

export function fqBool(rec: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = rec[key];
  return v === true;
}

/**
 * 依序取第一个非空字符串字段；数字（非 0）转字符串返回。
 * 对齐 Dart 侧 `_firstString` 语义。
 */
export function fqFirstString(rec: Record<string, Object>, keys: string[]): string {
  for (const key of keys) {
    const v: Object | undefined = rec[key];
    if (typeof v === 'string' && v.trim().length > 0) {
      return v.trim();
    }
    if (typeof v === 'number' && v !== 0) {
      return v.toString();
    }
  }
  return '';
}

/** 宽松整数解析（bool 之外的 JSON 值都试一次），失败返回 fallback。 */
export function fqAsInt(raw: Object | undefined, fallback: number): number {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return Math.trunc(raw);
  }
  if (typeof raw === 'string' && raw.trim().length > 0) {
    const parsed: number = Number.parseInt(raw.trim(), 10);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

export function fqTruthy(v: Object | undefined): boolean {
  if (typeof v === 'undefined') {
    return false;
  }
  if (v === null) {
    return false;
  }
  if (typeof v === 'string') {
    return v.length > 0;
  }
  if (typeof v === 'number') {
    return v !== 0;
  }
  if (typeof v === 'boolean') {
    return v;
  }
  return true;
}

export function fqTruthyAny(rec: Record<string, Object>, keys: string[]): boolean {
  for (const key of keys) {
    if (fqTruthy(rec[key])) {
      return true;
    }
  }
  return false;
}

/** 解析 JSON 文本为顶层 Record；失败或非对象返回 null。 */
export function fqParseObject(text: string): Record<string, Object> | null {
  try {
    const parsed: Object | null = JSON.parse(text);
    return fqAsRecord(parsed);
  } catch (error) {
    return null;
  }
}

/** 浅合并 override 到 target（override 优先），用于摊平嵌套卡片字段。 */
export function fqShallowMergeInto(target: Record<string, Object>, source: Record<string, Object>): void {
  const keys: string[] = Object.keys(source);
  for (const key of keys) {
    target[key] = source[key];
  }
}

export function fqEmptyRecord(): Record<string, Object> {
  const empty: Record<string, Object> = {};
  return empty;
}

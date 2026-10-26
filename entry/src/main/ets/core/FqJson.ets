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

/**
 * 段评/章评作者判定（仅 shape A 主楼列表，实测 3 本书 ~5700 条样本）：
 * - 作者本人从不出现在主楼列表（仅经楼中楼回复参与，App 未渲染回复），
 *   主楼中的 is_author 标记（user_tag.is_author）只代表评论者是平台作家（误标来源）；
 * - 因此本判定仅在 creator_id 为空且 is_author 为真时视为作者（保守，不误标），
 *   user_id 与 creator_id 相等时视为作者（同 id 兜底）。
 * 书评（shape B）不走本函数：其 user_info.is_author 即本书作者，直接使用。
 */
export function fqIsCreatorComment(isAuthorFlag: boolean, userIdRaw: Object | undefined,
  creatorIdRaw: Object | undefined): boolean {
  const userId: string = typeof userIdRaw === 'number' ? userIdRaw.toString()
    : (typeof userIdRaw === 'string' ? userIdRaw : '');
  const creatorId: string = typeof creatorIdRaw === 'number' ? creatorIdRaw.toString()
    : (typeof creatorIdRaw === 'string' ? creatorIdRaw : '');
  if (userId.length > 0 && creatorId.length > 0) {
    return userId === creatorId;
  }
  return isAuthorFlag && creatorId.length === 0;
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

/** 顶层键名列表（仅用于 DFS 遍历未知结构）。 */
export function fqKeys(rec: Record<string, Object>): string[] {
  return Object.keys(rec);
}

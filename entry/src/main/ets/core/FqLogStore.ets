/**
 * 应用日志中心（对齐 fqapp AppLog / Rust core_log）：
 * - FqLogLevel / FqLogEntry / FqLogStore（@ObservedV2 环形缓冲，revision 自增驱动日志页刷新）；
 * - FqLog.d/i/w/e：应用侧日志入口（当前接线：本地后端启动与请求失败）；
 * - fqParseLogLines：解析 Rust 核心 rust.log 行（「[D] ISO core: 模块: 消息」，UTC 落盘），
 *   与应用条目同形，日志页「核心」源直接渲染；
 * - fqFormatLogLines：复制 / 导出用的行文本（与应用 app.log、核心 rust.log 同形）。
 */

/** 应用日志环形缓冲上限（条，旧条目超出即淘汰）。 */
const FQ_LOG_RING_MAX: number = 1000;

/** 日志级别（token 与 rust.log / fqapp app.log 行前缀一致）。 */
export enum FqLogLevel {
  debug = 0,
  info = 1,
  warn = 2,
  error = 3,
}

/** 级别中文标签（徽标与筛选菜单共用）。 */
export function fqLogLevelLabel(level: FqLogLevel): string {
  switch (level) {
    case FqLogLevel.debug:
      return '调试';
    case FqLogLevel.info:
      return '资讯';
    case FqLogLevel.warn:
      return '警告';
    case FqLogLevel.error:
      return '错误';
    default:
      return '调试';
  }
}

function levelToken(level: FqLogLevel): string {
  switch (level) {
    case FqLogLevel.debug:
      return 'D';
    case FqLogLevel.info:
      return 'I';
    case FqLogLevel.warn:
      return 'W';
    case FqLogLevel.error:
      return 'E';
    default:
      return 'D';
  }
}

/** 两位补零。 */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 本地时间戳（YYYY-MM-DDTHH:mm:ss，与 rust.log 行格式一致）。 */
export function fqLogStamp(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}` +
    `T${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`;
}

/** 本地时刻短文本（HH:mm:ss，日志行用）。 */
export function fqLogClock(date: Date): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`;
}

/**
 * 单条日志：seq 为来源内唯一序号（应用 = 环形写入序号，核心 = 文件行号），
 * 作日志页 LazyForEach 的 key；format 与 rust.log / fqapp app.log 行同形。
 */
export class FqLogEntry {
  public readonly seq: number;
  public readonly timeMs: number;
  public readonly level: FqLogLevel;
  public readonly tag: string;
  public readonly message: string;

  constructor(seq: number, timeMs: number, level: FqLogLevel, tag: string, message: string) {
    this.seq = seq;
    this.timeMs = timeMs;
    this.level = level;
    this.tag = tag;
    this.message = message;
  }

  /** 导出 / 复制行格式。 */
  public format(): string {
    return `[${levelToken(this.level)}] ${fqLogStamp(new Date(this.timeMs))} ${this.tag}: ${this.message}`;
  }
}

/** 批量行文本（逐行 format，换行连接）。 */
export function fqFormatLogLines(entries: FqLogEntry[]): string {
  const lines: string[] = [];
  for (const entry of entries) {
    lines.push(entry.format());
  }
  return lines.join('\n');
}

/** rust.log / app.log 行解析（fqapp _parseHistoryLines 同形）：[D/I/W/E] ISO 标签: 消息。 */
const LOG_LINE_PATTERN: RegExp = /^\[([DIWE])\] (\S+) ([^:]*): (.*)$/;

function levelOfToken(token: string): FqLogLevel | null {
  if (token === 'D') {
    return FqLogLevel.debug;
  }
  if (token === 'I') {
    return FqLogLevel.info;
  }
  if (token === 'W') {
    return FqLogLevel.warn;
  }
  if (token === 'E') {
    return FqLogLevel.error;
  }
  return null;
}

/**
 * 解析核心 rust.log 行（seq = 行号；时间戳为 UTC，补 Z 解析转设备时区；
 * 无法解析的行丢弃）。空行（文件末尾换行等）跳过。
 */
export function fqParseLogLines(lines: string[]): FqLogEntry[] {
  const entries: FqLogEntry[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.trim().length === 0) {
      continue;
    }
    const match: RegExpExecArray | null = LOG_LINE_PATTERN.exec(line);
    if (match === null || match.length < 5) {
      continue;
    }
    const level: FqLogLevel | null = levelOfToken(match[1]);
    if (level === null) {
      continue;
    }
    let timeMs: number = Date.now();
    const parsed: number = Date.parse(`${match[2]}Z`);
    if (!Number.isNaN(parsed)) {
      timeMs = parsed;
    }
    entries.push(new FqLogEntry(i, timeMs, level, match[3], match[4]));
  }
  return entries;
}

/** 应用日志环形缓冲（@ObservedV2：revision 自增驱动日志页 @Monitor 刷新）。 */
@ObservedV2
export class FqLogStore {
  @Trace public revision: number = 0;
  private ring: FqLogEntry[] = [];
  private seqCounter: number = 0;

  /** 全部条目（旧 → 新，副本，调用方可安全倒序渲染）。 */
  public entries(): FqLogEntry[] {
    return this.ring.slice();
  }

  public emit(level: FqLogLevel, tag: string, message: string): void {
    this.seqCounter += 1;
    this.ring.push(new FqLogEntry(this.seqCounter, Date.now(), level, tag, message));
    if (this.ring.length > FQ_LOG_RING_MAX) {
      this.ring.splice(0, this.ring.length - FQ_LOG_RING_MAX);
    }
    this.revision += 1;
  }

  public clear(): void {
    this.ring = [];
    this.revision += 1;
  }
}

/** 全局单例（应用侧唯一日志存储）。 */
export const fqLogStore: FqLogStore = new FqLogStore();

/** 应用侧日志入口（对齐 fqapp AppLog.d/i/w/e 静态方法）。 */
export class FqLog {
  public static d(tag: string, message: string): void {
    fqLogStore.emit(FqLogLevel.debug, tag, message);
  }

  public static i(tag: string, message: string): void {
    fqLogStore.emit(FqLogLevel.info, tag, message);
  }

  public static w(tag: string, message: string): void {
    fqLogStore.emit(FqLogLevel.warn, tag, message);
  }

  public static e(tag: string, message: string): void {
    fqLogStore.emit(FqLogLevel.error, tag, message);
  }
}

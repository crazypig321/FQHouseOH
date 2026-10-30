/**
 * 阅读进度与阅读设置持久化（preferences，参考 musicfreeOH KVStore 用法）：
 * - 进度：每本书 { chapterIndex, domPos }（Reader Kit pageShow 的 startDomPos）。
 * - 设置：字号/行距/主题/翻页方式，全局共享，内存单例 + 落盘。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { fqAsRecord, fqAsArray, fqKeys, fqStr, fqNum } from './FqJson';
import { appState } from '../entryability/AppState';

const FQ_READER_STORE_NAME: string = 'fq_reader';
const FQ_READER_KEY_SETTINGS: string = 'settings';
const FQ_READER_KEY_PROGRESS: string = 'progress_';
const FQ_READER_KEY_PAGES: string = 'pages_';
const FQ_READER_KEY_READ: string = 'read_';
/** 自定义主题背景图压缩参数（导入即压缩，控制沙箱与备份内嵌体积）。 */
const FQ_THEME_BG_MAX_EDGE: number = 1440;
const FQ_THEME_BG_JPEG_QUALITY: number = 85;

/** 单书阅读进度。 */
export class FqReaderProgress {
  readonly chapterIndex: number;
  readonly domPos: string;
  /** 整书阅读百分比 0..100（书架封面角标用）；-1 = 未记录。 */
  readonly percent: number;

  constructor(chapterIndex: number, domPos: string, percent: number = -1) {
    this.chapterIndex = chapterIndex;
    this.domPos = domPos;
    this.percent = percent;
  }
}

/** 阅读设置（构造即默认值）。 */
export class FqReaderSettings {
  fontSize: number = 19;
  lineHeight: number = 1.9;
  /** -1 跟随系统深浅色 / 0 纸白 / 1 米黄 / 2 夜间 / 3 自定义背景图（customThemeId 指定）。 */
  themeIndex: number = -1;
  /** 0 仿真翻页 / 1 横滑翻页 / 2 上下滚动。 */
  flipIndex: number = 0;
  /** 漫画翻页方式：0 仿真 / 1 覆盖 / 2 上下滚动。 */
  comicFlipIndex: number = 0;
  /** 字体档位（FQ_FONT_OPTIONS 下标）：0 系统（跟随系统字体设置）/ 1 书宋 / 2 黑体。 */
  fontIndex: number = 0;
  /** 段评显示开关（关闭后不显示段评气泡与计数，重新分页）。 */
  showParagraphComment: boolean = true;
  /** 音量键翻页开关（阅读页/漫画页共用；分页模式拦截音量上/下 = 上/下一页，上下滚动模式不拦截）。 */
  volumeKeyPaging: boolean = false;
  /** 自定义阅读主题列表（背景图 + 独立排版参数；themeIndex=3 生效）。 */
  customThemes: FqCustomReaderTheme[] = [];
  /** 当前选中的自定义主题 id（themeIndex=3 时生效；空 = 无选中）。 */
  customThemeId: string = '';
  /** 自定义字色板（取色器新增字色，新色在前；阅读主题编辑弹窗字色列表共用）。 */
  customFontColors: string[] = [];
}

/** 自定义阅读主题：浅色/深色双模式（各配背景图 + 独立排版参数，0/-1/空 = 跟随全局阅读设置）。 */
export class FqCustomReaderTheme {
  id: string = '';
  name: string = '自定义';
  /** 浅色模式背景图沙箱绝对路径（空 = 未设置浅色模式）。 */
  lightBgPath: string = '';
  /** 浅色模式正文字色（空 = 默认墨黑 #1F2329）。 */
  lightFontColor: string = '';
  /** 浅色模式字号（0 = 跟随全局）。 */
  lightFontSize: number = 0;
  /** 浅色模式字体档位（-1 = 跟随全局）。 */
  lightFontIndex: number = -1;
  /** 浅色模式行距（0 = 跟随全局）。 */
  lightLineHeight: number = 0;
  /** 深色模式背景图沙箱绝对路径（空 = 未设置深色模式）。 */
  darkBgPath: string = '';
  /** 深色模式正文字色（空 = 默认夜间灰 #9AA0A6）。 */
  darkFontColor: string = '';
  /** 深色模式字号（0 = 跟随全局）。 */
  darkFontSize: number = 0;
  /** 深色模式字体档位（-1 = 跟随全局）。 */
  darkFontIndex: number = -1;
  /** 深色模式行距（0 = 跟随全局）。 */
  darkLineHeight: number = 0;
}

/** 双模式主题当前应使用的模式：仅设深色图 → 深；仅设浅色图 → 浅；双设 → systemDark。 */
export function fqCustomThemeUseDark(theme: FqCustomReaderTheme, systemDark: boolean): boolean {
  if (theme.darkBgPath.length === 0) {
    return false;
  }
  if (theme.lightBgPath.length === 0) {
    return true;
  }
  return systemDark;
}

/** 字色规范化：仅收 6 位 #RRGGBB（8 位视为 #AARRGGBB 取 RGB 段），非法返回空串。 */
export function fqNormalizeThemeFontColor(value: string): string {
  const text: string = value.trim();
  if (/^#[0-9A-Fa-f]{6}$/.test(text)) {
    return text;
  }
  if (/^#[0-9A-Fa-f]{8}$/.test(text)) {
    return `#${text.substring(3)}`;
  }
  return '';
}

function fqClampThemeName(value: string): string {
  const text: string = value.trim().substring(0, 12);
  return text.length > 0 ? text : '自定义';
}

function fqClampThemeFontSize(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return fqClampFontSize(value);
}

function fqClampThemeLineHeight(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return fqClampLineHeight(value);
}

function fqClampFontSize(value: number): number {
  return Math.min(32, Math.max(12, Math.round(value)));
}

function fqClampLineHeight(value: number): number {
  return Math.min(2.6, Math.max(1.2, Math.round(value * 10) / 10));
}

export class FqReaderStore {
  private static pref: preferences.Preferences | null = null;
  private static settings: FqReaderSettings = new FqReaderSettings();
  private static filesDir: string = '';

  public static init(context: common.Context): void {
    FqReaderStore.filesDir = context.filesDir;
    if (FqReaderStore.pref !== null) {
      return;
    }
    try {
      FqReaderStore.pref = preferences.getPreferencesSync(context, { name: FQ_READER_STORE_NAME });
    } catch (error) {
      FqReaderStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqReaderStore.pref.getSync(FQ_READER_KEY_SETTINGS, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = parsed === null ? null : fqAsRecord(parsed);
      if (rec === null) {
        return;
      }
      const fontSize: Object | undefined = rec['fontSize'];
      if (typeof fontSize === 'number') {
        FqReaderStore.settings.fontSize = fqClampFontSize(fontSize);
      }
      const lineHeight: Object | undefined = rec['lineHeight'];
      if (typeof lineHeight === 'number') {
        FqReaderStore.settings.lineHeight = fqClampLineHeight(lineHeight);
      }
      const themeIndex: Object | undefined = rec['themeIndex'];
      if (typeof themeIndex === 'number') {
        FqReaderStore.settings.themeIndex = Math.min(3, Math.max(-1, Math.trunc(themeIndex)));
      }
      // 旧版本数据（无版本号）迁移：主题重置为跟随系统（旧版无跟随档，存值语义已变化）
      const version: Object | undefined = rec['v'];
      if (typeof version !== 'number' || Math.trunc(version) < 2) {
        FqReaderStore.settings.themeIndex = -1;
      }
      const flipIndex: Object | undefined = rec['flipIndex'];
      if (typeof flipIndex === 'number') {
        FqReaderStore.settings.flipIndex = Math.min(2, Math.max(0, Math.trunc(flipIndex)));
      }
      const comicFlipIndex: Object | undefined = rec['comicFlipIndex'];
      if (typeof comicFlipIndex === 'number') {
        FqReaderStore.settings.comicFlipIndex = Math.min(2, Math.max(0, Math.trunc(comicFlipIndex)));
      }
      const fontIndex: Object | undefined = rec['fontIndex'];
      if (typeof fontIndex === 'number') {
        FqReaderStore.settings.fontIndex = Math.max(0, Math.trunc(fontIndex));
      }
      // v2→v3：字体档位重排（系统档提前）——旧 0 书宋→1、旧 1 黑体→2、旧 2 系统→0
      if (typeof version !== 'number' || Math.trunc(version) < 3) {
        const oldFont: number = FqReaderStore.settings.fontIndex;
        FqReaderStore.settings.fontIndex = oldFont === 0 ? 1 : (oldFont === 1 ? 2 : 0);
      }
      const showParagraphComment: Object | undefined = rec['showParagraphComment'];
      if (typeof showParagraphComment === 'boolean') {
        FqReaderStore.settings.showParagraphComment = showParagraphComment;
      }
      const volumeKeyPaging: Object | undefined = rec['volumeKeyPaging'];
      if (typeof volumeKeyPaging === 'boolean') {
        FqReaderStore.settings.volumeKeyPaging = volumeKeyPaging;
      }
      // 旧版单张自定义背景（v4 及以前 customBgPath）迁移为自定义主题列表首项
      const customBgPath: Object | undefined = rec['customBgPath'];
      if (typeof customBgPath === 'string' && customBgPath.length > 0
        && FqReaderStore.settings.customThemes.length === 0) {
        const migrated: FqCustomReaderTheme = new FqCustomReaderTheme();
        migrated.id = `ct${Date.now()}`;
        migrated.name = '自定义';
        migrated.lightBgPath = customBgPath;
        FqReaderStore.settings.customThemes.push(migrated);
        if (FqReaderStore.settings.themeIndex === 3) {
          FqReaderStore.settings.customThemeId = migrated.id;
        }
      }
      // 自定义主题列表（JSON 数组，字段逐条校验，坏条目跳过）
      const customThemesRaw: Object | undefined = rec['customThemes'];
      if (typeof customThemesRaw === 'string' && customThemesRaw.length > 0) {
        try {
          const parsedThemes: Object | null = JSON.parse(customThemesRaw);
          const themeArray: Object[] | null = fqAsArray(parsedThemes);
          if (themeArray !== null) {
            const ids: Set<string> = new Set<string>();
            const themes: FqCustomReaderTheme[] = [];
            for (const item of themeArray) {
              const entry: FqCustomReaderTheme | null = FqReaderStore.decodeCustomTheme(item);
              if (entry === null || ids.has(entry.id)) {
                continue;
              }
              ids.add(entry.id);
              themes.push(entry);
            }
            FqReaderStore.settings.customThemes = themes;
          }
        } catch (error) {
          // 列表损坏按空处理
        }
      }
      const customThemeId: Object | undefined = rec['customThemeId'];
      if (typeof customThemeId === 'string') {
        FqReaderStore.settings.customThemeId = customThemeId;
      }
      // 自定义字色板（JSON 数组，逐条规范化，坏值/重复跳过）
      const customFontColorsRaw: Object | undefined = rec['customFontColors'];
      if (typeof customFontColorsRaw === 'string' && customFontColorsRaw.length > 0) {
        try {
          const parsedColors: Object | null = JSON.parse(customFontColorsRaw);
          const colorArray: Object[] | null = fqAsArray(parsedColors);
          if (colorArray !== null) {
            const colors: string[] = [];
            for (const item of colorArray) {
              if (typeof item !== 'string') {
                continue;
              }
              const normalized: string = fqNormalizeThemeFontColor(item);
              if (normalized.length === 0 || colors.indexOf(normalized) >= 0) {
                continue;
              }
              colors.push(normalized);
            }
            FqReaderStore.settings.customFontColors = colors;
          }
        } catch (error) {
          // 列表损坏按空处理
        }
      }
    } catch (error) {
      // 损坏配置按默认处理
    }
  }

  public static getSettings(): FqReaderSettings {
    return FqReaderStore.settings;
  }

  public static saveSettings(fontSize: number, lineHeight: number,
    themeIndex: number, flipIndex: number, fontIndex: number, showParagraphComment: boolean): void {
    FqReaderStore.settings.fontSize = fqClampFontSize(fontSize);
    FqReaderStore.settings.lineHeight = fqClampLineHeight(lineHeight);
    FqReaderStore.settings.themeIndex = Math.min(3, Math.max(-1, Math.trunc(themeIndex)));
    FqReaderStore.settings.flipIndex = Math.min(2, Math.max(0, Math.trunc(flipIndex)));
    FqReaderStore.settings.fontIndex = Math.max(0, Math.trunc(fontIndex));
    FqReaderStore.settings.showParagraphComment = showParagraphComment;
    FqReaderStore.persistSettings();
  }

  /** 漫画翻页方式单独保存（不动小说设置）。 */
  public static saveComicFlip(comicFlipIndex: number): void {
    FqReaderStore.settings.comicFlipIndex = Math.min(2, Math.max(0, Math.trunc(comicFlipIndex)));
    FqReaderStore.persistSettings();
  }

  /** 音量键翻页开关单独保存（阅读页/漫画页/设置页共用；同步 AppState 全局开关实时联动）。 */
  public static saveVolumeKeyPaging(enabled: boolean): void {
    FqReaderStore.settings.volumeKeyPaging = enabled;
    appState.volumeKeyPaging = enabled;
    FqReaderStore.persistSettings();
  }

  /** 取自定义字色板（新色在前）。 */
  public static getCustomFontColors(): string[] {
    return FqReaderStore.settings.customFontColors;
  }

  /** 新增自定义字色：规范化去重后插到最前（已存在则提前），落盘。 */
  public static addCustomFontColor(color: string): void {
    const normalized: string = fqNormalizeThemeFontColor(color);
    if (normalized.length === 0) {
      return;
    }
    const next: string[] = [normalized];
    for (const item of FqReaderStore.settings.customFontColors) {
      if (item !== normalized) {
        next.push(item);
      }
    }
    FqReaderStore.settings.customFontColors = next;
    FqReaderStore.persistSettings();
  }

  /** 自定义主题条目解析（JSON 记录 → 模型；id 缺失或无任何背景图返回 null，参数越界钳制）。
   *  兼容旧版单模式条目（bgPath + dark 标记）：按 dark 路由到对应模式的图与参数。 */
  private static decodeCustomTheme(item: Object): FqCustomReaderTheme | null {
    const rec: Record<string, Object> | null = fqAsRecord(item);
    if (rec === null) {
      return null;
    }
    const id: string = fqStr(rec, 'id');
    if (id.trim().length === 0) {
      return null;
    }
    const lightBgPath: string = fqStr(rec, 'lightBgPath');
    const darkBgPath: string = fqStr(rec, 'darkBgPath');
    const legacyBgPath: string = fqStr(rec, 'bgPath');
    if (lightBgPath.length === 0 && darkBgPath.length === 0 && legacyBgPath.length === 0) {
      return null;
    }
    const entry: FqCustomReaderTheme = new FqCustomReaderTheme();
    entry.id = id.trim();
    entry.name = fqClampThemeName(fqStr(rec, 'name'));
    if (lightBgPath.length === 0 && darkBgPath.length === 0) {
      const legacyDark: boolean = rec['dark'] === true;
      if (legacyDark) {
        entry.darkBgPath = legacyBgPath;
      } else {
        entry.lightBgPath = legacyBgPath;
      }
      const legacyFontColor: string = fqNormalizeThemeFontColor(fqStr(rec, 'fontColor'));
      const legacyFontSize: number = fqClampThemeFontSize(fqNum(rec, 'fontSize'));
      const legacyFontIndexRaw: number = fqNum(rec, 'fontIndex');
      const legacyFontIndex: number = Number.isFinite(legacyFontIndexRaw) && legacyFontIndexRaw >= -1
        ? Math.trunc(legacyFontIndexRaw) : -1;
      const legacyLineHeight: number = fqClampThemeLineHeight(fqNum(rec, 'lineHeight'));
      if (legacyDark) {
        entry.darkFontColor = legacyFontColor;
        entry.darkFontSize = legacyFontSize;
        entry.darkFontIndex = legacyFontIndex;
        entry.darkLineHeight = legacyLineHeight;
      } else {
        entry.lightFontColor = legacyFontColor;
        entry.lightFontSize = legacyFontSize;
        entry.lightFontIndex = legacyFontIndex;
        entry.lightLineHeight = legacyLineHeight;
      }
    } else {
      entry.lightBgPath = lightBgPath;
      entry.darkBgPath = darkBgPath;
      entry.lightFontColor = fqNormalizeThemeFontColor(fqStr(rec, 'lightFontColor'));
      entry.lightFontSize = fqClampThemeFontSize(fqNum(rec, 'lightFontSize'));
      const lightFontIndexRaw: number = fqNum(rec, 'lightFontIndex');
      entry.lightFontIndex = Number.isFinite(lightFontIndexRaw) && lightFontIndexRaw >= -1
        ? Math.trunc(lightFontIndexRaw) : -1;
      entry.lightLineHeight = fqClampThemeLineHeight(fqNum(rec, 'lightLineHeight'));
      entry.darkFontColor = fqNormalizeThemeFontColor(fqStr(rec, 'darkFontColor'));
      entry.darkFontSize = fqClampThemeFontSize(fqNum(rec, 'darkFontSize'));
      const darkFontIndexRaw: number = fqNum(rec, 'darkFontIndex');
      entry.darkFontIndex = Number.isFinite(darkFontIndexRaw) && darkFontIndexRaw >= -1
        ? Math.trunc(darkFontIndexRaw) : -1;
      entry.darkLineHeight = fqClampThemeLineHeight(fqNum(rec, 'darkLineHeight'));
    }
    return entry;
  }

  /** 主题草稿参数净化（名称/字色/字号/字体/行距钳制；背景图路径原样透传）。 */
  private static sanitizeTheme(draft: FqCustomReaderTheme): FqCustomReaderTheme {
    const entry: FqCustomReaderTheme = new FqCustomReaderTheme();
    entry.name = fqClampThemeName(draft.name);
    entry.lightBgPath = draft.lightBgPath;
    entry.lightFontColor = fqNormalizeThemeFontColor(draft.lightFontColor);
    entry.lightFontSize = fqClampThemeFontSize(draft.lightFontSize);
    entry.lightFontIndex = draft.lightFontIndex >= -1 ? Math.trunc(draft.lightFontIndex) : -1;
    entry.lightLineHeight = fqClampThemeLineHeight(draft.lightLineHeight);
    entry.darkBgPath = draft.darkBgPath;
    entry.darkFontColor = fqNormalizeThemeFontColor(draft.darkFontColor);
    entry.darkFontSize = fqClampThemeFontSize(draft.darkFontSize);
    entry.darkFontIndex = draft.darkFontIndex >= -1 ? Math.trunc(draft.darkFontIndex) : -1;
    entry.darkLineHeight = fqClampThemeLineHeight(draft.darkLineHeight);
    return entry;
  }

  /** 图片导入序号（同一毫秒内多次选图去重）。 */
  private static themeImportSeq: number = 0;

  /**
   * 系统图库选图 URI → 压缩转 JPEG（限最长边 1440、质量 85）写入沙箱
   * fq_reader_bg/ct{时间戳}_{序号}.jpg（不落条目）；压缩失败回退原图拷贝。
   * 先写临时文件再原子改名，失败不产生脏文件；返回沙箱绝对路径（失败返回空串）。
   */
  public static async importThemeImage(uri: string): Promise<string> {
    const filesDir: string = FqReaderStore.filesDir;
    if (filesDir.length === 0 || uri.length === 0) {
      return '';
    }
    let ext: string = 'jpg';
    const dot: number = uri.lastIndexOf('.');
    const slash: number = uri.lastIndexOf('/');
    if (dot > slash && dot < uri.length - 1) {
      const raw: string = uri.substring(dot + 1).toLowerCase();
      if (raw === 'png' || raw === 'gif' || raw === 'webp' || raw === 'bmp' || raw === 'heic') {
        ext = raw;
      }
    }
    FqReaderStore.themeImportSeq += 1;
    const name: string = `ct${Date.now()}_${FqReaderStore.themeImportSeq}`;
    const dir: string = `${filesDir}/fq_reader_bg`;
    const tmpBase: string = `${dir}/${name}_new`;
    let target: string = `${dir}/${name}.jpg`;
    let src: fileIo.File | null = null;
    let dst: fileIo.File | null = null;
    let wroteJpeg: boolean = false;
    try {
      try {
        fileIo.mkdirSync(dir);
      } catch (error) {
        // 目录已存在
      }
      src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      // 压缩为 JPEG 小图（备份内嵌体积可控）；失败回退原图拷贝
      const packed: ArrayBuffer | null =
        await FqReaderStore.packJpegBytes(src.fd, FQ_THEME_BG_MAX_EDGE, FQ_THEME_BG_JPEG_QUALITY);
      if (packed !== null) {
        dst = fileIo.openSync(`${tmpBase}.jpg`,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(dst.fd, packed);
        fileIo.closeSync(dst);
        dst = null;
        wroteJpeg = true;
      } else {
        dst = fileIo.openSync(`${tmpBase}.${ext}`,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.copyFileSync(src.fd, dst.fd);
        fileIo.closeSync(dst);
        dst = null;
        target = `${dir}/${name}.${ext}`;
      }
      fileIo.closeSync(src);
      src = null;
      try {
        fileIo.unlinkSync(target);
      } catch (unlinkError) {
        // 目标不存在属正常
      }
      fileIo.renameSync(wroteJpeg ? `${tmpBase}.jpg` : `${tmpBase}.${ext}`, target);
      return target;
    } catch (error) {
      if (src !== null) {
        try {
          fileIo.closeSync(src);
        } catch (closeError) {
          // 忽略关闭失败
        }
      }
      if (dst !== null) {
        try {
          fileIo.closeSync(dst);
        } catch (closeError) {
          // 忽略关闭失败
        }
      }
      try {
        fileIo.unlinkSync(`${tmpBase}.jpg`);
      } catch (cleanError) {
        // 忽略清理失败
      }
      try {
        fileIo.unlinkSync(`${tmpBase}.${ext}`);
      } catch (cleanError) {
        // 忽略清理失败
      }
      return '';
    }
  }

  /** 图片 fd 解码 → 最长边压到 maxEdge（小图不放大）→ JPEG（quality）字节；失败返回 null。 */
  private static async packJpegBytes(fd: number, maxEdge: number, quality: number):
    Promise<ArrayBuffer | null> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      source = image.createImageSource(fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return null;
      }
      let targetWidth: number = width;
      let targetHeight: number = height;
      const longer: number = Math.max(width, height);
      if (longer > maxEdge) {
        const scale: number = maxEdge / longer;
        targetWidth = Math.max(1, Math.round(width * scale));
        targetHeight = Math.max(1, Math.round(height * scale));
      }
      pixelMap = await source.createPixelMap({
        desiredSize: { width: targetWidth, height: targetHeight },
      });
      packer = image.createImagePacker();
      return await packer.packing(pixelMap, { format: 'image/jpeg', quality: quality });
    } catch (error) {
      return null;
    } finally {
      if (pixelMap !== null) {
        pixelMap.release();
      }
      if (packer !== null) {
        packer.release();
      }
      if (source !== null) {
        source.release();
      }
    }
  }

  /**
   * 备份内嵌用：读背景图文件字节（文件 ≤ rawMax 直接读原文，超限压缩转 JPEG 控制体积）。
   * 文件名仅允许 fq_reader_bg/ 下的裸文件名；失败返回 null。
   */
  public static async loadBgBytesForBackup(fileName: string, rawMax: number):
    Promise<ArrayBuffer | null> {
    const clean: string = fileName.trim();
    if (FqReaderStore.filesDir.length === 0 || clean.length === 0
      || clean.length > 128 || clean.indexOf('/') >= 0 || clean.indexOf('\\') >= 0) {
      return null;
    }
    const path: string = `${FqReaderStore.filesDir}/fq_reader_bg/${clean}`;
    let size: number = -1;
    try {
      size = fileIo.statSync(path).size;
    } catch (error) {
      return null;
    }
    if (size <= 0) {
      return null;
    }
    if (size <= rawMax) {
      try {
        const data: ArrayBuffer = new ArrayBuffer(size);
        const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        try {
          fileIo.readSync(file.fd, data);
        } finally {
          fileIo.closeSync(file);
        }
        return data;
      } catch (error) {
        return null;
      }
    }
    // 旧版导入的大图：压缩后再内嵌
    let src: fileIo.File | null = null;
    try {
      src = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      return await FqReaderStore.packJpegBytes(src.fd, FQ_THEME_BG_MAX_EDGE, FQ_THEME_BG_JPEG_QUALITY);
    } catch (error) {
      return null;
    } finally {
      if (src !== null) {
        try {
          fileIo.closeSync(src);
        } catch (closeError) {
          // 忽略关闭失败
        }
      }
    }
  }

  /** 备份恢复：背景图字节写入沙箱 fq_reader_bg/（本机已有同名文件保留现状）；失败返回 false。 */
  public static writeBgBytes(fileName: string, data: ArrayBuffer): boolean {
    const clean: string = fileName.trim();
    if (FqReaderStore.filesDir.length === 0 || clean.length === 0
      || clean.length > 128 || clean.indexOf('/') >= 0 || clean.indexOf('\\') >= 0) {
      return false;
    }
    const dir: string = `${FqReaderStore.filesDir}/fq_reader_bg`;
    const target: string = `${dir}/${clean}`;
    try {
      if (fileIo.accessSync(target)) {
        return true;
      }
    } catch (error) {
      // 文件不存在，继续写入
    }
    try {
      fileIo.mkdirSync(dir);
    } catch (error) {
      // 目录已存在
    }
    const tmp: string = `${target}.tmp`;
    let dst: fileIo.File | null = null;
    try {
      dst = fileIo.openSync(tmp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(dst.fd, data);
      fileIo.closeSync(dst);
      dst = null;
      fileIo.renameSync(tmp, target);
      return true;
    } catch (error) {
      if (dst !== null) {
        try {
          fileIo.closeSync(dst);
        } catch (closeError) {
          // 忽略关闭失败
        }
      }
      try {
        fileIo.unlinkSync(tmp);
      } catch (cleanError) {
        // 忽略清理失败
      }
      return false;
    }
  }

  /** 新建自定义主题（draft 需至少一张背景图）；返回新条目（失败返回 null）。 */
  public static createCustomTheme(draft: FqCustomReaderTheme): FqCustomReaderTheme | null {
    if (draft.lightBgPath.length === 0 && draft.darkBgPath.length === 0) {
      return null;
    }
    const entry: FqCustomReaderTheme = FqReaderStore.sanitizeTheme(draft);
    entry.id = `ct${Date.now()}`;
    if (FqReaderStore.hasCustomTheme(entry.id)) {
      return null;
    }
    FqReaderStore.settings.customThemes = FqReaderStore.settings.customThemes.concat([entry]);
    FqReaderStore.persistSettings();
    return entry;
  }

  /** 保存自定义主题编辑结果（全量替换，含双模式背景图路径）；条目不存在返回 false。 */
  public static updateCustomTheme(id: string, draft: FqCustomReaderTheme): boolean {
    const next: FqCustomReaderTheme[] = [];
    let found: boolean = false;
    for (const item of FqReaderStore.settings.customThemes) {
      if (item.id === id) {
        const updated: FqCustomReaderTheme = FqReaderStore.sanitizeTheme(draft);
        updated.id = item.id;
        next.push(updated);
        found = true;
      } else {
        next.push(item);
      }
    }
    if (!found) {
      return false;
    }
    FqReaderStore.settings.customThemes = next;
    FqReaderStore.persistSettings();
    return true;
  }

  /** 编辑弹窗名称实时写回：仅更新名称与排版参数，双模式背景图路径保持条目现值
   *  （编辑中未保存的新导入不落盘，取消时由编辑弹窗清理）。 */
  public static updateCustomThemeParams(id: string, draft: FqCustomReaderTheme): boolean {
    const next: FqCustomReaderTheme[] = [];
    let found: boolean = false;
    for (const item of FqReaderStore.settings.customThemes) {
      if (item.id === id) {
        const updated: FqCustomReaderTheme = FqReaderStore.sanitizeTheme(draft);
        updated.id = item.id;
        updated.lightBgPath = item.lightBgPath;
        updated.darkBgPath = item.darkBgPath;
        next.push(updated);
        found = true;
      } else {
        next.push(item);
      }
    }
    if (!found) {
      return false;
    }
    FqReaderStore.settings.customThemes = next;
    FqReaderStore.persistSettings();
    return true;
  }

  /** 删除自定义主题（连同双模式背景图文件；若为当前选中同时清空 customThemeId）。 */
  public static removeCustomTheme(id: string): boolean {
    const list: FqCustomReaderTheme[] = FqReaderStore.settings.customThemes;
    const next: FqCustomReaderTheme[] = [];
    let found: boolean = false;
    for (const item of list) {
      if (item.id === id) {
        found = true;
        try {
          fileIo.unlinkSync(item.lightBgPath);
        } catch (unlinkError) {
          // 文件可能已被清理
        }
        try {
          fileIo.unlinkSync(item.darkBgPath);
        } catch (unlinkError) {
          // 文件可能已被清理
        }
      } else {
        next.push(item);
      }
    }
    if (!found) {
      return false;
    }
    FqReaderStore.settings.customThemes = next;
    if (FqReaderStore.settings.customThemeId === id) {
      FqReaderStore.settings.customThemeId = '';
    }
    FqReaderStore.persistSettings();
    return true;
  }

  /** 选中自定义主题（themeIndex 由调用方切换到 3）。 */
  public static selectCustomTheme(id: string): void {
    FqReaderStore.settings.customThemeId = id;
    FqReaderStore.persistSettings();
  }

  /** 备份恢复合并：按模式校验背景图文件仍在本机沙箱时重建条目
   *  （单模式缺图自动降级为只保留另一模式，双模式图均缺失跳过）。 */
  public static mergeCustomTheme(id: string, name: string,
    lightBgFile: string, lightFontColor: string, lightFontSize: number,
    lightFontIndex: number, lightLineHeight: number,
    darkBgFile: string, darkFontColor: string, darkFontSize: number,
    darkFontIndex: number, darkLineHeight: number): boolean {
    const cleanId: string = id.trim();
    if (cleanId.length === 0) {
      return false;
    }
    for (const item of FqReaderStore.settings.customThemes) {
      if (item.id === cleanId) {
        return false;
      }
    }
    const entry: FqCustomReaderTheme = new FqCustomReaderTheme();
    entry.id = cleanId;
    entry.name = fqClampThemeName(name);
    if (FqReaderStore.themeBgFileExists(lightBgFile)) {
      entry.lightBgPath = `${FqReaderStore.filesDir}/fq_reader_bg/${lightBgFile.trim()}`;
      entry.lightFontColor = fqNormalizeThemeFontColor(lightFontColor);
      entry.lightFontSize = fqClampThemeFontSize(lightFontSize);
      entry.lightFontIndex = lightFontIndex >= -1 ? Math.trunc(lightFontIndex) : -1;
      entry.lightLineHeight = fqClampThemeLineHeight(lightLineHeight);
    }
    if (FqReaderStore.themeBgFileExists(darkBgFile)) {
      entry.darkBgPath = `${FqReaderStore.filesDir}/fq_reader_bg/${darkBgFile.trim()}`;
      entry.darkFontColor = fqNormalizeThemeFontColor(darkFontColor);
      entry.darkFontSize = fqClampThemeFontSize(darkFontSize);
      entry.darkFontIndex = darkFontIndex >= -1 ? Math.trunc(darkFontIndex) : -1;
      entry.darkLineHeight = fqClampThemeLineHeight(darkLineHeight);
    }
    if (entry.lightBgPath.length === 0 && entry.darkBgPath.length === 0) {
      return false;
    }
    FqReaderStore.settings.customThemes = FqReaderStore.settings.customThemes.concat([entry]);
    FqReaderStore.persistSettings();
    return true;
  }

  /** 备份背景图文件是否仍在本机沙箱（fq_reader_bg/ 下）。 */
  private static themeBgFileExists(fileName: string): boolean {
    const clean: string = fileName.trim();
    if (clean.length === 0 || clean.indexOf('/') >= 0 || clean.indexOf('\\') >= 0) {
      return false;
    }
    try {
      return fileIo.accessSync(`${FqReaderStore.filesDir}/fq_reader_bg/${clean}`);
    } catch (error) {
      return false;
    }
  }

  /** 是否存在指定 id 的自定义主题。 */
  public static hasCustomTheme(id: string): boolean {
    for (const item of FqReaderStore.settings.customThemes) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  /** 设置整体落盘（记录 v:5，含小说与漫画全部字段及自定义主题列表）。 */
  private static persistSettings(): void {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null) {
      return;
    }
    const rec: Record<string, Object> = {};
    rec['v'] = 5;
    rec['fontSize'] = FqReaderStore.settings.fontSize;
    rec['lineHeight'] = FqReaderStore.settings.lineHeight;
    rec['themeIndex'] = FqReaderStore.settings.themeIndex;
    rec['flipIndex'] = FqReaderStore.settings.flipIndex;
    rec['comicFlipIndex'] = FqReaderStore.settings.comicFlipIndex;
    rec['fontIndex'] = FqReaderStore.settings.fontIndex;
    rec['showParagraphComment'] = FqReaderStore.settings.showParagraphComment;
    rec['volumeKeyPaging'] = FqReaderStore.settings.volumeKeyPaging;
    const themes: Record<string, Object>[] = [];
    for (const item of FqReaderStore.settings.customThemes) {
      const themeRec: Record<string, Object> = {};
      themeRec['id'] = item.id;
      themeRec['name'] = item.name;
      themeRec['lightBgPath'] = item.lightBgPath;
      themeRec['lightFontColor'] = item.lightFontColor;
      themeRec['lightFontSize'] = item.lightFontSize;
      themeRec['lightFontIndex'] = item.lightFontIndex;
      themeRec['lightLineHeight'] = item.lightLineHeight;
      themeRec['darkBgPath'] = item.darkBgPath;
      themeRec['darkFontColor'] = item.darkFontColor;
      themeRec['darkFontSize'] = item.darkFontSize;
      themeRec['darkFontIndex'] = item.darkFontIndex;
      themeRec['darkLineHeight'] = item.darkLineHeight;
      themes.push(themeRec);
    }
    rec['customThemes'] = JSON.stringify(themes);
    rec['customThemeId'] = FqReaderStore.settings.customThemeId;
    rec['customFontColors'] = JSON.stringify(FqReaderStore.settings.customFontColors);
    try {
      pref.putSync(FQ_READER_KEY_SETTINGS, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 读取单书进度；无记录时 chapterIndex 为 -1。 */
  public static getProgress(bookId: string): FqReaderProgress {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return new FqReaderProgress(-1, '');
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(`${FQ_READER_KEY_PROGRESS}${bookId}`, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return new FqReaderProgress(-1, '');
    }
    if (text.length === 0) {
      return new FqReaderProgress(-1, '');
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = parsed === null ? null : fqAsRecord(parsed);
      if (rec === null) {
        return new FqReaderProgress(-1, '');
      }
      const chapterIndex: Object | undefined = rec['chapterIndex'];
      const domPos: Object | undefined = rec['domPos'];
      if (typeof chapterIndex !== 'number' || typeof domPos !== 'string') {
        return new FqReaderProgress(-1, '');
      }
      const percentRaw: Object | undefined = rec['percent'];
      let percent: number = -1;
      if (typeof percentRaw === 'number' && percentRaw >= 0 && percentRaw <= 100) {
        percent = Math.trunc(percentRaw);
      }
      return new FqReaderProgress(Math.trunc(chapterIndex), domPos, percent);
    } catch (error) {
      return new FqReaderProgress(-1, '');
    }
  }

  public static saveProgress(bookId: string, chapterIndex: number, domPos: string, percent: number = -1): void {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return;
    }
    const rec: Record<string, Object> = {};
    rec['chapterIndex'] = chapterIndex;
    rec['domPos'] = domPos;
    // percent < 0：调用方未提供（导入/恢复/进度回填等），保留既有整书百分比
    const eff: number = percent >= 0 ? Math.min(100, Math.max(0, Math.trunc(percent)))
      : FqReaderStore.getProgress(bookId).percent;
    if (eff >= 0) {
      rec['percent'] = eff;
    }
    try {
      pref.putSync(`${FQ_READER_KEY_PROGRESS}${bookId}`, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 读取单书各章已排版页数（chapterIndex → 页数）。 */
  public static getChapterPages(bookId: string): Map<number, number> {
    const result: Map<number, number> = new Map();
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return result;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(`${FQ_READER_KEY_PAGES}${bookId}`, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return result;
    }
    if (text.length === 0) {
      return result;
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = parsed === null ? null : fqAsRecord(parsed);
      if (rec === null) {
        return result;
      }
      for (const key of fqKeys(rec)) {
        const value: Object | undefined = rec[key];
        const index: number = Number.parseInt(key, 10);
        if (typeof value === 'number' && value > 0 && !Number.isNaN(index) && index >= 0) {
          result.set(index, Math.trunc(value));
        }
      }
    } catch (error) {
      // 损坏数据按空处理
    }
    return result;
  }

  public static saveChapterPages(bookId: string, pages: Map<number, number>): void {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return;
    }
    const rec: Record<string, Object> = {};
    pages.forEach((value: number, key: number): void => {
      rec[`${key}`] = value;
    });
    try {
      pref.putSync(`${FQ_READER_KEY_PAGES}${bookId}`, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 读取单书已读章节集合（读毕章节，目录进度用；"a-b,c" 区间串持久化）。 */
  public static getReadChapters(bookId: string): Set<number> {
    const result: Set<number> = new Set();
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return result;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(`${FQ_READER_KEY_READ}${bookId}`, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return result;
    }
    return fqDecodeReadRanges(text);
  }

  public static saveReadChapters(bookId: string, chapters: Set<number>): void {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return;
    }
    try {
      pref.putSync(`${FQ_READER_KEY_READ}${bookId}`, fqEncodeReadRanges(chapters));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 全部有阅读进度的书 id（备份导出用）。 */
  public static progressBookIds(): string[] {
    const result: string[] = [];
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null) {
      return result;
    }
    const all: Record<string, Object> | null = fqAsRecord(pref.getAllSync());
    if (all === null) {
      return result;
    }
    for (const key of Object.keys(all)) {
      if (key.startsWith(FQ_READER_KEY_PROGRESS)) {
        result.push(key.substring(FQ_READER_KEY_PROGRESS.length));
      }
    }
    return result;
  }
}

/** 已读章节区间串编码：连续下标合并为 "a-b"，单值 "a"，逗号连接。 */
export function fqEncodeReadRanges(chapters: Set<number>): string {
  const indices: number[] = [];
  chapters.forEach((value: number): void => {
    if (value >= 0) {
      indices.push(value);
    }
  });
  indices.sort((a: number, b: number): number => a - b);
  const parts: string[] = [];
  let index: number = 0;
  while (index < indices.length) {
    let end: number = index;
    while (end + 1 < indices.length && indices[end + 1] === indices[end] + 1) {
      end++;
    }
    parts.push(end === index ? `${indices[index]}` : `${indices[index]}-${indices[end]}`);
    index = end + 1;
  }
  return parts.join(',');
}

/** 已读章节区间串解码："a-b,c" → 下标集合；越界/非法片段跳过。 */
export function fqDecodeReadRanges(text: string): Set<number> {
  const result: Set<number> = new Set();
  if (text.trim().length === 0) {
    return result;
  }
  const parts: string[] = text.split(',');
  for (const part of parts) {
    if (part.length === 0) {
      continue;
    }
    const dash: number = part.indexOf('-');
    if (dash < 0) {
      const value: number = Number.parseInt(part, 10);
      if (!Number.isNaN(value) && value >= 0) {
        result.add(value);
      }
      continue;
    }
    const start: number = Number.parseInt(part.substring(0, dash), 10);
    const end: number = Number.parseInt(part.substring(dash + 1), 10);
    if (Number.isNaN(start) || Number.isNaN(end) || start < 0 || end < start) {
      continue;
    }
    for (let value: number = start; value <= end; value++) {
      result.add(value);
    }
  }
  return result;
}

import { bookParser } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqChapter } from '../model/FqModels';

/** 章节内容按需加载器：入参为书脊索引（与章节下标一致）。 */
export type FqChapterFetcher = (spineIndex: number) => Promise<string>;

/** 字体档位：name 为引擎侧字体族名（引擎按「name + .ttf」请求并缓存字体，每档必须
 *  唯一——切档换名才令引擎视为新字体重新加载，否则一直命中启动时加载的旧字体）；
 *  label 供设置面板展示；candidates 为设备系统字体候选（取首个可用），为空表示
 *  系统默认字体档（不拷沙箱、不注册，测量/渲染走系统字体设置）。 */
export interface FqFontOption {
  readonly name: string;
  readonly label: string;
  readonly candidates: string[];
}

/** 阅读字体档位（下标持久化于阅读设置 fontIndex）。 */
export const FQ_FONT_OPTIONS: FqFontOption[] = [
  { name: '系统', label: '系统', candidates: [] },
  { name: '书宋', label: '书宋', candidates: ['/system/fonts/ShuS-SC.ttf'] },
  { name: '黑体', label: '黑体', candidates: ['/system/fonts/HarmonyOS_Sans_SC.ttf', '/system/fonts/HYQiHeiL3.ttf'] },
];

/**
 * 在线书籍解析器：整本书对应一个 BookParserHandler（Reader Kit 架构）。
 * 目录与书脊均与网络目录一一对应（spine index = 章节 index），
 * 章节正文由排版引擎按需通过 getSpineItemContent 拉取（懒加载 + 内存缓存）。
 * registerBookParser 仅需一次；换章/跳转由 startPlay(spineIndex, domPos) 完成，
 * 跨章翻页由引擎在书脊间自行推进。
 * 字体：自定义 handler 不会获得 Kit 内置字体，引擎排版时会以
 * 「fontName + .ttf」发起资源请求，须由 getResourceContent /
 * controller.on('resourceRequest') 返回真实字体字节，
 * 否则 font_loader 拿到空 buffer → load failed errorCode 4 → 卡加载。
 * 分页 CSS：排版模板引用 hr_ebook_template.css / epub.css / hw_normalize.css
 * 等 Kit 内置资源，自定义 handler 同样拿不到，缺省时正文排成单窄块
 * （总宽 376 < 栏宽 391.11）→ 0 页 → load failed errorCode 4 → pageShow 不派发。
 * 故内部持有 getDefaultHandler 委托：字体走沙箱副本，其余资源请求
 * （Kit 内置 CSS/字体等）统一转发给默认 handler 供应。
 */
export class FqOnlineParser extends bookParser.BookParserHandler {
  private readonly bookTitle: string;
  private readonly chapters: FqChapter[];
  private readonly fetcher: FqChapterFetcher;
  private readonly cache: Map<number, string> = new Map<number, string>();
  /** 沙箱内字体副本路径（prepareFont 成功后非空，跨会话复用）。 */
  private fontSandboxPath: string = '';
  /** 字体字节内存缓存（getResourceContent 为同步接口，避免重复读 10MB 文件）。 */
  private fontBuf: ArrayBuffer | null = null;
  /** 当前已备好沙箱副本的字体档位（-1 表示尚未准备）。 */
  private preparedFontIndex: number = -1;
  /** 默认 handler 委托：供应 Kit 内置分页 CSS / 内置字体等资源。 */
  private defaultHandler: bookParser.BookParserHandler | null = null;

  constructor(bookTitle: string, chapters: FqChapter[], fetcher: FqChapterFetcher) {
    super();
    this.bookTitle = bookTitle;
    this.chapters = chapters;
    this.fetcher = fetcher;
  }

  /** 按档位把可读的系统字体复制进沙箱（每档独立副本，幂等），并准备默认 handler 委托。 */
  public async prepareFont(filesDir: string, fontIndex: number): Promise<void> {
    await this.ensureDefaultHandler(filesDir);
    if (this.preparedFontIndex === fontIndex && this.fontSandboxPath.length > 0) {
      return;
    }
    const option: FqFontOption | undefined = FQ_FONT_OPTIONS[fontIndex];
    if (option === undefined) {
      return;
    }
    const target: string = `${filesDir}/fq_reader_font_${fontIndex}.ttf`;
    if (FqOnlineParser.fileExists(target)) {
      this.applyFont(target, fontIndex);
      hilog.info(0x0001, 'FqOnlineParser', `prepareFont reuse ${target}`);
      return;
    }
    for (const src of option.candidates) {
      if (!FqOnlineParser.fileExists(src)) {
        hilog.warn(0x0001, 'FqOnlineParser', `prepareFont candidate missing ${src}`);
        continue;
      }
      try {
        await fileIo.copyFile(src, target);
        this.applyFont(target, fontIndex);
        hilog.info(0x0001, 'FqOnlineParser', `prepareFont copied ${src} -> ${target}`);
        return;
      } catch (error) {
        const err: BusinessError = error as BusinessError;
        hilog.warn(0x0001, 'FqOnlineParser', `prepareFont copy ${src} failed: ${err.code} ${err.message}`);
      }
    }
    hilog.error(0x0001, 'FqOnlineParser', `prepareFont no readable system font for ${option.label}`);
  }

  /** 记录当前生效字体档位；切档后作废字节缓存，readFontBuffer 按新副本重读。 */
  private applyFont(target: string, fontIndex: number): void {
    this.fontSandboxPath = target;
    this.preparedFontIndex = fontIndex;
    this.fontBuf = null;
  }

  /**
   * 创建默认 handler 委托（幂等）：以沙箱内占位 txt 为书源。
   * Kit 内置分页 CSS（hr_ebook_template.css 等）与内置字体均由其供应，
   * 这是引擎模板排版出多栏（>1 页）的必要条件。
   */
  private async ensureDefaultHandler(filesDir: string): Promise<void> {
    if (this.defaultHandler !== null) {
      return;
    }
    const dummyPath: string = `${filesDir}/fq_reader_delegate.txt`;
    try {
      if (!FqOnlineParser.fileExists(dummyPath)) {
        const file: fileIo.File = fileIo.openSync(
          dummyPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, 'fq');
        fileIo.closeSync(file);
      }
      this.defaultHandler = await bookParser.getDefaultHandler(dummyPath);
      hilog.info(0x0001, 'FqOnlineParser', `ensureDefaultHandler ready ${dummyPath}`);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(0x0001, 'FqOnlineParser', `ensureDefaultHandler failed: ${err.code} ${err.message}`);
    }
  }

  /** 沙箱字体副本路径（未准备好时为空串）。 */
  public getFontSandboxPath(): string {
    return this.fontSandboxPath;
  }

  /** 指定档位的沙箱字体副本是否就绪（buildSetting 选 fontName 依据：未就绪回退 Kit 内置「系统字体」）。 */
  public isFontReady(fontIndex: number): boolean {
    return this.preparedFontIndex === fontIndex && this.fontSandboxPath.length > 0;
  }

  /** controller.on('resourceRequest') 回调入口：与 getResourceContent 同源供给字体。 */
  public serveFontBytes(fileName: string): ArrayBuffer {
    hilog.info(0x0001, 'FqOnlineParser', `serveFontBytes file=${fileName}`);
    return this.getResourceContent(-1, fileName);
  }

  public getBookInfo(): bookParser.BookInfo {
    const info: bookParser.BookInfo = {
      bookTitle: this.bookTitle,
      bookType: 'txt',
      bookLanguage: 'zh_CN',
    };
    return info;
  }

  public getCatalogList(): bookParser.CatalogItem[] {
    const list: bookParser.CatalogItem[] = [];
    for (let i: number = 0; i < this.chapters.length; i += 1) {
      const item: bookParser.CatalogItem = {
        catalogId: i,
        catalogName: this.chapters[i].title,
        catalogLevel: 0,
        playOrder: i,
        idRef: `ch${i}`,
        href: `chapter${i}.txt`,
        resourceFile: `chapter${i}.txt`,
      };
      list.push(item);
    }
    return list;
  }

  public getSpineList(): bookParser.SpineItem[] {
    const list: bookParser.SpineItem[] = [];
    for (let i: number = 0; i < this.chapters.length; i += 1) {
      const item: bookParser.SpineItem = {
        idRef: `ch${i}`,
        index: i,
        href: `chapter${i}.txt`,
        properties: '',
      };
      list.push(item);
    }
    return list;
  }

  public async getSpineItemContent(spineIndex: number): Promise<string> {
    const cached: string | undefined = this.cache.get(spineIndex);
    if (cached !== undefined) {
      return cached;
    }
    const chapter: FqChapter | undefined = this.chapters[spineIndex];
    if (chapter === undefined) {
      return '';
    }
    hilog.info(0x0001, 'FqOnlineParser', `getSpineItemContent index=${spineIndex} title=${chapter.title}`);
    const text: string = await this.fetcher(spineIndex);
    this.cache.set(spineIndex, text);
    return text;
  }

  public getResourceContent(spineIndex: number, filePath: string): ArrayBuffer {
    hilog.info(0x0001, 'FqOnlineParser', `getResourceContent spine=${spineIndex} path=${filePath}`);
    if (filePath.length > 0 && FqOnlineParser.isFontFile(filePath)) {
      const buf: ArrayBuffer | null = this.readFontBuffer();
      if (buf !== null) {
        hilog.info(0x0001, 'FqOnlineParser',
          `getResourceContent serve font ${filePath} bytes=${buf.byteLength}`);
        return buf;
      }
      hilog.error(0x0001, 'FqOnlineParser', `getResourceContent font not ready for ${filePath}`);
    }
    if (this.defaultHandler !== null) {
      try {
        // 委托书源是单 spine 占位 txt：spineIndex 必须传 0（超出会抛
        // 「getResourceContent: Parameter error」）；CSS/字体均为 spine 无关的 Kit 内置资源。
        const delegated: ArrayBuffer = this.defaultHandler.getResourceContent(0, filePath);
        if (delegated.byteLength > 0) {
          hilog.info(0x0001, 'FqOnlineParser',
            `getResourceContent delegated ${filePath} bytes=${delegated.byteLength}`);
          return delegated;
        }
      } catch (error) {
        const err: BusinessError = error as BusinessError;
        hilog.error(0x0001, 'FqOnlineParser',
          `getResourceContent delegate ${filePath} failed: ${err.code} ${err.message}`);
      }
    }
    return new ArrayBuffer(0);
  }

  public getDomPosByCatalogHref(href: string): string {
    return '';
  }

  public getAbsoluteResourcePath(spineIndex: number): string {
    hilog.info(0x0001, 'FqOnlineParser', `getAbsoluteResourcePath spine=${spineIndex}`);
    return '';
  }

  private static fileExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private static isFontFile(path: string): boolean {
    return path.endsWith('.ttf') || path.endsWith('.otf') || path.endsWith('.ttc');
  }

  /** 同步读取沙箱字体副本（结果内存缓存），供 getResourceContent / serveFontBytes 共用。 */
  private readFontBuffer(): ArrayBuffer | null {
    if (this.fontBuf !== null) {
      return this.fontBuf;
    }
    if (this.fontSandboxPath.length === 0 || !FqOnlineParser.fileExists(this.fontSandboxPath)) {
      return null;
    }
    try {
      const file: fileIo.File = fileIo.openSync(this.fontSandboxPath, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(this.fontSandboxPath).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      this.fontBuf = buf;
      return buf;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(0x0001, 'FqOnlineParser', `readFontBuffer failed: ${err.code} ${err.message}`);
      return null;
    }
  }
}

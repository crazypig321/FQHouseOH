/**
 * EPUB 解析（对齐 fqapp imported_book_store.dart 的 _parseEpub 流程）。
 *
 * - 文件随机读取（RandomAccessFile），不整包驻留内存：支持数百 MB 的 EPUB，
 *   图片 / 字体等非正文条目完全不加载；
 * - ZIP 结构校验：EOCD / 中央目录（条目数、ZIP64、压缩比），
 *   条目按需解压（STORED 直读，DEFLATE 走 @ohos.zlib 原始 inflate 流）；
 * - 解压总量只统计实际抽取的 XHTML 正文（累计 64 MB、单条目 64 MB 上限）；
 * - container.xml → OPF（manifest/spine）→ 按 spine 顺序抽取 XHTML 正文；
 * - XHTML 转纯文本：块级元素断段、script/style/noscript/nav 剔除、实体反转义；
 * - 章节标题取文档首个 h1~h6，无标题回退「第N章」；
 * - 只有标题没有正文的文档（目录页、纯标题前言页）丢弃；
 * - 图片页（含 <img/<image 且正文极短）的残留文本（「cover」类）丢弃；
 * - 内嵌封面 best-effort 提取（发现顺序对齐 Legado/fqapp），失败不阻断导入。
 */

import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

const FQ_EPUB_MAX_ENTRIES: number = 4000;
/** 实际抽取的 XHTML 正文累计解压上限。 */
const FQ_EPUB_MAX_EXPANDED_BYTES: number = 64 * 1024 * 1024;
/** 单条目解压上限（防解压炸弹 / 异常超大分配）。 */
const FQ_EPUB_MAX_ENTRY_BYTES: number = 64 * 1024 * 1024;
const FQ_EPUB_MAX_CHAPTERS: number = 20000;
/** 图片页残留文本上限：含图文档折叠空白后正文不超过该长度视为图片页，丢弃。 */
const FQ_EPUB_IMAGE_PAGE_MAX_TEXT: number = 20;
/** 图片标签探测：<img / <image（SVG 内嵌图）。 */
const FQ_EPUB_IMAGE_TAG_PATTERN: RegExp = /<(?:img|image)[\s/>]/i;
/** 封面单资源字节上限（对齐 fqapp _maxCoverResourceBytes）。 */
const FQ_EPUB_MAX_COVER_RESOURCE_BYTES: number = 8 * 1024 * 1024;
/** 封面文档（XHTML/SVG 包装层）字节上限（对齐 fqapp _maxCoverDocumentBytes）。 */
const FQ_EPUB_MAX_COVER_DOCUMENT_BYTES: number = 1024 * 1024;
/** 封面重编码最长边（对齐 fqapp _maxCoverImageEdge）。 */
const FQ_EPUB_MAX_COVER_EDGE: number = 1600;
/** 封面透明像素采样上限（对齐 fqapp _maxCoverAlphaScanPixels）。 */
const FQ_EPUB_MAX_COVER_ALPHA_SCAN_PIXELS: number = 512 * 1000;
/** 封面 JPEG 质量（对齐 fqapp _coverJpegQuality）。 */
const FQ_EPUB_COVER_JPEG_QUALITY: number = 90;
/** 封面提示词（对齐 fqapp _coverHint）：id / 路径携带才进入猜测。 */
const FQ_EPUB_COVER_HINT: RegExp =
  /(?:^|[/_.~\-])(cover|frontcover|titlepage|title-page)(?:$|[/_.~\-])/i;
/** 封面文档内嵌引用：src/href 属性 + CSS url()（对齐 fqapp）。 */
const FQ_EPUB_COVER_REF_PATTERN: RegExp =
  /(?:src|href)\s*=\s*["']([^"']+)["']/gi;
const FQ_EPUB_COVER_CSS_URL_PATTERN: RegExp =
  /url\(\s*["']?([^"')]+)["']?\s*\)/gi;

/** 解析产物：单章。 */
export class FqEpubChapter {
  public readonly title: string;
  public readonly text: string;

  constructor(title: string, text: string) {
    this.title = title;
    this.text = text;
  }
}

/** 解析产物：整书。 */
export class FqEpubBook {
  public readonly title: string;
  public readonly author: string;
  public readonly chapters: FqEpubChapter[];
  public readonly cover: FqEpubCover | null;

  constructor(title: string, author: string, chapters: FqEpubChapter[],
    cover: FqEpubCover | null) {
    this.title = title;
    this.author = author;
    this.chapters = chapters;
    this.cover = cover;
  }
}

/** 提取的内嵌封面：重编码后的位图（png/jpg）或原始 SVG。 */
export class FqEpubCover {
  public readonly bytes: Uint8Array;
  /** png | jpg | svg。 */
  public readonly extension: string;

  constructor(bytes: Uint8Array, extension: string) {
    this.bytes = bytes;
    this.extension = extension;
  }
}

/** ZIP 中央目录条目。 */
class FqZipEntry {
  public readonly name: string;
  /** 0 STORED / 8 DEFLATE。 */
  public readonly method: number;
  public readonly compressedSize: number;
  public readonly size: number;
  /** 本地文件头偏移。 */
  public readonly headerOffset: number;

  constructor(name: string, method: number, compressedSize: number, size: number,
    headerOffset: number) {
    this.name = name;
    this.method = method;
    this.compressedSize = compressedSize;
    this.size = size;
    this.headerOffset = headerOffset;
  }
}

/** OPF manifest 条目。 */
class FqEpubManifestItem {
  public readonly href: string;
  public readonly mediaType: string;
  /** properties 属性原文（小写，如 "cover-image"）。 */
  public readonly properties: string;

  constructor(href: string, mediaType: string, properties: string) {
    this.href = href;
    this.mediaType = mediaType;
    this.properties = properties;
  }
}

/** XML 元素抽取结果：开标签原文 + 内部文本。 */
class FqXmlElement {
  public readonly tag: string;
  public readonly text: string;

  constructor(tag: string, text: string) {
    this.tag = tag;
    this.text = text;
  }
}

/** XHTML 转纯文本结果：heading = 文档首个 h1~h6 文本。 */
class FqEpubHtmlText {
  public readonly heading: string;
  public readonly text: string;

  constructor(heading: string, text: string) {
    this.heading = heading;
    this.text = text;
  }
}

/** 只读随机访问文件包装：按偏移逐段读取，大文件不整包驻留内存。 */
class FqEpubRandomFile {
  private readonly raf: fileIo.RandomAccessFile;
  private readonly fd: number;
  public readonly size: number;

  constructor(raf: fileIo.RandomAccessFile, fd: number, size: number) {
    this.raf = raf;
    this.fd = fd;
    this.size = size;
  }

  /** 读取 [offset, offset+length) 字节；越界 / 短读视为损坏。 */
  public async readAt(offset: number, length: number): Promise<Uint8Array> {
    if (offset < 0 || length < 0 || offset + length > this.size) {
      throw new Error('EPUB ZIP 数据损坏');
    }
    if (length === 0) {
      return new Uint8Array(0);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    this.raf.setFilePointer(offset);
    const got: number = await this.raf.read(buffer, { length: length });
    if (got !== length) {
      throw new Error('EPUB ZIP 数据损坏');
    }
    return new Uint8Array(buffer);
  }

  public close(): void {
    try {
      this.raf.close();
    } catch (error) {
      // 关闭失败忽略
    }
    try {
      fileIo.closeSync(this.fd);
    } catch (error) {
      // 已随 RandomAccessFile 关闭
    }
  }
}

export class FqEpubParser {
  /** 解析 EPUB 文件（picker uri 或沙箱路径）为章节列表；结构损坏 / 缺失抛中文错误。 */
  public static async parse(uri: string, fileTitle: string): Promise<FqEpubBook> {
    const file: FqEpubRandomFile = FqEpubParser.openEpub(uri);
    try {
      return await FqEpubParser.parseEpub(file, fileTitle);
    } finally {
      file.close();
    }
  }

  /** 打开只读随机访问句柄；空文件 / 打不开抛中文错误。 */
  private static openEpub(uri: string): FqEpubRandomFile {
    const opened = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(opened.fd).size;
      if (size <= 0) {
        throw new Error('文件内容为空');
      }
      const raf: fileIo.RandomAccessFile = fileIo.createRandomAccessFileSync(opened);
      return new FqEpubRandomFile(raf, opened.fd, size);
    } catch (error) {
      try {
        fileIo.closeSync(opened);
      } catch (closeError) {
        // 关闭失败忽略
      }
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('EPUB 文件无法读取');
    }
  }

  private static async parseEpub(file: FqEpubRandomFile, fileTitle: string): Promise<FqEpubBook> {
    const entries: Map<string, FqZipEntry> = await FqEpubParser.readCentralDirectory(file);
    const containerEntry: FqZipEntry | undefined = entries.get('META-INF/container.xml');
    if (containerEntry === undefined) {
      throw new Error('EPUB 缺少 META-INF/container.xml');
    }
    const containerXml: string =
      FqEpubParser.decodeXmlBytes(await FqEpubParser.readEntry(file, containerEntry));
    const rawOpfPath: string =
      FqEpubParser.attrOf(FqEpubParser.firstTagOf(containerXml, 'rootfile'), 'full-path');
    if (rawOpfPath.trim().length === 0) {
      throw new Error('EPUB 目录文件无效');
    }
    const opfPath: string = FqEpubParser.resolveHref('', rawOpfPath);
    if (opfPath.length === 0) {
      throw new Error('EPUB 目录路径无效');
    }
    const opfEntry: FqZipEntry | undefined = entries.get(opfPath);
    if (opfEntry === undefined) {
      throw new Error('EPUB 目录文件不存在');
    }
    const opf: string = FqEpubParser.decodeXmlBytes(await FqEpubParser.readEntry(file, opfEntry));
    const title: string = FqEpubParser.firstTextOf(opf, 'title');
    const author: string = FqEpubParser.firstTextOf(opf, 'creator');
    const baseDirectory: string = opfPath.indexOf('/') >= 0
      ? opfPath.substring(0, opfPath.lastIndexOf('/')) : '';
    const manifest: Map<string, FqEpubManifestItem> = FqEpubParser.parseManifest(opf);
    const spine: string[] = FqEpubParser.parseSpine(opf);
    const chapters: FqEpubChapter[] = [];
    let expandedBytes: number = 0;
    for (const idref of spine) {
      const item: FqEpubManifestItem | undefined = manifest.get(idref);
      if (item === undefined) {
        continue;
      }
      if (item.mediaType.indexOf('xhtml') < 0 && item.mediaType.indexOf('html') < 0) {
        continue;
      }
      const path: string = FqEpubParser.resolveHref(baseDirectory, item.href);
      if (path.length === 0) {
        continue;
      }
      const entry: FqZipEntry | undefined = entries.get(path);
      if (entry === undefined) {
        continue;
      }
      // 只统计实际抽取的正文条目（图片 / 字体不加载不计数）
      expandedBytes += entry.size;
      if (expandedBytes > FQ_EPUB_MAX_EXPANDED_BYTES) {
        throw new Error('EPUB 解压后超过 64 MB');
      }
      const source: string =
        FqEpubParser.decodeXmlBytes(await FqEpubParser.readEntry(file, entry));
      const converted: FqEpubHtmlText = FqEpubParser.htmlToText(source);
      if (converted.text.length === 0) {
        continue;
      }
      // 只有标题、没有正文的文档（spine 里的 nav 目录页、只有标题的前言页）丢弃
      if (converted.heading.length > 0
        && FqEpubParser.collapseWhitespace(converted.text)
        === FqEpubParser.collapseWhitespace(converted.heading)) {
        continue;
      }
      // 图片页（插图页/封面页）残留的极短文本（figcaption/alt 类「cover」）不作为章节
      if (FQ_EPUB_IMAGE_TAG_PATTERN.test(source)
        && FqEpubParser.collapseWhitespace(converted.text).length
        <= FQ_EPUB_IMAGE_PAGE_MAX_TEXT) {
        continue;
      }
      const chapterTitle: string = converted.heading.length > 0
        ? converted.heading : `第${chapters.length + 1}章`;
      chapters.push(new FqEpubChapter(chapterTitle, converted.text));
      if (chapters.length > FQ_EPUB_MAX_CHAPTERS) {
        throw new Error('章节数量超过支持上限');
      }
    }
    if (chapters.length === 0) {
      throw new Error('EPUB 中没有可阅读的章节');
    }
    // 封面提取 best-effort：损坏 / 不支持的作品不阻断导入（对齐 fqapp）
    const cover: FqEpubCover | null =
      await FqEpubParser.extractCover(file, entries, manifest, opf, baseDirectory);
    return new FqEpubBook(title.length > 0 ? title : fileTitle, author, chapters, cover);
  }

  // ---------------------------------------------------------------------------
  // 内嵌封面提取（对齐 fqapp _extractEpubCover，发现顺序同 Legado）
  // ---------------------------------------------------------------------------

  /** 封面提取：失败返回 null，不影响导入。 */
  private static async extractCover(file: FqEpubRandomFile,
    entries: Map<string, FqZipEntry>, manifest: Map<string, FqEpubManifestItem>,
    opf: string, baseDirectory: string): Promise<FqEpubCover | null> {
    try {
      const href: string | null =
        FqEpubParser.findCoverHref(entries, manifest, opf, baseDirectory);
      if (href === null) {
        return null;
      }
      return await FqEpubParser.loadCoverArtwork(file, entries, href, baseDirectory);
    } catch (error) {
      return null;
    }
  }

  /** 封面资源定位：声明优先（EPUB3 属性 / metadata / EPUB2 meta / guide），猜测殿后。 */
  private static findCoverHref(entries: Map<string, FqZipEntry>,
    manifest: Map<string, FqEpubManifestItem>, opf: string,
    baseDirectory: string): string | null {
    const manifestIds: string[] = [];
    manifest.forEach((_item: FqEpubManifestItem, id: string): void => {
      manifestIds.push(id);
    });
    // EPUB 3：manifest item 自带 cover-image 属性
    for (const id of manifestIds) {
      const item: FqEpubManifestItem | undefined = manifest.get(id);
      if (item === undefined || !FqEpubParser.hasCoverImageProperty(item.properties)) {
        continue;
      }
      const found: string | null =
        FqEpubParser.coverCandidate(item.href, entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
    }
    const metas: FqXmlElement[] = FqEpubParser.elementsOf(opf, 'meta');
    // EPUB 3 metadata：meta property="cover-image"（refines / 内文本）
    for (const meta of metas) {
      const property: string = FqEpubParser.attrOf(meta.tag, 'property').trim().toLowerCase();
      if (property !== 'cover-image') {
        continue;
      }
      const text: string = FqEpubParser.unescapeEntities(meta.text).trim();
      const refined: string | null =
        FqEpubParser.coverCandidate(FqEpubParser.attrOf(meta.tag, 'refines'),
          entries, manifest, baseDirectory);
      if (refined !== null) {
        return refined;
      }
      const content: string = text.length > 0 ? text : FqEpubParser.attrOf(meta.tag, 'content');
      const found: string | null =
        FqEpubParser.coverCandidate(content, entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
    }
    // EPUB 2：meta name="cover" content（manifest id 或相对路径；只信第一条）
    for (const meta of metas) {
      const name: string = FqEpubParser.attrOf(meta.tag, 'name').trim().toLowerCase();
      if (name !== 'cover') {
        continue;
      }
      const found: string | null =
        FqEpubParser.coverCandidate(FqEpubParser.attrOf(meta.tag, 'content'),
          entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
      break;
    }
    // EPUB 2 guide：reference type="cover" 指向封面文档（声明之后才信）
    const references: FqXmlElement[] = FqEpubParser.elementsOf(opf, 'reference');
    for (const reference of references) {
      const type: string = FqEpubParser.attrOf(reference.tag, 'type').trim().toLowerCase();
      if (type !== 'cover') {
        continue;
      }
      const found: string | null =
        FqEpubParser.coverCandidate(FqEpubParser.attrOf(reference.tag, 'href'),
          entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
      break;
    }
    // 无声明：仅限 id / 路径携带 cover 提示的资源（图片优先，其次封面文档）
    for (const id of manifestIds) {
      const item: FqEpubManifestItem | undefined = manifest.get(id);
      if (item === undefined || !FqEpubParser.isImageMediaType(item.mediaType)) {
        continue;
      }
      if (!FqEpubParser.isCoverHinted(id, item.href)) {
        continue;
      }
      const found: string | null =
        FqEpubParser.coverCandidate(item.href, entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
    }
    for (const id of manifestIds) {
      const item: FqEpubManifestItem | undefined = manifest.get(id);
      if (item === undefined || !FqEpubParser.isCoverDocumentMediaType(item.mediaType)) {
        continue;
      }
      if (!FqEpubParser.isCoverHinted(id, item.href)) {
        continue;
      }
      const found: string | null =
        FqEpubParser.coverCandidate(item.href, entries, manifest, baseDirectory);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

  /** manifest id / 归档路径候选（对齐 fqapp candidate：'#' 前缀仅查 manifest）。 */
  private static coverCandidate(rawValue: string, entries: Map<string, FqZipEntry>,
    manifest: Map<string, FqEpubManifestItem>, baseDirectory: string): string | null {
    const value: string = rawValue.trim();
    if (value.length === 0) {
      return null;
    }
    const key: string = value.startsWith('#') ? value.substring(1) : value;
    const byId: FqEpubManifestItem | undefined = manifest.get(key);
    if (byId !== undefined) {
      const path: string = FqEpubParser.resolveHref(baseDirectory, byId.href);
      if (path.length > 0 && entries.has(path)) {
        return path;
      }
    }
    if (value.startsWith('#')) {
      return null;
    }
    const direct: string = FqEpubParser.resolveHref('', value);
    if (direct.length > 0 && entries.has(direct)) {
      return direct;
    }
    const based: string = FqEpubParser.resolveHref(baseDirectory, value);
    if (based.length > 0 && entries.has(based)) {
      return based;
    }
    return null;
  }

  /** 读取封面作品：位图重编码；包装文档跟一层内嵌引用；SVG 原样返回。 */
  private static async loadCoverArtwork(file: FqEpubRandomFile,
    entries: Map<string, FqZipEntry>, href: string,
    baseDirectory: string): Promise<FqEpubCover | null> {
    const bytes: Uint8Array | null = await FqEpubParser.readCoverBytes(file, entries, href);
    if (bytes === null) {
      return null;
    }
    const raster: FqEpubCover | null = await FqEpubParser.encodeRasterCover(bytes);
    if (raster !== null) {
      return raster;
    }
    // 封面文档（XHTML/SVG）只包一层真正作品：跟一层 src/href / CSS url() 引用
    const directory: string = href.indexOf('/') >= 0
      ? href.substring(0, href.lastIndexOf('/')) : baseDirectory;
    const references: string[] = FqEpubParser.coverReferences(bytes);
    for (const reference of references) {
      const path: string = FqEpubParser.resolveHref(directory, reference);
      if (path.length === 0 || path === href) {
        continue;
      }
      const nested: Uint8Array | null = await FqEpubParser.readCoverBytes(file, entries, path);
      if (nested === null) {
        continue;
      }
      const nestedCover: FqEpubCover | null = await FqEpubParser.encodeRasterCover(nested);
      if (nestedCover !== null) {
        return nestedCover;
      }
    }
    if (FqEpubParser.looksLikeSvg(bytes)) {
      return new FqEpubCover(bytes, 'svg');
    }
    return null;
  }

  private static async readCoverBytes(file: FqEpubRandomFile,
    entries: Map<string, FqZipEntry>, path: string): Promise<Uint8Array | null> {
    const entry: FqZipEntry | undefined = entries.get(path);
    if (entry === undefined || entry.size === 0
      || entry.size > FQ_EPUB_MAX_COVER_RESOURCE_BYTES) {
      return null;
    }
    const bytes: Uint8Array = await FqEpubParser.readEntry(file, entry);
    if (bytes.byteLength === 0) {
      return null;
    }
    return bytes;
  }

  /** 位图重编码：魔数嗅探（不信任声明的 media-type），最长边 1600，透明存 PNG 否则 JPEG。 */
  private static async encodeRasterCover(bytes: Uint8Array): Promise<FqEpubCover | null> {
    if (!FqEpubParser.isRasterBytes(bytes)) {
      return null;
    }
    const source: image.ImageSource = image.createImageSource(
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    try {
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return null;
      }
      let targetWidth: number = width;
      let targetHeight: number = height;
      if (width > FQ_EPUB_MAX_COVER_EDGE || height > FQ_EPUB_MAX_COVER_EDGE) {
        if (width >= height) {
          targetWidth = FQ_EPUB_MAX_COVER_EDGE;
          targetHeight = Math.max(1, Math.round(height * FQ_EPUB_MAX_COVER_EDGE / width));
        } else {
          targetHeight = FQ_EPUB_MAX_COVER_EDGE;
          targetWidth = Math.max(1, Math.round(width * FQ_EPUB_MAX_COVER_EDGE / height));
        }
      }
      const pixelMap: image.PixelMap = await source.createPixelMap({
        desiredSize: { width: targetWidth, height: targetHeight },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      try {
        const transparent: boolean =
          await FqEpubParser.hasTransparentPixel(pixelMap, targetWidth, targetHeight);
        const packer: image.ImagePacker = image.createImagePacker();
        try {
          if (transparent) {
            const packed: ArrayBuffer = await packer.packToData(pixelMap,
              { format: 'image/png', quality: 100 });
            return new FqEpubCover(new Uint8Array(packed), 'png');
          }
          const packed: ArrayBuffer = await packer.packToData(pixelMap,
            { format: 'image/jpeg', quality: FQ_EPUB_COVER_JPEG_QUALITY });
          return new FqEpubCover(new Uint8Array(packed), 'jpg');
        } finally {
          packer.release().catch((_error: BusinessError): void => {
            // 释放失败忽略
          });
        }
      } finally {
        pixelMap.release().catch((_error: BusinessError): void => {
          // 释放失败忽略
        });
      }
    } finally {
      source.release().catch((_error: BusinessError): void => {
        // 释放失败忽略
      });
    }
  }

  /** 透明像素采样扫描（步长保证 ≤512000 像素；无透明存 JPEG 保持体积小）。 */
  private static async hasTransparentPixel(pixelMap: image.PixelMap,
    width: number, height: number): Promise<boolean> {
    const total: number = width * height;
    if (total <= 0) {
      return false;
    }
    const byteLength: number = pixelMap.getPixelBytesNumber();
    if (byteLength <= 0) {
      return false;
    }
    const buffer: ArrayBuffer = new ArrayBuffer(byteLength);
    await pixelMap.readPixelsToBuffer(buffer);
    const pixels: Uint8Array = new Uint8Array(buffer);
    const stride: number = Math.max(width * 4, Math.ceil(byteLength / height));
    const step: number = total <= FQ_EPUB_MAX_COVER_ALPHA_SCAN_PIXELS
      ? 1 : Math.ceil(total / FQ_EPUB_MAX_COVER_ALPHA_SCAN_PIXELS);
    for (let index: number = 0; index < total; index += step) {
      const x: number = index % width;
      const y: number = (index - x) / width;
      const offset: number = y * stride + x * 4 + 3;
      if (offset < pixels.byteLength && pixels[offset] < 255) {
        return true;
      }
    }
    return false;
  }

  /** 位图魔数嗅探：png / jpg / gif / webp（不信任声明的 media-type）。 */
  private static isRasterBytes(bytes: Uint8Array): boolean {
    if (FqEpubParser.bytesStartWith(bytes, [0x89, 0x50, 0x4e, 0x47])) {
      return true;
    }
    if (FqEpubParser.bytesStartWith(bytes, [0xff, 0xd8, 0xff])) {
      return true;
    }
    if (FqEpubParser.bytesStartWith(bytes, [0x47, 0x49, 0x46, 0x38])) {
      return true;
    }
    if (FqEpubParser.bytesStartWith(bytes, [0x52, 0x49, 0x46, 0x46])
      && FqEpubParser.bytesStartWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)) {
      return true;
    }
    return false;
  }

  private static bytesStartWith(bytes: Uint8Array, magic: number[],
    offset: number = 0): boolean {
    if (bytes.byteLength < offset + magic.length) {
      return false;
    }
    for (let index: number = 0; index < magic.length; index++) {
      if (bytes[offset + index] !== magic[index]) {
        return false;
      }
    }
    return true;
  }

  /** 封面文档内嵌引用（src/href + CSS url()，≤1MB 才解析）。 */
  private static coverReferences(bytes: Uint8Array): string[] {
    if (bytes.byteLength === 0 || bytes.byteLength > FQ_EPUB_MAX_COVER_DOCUMENT_BYTES) {
      return [];
    }
    const source: string = FqEpubParser.decodeXmlBytes(bytes);
    const out: string[] = [];
    const patterns: RegExp[] = [FQ_EPUB_COVER_REF_PATTERN, FQ_EPUB_COVER_CSS_URL_PATTERN];
    for (const pattern of patterns) {
      pattern.lastIndex = 0;
      let match: RegExpExecArray | null = pattern.exec(source);
      while (match !== null) {
        if (match[1].length > 0) {
          out.push(match[1]);
        }
        match = pattern.exec(source);
      }
    }
    return out;
  }

  /** SVG 嗅探：头部 2KB 内出现 <svg 开标签。 */
  private static looksLikeSvg(bytes: Uint8Array): boolean {
    if (bytes.byteLength === 0 || bytes.byteLength > FQ_EPUB_MAX_COVER_DOCUMENT_BYTES) {
      return false;
    }
    const head: Uint8Array = bytes.byteLength <= 2048
      ? bytes : bytes.subarray(0, 2048);
    return /<svg[\s>]/i.test(FqEpubParser.decodeXmlBytes(head));
  }

  private static hasCoverImageProperty(properties: string): boolean {
    if (properties.length === 0) {
      return false;
    }
    const tokens: string[] = properties.split(/\s+/);
    return tokens.includes('cover-image');
  }

  private static isImageMediaType(mediaType: string): boolean {
    return mediaType.trim().toLowerCase().startsWith('image/');
  }

  private static isCoverDocumentMediaType(mediaType: string): boolean {
    const value: string = mediaType.split(';')[0].trim().toLowerCase();
    return value === 'application/xhtml+xml' || value === 'text/html'
      || value === 'image/svg+xml';
  }

  private static isCoverHinted(id: string, href: string): boolean {
    return FQ_EPUB_COVER_HINT.test(id) || FQ_EPUB_COVER_HINT.test(href);
  }

  // ---------------------------------------------------------------------------
  // ZIP 中央目录与条目读取
  // ---------------------------------------------------------------------------

  /** EOCD 定位 + 中央目录遍历：条目数 / ZIP64 / 压缩比校验（对齐 fqapp）。 */
  private static async readCentralDirectory(
    file: FqEpubRandomFile): Promise<Map<string, FqZipEntry>> {
    if (file.size < 22) {
      throw new Error('EPUB 文件不是有效的 ZIP');
    }
    // EOCD 必在文件末尾 64 KB + 22 字节内：只读尾部定位，不加载整个文件
    const tailSize: number = Math.min(file.size, 65557);
    const tail: Uint8Array = await file.readAt(file.size - tailSize, tailSize);
    let eocd: number = -1;
    for (let offset: number = tail.length - 22; offset >= 0; offset--) {
      if (FqEpubParser.u32(tail, offset) === 0x06054b50) {
        eocd = offset;
        break;
      }
    }
    if (eocd < 0) {
      throw new Error('EPUB ZIP 目录损坏');
    }
    const entryCount: number = FqEpubParser.u16(tail, eocd + 10);
    const dirSize: number = FqEpubParser.u32(tail, eocd + 12);
    const dirOffset: number = FqEpubParser.u32(tail, eocd + 16);
    if (entryCount === 0xffff || dirSize === 0xffffffff || dirOffset === 0xffffffff) {
      throw new Error('暂不支持 ZIP64 格式 EPUB');
    }
    if (entryCount > FQ_EPUB_MAX_ENTRIES) {
      throw new Error('EPUB 目录超出支持范围');
    }
    const eocdFileOffset: number = file.size - tailSize + eocd;
    if (dirOffset + dirSize > eocdFileOffset) {
      throw new Error('EPUB 目录超出支持范围');
    }
    const dir: Uint8Array = await file.readAt(dirOffset, dirSize);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
    const map: Map<string, FqZipEntry> = new Map<string, FqZipEntry>();
    let offset: number = 0;
    for (let index: number = 0; index < entryCount; index++) {
      if (offset + 46 > dir.length || FqEpubParser.u32(dir, offset) !== 0x02014b50) {
        throw new Error('EPUB ZIP 目录条目损坏');
      }
      const method: number = FqEpubParser.u16(dir, offset + 10);
      const compressed: number = FqEpubParser.u32(dir, offset + 20);
      const size: number = FqEpubParser.u32(dir, offset + 24);
      const nameLength: number = FqEpubParser.u16(dir, offset + 28);
      const extraLength: number = FqEpubParser.u16(dir, offset + 30);
      const commentLength: number = FqEpubParser.u16(dir, offset + 32);
      const headerOffset: number = FqEpubParser.u32(dir, offset + 42);
      if (compressed === 0xffffffff || size === 0xffffffff) {
        throw new Error('暂不支持 ZIP64 格式 EPUB');
      }
      if ((compressed === 0 && size > 0) || (compressed > 0 && size / compressed > 1000)) {
        throw new Error('EPUB 压缩比例异常');
      }
      const name: string =
        decoder.decodeWithStream(dir.subarray(offset + 46, offset + 46 + nameLength),
          { stream: false });
      if (name.length > 0) {
        map.set(name, new FqZipEntry(name, method, compressed, size, headerOffset));
      }
      offset += 46 + nameLength + extraLength + commentLength;
      if (offset > dirSize) {
        throw new Error('EPUB ZIP 目录条目越界');
      }
    }
    return map;
  }

  /** 按需读取单个条目：先读本地文件头定位数据，STORED 直读，DEFLATE 原始 inflate。 */
  private static async readEntry(
    file: FqEpubRandomFile, entry: FqZipEntry): Promise<Uint8Array> {
    if (entry.size === 0) {
      return new Uint8Array(0);
    }
    if (entry.size > FQ_EPUB_MAX_ENTRY_BYTES) {
      throw new Error('EPUB 单个文件超过 64 MB');
    }
    const header: Uint8Array = await file.readAt(entry.headerOffset, 30);
    if (FqEpubParser.u32(header, 0) !== 0x04034b50) {
      throw new Error('EPUB ZIP 数据损坏');
    }
    const nameLength: number = FqEpubParser.u16(header, 26);
    const extraLength: number = FqEpubParser.u16(header, 28);
    const dataOffset: number = entry.headerOffset + 30 + nameLength + extraLength;
    if (dataOffset + entry.compressedSize > file.size) {
      throw new Error('EPUB ZIP 数据损坏');
    }
    const data: Uint8Array = await file.readAt(dataOffset, entry.compressedSize);
    if (entry.method === 0) {
      return data;
    }
    if (entry.method === 8) {
      return FqEpubParser.inflateRaw(data, entry.size);
    }
    throw new Error('EPUB ZIP 数据损坏');
  }

  /** 原始 DEFLATE 解压（zlib 流式接口，windowBits = -15）。 */
  private static async inflateRaw(data: Uint8Array, expectedSize: number): Promise<Uint8Array> {
    const zip: zlib.Zip = zlib.createZipSync();
    const input: ArrayBuffer =
      data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    const output: ArrayBuffer = new ArrayBuffer(expectedSize);
    const stream: zlib.ZStream = {
      nextIn: input,
      availableIn: input.byteLength,
      nextOut: output,
      availableOut: expectedSize,
    };
    try {
      await zip.inflateInit2(stream, -15);
      const status: zlib.ReturnStatus =
        await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
      if (status !== zlib.ReturnStatus.STREAM_END) {
        throw new Error('EPUB ZIP 数据损坏');
      }
    } finally {
      zip.inflateEnd(stream).catch((_error: BusinessError): void => {
        // 结束失败不阻断
      });
    }
    const produced: number = stream.totalOut !== undefined ? stream.totalOut : expectedSize;
    if (produced <= 0 || produced > expectedSize) {
      throw new Error('EPUB ZIP 数据损坏');
    }
    return new Uint8Array(output.slice(0, produced));
  }

  private static u16(bytes: Uint8Array, offset: number): number {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  private static u32(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24)) >>> 0;
  }

  // ---------------------------------------------------------------------------
  // XML / XHTML 解析
  // ---------------------------------------------------------------------------

  /** 取文档中首个指定名字的完整标签（如 rootfile / item / itemref），无则空串。 */
  private static firstTagOf(xml: string, name: string): string {
    const pattern: RegExp = new RegExp(`<${name}\\b[^>]*>`, 'i');
    const match: RegExpExecArray | null = pattern.exec(xml);
    return match === null ? '' : match[0];
  }

  /** 标签属性值（双引号 / 单引号），缺省空串。 */
  private static attrOf(tag: string, name: string): string {
    const pattern: RegExp =
      new RegExp(`${name}\\s*=\\s*"([^"]*)"|${name}\\s*=\\s*'([^']*)'`, 'i');
    const match: RegExpExecArray | null = pattern.exec(tag);
    if (match === null) {
      return '';
    }
    return match[1] !== undefined ? match[1] : match[2];
  }

  /** 首个非空元素文本（dc:title / dc:creator 等，容忍任意命名空间前缀）。 */
  private static firstTextOf(xml: string, localName: string): string {
    const pattern: RegExp = new RegExp(
      `<(?:[A-Za-z][A-Za-z0-9.-]*:)?${localName}\\b[^>]*>([^<]*)` +
      `</(?:[A-Za-z][A-Za-z0-9.-]*:)?${localName}\\s*>`, 'g');
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      const value: string = FqEpubParser.unescapeEntities(match[1]).trim();
      if (value.length > 0) {
        return value;
      }
      match = pattern.exec(xml);
    }
    return '';
  }

  /** manifest：id → (href, media-type, properties)。 */
  private static parseManifest(opf: string): Map<string, FqEpubManifestItem> {
    const manifest: Map<string, FqEpubManifestItem> = new Map<string, FqEpubManifestItem>();
    const pattern: RegExp = /<item\b[^>]*>/g;
    let match: RegExpExecArray | null = pattern.exec(opf);
    while (match !== null) {
      const tag: string = match[0];
      const id: string = FqEpubParser.attrOf(tag, 'id');
      const href: string = FqEpubParser.attrOf(tag, 'href');
      if (id.length > 0 && href.length > 0) {
        manifest.set(id, new FqEpubManifestItem(FqEpubParser.unescapeEntities(href),
          FqEpubParser.attrOf(tag, 'media-type'),
          FqEpubParser.attrOf(tag, 'properties').trim().toLowerCase()));
      }
      match = pattern.exec(opf);
    }
    return manifest;
  }

  /** 抽取所有指定名字的元素：开标签原文 + 内部文本（自闭合无文本）。 */
  private static elementsOf(xml: string, name: string): FqXmlElement[] {
    const out: FqXmlElement[] = [];
    const pattern: RegExp = new RegExp(`<${name}\\b[^>]*>`, 'g');
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      const tag: string = match[0];
      if (tag.endsWith('/>')) {
        out.push(new FqXmlElement(tag, ''));
      } else {
        const closeIndex: number = xml.indexOf(`</${name}`, match.index + tag.length);
        if (closeIndex < 0) {
          out.push(new FqXmlElement(tag, ''));
        } else {
          out.push(new FqXmlElement(tag,
            xml.substring(match.index + tag.length, closeIndex)));
        }
      }
      match = pattern.exec(xml);
    }
    return out;
  }

  /** spine：按文档顺序的 idref 列表。 */
  private static parseSpine(opf: string): string[] {
    const spine: string[] = [];
    const pattern: RegExp = /<itemref\b[^>]*>/g;
    let match: RegExpExecArray | null = pattern.exec(opf);
    while (match !== null) {
      const idref: string = FqEpubParser.attrOf(match[0], 'idref');
      if (idref.length > 0) {
        spine.push(idref);
      }
      match = pattern.exec(opf);
    }
    return spine;
  }

  /**
   * XHTML 转纯文本：块级元素断段（\n）、br 断行、script/style/noscript/nav 整段剔除、
   * 注释与 CDATA 处理、实体反转义；heading 取首个 h1~h6 内文本。
   */
  private static htmlToText(source: string): FqEpubHtmlText {
    const skipTags: string[] = ['script', 'style', 'noscript', 'nav'];
    const blockTags: string[] = ['address', 'article', 'aside', 'blockquote', 'dd', 'div',
      'dl', 'dt', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'header', 'li', 'main', 'ol', 'p', 'section', 'table', 'tr', 'ul'];
    const headingTags: string[] = ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'];
    let out: string = '';
    let skipUntil: string = '';
    let headingTag: string = '';
    let headingText: string = '';
    let pos: number = 0;
    while (pos < source.length) {
      const lt: number = source.indexOf('<', pos);
      const textEnd: number = lt < 0 ? source.length : lt;
      if (textEnd > pos) {
        const rawText: string = source.substring(pos, textEnd);
        if (skipUntil.length === 0) {
          const unescaped: string = FqEpubParser.unescapeEntities(rawText);
          out += unescaped;
          if (headingTag.length > 0) {
            headingText += unescaped;
          }
        }
      }
      if (lt < 0) {
        break;
      }
      if (FqEpubParser.startsWithAt(source, '<!--', lt)) {
        const end: number = source.indexOf('-->', lt + 4);
        pos = end < 0 ? source.length : end + 3;
        continue;
      }
      if (FqEpubParser.startsWithAt(source, '<![CDATA[', lt)) {
        const end: number = source.indexOf(']]>', lt + 9);
        const content: string = end < 0 ? source.substring(lt + 9)
          : source.substring(lt + 9, end);
        if (skipUntil.length === 0) {
          out += content;
          if (headingTag.length > 0) {
            headingText += content;
          }
        }
        pos = end < 0 ? source.length : end + 3;
        continue;
      }
      const gt: number = source.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      const raw: string = source.substring(lt, gt + 1);
      pos = gt + 1;
      const nameMatch: RegExpExecArray | null = /^<\/?\s*([a-zA-Z][a-zA-Z0-9:-]*)/.exec(raw);
      if (nameMatch === null) {
        continue;
      }
      const name: string = nameMatch[1].toLowerCase();
      const closing: boolean = raw.startsWith('</');
      const selfClosing: boolean = raw.endsWith('/>');
      if (skipUntil.length > 0) {
        if (closing && name === skipUntil) {
          skipUntil = '';
        }
        continue;
      }
      if (closing) {
        if (headingTag.length > 0 && name === headingTag) {
          headingTag = '';
        } else if (blockTags.includes(name)) {
          out += '\n';
        }
        continue;
      }
      if (skipTags.includes(name)) {
        skipUntil = name;
        continue;
      }
      if (name === 'br') {
        out += '\n';
        continue;
      }
      if (blockTags.includes(name)) {
        out += '\n';
        if (selfClosing) {
          out += '\n';
        }
      }
      if (headingTag.length === 0 && !selfClosing && headingTags.includes(name)) {
        headingTag = name;
        headingText = '';
      }
    }
    return new FqEpubHtmlText(headingText.trim(), FqEpubParser.normalizeHtmlText(out));
  }

  /** 逐行折叠空白、去空行、段落以空行分隔（对齐 fqapp _normalizeHtmlText）。 */
  private static normalizeHtmlText(value: string): string {
    const lines: string[] = value.replace(/\r/g, '').split('\n');
    const cleaned: string[] = [];
    for (const line of lines) {
      const collapsed: string = line.replace(/[\t\u00a0 ]+/g, ' ').trim();
      if (collapsed.length > 0) {
        cleaned.push(collapsed);
      }
    }
    return cleaned.join('\n\n');
  }

  private static collapseWhitespace(value: string): string {
    return value.replace(/\s+/g, '');
  }

  /** XML 实体反转义（命名 + 数字十进制 / 十六进制，未知实体保留原文）。 */
  private static unescapeEntities(value: string): string {
    if (value.indexOf('&') < 0) {
      return value;
    }
    let result: string = '';
    let pos: number = 0;
    while (pos < value.length) {
      const amp: number = value.indexOf('&', pos);
      if (amp < 0) {
        result += value.substring(pos);
        break;
      }
      if (amp > pos) {
        result += value.substring(pos, amp);
      }
      const semi: number = value.indexOf(';', amp + 1);
      if (semi < 0 || semi - amp > 12 || semi === amp + 1) {
        result += '&';
        pos = amp + 1;
        continue;
      }
      result += FqEpubParser.decodeEntity(value.substring(amp + 1, semi));
      pos = semi + 1;
    }
    return result;
  }

  private static decodeEntity(body: string): string {
    if (body === 'amp') {
      return '&';
    }
    if (body === 'lt') {
      return '<';
    }
    if (body === 'gt') {
      return '>';
    }
    if (body === 'quot') {
      return '"';
    }
    if (body === 'apos') {
      return '\'';
    }
    if (body === 'nbsp') {
      return '\u00a0';
    }
    if (body.startsWith('#x') || body.startsWith('#X')) {
      return FqEpubParser.codePointText(parseInt(body.substring(2), 16));
    }
    if (body.startsWith('#')) {
      const digits: string = body.substring(1);
      let allDigits: boolean = digits.length > 0;
      for (let index: number = 0; index < digits.length; index++) {
        if (digits.charAt(index) < '0' || digits.charAt(index) > '9') {
          allDigits = false;
          break;
        }
      }
      if (!allDigits) {
        return `&${body};`;
      }
      return FqEpubParser.codePointText(parseInt(digits, 10));
    }
    return `&${body};`;
  }

  private static codePointText(code: number): string {
    if (!Number.isFinite(code) || code <= 0 || code > 0x10FFFF
      || (code >= 0xD800 && code <= 0xDFFF)) {
      return '\uFFFD';
    }
    if (code <= 0xFFFF) {
      return String.fromCharCode(code);
    }
    const offset: number = code - 0x10000;
    return String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF));
  }

  // ---------------------------------------------------------------------------
  // 编码与路径
  // ---------------------------------------------------------------------------

  /** XML 字节解码：UTF-16 BOM 优先，UTF-8 BOM 剥离，其余宽松 UTF-8（对齐 fqapp）。 */
  private static decodeXmlBytes(bytes: Uint8Array): string {
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
      return FqEpubParser.decodeUtf16(bytes.subarray(2), true);
    }
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
      return FqEpubParser.decodeUtf16(bytes.subarray(2), false);
    }
    let start: number = 0;
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      start = 3;
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
    return decoder.decodeWithStream(bytes.subarray(start), { stream: false });
  }

  private static decodeUtf16(bytes: Uint8Array, littleEndian: boolean): string {
    const parts: string[] = [];
    let chunk: string = '';
    for (let offset: number = 0; offset + 1 < bytes.length; offset += 2) {
      const unit: number = littleEndian
        ? bytes[offset] | (bytes[offset + 1] << 8)
        : (bytes[offset] << 8) | bytes[offset + 1];
      chunk += String.fromCharCode(unit);
      if (chunk.length >= 1024) {
        parts.push(chunk);
        chunk = '';
      }
    }
    if (bytes.length % 2 === 1) {
      chunk += String.fromCharCode(0xfffd);
    }
    parts.push(chunk);
    return parts.join('');
  }

  /** 归档内 href 归一化：去 #/?、URI 解码、基准目录合并、. / .. 消解（对齐 fqapp）。 */
  private static resolveHref(baseDirectory: string, href: string): string {
    const withoutSuffix: string = href.split('#')[0].split('?')[0];
    if (withoutSuffix.length === 0) {
      return '';
    }
    let decoded: string = '';
    try {
      decoded = decodeURIComponent(withoutSuffix);
    } catch (error) {
      return '';
    }
    decoded = decoded.replace(/\\/g, '/');
    const parts: string[] = [];
    if (!decoded.startsWith('/')) {
      const baseParts: string[] = baseDirectory.split('/');
      for (const part of baseParts) {
        if (part.length > 0) {
          parts.push(part);
        }
      }
    }
    const segments: string[] = decoded.split('/');
    for (const segment of segments) {
      parts.push(segment);
    }
    return FqEpubParser.normalizePath(parts.join('/'));
  }

  private static normalizePath(path: string): string {
    const parts: string[] = [];
    const segments: string[] = path.replace(/\\/g, '/').split('/');
    for (const segment of segments) {
      if (segment.length === 0 || segment === '.') {
        continue;
      }
      if (segment === '..') {
        if (parts.length > 0) {
          parts.pop();
        }
        continue;
      }
      parts.push(segment);
    }
    return parts.join('/');
  }

  private static startsWithAt(source: string, prefix: string, offset: number): boolean {
    if (offset + prefix.length > source.length) {
      return false;
    }
    return source.startsWith(prefix, offset);
  }
}

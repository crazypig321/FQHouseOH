/**
 * 本地书籍导入（对齐 fqapp ImportedBookStore 的 TXT / EPUB 子集）。
 *
 * - documentViewPicker 选择 .txt / .epub（免权限）；
 * - TXT：UTF-8 优先解码（fatal 探测），失败回退 GBK；
 *   章节切分：行首「第X章/回/节/卷」标记；无标记时整本一章；
 * - EPUB：FqEpubParser 随机读取解析（≤1GB，图片 / 字体不加载，正文 ≤64MB）；
 * - 正文写入应用沙箱 files/local_books/<id>.txt，章节偏移持久化到 preferences；
 * - 书架条目 id 形如 local_h<内容哈希>（同文件重复导入复用同一本书，进度/已读命中），
 *   kind 'book'，cover 为空（书架卡片显示 kind 图标占位）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { FqChapter } from '../model/FqModels';
import { FqShelfItem } from './FqShelfStore';
import { FqEpubBook, FqEpubCover, FqEpubParser } from './FqEpubParser';
import { fqAsArray, fqAsRecord, fqStr, fqNum } from './FqJson';

const FQ_LOCAL_BOOK_NAME: string = 'fq_local_books';
const FQ_LOCAL_BOOK_KEY: string = 'books';
const FQ_LOCAL_BOOK_DIR: string = 'local_books';
const FQ_LOCAL_ID_PREFIX: string = 'local_';
/** 章节标题行：行首「第X章/回/节/卷」+ 少量补充文字。 */
const FQ_CHAPTER_LINE: RegExp =
  /^\s{0,4}(第[0-9零一二三四五六七八九十百千万两]+[章回节卷])[^\n]{0,40}$/;
/** EPUB 细分切片废章阈值：短于该长度（目录页「Table of Contents」残留、占位「未知」）
 *  不进目录，但正文保留（文件内容不变，重复导入命中同一本书）。 */
const FQ_EPUB_JUNK_SUB_MAX: number = 40;

/** 章节索引（正文字符偏移 + 长度 + 分组标题）。 */
export class FqLocalChapter {
  readonly title: string;
  readonly offset: number;
  readonly length: number;
  /** 分组标题（EPUB spine 文档标题；空串不分组）。 */
  readonly group: string;

  constructor(title: string, offset: number, length: number, group: string = '') {
    this.title = title;
    this.offset = offset;
    this.length = length;
    this.group = group;
  }
}

/** 本地书籍元数据。 */
export class FqLocalBookMeta {
  readonly id: string;
  readonly title: string;
  /** 沙箱内正文文件绝对路径。 */
  readonly file: string;
  readonly chapters: FqLocalChapter[];

  constructor(id: string, title: string, file: string, chapters: FqLocalChapter[]) {
    this.id = id;
    this.title = title;
    this.file = file;
    this.chapters = chapters;
  }
}

export class FqLocalBookStore {
  private static pref: preferences.Preferences | null = null;
  private static books: Map<string, FqLocalBookMeta> = new Map<string, FqLocalBookMeta>();
  private static filesDir: string = '';

  public static init(context: common.Context): void {
    if (FqLocalBookStore.pref !== null) {
      return;
    }
    FqLocalBookStore.filesDir = context.filesDir;
    try {
      FqLocalBookStore.pref = preferences.getPreferencesSync(context, { name: FQ_LOCAL_BOOK_NAME });
    } catch (error) {
      FqLocalBookStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqLocalBookStore.pref.getSync(FQ_LOCAL_BOOK_KEY, '');
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
      const arr: Object[] | null = fqAsArray(parsed);
      if (arr === null) {
        return;
      }
      for (const entry of arr) {
        const meta = FqLocalBookStore.parseMeta(entry);
        if (meta !== null) {
          FqLocalBookStore.books.set(meta.id, meta);
        }
      }
    } catch (error) {
      // 损坏元数据按空处理
    }
  }

  public static isLocalBookId(id: string): boolean {
    return id.startsWith(FQ_LOCAL_ID_PREFIX);
  }

  /** 目录章节（阅读页本地模式数据源）。 */
  public static chapters(bookId: string): FqChapter[] {
    const meta: FqLocalBookMeta | undefined = FqLocalBookStore.books.get(bookId);
    if (meta === undefined) {
      return [];
    }
    const out: FqChapter[] = [];
    for (let i = 0; i < meta.chapters.length; i++) {
      out.push(new FqChapter(`${bookId}_c${i}`, meta.chapters[i].title, '',
        meta.chapters[i].group));
    }
    return out;
  }

  /** 章节正文（按导入时的偏移切片）。 */
  public static chapterText(bookId: string, index: number): string {
    const meta: FqLocalBookMeta | undefined = FqLocalBookStore.books.get(bookId);
    if (meta === undefined || index < 0 || index >= meta.chapters.length) {
      return '';
    }
    const full: string = FqLocalBookStore.readBookFile(meta.file);
    if (full.length === 0) {
      return '';
    }
    const chapter: FqLocalChapter = meta.chapters[index];
    return full.substring(chapter.offset, chapter.offset + chapter.length);
  }

  /**
   * 本地书移出书架：删除沙箱正文 / 封面文件与元数据，避免残留占空间。
   * 非本地书 id 自动跳过；重复调用安全。
   */
  public static deleteBooks(ids: string[]): void {
    let changed: boolean = false;
    for (const id of ids) {
      if (!FqLocalBookStore.isLocalBookId(id)) {
        continue;
      }
      const meta: FqLocalBookMeta | undefined = FqLocalBookStore.books.get(id);
      if (meta !== undefined) {
        FqLocalBookStore.deleteFileQuietly(meta.file);
        FqLocalBookStore.books.delete(id);
        changed = true;
      }
      // 封面扩展名不在元数据里（png/jpg/svg 逐一尝试删除）
      const dir: string = `${FqLocalBookStore.filesDir}/${FQ_LOCAL_BOOK_DIR}`;
      const extensions: string[] = ['png', 'jpg', 'svg'];
      for (const extension of extensions) {
        FqLocalBookStore.deleteFileQuietly(`${dir}/${id}_cover.${extension}`);
      }
    }
    if (changed) {
      FqLocalBookStore.persist();
    }
  }

  /** 删除单个沙箱文件：不存在 / 失败静默忽略。 */
  private static deleteFileQuietly(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
      // 文件不存在 / 删除失败忽略
    }
  }

  /**
   * 选择并导入一本本地 TXT / EPUB；返回书架条目（取消返回 null）。
   * 调用方负责写入书架与提示。
   */
  public static async pickAndImport(context: common.Context): Promise<FqShelfItem | null> {
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    const uris: string[] = await docPicker.select({
      maxSelectNumber: 1,
      fileSuffixFilters: ['txt', 'epub'],
    });
    if (uris.length === 0) {
      return null;
    }
    return FqLocalBookStore.importFromUri(context, uris[0]);
  }

  /**
   * 从文件 URI 导入一本本地 TXT / EPUB（选择器 / 分享文件打开复用）。
   * 同内容幂等复用同一本书（哈希稳定 id）；调用方负责写入书架与提示。
   */
  public static async importFromUri(context: common.Context, uri: string): Promise<FqShelfItem> {
    const suffix: string = FqLocalBookStore.suffixFromUri(uri);
    if (suffix === 'epub') {
      return FqLocalBookStore.importEpub(context, uri);
    }
    if (suffix !== 'txt') {
      throw new Error('仅支持 TXT 和 EPUB 文件');
    }
    const title: string = FqLocalBookStore.titleFromUri(uri);
    const text: string = FqLocalBookStore.readAndDecode(uri);
    if (text.trim().length === 0) {
      throw new Error('文件内容为空');
    }
    const chapters: FqLocalChapter[] = FqLocalBookStore.splitChapters(text);
    // 内容哈希稳定 id：同一文件重复导入复用同一本书，阅读进度/已读章节直接命中
    const id: string = `${FQ_LOCAL_ID_PREFIX}h${FqLocalBookStore.textHash(text)}`;
    const file: string = FqLocalBookStore.writeBookFile(context, id, text);
    const meta: FqLocalBookMeta = new FqLocalBookMeta(id, title, file, chapters);
    FqLocalBookStore.books.set(id, meta);
    FqLocalBookStore.persist();
    return new FqShelfItem(id, 'book', title, '');
  }

  /** 本地书沙箱正文文件路径（分享文件本体用；未知 id 返回空串）。 */
  public static bookFilePath(bookId: string): string {
    const meta: FqLocalBookMeta | undefined = FqLocalBookStore.books.get(bookId);
    return meta !== undefined ? meta.file : '';
  }

  /** 本地书标题（分享面板标题用；未知 id 返回空串）。 */
  public static bookTitle(bookId: string): string {
    const meta: FqLocalBookMeta | undefined = FqLocalBookStore.books.get(bookId);
    return meta !== undefined ? meta.title : '';
  }

  /** 48 位 djb2 文本哈希（运算量控制在双精度可精确表示区间）；同内容文件得到相同哈希。 */
  private static textHash(text: string): string {
    let h: number = 5381;
    for (let i: number = 0; i < text.length; i++) {
      h = (h * 33 + text.charCodeAt(i)) % 281474976710656;
    }
    return h.toString(16);
  }

  /** EPUB 导入：随机读取解析 → 拼整书正文并记录章节偏移（架构与 TXT 一致）。 */
  private static async importEpub(context: common.Context, uri: string): Promise<FqShelfItem> {
    const size: number = FqLocalBookStore.statFileSize(uri);
    if (size > 1024 * 1024 * 1024) {
      throw new Error('请选择小于 1 GB 的 EPUB 文件');
    }
    const fileTitle: string = FqLocalBookStore.titleFromUri(uri);
    const book: FqEpubBook = await FqEpubParser.parse(uri, fileTitle);
    // 章节拼接：每个 spine 文档再细分章（一章 = splitChapters 的一个切片），
    // parts 一次 join，避免 O(n²) 字符串拼接。
    // 纯标题行连续段（目录页条目等）不写入文件；偏移必须按 parts 实际写入
    // 顺序顺序累计——按 doc.text 原位映射会因被丢弃的尾巴/间隙而漂移。
    const parts: string[] = [];
    const chapters: FqLocalChapter[] = [];
    let offset: number = 0;
    // 孤儿文档归并：root NCX 漏映射的文档（如分卷中段被 calibre 拆出的续篇文件）
    // 无分组也无标题，单切片且不以章标题行开头时并入上一章，避免伪章节行。
    let lastGroup: string = '';
    let lastDocKept: boolean = false;
    for (const doc of book.chapters) {
      // 裸目录页（整页纯章标题行、无引导标题）：整页丢弃，不进正文也不进目录
      if (FqLocalBookStore.isBareTocText(doc.text)) {
        continue;
      }
      const subs: FqLocalChapter[] = FqLocalBookStore.splitChapters(doc.text);
      let keptCount: number = 0;
      let keptTitle: string = '';
      for (const sub of subs) {
        if (sub.length >= FQ_EPUB_JUNK_SUB_MAX) {
          keptCount++;
          if (keptTitle.length === 0) {
            keptTitle = sub.title;
          }
        }
      }
      // 续篇片段：无 NCX 分组 + 上文已有分组且产章 + 单切片非章标题行开头 → 并入上一章
      const mergeFragment: boolean = doc.group.length === 0 && lastGroup.length > 0
        && lastDocKept && keptCount === 1 && chapters.length > 0
        && !FqLocalBookStore.isChapterTitleLine(keptTitle.trim());
      if (mergeFragment) {
        const before: number = offset;
        for (const sub of subs) {
          parts.push(doc.text.substring(sub.offset, sub.offset + sub.length));
          offset += sub.length;
        }
        const last: FqLocalChapter = chapters[chapters.length - 1];
        // 上一章延伸到本片段末尾（+2 为上一文档结尾的分隔空行）
        chapters[chapters.length - 1] = new FqLocalChapter(last.title, last.offset,
          last.length + (offset - before) + 2, last.group);
        parts.push('\n\n');
        offset += 2;
        continue;
      }
      const multi: boolean = keptCount > 1;
      // 分组：NCX 分卷名 > 上文分组继承（NCX 漏映射文档）> 文档标题（细分多章且非章标题行）
      let group: string = doc.group;
      if (group.length === 0) {
        group = lastGroup;
      }
      if (group.length === 0 && multi
        && !FqLocalBookStore.isChapterTitleLine(doc.title.trim())) {
        group = doc.title;
      }
      for (const sub of subs) {
        const title: string = !multi || sub.title.length === 0 ? doc.title : sub.title;
        if (sub.length >= FQ_EPUB_JUNK_SUB_MAX) {
          chapters.push(new FqLocalChapter(title, offset, sub.length, group));
        }
        parts.push(doc.text.substring(sub.offset, sub.offset + sub.length));
        offset += sub.length;
      }
      parts.push('\n\n');
      offset += 2;
      if (doc.group.length > 0) {
        lastGroup = doc.group;
      }
      lastDocKept = keptCount > 0;
    }
    const full: string = parts.join('');
    // 正文内容哈希稳定 id（与 TXT 同域）：相同正文的 EPUB / TXT 复用同一本书
    const id: string = `${FQ_LOCAL_ID_PREFIX}h${FqLocalBookStore.textHash(full)}`;
    const file: string = FqLocalBookStore.writeBookFile(context, id, full);
    const meta: FqLocalBookMeta = new FqLocalBookMeta(id, book.title, file, chapters);
    FqLocalBookStore.books.set(id, meta);
    FqLocalBookStore.persist();
    // 内嵌封面 best-effort：提取成功写沙箱并以 file URI 入架，失败回退网络匹配
    const coverUri: string = book.cover !== null
      ? FqLocalBookStore.writeCoverFile(context, id, book.cover) : '';
    return new FqShelfItem(id, 'book', book.title, coverUri);
  }

  /** 封面写入沙箱并返回 file URI（Image 可直接加载；失败返回空串）。 */
  private static writeCoverFile(context: common.Context, id: string,
    cover: FqEpubCover): string {
    const dir: string = `${context.filesDir}/${FQ_LOCAL_BOOK_DIR}`;
    try {
      fileIo.mkdirSync(dir);
    } catch (error) {
      // 目录已存在
    }
    const file: string = `${dir}/${id}_cover.${cover.extension}`;
    let fd: number = -1;
    try {
      fd = fileIo.openSync(file,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
      fileIo.writeSync(fd, cover.bytes.buffer);
    } catch (error) {
      return '';
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
          // 关闭失败忽略
        }
      }
    }
    try {
      return fileUri.getUriFromPath(file);
    } catch (error) {
      return '';
    }
  }

  /** 文件大小（字节）；空文件 / 不可读抛中文错误。 */
  private static statFileSize(uri: string): number {
    let fd: number = -1;
    try {
      fd = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY).fd;
      const stat = fileIo.statSync(fd);
      const size: number = stat.size;
      if (size <= 0) {
        throw new Error('文件内容为空');
      }
      return size;
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
          // 关闭失败忽略
        }
      }
    }
  }

  /** 文件 URI 后缀（小写，去 query / decode）。 */
  private static suffixFromUri(uri: string): string {
    const noQuery: string = uri.split('?')[0];
    const segments: string[] = noQuery.split('/');
    const name: string = segments.length > 0 ? segments[segments.length - 1] : '';
    let decoded: string = name;
    try {
      decoded = decodeURIComponent(name);
    } catch (error) {
      // 保留原始名
    }
    const dot: number = decoded.lastIndexOf('.');
    return (dot >= 0 ? decoded.substring(dot + 1) : '').toLowerCase();
  }

  private static titleFromUri(uri: string): string {
    const noQuery: string = uri.split('?')[0];
    const segments: string[] = noQuery.split('/');
    const name: string = segments.length > 0 ? segments[segments.length - 1] : '';
    let decoded: string = name;
    try {
      decoded = decodeURIComponent(name);
    } catch (error) {
      // 保留原始名
    }
    const dot: number = decoded.lastIndexOf('.');
    const title: string = dot > 0 ? decoded.substring(0, dot) : decoded;
    return title.trim().length > 0 ? title.trim() : '本地书籍';
  }

  /** 读取原始字节并解码：UTF-8（fatal 探测）优先，失败回退 GBK。 */
  private static readAndDecode(uri: string): string {
    let fd: number = -1;
    try {
      fd = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY).fd;
      const stat = fileIo.statSync(fd);
      const size: number = stat.size;
      if (size <= 0 || size > 64 * 1024 * 1024) {
        throw new Error('文件过大或不可读');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(fd, buffer);
      const bytes: Uint8Array = new Uint8Array(buffer);
      try {
        const utf8: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
        return utf8.decodeWithStream(bytes, { stream: false });
      } catch (error) {
        // 非 UTF-8，尝试 GBK
      }
      try {
        const gbk: util.TextDecoder = util.TextDecoder.create('gbk', { fatal: false });
        return gbk.decodeWithStream(bytes, { stream: false });
      } catch (error) {
        // GBK 也不支持时退回宽松 UTF-8
      }
      const loose: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
      return loose.decodeWithStream(bytes, { stream: false });
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
          // 关闭失败忽略
        }
      }
    }
  }

  /** 章节标题行判定（导出规范化复用同一规则）。 */
  public static isChapterTitleLine(line: string): boolean {
    return FQ_CHAPTER_LINE.test(line);
  }

  /**
   * 章节切分：行首「第X章/回/节/卷」为界；无标记时整本一章。
   * 容错：
   * - 连续标记行（本应用导出文件「目录标题 + 正文首行重复标题」、正文内标题变体）合并为同一章；
   * - 软标记：前后被空行包围的短行（本应用导出格式「内容+空行+空行+标题+空行+内容」）
   *   也作为章节起点，覆盖目录标题不匹配「第X章」正则的章节；
   * - 首个标记前的正文立为前置章不丢弃。
   */
  private static splitChapters(text: string): FqLocalChapter[] {
    const chapters: FqLocalChapter[] = [];
    const lines: string[] = text.split('\n');
    const offsets: number[] = [];
    let acc: number = 0;
    for (const line of lines) {
      offsets.push(acc);
      acc += line.length + 1;
    }
    let currentTitle: string = '';
    let chapterStart: number = -1;
    let hasBody: boolean = false;
    let preambleTitle: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (FqLocalBookStore.isChapterTitleLine(trimmed)
        || FqLocalBookStore.isSoftChapterTitle(lines, i)) {
        // 上一段已有正文才立章；只含标题的空段并入新标记行
        if (chapterStart >= 0 && hasBody) {
          chapters.push(new FqLocalChapter(currentTitle, chapterStart, offsets[i] - chapterStart));
        } else if (chapterStart < 0 && hasBody) {
          chapters.push(new FqLocalChapter(preambleTitle.length > 0 ? preambleTitle : '正文', 0, offsets[i]));
        }
        currentTitle = trimmed;
        chapterStart = offsets[i];
        hasBody = false;
      } else if (trimmed.length > 0) {
        if (chapterStart < 0 && preambleTitle.length === 0) {
          preambleTitle = trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
        }
        hasBody = true;
      }
    }
    if (chapterStart >= 0 && hasBody) {
      chapters.push(new FqLocalChapter(currentTitle, chapterStart, text.length - chapterStart));
    } else if (chapterStart < 0 && hasBody) {
      chapters.push(new FqLocalChapter(preambleTitle.length > 0 ? preambleTitle : '正文', 0, text.length));
    }
    if (chapters.length === 0) {
      chapters.push(new FqLocalChapter('正文', 0, text.length));
    }
    return chapters;
  }

  /** 软章节标记：短行且前面至少两个空行、后面紧跟一个空行（本应用导出文件分章结构）。 */
  private static isSoftChapterTitle(lines: string[], index: number): boolean {
    const trimmed: string = lines[index].trim();
    if (trimmed.length === 0 || trimmed.length > 40) {
      return false;
    }
    if (index < 2) {
      return false;
    }
    if (lines[index - 1].trim().length > 0 || lines[index - 2].trim().length > 0) {
      return false;
    }
    if (index + 1 >= lines.length || lines[index + 1].trim().length > 0) {
      return false;
    }
    return true;
  }

  /** 裸目录页判定：非空行 ≥2 且全部是章标题行（无引导标题的纯目录）。 */
  private static isBareTocText(text: string): boolean {
    const lines: string[] = text.split('\n');
    let count: number = 0;
    for (const line of lines) {
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (!FqLocalBookStore.isChapterTitleLine(trimmed)) {
        return false;
      }
      count++;
    }
    return count >= 2;
  }

  private static writeBookFile(context: common.Context, id: string, text: string): string {
    const dir: string = `${context.filesDir}/${FQ_LOCAL_BOOK_DIR}`;
    try {
      fileIo.mkdirSync(dir);
    } catch (error) {
      // 目录已存在
    }
    const file: string = `${dir}/${id}.txt`;
    let fd: number = -1;
    try {
      fd = fileIo.openSync(file,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
      fileIo.writeSync(fd, text);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (error) {
          // 关闭失败忽略
        }
      }
    }
    return file;
  }

  private static readBookFile(file: string): string {
    try {
      return fileIo.readTextSync(file);
    } catch (error) {
      return '';
    }
  }

  private static parseMeta(entry: Object): FqLocalBookMeta | null {
    const rec: Record<string, Object> | null = fqAsRecord(entry);
    if (rec === null) {
      return null;
    }
    const id: string = fqStr(rec, 'id');
    const file: string = fqStr(rec, 'file');
    if (id.length === 0 || file.length === 0) {
      return null;
    }
    const chaptersRaw: Object[] | null = fqAsArray(rec['chapters'] ?? null);
    const chapters: FqLocalChapter[] = [];
    if (chaptersRaw !== null) {
      for (const raw of chaptersRaw) {
        const chapterRec: Record<string, Object> | null = fqAsRecord(raw);
        if (chapterRec === null) {
          continue;
        }
        chapters.push(new FqLocalChapter(fqStr(chapterRec, 'title'),
          fqNum(chapterRec, 'offset'), fqNum(chapterRec, 'length'),
          fqStr(chapterRec, 'group')));
      }
    }
    if (chapters.length === 0) {
      return null;
    }
    return new FqLocalBookMeta(id, fqStr(rec, 'title'), file, chapters);
  }

  private static persist(): void {
    const pref: preferences.Preferences | null = FqLocalBookStore.pref;
    if (pref === null) {
      return;
    }
    const recs: Object[] = [];
    FqLocalBookStore.books.forEach((meta: FqLocalBookMeta): void => {
      const chapters: Object[] = [];
      for (const chapter of meta.chapters) {
        const chapterRec: Record<string, Object> = {};
        chapterRec['title'] = chapter.title;
        chapterRec['offset'] = chapter.offset;
        chapterRec['length'] = chapter.length;
        chapterRec['group'] = chapter.group;
        chapters.push(chapterRec);
      }
      const rec: Record<string, Object> = {};
      rec['id'] = meta.id;
      rec['title'] = meta.title;
      rec['file'] = meta.file;
      rec['chapters'] = chapters;
      recs.push(rec);
    });
    try {
      pref.putSync(FQ_LOCAL_BOOK_KEY, JSON.stringify(recs));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

/**
 * 漫画阅读页（ComicPage，CommonNav 框架，复用 ReaderPage 阅读体验）：
 * - 正文：整页图片（Contain，纯黑底，显式定高不随菜单呼出的容器
 *   resize 缩放），一页一张图；邻图预解码为 PixelMap 经 FqComicCanvas 同帧绘制
 *   （提交翻页换源即换绘，无 Image 跨实例换源上传闪帧；未就绪回退 URL 异步加载兜底）；
 * - 翻页方式：0 仿真 / 1 覆盖（FqReaderFlip flipMode=0/2）/ 2 上下滚动
 *   （webtoon：List + LazyForEach 整章图片连续纵向滚动，滚到章尾自动追加下一话）；
 * - 眉页（章节名）/眉脚（时钟/电量/章内图序），目录半模态、漫评半模态、
 *   「漫画设置」公共弹窗（仅翻页方式）、沉浸状态栏、进度持久化，
 *   均与 ReaderPage 行为对齐（不锁定应用色彩模式，工具栏跟随系统深浅色）。
 * 进度编码：domPos = 'img:N'（章内图片下标），与小说 'p2:' 格式互不冲突。
 */

import { common } from '@kit.AbilityKit';
import { display, promptAction, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { batteryInfo, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqChapter, FqCacheTaskView, fqKindToTab } from '../../model/FqModels';
import { FqReaderProgress, FqReaderStore } from '../../core/FqReaderStore';
import { FqReadStatsStore } from '../../core/FqReadStatsStore';
import { ComicNavParams, ROUTE_CACHED_COMICS } from '../../model/FqNavModels';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { CommonNav, titleBarOf } from '../../view/CommonNav';
import { CommonLoading, FQ_ACCENT } from '../../view/CommonCom';
import { FqSheetOptions } from '../../view/sheet/CommonSheet';
import { FqCommentSheet, fqCommentSheetHeightVp } from '../../view/sheet/FqCommentSheet';
import { FqCatalogSheet } from '../../view/sheet/FqCatalogSheet';
import { FqCacheSheet } from '../../view/sheet/FqCacheSheet';
import { FqComicCacheStore } from '../../core/FqComicCacheStore';
import {
  fqComicDownloader,
  FqComicDownloader,
  FqComicDownloadTask,
  ComicDownloadStatus,
} from '../../core/FqComicDownloader';
import { appState } from '../../entryability/AppState';
import { DialogManager } from '../../utils/DialogUtils';
import { FqReaderFlip } from '../../reader/FqReaderFlip';
import { FqComicCanvas } from '../../reader/FqComicCanvas';
import { fqComicSettingsBus } from '../../core/FqComicSettingsBus';

/** 漫画正文底色（纯黑）。 */
const FQ_COMIC_BG: string = '#000000';
/** 日志标签。 */
const FQ_COMIC_TAG: string = 'FqComicPage';
/** 漫画眉页/眉脚文字色（黑底白字）。 */
const FQ_COMIC_TEXT: string = '#E6E6E6';

/** 上下滚动模式单图条目（所属章下标 + 章内图下标 + 图片地址）。 */
export class FqComicImageItem {
  readonly chapterIndex: number;
  readonly imageIndex: number;
  readonly url: string;

  constructor(chapterIndex: number, imageIndex: number, url: string) {
    this.chapterIndex = chapterIndex;
    this.imageIndex = imageIndex;
    this.url = url;
  }
}

/** 上下滚动模式懒加载数据源（List + LazyForEach；追加逐项通知、重置整体通知）。 */
export class FqComicImageSource implements IDataSource {
  private items: FqComicImageItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): FqComicImageItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 追加单条（onDataAdd 逐项通知，滚动位置稳定）。 */
  append(item: FqComicImageItem): void {
    this.items.push(item);
    const index: number = this.items.length - 1;
    for (const listener of this.listeners) {
      listener.onDataAdd(index);
    }
  }

  /** 清空重建（onDataReloaded 整体通知）。 */
  reset(): void {
    this.items = [];
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct ComicPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local menuVisible: boolean = false;
  @Local sheetVisible: boolean = false;
  /** 目录打开令牌：每次打开 +1（公共 FqCatalogSheet 据此重置搜索/排序并定位当前章）。 */
  @Local sheetOpenToken: number = 0;
  /** 漫评半模态（标题栏评论键呼出）。 */
  @Local commentSheetVisible: boolean = false;
  @Local chapterIndex: number = 0;
  @Local totalChapters: number = 0;
  /** 翻页方式：0 仿真 / 1 覆盖 / 2 上下滚动。 */
  @Local comicFlipIndex: number = 0;
  /** 当前章图片 / 邻章预载缓存（引用替换驱动翻页容器刷新）。 */
  @Local curImages: string[] = [];
  @Local prevImages: string[] = [];
  @Local nextImages: string[] = [];
  /** 当前页（章内图片下标）。 */
  @Local pageIndex: number = 0;
  /** 眉脚时钟文本（HH:mm）与电量百分比（-1 未知）。 */
  @Local footerClock: string = '';
  @Local batteryLevel: number = -1;
  /** 上下滚动模式：章尾追加中 / 已到最后一话（提示去重）。 */
  @Local verticalAppending: boolean = false;
  /** 分页模式图高（窗口高 - 眉页/眉脚区；显式定值，菜单呼出容器 resize 不再缩放图片）。 */
  @Local pagedImageHeightVp: number = 0;
  /** 三槽位图源（下标 0..2 对应 slot -1..+1；PixelMap 优先 / URL 回退，整体替换驱动重渲染）。 */
  @Local slotSources: Array<image.PixelMap | string> = ['', '', ''];
  /** 翻页容器眉页/眉脚区高（vp，避让区变化时更新）。 */
  @Local headerZoneVp: number = 20;
  @Local footerZoneVp: number = 20;
  /** 阅读体高（vp；菜单隐藏时实测校准，0=未测回退全窗高）。
   *  显式定高 + 顶偏移补偿：呼出菜单标题栏下压内容区时，阅读体钉在窗口原位不动。 */
  @Local bodyHeightVp: number = 0;
  /** 标题栏下压补偿量（vp，外层实测；0=未下压）。 */
  @Local bodyTopCompVp: number = 0;
  /** 离线缓存 sheet（独立零尺寸宿主，标题栏下载键呼出）。 */
  @Local cacheSheetVisible: boolean = false;
  private cacheCloseToken: number = 0;
  /** 缓存 sheet 打开令牌（FqCacheSheet 据此重置勾选并定位当前话）。 */
  @Local cacheOpenToken: number = 0;
  /** 当前书已离线话集合（打开 sheet 时刷新）。 */
  @Local cacheDownloadedIds: Set<string> = new Set<string>();
  /** 漫画下载器单例（@Trace taskList 驱动缓存格任务态实时刷新）。 */
  @Local dl: FqComicDownloader = fqComicDownloader;

  private bookId: string = '';
  private bookTitle: string = '';
  private startChapterIndex: number = -1;
  private chapters: FqChapter[] = [];
  private loadToken: number = 0;
  private clockTimer: number = -1;
  private titleBarOp: TitleBarContentOptions | undefined = undefined;
  /** 各章图片缓存（跨章翻页/上下追加复用，会话内有效）。 */
  private chapterImageCache: Map<number, string[]> = new Map();
  /** 已读章节集合（翻过章末/下一话/上下滚动进后章时标记，目录进度用；目录跳转不标记）。 */
  private readChapters: Set<number> = new Set();
  /** 上下滚动模式数据源与滚动控制器。 */
  private verticalSource: FqComicImageSource = new FqComicImageSource();
  private verticalScroller: Scroller = new Scroller();
  /** 「已经是最后一话」提示去重（跳章/重建时复位）。 */
  private verticalEndedToastOnce: boolean = false;
  /** 图片预解码缓存（URL → PixelMap，翻页提交同帧渲染）。 */
  private pixelCache: Map<string, image.PixelMap> = new Map();
  /** 在途预解码去重。 */
  private pixelInflight: Set<string> = new Set();
  /** 缓存 LRU 序列。 */
  private pixelOrder: string[] = [];
  /** 预解码失败 URL（放行翻页兜底 + 后台重试）。 */
  private pixelFailed: Set<string> = new Set();
  /** 预解码失败 toast 只提示一次（诊断通道）。 */
  private decodeFailToastShown: boolean = false;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.bookId = ComicNavParams.id;
    this.bookTitle = ComicNavParams.title;
    this.startChapterIndex = ComicNavParams.chapterIndex;
    this.titleBarOp = titleBarOf(this.bookTitle, undefined, [
      {
        content: {
          icon: $r('sys.symbol.message'),
          label: 'comments',
          action: (): void => {
            this.openCommentSheet();
          },
        },
      },
      {
        content: {
          icon: $r('sys.symbol.download'),
          label: 'cache',
          action: (): void => {
            this.openCacheSheet();
          },
        },
      },
    ]);
    FqReaderStore.init(getContext(this));
    FqReadStatsStore.init(getContext(this));
    this.comicFlipIndex = FqReaderStore.getSettings().comicFlipIndex;
    this.updateZones();
    this.refreshFooterStatus();
    this.clockTimer = setInterval((): void => {
      this.refreshFooterStatus();
      // 阅读页驻留累计今日已读时长（30s 心跳，按书+全局双层）
      FqReadStatsStore.addBookSeconds(this.bookId, 30);
    }, 30000);
    this.applySystemBar(false);
    this.attachSettingsBus();
    this.load();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.releasePixelCache();
    this.applySystemBar(true);
    this.loadToken += 1;
    this.saveProgressNow();
    fqComicSettingsBus.handler = null;
    DialogManager.CloseDialog();
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  build() {
    CommonNav({
      hideTitleBar: !this.menuVisible,
      titleBarOp: this.titleBarOp,
      pageBackgroundColor: FQ_COMIC_BG,
      showBrandGradient: false,
      scrollMaskExtraHeight: 0,
      tabMaskHeight: 0,
      isShowBar: true,
      isShowBarController: this.menuVisible,
      readBarKind: 'reader',
      // 纯黑底：标题栏/底部工具条前景固定白色，不随深浅模式（sheet 内仍走系统色）
      barForegroundColor: Color.White,
      readerBarClick: (key: string): void => {
        this.onReadBarAction(key);
      },
      backPressed: (): boolean => this.handleBackPressed(),
    }) {
      // 外层：跟随容器（呼出菜单时被标题栏压缩，实测下压量）
      Stack() {
        // 内层：阅读体（显式定高 + 顶偏移补偿，钉在窗口原位——菜单呼出/收起全程图片不动）
        Stack() {
          if (this.comicFlipIndex === 2) {
            this.VerticalBody()
          } else {
            FqReaderFlip({
              flipMode: this.comicFlipIndex === 0 ? 0 : 2,
              snapshotPrefix: 'fq_comic',
              hasPrev: this.flipHasPrev(),
              hasNext: this.flipHasNext(),
              canTurn: (isNext: boolean): boolean => this.flipTargetReady(isNext),
              headerZoneVp: this.headerZoneVp,
              footerZoneVp: this.footerZoneVp,
              pageBgColor: FQ_COMIC_BG,
              pageRenderer: (slot: number): void => {
                this.imageSlot(slot);
              },
              headerRenderer: (slot: number): void => {
                this.slotHeader(slot);
              },
              footerRenderer: (slot: number): void => {
                this.slotFooter(slot);
              },
              onTurn: (isNext: boolean): void => {
                this.onFlipTurn(isNext);
              },
              onMenuTap: (): void => {
                this.toggleMenu();
              },
            })
          }

          // 漫评半模态宿主（0 尺寸稳定节点）
          Column()
            .width(0)
            .height(0)
            .bindSheet(this.commentSheetVisible, this.CommentSheet(), FqSheetOptions((): void => {
              this.onCommentSheetClose();
            }, fqCommentSheetHeightVp()))

          // 离线缓存 sheet 宿主（0 尺寸稳定节点，标题栏下载键呼出）
          Column()
            .width(0)
            .height(0)
            .bindSheet(this.cacheSheetVisible, this.CacheSheetBuilder(), FqSheetOptions((): void => {
              this.closeCacheSheet();
            }, this.fqRatioSheetHeightVp(), false))

          if (this.loadingState) {
            Column({ space: 12 }) {
              CommonLoading({ sizeValue: 36, loadColor: FQ_ACCENT })
              Text('正在加载本话内容')
                .fontSize(14)
                .fontColor(FQ_COMIC_TEXT)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(FQ_COMIC_BG)
          } else if (this.errorMsg.length > 0) {
            Column({ space: 12 }) {
              Text(this.errorMsg)
                .fontSize(14)
                .fontColor(FQ_COMIC_TEXT)
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              Button('重试')
                .backgroundColor(FQ_ACCENT)
                .onClick(() => this.retry())
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(FQ_COMIC_BG)
          }

          if (this.menuVisible) {
            Column()
              .width('100%')
              .height('100%')
              .onClick(() => {
                this.menuVisible = false;
                this.sheetVisible = false;
              })
          }
        }
        .width('100%')
        .height(this.bodyHeightVp > 0 ? this.bodyHeightVp : '100%')
        .offset({ y: -this.bodyTopCompVp })
        .backgroundColor(FQ_COMIC_BG)
        .bindSheet(this.sheetVisible, this.CatalogSheet(), FqSheetOptions((): void => {
          this.onSheetClose();
        }))
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Top)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.onBodyAreaChange(newArea);
      })
    }
  }

  // ---------------------------------------------------------------------------
  // 翻页模式正文
  // ---------------------------------------------------------------------------

  /** 仿真/覆盖模式槽位图（slot：-1 / 0 / +1，章内邻图优先，越界取预载邻章）：
   *  显式定高（窗口高 - 眉页/眉脚区），菜单呼出容器 resize 不缩放图片（治“弹一下”）；
   *  图源经 FqComicCanvas：预解码 PixelMap 同帧 Contain 绘制（提交翻页换源即换绘，
   *  无 Image 跨实例换源上传，治“闪一下”），未就绪回退 URL 异步加载兜底。 */
  @Builder
  private imageSlot(slot: number) {
    if (this.imageForSlot(slot).length > 0) {
      FqComicCanvas({
        source: this.slotSources[slot + 1],
        heightVp: this.pagedImageHeightVp,
      })
    }
  }

  /** 槽位图片地址（空串 = 无图，越界且邻章未预载）。 */
  private imageForSlot(slot: number): string {
    const images: string[] = this.curImages;
    const index: number = this.pageIndex + slot;
    if (index >= 0 && index < images.length) {
      return images[index];
    }
    if (index < 0) {
      return this.prevImages.length > 0 ? this.prevImages[this.prevImages.length - 1] : '';
    }
    return this.nextImages.length > 0 ? this.nextImages[0] : '';
  }

  // ---------------------------------------------------------------------------
  // 图片预解码（PixelMap 缓存：翻页提交同帧渲染，杜绝旧图残留闪帧）
  // ---------------------------------------------------------------------------

  /** 刷新三槽位图源（页面状态或解码完成后调用；整体替换驱动槽位重渲染）。 */
  private refreshSlotSources(): void {
    const sources: Array<image.PixelMap | string> = [];
    for (let slot: number = -1; slot <= 1; slot++) {
      const url: string = this.imageForSlot(slot);
      const map: image.PixelMap | undefined = url.length > 0 ? this.pixelCache.get(url) : undefined;
      sources.push(map !== undefined ? map : url);
    }
    this.slotSources = sources;
  }

  /** 预解码当前三槽位图（上下滚动模式跳过）。 */
  private preloadVisiblePixels(): void {
    if (this.comicFlipIndex === 2 || this.curImages.length === 0) {
      return;
    }
    this.refreshSlotSources();
    for (let slot: number = -1; slot <= 1; slot++) {
      this.ensurePixelMap(this.imageForSlot(slot));
    }
  }

  /** 预解码单图（缓存/在途去重；失败记录 + 日志 + 一次性 toast 诊断，可重试）。 */
  private ensurePixelMap(url: string): void {
    if (url.length === 0 || this.pixelCache.has(url) || this.pixelInflight.has(url)) {
      return;
    }
    this.pixelInflight.add(url);
    ComicPage.fetchPixelMap(url).then((map: image.PixelMap) => {
      this.pixelInflight.delete(url);
      if (this.disposed) {
        this.releasePixelMapQuietly(map);
        return;
      }
      this.pixelFailed.delete(url);
      this.pixelCache.set(url, map);
      this.pixelOrder.push(url);
      this.trimPixelCache();
      this.refreshSlotSources();
    }).catch((error: BusinessError) => {
      this.pixelInflight.delete(url);
      if (this.disposed) {
        return;
      }
      this.pixelFailed.add(url);
      hilog.error(0x0000, FQ_COMIC_TAG, 'fetchPixelMap failed: %{public}s code=%{public}d message=%{public}s',
        url, error.code, error.message);
      if (!this.decodeFailToastShown) {
        this.decodeFailToastShown = true;
        promptAction.showToast({ message: '图片预载失败，已回退在线加载', duration: 2000 });
      }
    });
  }

  /** 翻页目标页图源是否就绪（FqReaderFlip canTurn 门禁）：
   *  已解码 / 无图 / 曾失败（回退 URL 兜底）→ 放行；未就绪 → 拒绝并触发预解码。 */
  private flipTargetReady(isNext: boolean): boolean {
    const url: string = this.imageForSlot(isNext ? 1 : -1);
    if (url.length === 0 || this.pixelCache.has(url) || this.pixelFailed.has(url)) {
      return true;
    }
    this.ensurePixelMap(url);
    return false;
  }

  /** 下载并解码网络图片（http → ArrayBuffer → ImageSource → PixelMap）；
   *  本地离线图片（file://）直接读盘解码，不走网络。 */
  private static async fetchPixelMap(url: string): Promise<image.PixelMap> {
    if (url.startsWith('file://')) {
      return ComicPage.fetchLocalPixelMap(url.substring('file://'.length));
    }
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true,
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const result: string | Object | ArrayBuffer = response.result;
      if (!(result instanceof ArrayBuffer)) {
        throw new Error('图片数据格式异常');
      }
      const source: image.ImageSource = image.createImageSource(result);
      const map: image.PixelMap = await source.createPixelMap();
      source.release();
      return map;
    } finally {
      client.destroy();
    }
  }

  /** 本地图片解码（读盘 → ImageSource → PixelMap）。 */
  private static async fetchLocalPixelMap(path: string): Promise<image.PixelMap> {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      const source: image.ImageSource = image.createImageSource(buffer);
      const map: image.PixelMap = await source.createPixelMap();
      source.release();
      return map;
    } finally {
      fs.closeSync(file);
    }
  }

  /** LRU 淘汰超限条目（当前三槽位在用条目跳过；上限 12 张约 60-80MB 解码内存，
   *  减少快翻场景邻图淘汰后的回退重解码）。 */
  private trimPixelCache(): void {
    const cap: number = 12;
    while (this.pixelOrder.length > cap) {
      let evicted: boolean = false;
      for (let index: number = 0; index < this.pixelOrder.length; index++) {
        const url: string = this.pixelOrder[index];
        if (this.urlInUse(url)) {
          continue;
        }
        this.pixelOrder.splice(index, 1);
        const map: image.PixelMap | undefined = this.pixelCache.get(url);
        this.pixelCache.delete(url);
        if (map !== undefined) {
          this.releasePixelMapQuietly(map);
        }
        evicted = true;
        break;
      }
      if (!evicted) {
        break;
      }
    }
  }

  /** URL 是否被当前三槽位显示（淘汰保护）。 */
  private urlInUse(url: string): boolean {
    return this.imageForSlot(-1) === url || this.imageForSlot(0) === url || this.imageForSlot(1) === url;
  }

  private releasePixelMapQuietly(map: image.PixelMap): void {
    try {
      map.release();
    } catch (error) {
      // 释放失败忽略
    }
  }

  /** 释放全部预解码图片（页面销毁）。 */
  private releasePixelCache(): void {
    this.pixelCache.forEach((map: image.PixelMap): void => {
      this.releasePixelMapQuietly(map);
    });
    this.pixelCache.clear();
    this.pixelOrder = [];
    this.pixelInflight.clear();
    this.pixelFailed.clear();
  }

  /** 槽位图所属章下标（-1 无章）。 */
  private slotChapterIndex(slot: number): number {
    const index: number = this.pageIndex + slot;
    if (index >= 0 && index < this.curImages.length) {
      return this.chapterIndex;
    }
    if (index < 0) {
      return this.pageIndex > 0 ? this.chapterIndex
        : (this.prevImages.length > 0 ? this.chapterIndex - 1 : -1);
    }
    return this.pageIndex + 1 < this.curImages.length ? this.chapterIndex
      : (this.nextImages.length > 0 ? this.chapterIndex + 1 : -1);
  }

  /** 槽位图在所属章内的图片下标（-1 无图）。 */
  private slotImageInChapter(slot: number): number {
    const index: number = this.pageIndex + slot;
    if (index >= 0 && index < this.curImages.length) {
      return index;
    }
    if (index < 0) {
      return this.prevImages.length > 0 ? this.prevImages.length - 1 : -1;
    }
    return this.nextImages.length > 0 ? 0 : -1;
  }

  /** 槽位所属章图片总数（0 无图）。 */
  private slotChapterImageCount(slot: number): number {
    const chapter: number = this.slotChapterIndex(slot);
    if (chapter === this.chapterIndex) {
      return this.curImages.length;
    }
    if (chapter === this.chapterIndex - 1) {
      return this.prevImages.length;
    }
    if (chapter === this.chapterIndex + 1) {
      return this.nextImages.length;
    }
    return 0;
  }

  /** 槽位所属章标题。 */
  private slotChapterTitle(slot: number): string {
    const chapter: number = this.slotChapterIndex(slot);
    const item: FqChapter | undefined = this.chapters[chapter];
    return item !== undefined ? item.title : '';
  }

  /** 槽位眉页：章节名（菜单弹出淡出；空槽位不渲染，随仿真截图卷曲）。 */
  @Builder
  private slotHeader(slot: number) {
    if (!this.menuVisible && this.slotChapterIndex(slot) >= 0) {
      Text(this.slotChapterTitle(slot))
        .fontColor(FQ_COMIC_TEXT)
        .fontSize(14)
        .opacity(0.5)
        .maxLines(1)
        .width('100%')
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 20, right: 20 })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
    }
  }

  /** 槽位眉脚：左时钟+电量图标，右章内图序（菜单弹出淡出，随仿真截图卷曲）。 */
  @Builder
  private slotFooter(slot: number) {
    if (!this.menuVisible && this.slotChapterIndex(slot) >= 0) {
      Row({ space: 5 }) {
        Text(this.footerClock)
          .fontColor(FQ_COMIC_TEXT)
          .fontSize(12)
          .opacity(0.5)
          .maxLines(1)
        SymbolGlyph(this.batteryIcon())
          .fontSize(14)
          .fontColor([FQ_COMIC_TEXT])
          .opacity(0.5)
        Blank()
        Text(this.slotFooterPages(slot))
          .fontColor(FQ_COMIC_TEXT)
          .fontSize(12)
          .opacity(0.5)
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 20, right: 20 })
      .hitTestBehavior(HitTestMode.None)
      .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
    }
  }

  /** 眉脚章内图序：第N张/共M张。 */
  private slotFooterPages(slot: number): string {
    const count: number = this.slotChapterImageCount(slot);
    const image: number = this.slotImageInChapter(slot);
    if (count <= 0 || image < 0) {
      return '';
    }
    return `${image + 1}/${count}`;
  }

  private flipHasPrev(): boolean {
    return this.pageIndex > 0 || (this.chapterIndex > 0 && this.prevImages.length > 0);
  }

  private flipHasNext(): boolean {
    return this.pageIndex + 1 < this.curImages.length
      || (this.chapterIndex + 1 < this.totalChapters && this.nextImages.length > 0);
  }

  /** 翻页完成：章内翻图或跨章切换（邻章已预载时无缝，未就绪回退整章加载）。 */
  private onFlipTurn(isNext: boolean): void {
    if (isNext) {
      if (this.pageIndex + 1 < this.curImages.length) {
        this.pageIndex += 1;
        this.saveProgressNow();
      } else if (this.nextImages.length > 0) {
        this.markChapterRead(this.chapterIndex);
        this.switchToChapter(this.nextImages, this.chapterIndex + 1, 0);
      } else if (this.chapterIndex + 1 < this.totalChapters) {
        this.markChapterRead(this.chapterIndex);
        this.openChapter(this.chapterIndex + 1, '');
      }
    } else {
      if (this.pageIndex - 1 >= 0) {
        this.pageIndex -= 1;
        this.saveProgressNow();
      } else if (this.prevImages.length > 0) {
        const lastIndex: number = Math.max(0, this.prevImages.length - 1);
        this.switchToChapter(this.prevImages, this.chapterIndex - 1, lastIndex);
      } else if (this.chapterIndex > 0) {
        this.openChapter(this.chapterIndex - 1, '');
      }
    }
    this.preloadVisiblePixels();
  }

  /** 邻章无缝切换（预载就绪后的跨章翻页路径；旧章图片顺势转为反向邻章）。 */
  private switchToChapter(targetImages: string[], targetChapter: number, pageIndex: number): void {
    const oldImages: string[] = this.curImages;
    const goingNext: boolean = targetChapter > this.chapterIndex;
    this.curImages = targetImages;
    this.chapterIndex = targetChapter;
    this.pageIndex = pageIndex;
    if (goingNext) {
      this.prevImages = oldImages;
      this.nextImages = [];
    } else {
      this.nextImages = oldImages;
      this.prevImages = [];
    }
    this.saveProgressNow();
    this.preloadVisiblePixels();
    this.preloadNeighbors(this.loadToken);
  }

  // ---------------------------------------------------------------------------
  // 上下滚动模式（webtoon）
  // ---------------------------------------------------------------------------

  /** 上下滚动模式正文：整章图片连续纵向滚动，滚到章尾自动追加下一话。 */
  @Builder
  private VerticalBody() {
    Column() {
      List({ scroller: this.verticalScroller }) {
        LazyForEach(this.verticalSource, (item: FqComicImageItem) => {
          ListItem() {
            Image(item.url)
              .width('100%')
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }
        }, (item: FqComicImageItem): string => `${item.chapterIndex}_${item.imageIndex}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .cachedCount(4)
      .onScrollIndex((first: number, last: number): void => {
        this.onVerticalScrollIndex(first);
      })
      .onReachEnd((): void => {
        this.onVerticalReachEnd();
      })
      .onClick((): void => {
        this.toggleMenu();
      })

      if (this.verticalAppending) {
        Row({ space: 8 }) {
          CommonLoading({ sizeValue: 18, loadColor: FQ_COMIC_TEXT })
          Text('正在加载下一话')
            .fontSize(12)
            .fontColor(FQ_COMIC_TEXT)
            .opacity(0.6)
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(FQ_COMIC_BG)
  }

  /** 上下滚动模式重建：当前章图片入源并定位（startImage 章内图下标）。 */
  private buildVertical(startImage: number): void {
    this.verticalSource.reset();
    this.verticalEndedToastOnce = false;
    const images: string[] = this.curImages;
    for (let i: number = 0; i < images.length; i++) {
      this.verticalSource.append(new FqComicImageItem(this.chapterIndex, i, images[i]));
    }
    const target: number = Math.min(Math.max(0, startImage), Math.max(0, images.length - 1));
    setTimeout((): void => {
      if (this.verticalSource.totalCount() > target) {
        this.verticalScroller.scrollToIndex(target, false);
      }
    }, 50);
  }

  /** 滚动位置 → 阅读进度（首可见条目所属章/图，驱动目录定位与进度持久化）。 */
  private onVerticalScrollIndex(first: number): void {
    if (first < 0 || first >= this.verticalSource.totalCount()) {
      return;
    }
    const item: FqComicImageItem = this.verticalSource.getData(first);
    if (item.chapterIndex !== this.chapterIndex || item.imageIndex !== this.pageIndex) {
      if (item.chapterIndex > this.chapterIndex) {
        // 上下滚动滚进后话 = 前话已整话读过
        this.markChapterRead(this.chapterIndex);
      }
      this.chapterIndex = item.chapterIndex;
      this.pageIndex = item.imageIndex;
      this.saveProgressNow();
    }
  }

  /** 滚到章尾：追加下一话图片；无下话提示一次。 */
  private onVerticalReachEnd(): void {
    if (this.verticalAppending || this.loadingState) {
      return;
    }
    const nextIndex: number = this.chapterIndex + 1;
    if (nextIndex >= this.totalChapters) {
      if (!this.verticalEndedToastOnce) {
        this.verticalEndedToastOnce = true;
        promptAction.showToast({ message: '已经是最后一话了', duration: 1500 });
      }
      return;
    }
    this.appendVerticalChapter(nextIndex);
  }

  private async appendVerticalChapter(index: number): Promise<void> {
    const token: number = this.loadToken;
    this.verticalAppending = true;
    try {
      const images: string[] = await this.fetchChapterImages(index);
      if (token !== this.loadToken) {
        return;
      }
      for (let i: number = 0; i < images.length; i++) {
        this.verticalSource.append(new FqComicImageItem(index, i, images[i]));
      }
    } catch (error) {
      promptAction.showToast({ message: fqErrorMessage(error), duration: 1500 });
    }
    this.verticalAppending = false;
  }

  // ---------------------------------------------------------------------------
  // 行为（对齐 ReaderPage）
  // ---------------------------------------------------------------------------

  /** ReadBar 悬浮工具条分发：目录 / 设置 / 上一话 / 下一话。 */
  private onReadBarAction(key: string): void {
    if (key === '目录') {
      this.openSheet();
    } else if (key === '设置') {
      DialogManager.OpenDialog('漫画设置');
    } else if (key === '上一章') {
      this.openPrev();
    } else if (key === '下一章') {
      this.openNext();
    }
  }

  /** 系统返回：先关漫评/目录半模态，再关菜单，最后放行返回上一页。 */
  private handleBackPressed(): boolean {
    if (this.commentSheetVisible) {
      this.onCommentSheetClose();
      return true;
    }
    if (this.sheetVisible) {
      this.onSheetClose();
      return true;
    }
    if (this.menuVisible) {
      this.menuVisible = false;
      return true;
    }
    // 返回放行前先恢复系统状态栏（aboutToDisappear 里仍兜底恢复一次）
    this.applySystemBar(true);
    return false;
  }

  /** 沉浸控制：阅读时隐藏系统状态栏，菜单呼出（标题栏/工具栏出现）时恢复。 */
  @Monitor('menuVisible')
  onMenuVisibleChange(): void {
    this.applySystemBar(this.menuVisible);
  }

  private applySystemBar(show: boolean): void {
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window) => {
      if (show) {
        win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        win.setWindowSystemBarEnable(['navigation']);
      }
    }).catch((): void => {
    });
  }

  /** 避让区高度（供 @Monitor 监听状态栏/手势条变化）。 */
  @Computed
  get avoidBottom(): number {
    return appState.bottomRect;
  }

  @Computed
  get avoidTop(): number {
    return appState.maxTopRect;
  }

  /** 避让区变化：更新翻页容器眉页/眉脚区高。 */
  @Monitor('avoidBottom', 'avoidTop')
  onAvoidAreaChange(): void {
    this.updateZones();
  }

  private updateZones(): void {
    this.headerZoneVp = Math.max(appState.maxTopRect, 32) + 22;
    this.footerZoneVp = appState.bottomRect + 40;
    const body: number = this.bodyHeightVp > 0 ? this.bodyHeightVp : this.screenHeightVp();
    const height: number = body - 100;
    this.pagedImageHeightVp = height;
  }

  /** 内容区窗口纵坐标基线（vp，globalPosition.y；-1 = 未测）：
   *  标题栏收起（容器最靠上）时的位置，呼出下压按此差值上补偿。 */
  private bodyTopBaseVp: number = -1;

  /** 外层实测（onAreaChange）：
   *  - 高度基线（bodyHeightVp）：容器最大高（标题栏收起），内层阅读体按此定高，容器压缩不再重排；
   *  - 顶压补偿（bodyTopCompVp）= 当前窗口纵坐标 - 基线（globalPosition.y）：
   *    标题栏呼出把内容区整体下压 → 上移等量钉回窗口原位；底部压缩（ReadBar）不改变
   *    顶坐标 → 零补偿，仅靠定高保持不动。两类压缩均不产生图片位移。 */
  private onBodyAreaChange(area: Area): void {
    const heightVp: number = typeof area.height === 'number' ? area.height : 0;
    const topVp: number = typeof area.globalPosition.y === 'number' ? area.globalPosition.y : -1;
    if (heightVp <= 0) {
      return;
    }
    if (this.bodyHeightVp <= 0 || heightVp >= this.bodyHeightVp) {
      if (this.bodyHeightVp !== heightVp) {
        this.bodyHeightVp = heightVp;
        this.updateZones();
      }
    }
    if (topVp < 0) {
      return;
    }
    if (this.bodyTopBaseVp < 0 || topVp <= this.bodyTopBaseVp) {
      this.bodyTopBaseVp = topVp;
    }
    const comp: number = topVp - this.bodyTopBaseVp;
    this.bodyTopCompVp = comp > 0.5 ? comp : 0;
  }

  /** 窗口高（vp，含避让区整屏）。 */
  private screenHeightVp(): number {
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    return (appState.screenHeight > 0 ? appState.screenHeight : displayData.height) / density;
  }

  /** 窗口宽度/高度（供 @Monitor 监听小窗/全屏切换）。 */
  @Computed
  get windowWidth(): number {
    return appState.screenWidth;
  }

  @Computed
  get windowHeight(): number {
    return appState.screenHeight;
  }

  /** 窗口尺寸变化：重置实测基线（onAreaChange 重新校准），更新眉页/眉脚区。 */
  @Monitor('windowWidth', 'windowHeight')
  onWindowSizeChange(): void {
    this.bodyHeightVp = 0;
    this.bodyTopCompVp = 0;
    this.bodyTopBaseVp = -1;
    this.updateZones();
  }

  /** 眉脚电量图标：按系统电量映射到档位图标资源。 */
  private batteryIcon(): Resource {
    const level: number = this.batteryLevel;
    if (level >= 100) {
      return $r('sys.symbol.battery_100percent');
    }
    if (level >= 95) {
      return $r('sys.symbol.battery_95percent');
    }
    if (level >= 90) {
      return $r('sys.symbol.battery_90percent');
    }
    if (level >= 80) {
      return $r('sys.symbol.battery_80percent');
    }
    if (level >= 75) {
      return $r('sys.symbol.battery_75percent');
    }
    if (level >= 70) {
      return $r('sys.symbol.battery_70percent');
    }
    if (level >= 60) {
      return $r('sys.symbol.battery_60percent');
    }
    if (level >= 50) {
      return $r('sys.symbol.battery_50percent');
    }
    if (level >= 40) {
      return $r('sys.symbol.battery_40percent');
    }
    if (level >= 30) {
      return $r('sys.symbol.battery_30percent');
    }
    if (level >= 20) {
      return $r('sys.symbol.battery_20percent');
    }
    if (level >= 15) {
      return $r('sys.symbol.battery_15percent');
    }
    if (level >= 10) {
      return $r('sys.symbol.battery_10percent');
    }
    return $r('sys.symbol.battery_5percent');
  }

  /** 刷新眉脚时钟与电量（启动时与 30s 定时器调用）。 */
  private refreshFooterStatus(): void {
    const now: Date = new Date();
    const hours: number = now.getHours();
    const minutes: number = now.getMinutes();
    const hh: string = hours < 10 ? `0${hours}` : `${hours}`;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    this.footerClock = `${hh}:${mm}`;
    this.batteryLevel = batteryInfo.batterySOC;
  }

  private openSheet(): void {
    this.sheetOpenToken += 1;
    this.sheetVisible = true;
  }

  private onSheetClose(): void {
    this.sheetVisible = false;
  }

  private hasPrev(): boolean {
    return this.chapterIndex > 0;
  }

  private hasNext(): boolean {
    return this.chapterIndex < this.totalChapters - 1;
  }

  private toggleMenu(): void {
    if (this.sheetVisible) {
      this.onSheetClose();
      return;
    }
    this.getUIContext().animateTo({ duration: 300 }, (): void => {
      this.menuVisible = !this.menuVisible;
    });
  }

  private openCommentSheet(): void {
    this.commentSheetVisible = true;
  }

  private onCommentSheetClose(): void {
    this.commentSheetVisible = false;
  }

  private openPrev(): void {
    if (!this.hasPrev()) {
      return;
    }
    this.openChapter(this.chapterIndex - 1, '');
  }

  private openNext(): void {
    if (!this.hasNext()) {
      return;
    }
    this.markChapterRead(this.chapterIndex);
    this.openChapter(this.chapterIndex + 1, '');
  }

  private jumpToChapter(index: number): void {
    this.onSheetClose();
    if (index < 0 || index >= this.totalChapters || index === this.chapterIndex) {
      return;
    }
    this.openChapter(index, '');
  }

  private retry(): void {
    if (this.chapters.length === 0) {
      this.load();
    } else {
      this.openChapter(this.chapterIndex, '');
    }
  }

  // ---------------------------------------------------------------------------
  // 设置（fqComicSettingsBus 桥接「漫画设置」弹窗）
  // ---------------------------------------------------------------------------

  /** 弹窗宿主在 Index：镜像翻页方式并注册变更处理器（弹窗内容实时刷新）。 */
  private attachSettingsBus(): void {
    fqComicSettingsBus.comicFlipIndex = this.comicFlipIndex;
    fqComicSettingsBus.handler = {
      changeFlip: (index: number): void => {
        this.changeFlip(index);
      },
    };
  }

  /** 切换翻页方式：0/1 仅换渲染模式，进出上下滚动模式时迁移阅读位置。 */
  private changeFlip(index: number): void {
    if (index === this.comicFlipIndex || index < 0 || index > 2) {
      return;
    }
    const prevMode: number = this.comicFlipIndex;
    this.comicFlipIndex = index;
    FqReaderStore.saveComicFlip(index);
    fqComicSettingsBus.comicFlipIndex = index;
    if (prevMode === 2) {
      // 上下 → 仿真/覆盖：缓存命中直接还原分页态，缺失回退整章重载
      this.restorePagedFromVertical();
    } else {
      // 仿真/覆盖 → 上下：当前章图片入源并定位
      this.buildVertical(this.pageIndex);
    }
  }

  /** 上下 → 分页：按当前滚动位置还原当前章分页态。 */
  private restorePagedFromVertical(): void {
    const images: string[] | undefined = this.chapterImageCache.get(this.chapterIndex);
    if (images === undefined || images.length === 0) {
      this.openChapter(this.chapterIndex, `img:${this.pageIndex}`);
      return;
    }
    this.curImages = images;
    if (this.pageIndex >= images.length) {
      this.pageIndex = Math.max(0, images.length - 1);
    }
    this.prevImages = [];
    this.nextImages = [];
    this.saveProgressNow();
    this.preloadVisiblePixels();
    this.preloadNeighbors(this.loadToken);
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  private async load(): Promise<void> {
    if (this.bookId.length === 0) {
      this.errorMsg = '无效的作品';
      this.loadingState = false;
      return;
    }
    const token: number = ++this.loadToken;
    this.loadingState = true;
    this.errorMsg = '';
    this.readChapters = FqReaderStore.getReadChapters(this.bookId);
    try {
      await FqBackend.get().start(getContext(this));
      const chapters: FqChapter[] =
        await FqBackend.get().directoryChapters(this.bookId, fqKindToTab('manga'));
      if (token !== this.loadToken) {
        return;
      }
      if (chapters.length === 0) {
        this.errorMsg = '未获取到目录章节';
        this.loadingState = false;
        return;
      }
      this.chapters = chapters;
      this.totalChapters = chapters.length;
      const progress: FqReaderProgress = FqReaderStore.getProgress(this.bookId);
      let index: number = this.startChapterIndex;
      let domPos: string = '';
      if (index < 0 || index >= chapters.length) {
        index = progress.chapterIndex >= 0 && progress.chapterIndex < chapters.length
          ? progress.chapterIndex : 0;
        domPos = index === progress.chapterIndex ? progress.domPos : '';
      }
      await this.openChapter(index, domPos);
    } catch (error) {
      if (token === this.loadToken) {
        this.errorMsg = fqErrorMessage(error);
        this.loadingState = false;
      }
    }
  }

  private async openChapter(index: number, domPos: string): Promise<void> {
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return;
    }
    const token: number = ++this.loadToken;
    hilog.info(0x0001, 'ComicPage', `openChapter index=${index} domPos=${domPos}`);
    this.menuVisible = false;
    this.onSheetClose();
    this.chapterIndex = index;
    this.loadingState = true;
    this.errorMsg = '';
    try {
      const images: string[] = await this.fetchChapterImages(index);
      if (token !== this.loadToken) {
        return;
      }
      if (images.length === 0) {
        this.errorMsg = '本话内容为空';
        this.loadingState = false;
        return;
      }
      this.curImages = images;
      this.prevImages = [];
      this.nextImages = [];
      this.pageIndex = this.restoreImageIndex(domPos, images.length);
      this.loadingState = false;
      this.saveProgressNow();
      if (this.comicFlipIndex === 2) {
        this.buildVertical(this.pageIndex);
      } else {
        this.preloadVisiblePixels();
      }
      this.preloadNeighbors(token);
    } catch (error) {
      if (token === this.loadToken) {
        this.errorMsg = fqErrorMessage(error);
        this.loadingState = false;
      }
    }
  }

  /** 章图片获取（三层：会话缓存 → 离线整话（本地文件）→ 列表缓存（秒开）
   *  → 请求后端并回填列表缓存）。 */
  private async fetchChapterImages(index: number): Promise<string[]> {
    const cached: string[] | undefined = this.chapterImageCache.get(index);
    if (cached !== undefined) {
      return cached;
    }
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return [];
    }
    // 离线层：整话已下载 → file:// 本地路径，不走网络
    const local: string[] | null =
      FqComicCacheStore.cachedChapterImages(this.bookId, chapter.itemId);
    if (local !== null) {
      this.chapterImageCache.set(index, local);
      return local;
    }
    // 秒开层：图片 URL 列表缓存命中（TTL 内），列表不再请求后端
    const listCache: string[] | null =
      FqComicCacheStore.cachedImageList(this.bookId, chapter.itemId);
    if (listCache !== null) {
      this.chapterImageCache.set(index, listCache);
      return listCache;
    }
    const images: string[] = await FqBackend.get().chapterImages(chapter.itemId);
    if (images.length > 0) {
      this.chapterImageCache.set(index, images);
      FqComicCacheStore.saveImageList(this.bookId, chapter.itemId, images);
    }
    return images;
  }

  /** 邻章预载（后台，token 保护；先 next 后 prev；上下滚动模式按需追加不预载）。 */
  private async preloadNeighbors(token: number): Promise<void> {
    if (this.comicFlipIndex === 2) {
      return;
    }
    const nextIndex: number = this.chapterIndex + 1;
    if (nextIndex < this.totalChapters && this.nextImages.length === 0) {
      try {
        const images: string[] = await this.fetchChapterImages(nextIndex);
        if (token === this.loadToken && images.length > 0) {
          this.nextImages = images;
          // 跨章目标从 URL 兜底变为真实地址 → 立即刷新槽位并预解码（否则跨章翻页必走 URL 路径闪旧页）
          this.preloadVisiblePixels();
        }
      } catch (error) {
        // 邻章预载失败不阻断（跨章时回退整章加载路径）
      }
    }
    if (token !== this.loadToken) {
      return;
    }
    const prevIndex: number = this.chapterIndex - 1;
    if (prevIndex >= 0 && this.prevImages.length === 0) {
      try {
        const images: string[] = await this.fetchChapterImages(prevIndex);
        if (token === this.loadToken && images.length > 0) {
          this.prevImages = images;
          this.preloadVisiblePixels();
        }
      } catch (error) {
        // 邻章预载失败不阻断
      }
    }
  }

  /** 恢复图下标：'img:N' 进度解析，非法/越界回退首图。 */
  private restoreImageIndex(domPos: string, total: number): number {
    if (domPos.startsWith('img:')) {
      const n: number = parseInt(domPos.substring(4), 10);
      if (!Number.isNaN(n) && n >= 0 && n < total) {
        return n;
      }
    }
    return 0;
  }

  /** 进度持久化：domPos = 'img:章内图下标'。 */
  private saveProgressNow(): void {
    if (this.chapters.length === 0
      || this.chapterIndex < 0 || this.chapterIndex >= this.chapters.length) {
      return;
    }
    FqReaderStore.saveProgress(this.bookId, this.chapterIndex, `img:${this.pageIndex}`);
  }

  /** 章节已读进度：当前章按图位置计百分比、读毕章节 100%、未读章节 0%。 */
  private chapterProgressText(idx: number): string {
    if (idx === this.chapterIndex) {
      const total: number = this.curImages.length;
      if (total <= 0) {
        return '0%';
      }
      const pct: number = Math.round(((this.pageIndex + 1) / total) * 100);
      return `${Math.min(Math.max(pct, 1), 100)}%`;
    }
    return this.readChapters.has(idx) ? '100%' : '0%';
  }

  /** 标记章节读毕（翻过章末/下一话/上下滚动进后章时调用；目录跳转不标记）。 */
  private markChapterRead(index: number): void {
    if (index < 0 || this.readChapters.has(index)) {
      return;
    }
    this.readChapters.add(index);
    FqReaderStore.saveReadChapters(this.bookId, this.readChapters);
  }

  // ---------------------------------------------------------------------------
  // 半模态装配
  // ---------------------------------------------------------------------------

  /** 目录半模态：公共 FqCatalogSheet（搜索/排序/定位/进度自理）。 */
  @Builder
  private CatalogSheet() {
    FqCatalogSheet({
      chapters: this.chapters,
      fontColor: $r('sys.color.font_primary'),
      currentChapterIndex: this.chapterIndex,
      progressOf: (index: number): string => this.chapterProgressText(index),
      openToken: this.sheetOpenToken,
      contentEndExtra: 56,
      chapterClick: (index: number): void => {
        this.jumpToChapter(index);
      },
    })
  }

  /** 漫评半模态：公共 FqCommentSheet（首拉 Loading / 错误重试 / 空态 / 分页列表）。 */
  @Builder
  private CommentSheet() {
    FqCommentSheet({
      bookId: this.bookId,
      fontColor: $r('sys.color.font_primary'),
      commentLabel: '漫评',
    })
  }

  /** 离线缓存选话半模态（公共 FqCacheSheet 组件，标题栏下载键呼出）。 */
  @Builder
  private CacheSheetBuilder() {
    FqCacheSheet({
      sheetTitle: `离线缓存 · ${this.bookTitle}`,
      items: this.chapters,
      currentIndex: this.chapterIndex,
      downloadedIds: this.cacheDownloadedIds,
      taskViewOf: (itemId: string): FqCacheTaskView | null =>
        this.dl.taskOfItem(this.bookId, itemId),
      openToken: this.cacheOpenToken,
      itemLabel: '话',
      manageClick: (): void => {
        this.closeCacheSheet();
        NavPathUtils.push(ROUTE_CACHED_COMICS);
      },
      closeClick: (): void => {
        this.closeCacheSheet();
      },
      download: (itemIds: string[]): void => {
        this.confirmCacheDownload(itemIds);
      },
      taskClick: (itemId: string): void => {
        this.onCacheTaskClick(itemId);
      },
    })
  }

  /** 缓存 sheet 高度（屏高 75%，vp）。 */
  private fqRatioSheetHeightVp(): number {
    return Math.round(this.screenHeightVp() * 0.75);
  }

  /** 打开离线缓存选话半模态：刷新当前书已离线集合后呼出。 */
  private openCacheSheet(): void {
    if (this.chapters.length === 0) {
      promptAction.showToast({ message: '目录加载中', duration: 1500 });
      return;
    }
    this.cacheDownloadedIds = FqComicCacheStore.cachedItemIds(this.bookId);
    this.cacheOpenToken += 1;
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.cacheSheetVisible = true;
    });
  }

  /** 关闭离线缓存半模态：延迟一拍置 isShow（面板事件内同步改 isShow 会被框架丢弃）。 */
  private closeCacheSheet(): void {
    const token: number = ++this.cacheCloseToken;
    setTimeout((): void => {
      if (token === this.cacheCloseToken) {
        this.getUIContext().animateTo({ duration: 200 }, (): void => {
          this.cacheSheetVisible = false;
        });
      }
    }, 0);
  }

  /** 下载勾选话（FqCacheSheet 回传 itemId 数组；已离线/已在队列的 enqueue 内部跳过）。 */
  private confirmCacheDownload(itemIds: string[]): void {
    if (itemIds.length === 0) {
      return;
    }
    for (let i: number = 0; i < this.chapters.length; i++) {
      const chapter: FqChapter | undefined = this.chapters[i];
      if (chapter !== undefined && itemIds.includes(chapter.itemId)) {
        this.dl.enqueue(this.bookId, chapter.itemId, chapter.title,
          this.bookTitle, i + 1);
      }
    }
  }

  /** 缓存任务格点击（FqCacheSheet 转发）：失败重试 / 暂停继续。 */
  private onCacheTaskClick(itemId: string): void {
    const task: FqComicDownloadTask | null = this.dl.taskOfItem(this.bookId, itemId);
    if (task === null) {
      return;
    }
    if (task.status === ComicDownloadStatus.Failed) {
      this.dl.retry(task.key);
    } else if (task.status === ComicDownloadStatus.Paused) {
      this.dl.resume(task.key);
    }
  }
}

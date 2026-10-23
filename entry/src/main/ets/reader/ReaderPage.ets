/**
 * 自定义小说阅读页（ReaderPage，CommonNav 框架，不依赖 Reader Kit）：
 * 与 ReaderPage（官方 ReadPageComponent 版）UI 保持一致，正文由自研分页排版
 * 引擎渲染（FqPagination）：
 * - 分页：章节段落（fqNormalizeChapterText 产物）+ measure 断行 → 页片段/行，
 *   逐行独立 Text 渲染（断行零分歧）；
 * - 翻页：FqReaderFlip 三层 Stack（覆盖模式 = 仿真翻页过渡实现 / 平移横滑），
 *   拖动跟手 + 松手阈值判定，邻章预载后跨章无缝衔接；
 * - 段评：段尾气泡（引擎装页时记录命中区，翻页容器触区代理点击）→ 段评半模态
 *   （Provider 抽象，默认演示数据源，后端段落接口确认后替换）；
 * - 眉页（章节名）/眉脚（时钟/电量/整书页码估算）、目录半模态（搜索/定位/排序）、
 *   书评半模态（懒加载分页）、阅读设置公共弹窗、沉浸状态栏、进度与设置持久化，
 *   均与 ReaderPage 行为对齐。
 * 进度编码：domPos = 'p2:段下标:段内字符'（与 ReaderPage 的 Kit 进度格式互不解析，
 * 无前缀进度回退章首）。
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { CustomContentDialog, display, window } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsAnimationMode, HdsTabsController, TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqChapter, fqFormatCountInt, fqKindToTab } from '../model/FqModels';
import { FqReaderProgress, FqReaderStore } from '../core/FqReaderStore';
import { FqReadStatsStore } from '../core/FqReadStatsStore';
import { FqLocalBookStore } from '../core/FqLocalBookStore';
import { ReaderNavParams } from '../model/FqNavModels';
import { CommonNav, titleBarOf } from '../view/CommonNav';
import { CommonLoading, FQ_ACCENT } from '../view/CommonCom';
import { CommonSheet, FqSheetOptions } from '../view/CommonSheet';
import { FqCommentSheet, fqCommentSheetHeightVp } from '../view/FqCommentSheet';
import { FqCatalogSheet } from '../view/FqCatalogSheet';
import { FQ_FONT_OPTIONS, FqFontOption } from '../core/FqOnlineParser';
import { fqAudioSession } from '../core/FqAudioSession';
import { FqSubtitleCue, FqSubtitleTrack } from '../model/FqAudioModels';
import { appState } from '../entryability/AppState';
import { themeUtils } from '../utils/ThemeUtils';
import { DialogManager } from '../utils/DialogUtils';
import { FQ_READER_THEMES, FqReaderTheme, ReaderSettingsDialogContent } from '../view/dialog/ReaderSettingsDialogContent';
import {
  FQ_BUBBLE_GAP_VP,
  FQ_DEMO_PARAGRAPH_COMMENTS,
  FqChapterLayout,
  FqDemoParagraphCommentProvider,
  FqEmptyParagraphCommentProvider,
  FqPageBubble,
  FqPageFragment,
  FqParagraphComment,
  FqParagraphCommentProvider,
  FqReaderLayoutMetrics,
  FqReaderPageData,
} from './ReaderTypes';
import { FqPageCanvas } from './FqPageCanvas';
import { FqReaderFlip } from './FqReaderFlip';
import { FqMeasureFn, FqPaginationEngine, fqPageIndexForPosition } from './FqPagination';

/** 眉页「第N章」前缀匹配（N 支持数字与中文数字，量词：章节回卷集话篇）。 */
const FQ_HEADER_PREFIX_RE: RegExp = new RegExp('^第[0-9零一二三四五六七八九十百千万]+[章节回卷集话篇]');

/** 眉页前缀剥离（含其后空白），用于提取纯章节名。 */
const FQ_HEADER_PREFIX_STRIP_RE: RegExp =
  new RegExp('^第[0-9零一二三四五六七八九十百千万]+[章节回卷集话篇]\\s*');

/** 目录懒加载数据源与目录 Sheet UI 已抽至 view/FqCatalogSheet.ets（与详情页共用）。 */

@ComponentV2
export struct ReaderPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local menuVisible: boolean = false;
  @Local sheetVisible: boolean = false;
  /** 目录打开令牌：每次打开 +1（公共 FqCatalogSheet 据此重置搜索/排序并定位当前章）。 */
  @Local sheetOpenToken: number = 0;
  /** 书评半模态（标题栏书评键呼出；内容为公共 FqCommentSheet）。 */
  @Local commentSheetVisible: boolean = false;
  /** 段评半模态（段尾气泡呼出）。 */
  @Local paraSheetVisible: boolean = false;
  @Local paraSheetParaIndex: number = -1;
  @Local paraComments: FqParagraphComment[] = [];
  @Local paraLoading: boolean = false;
  @Local paraError: string = '';
  /** 眉页/眉脚字体族（随阅读字体档位注册；空串回退系统默认）。 */
  @Local readerFontFamily: string = '';
  @Local chapterIndex: number = 0;
  @Local totalChapters: number = 0;
  @Local fontSize: number = 19;
  @Local lineHeight: number = 1.9;
  @Local themeIndex: number = 0;
  @Local flipIndex: number = 0;
  @Local fontIndex: number = 0;
  /** 当前章分页结果 / 邻章预载缓存（引用替换驱动翻页容器刷新）。 */
  @Local curLayout: FqChapterLayout | null = null;
  @Local prevLayout: FqChapterLayout | null = null;
  @Local nextLayout: FqChapterLayout | null = null;
  /** 当前页（章内页下标）。 */
  @Local pageIndex: number = 0;
  /** 眉脚时钟文本（HH:mm）与电量百分比（-1 未知）。 */
  @Local footerClock: string = '';
  @Local batteryLevel: number = -1;
  /** 当前页章内偏移（整书页码用）。 */
  @Local shownPageOffset: number = 0;
  /** 边听边读：高亮段落下标（-1 无高亮）。 */
  @Local highlightParaIndex: number = -1;
  /** 边听边读模式（进入时消费 ReaderNavParams.listenAlong）。 */
  private listenAlong: boolean = false;
  /** 上次已消费的字幕 cue 下标（-2 强制首刷）。 */
  private lastCueIndex: number = -2;
  /** 段落匹配游标（字幕与段落均单调，向前优先）。 */
  private paraCursor: number = 0;
  /** 去空白段落数组（字幕文本匹配用，与 curLayout.paragraphs 同步重建）。 */
  private normParas: string[] = [];
  private bookId: string = '';
  private kind: string = 'book';
  private bookTitle: string = '';
  private startChapterIndex: number = -1;
  private chapters: FqChapter[] = [];
  private filesDir: string = '';
  private loadToken: number = 0;
  private clockTimer: number = -1;
  private titleBarOp: TitleBarContentOptions | undefined = undefined;
  /** 排版几何缓存（重排/开章时重建，渲染期间引用稳定）。 */
  private cachedMetrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
  /** 段评数据源（演示开关切换；后端段落接口确认后替换实现）。 */
  private commentProvider: FqParagraphCommentProvider = FQ_DEMO_PARAGRAPH_COMMENTS
    ? new FqDemoParagraphCommentProvider() : new FqEmptyParagraphCommentProvider();
  /** 各章实测页数与冻结估算（整书页码，对齐 ReaderPage 行为）。 */
  private chapterPages: Map<number, number> = new Map();
  private chapterEstimate: Map<number, number> = new Map();

  /** 「阅读设置」公共弹窗：内容组件在 view/dialog，无标题无按钮仅内容区。 */
  private settingsDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      contentBuilder: (): void => {
        this.DialogContentBuilder(DialogManager.dialogChangeKey);
      },
      contentAreaPadding: { top: 20, bottom: 20, left: 24, right: 24 },
    }),
    alignment: DialogAlignment.Bottom,
    // 工具栏顶 = 窗口底 - (悬浮底边距28 + 栏高56)；弹窗 Bottom 基准为导航避让区底（比窗口底高 bottomRect）。
    // 窗口化时 bottomRect=0，动态计算保证弹窗始终贴工具栏上沿（手机全屏时 -84+bottomRect 仍为 -68）。
    offset: { dx: 0, dy: - appState.bottomRect - 84 },
    autoCancel: true,
    onWillDisappear: (): void => {
      DialogManager.DisappearDialog(DialogManager.dialogChangeKey);
    },
  });

  aboutToAppear(): void {
    this.bookId = ReaderNavParams.id;
    this.kind = ReaderNavParams.kind;
    this.bookTitle = ReaderNavParams.title;
    // 本地导入书籍无后端数据：隐藏段评入口
    const isLocalBook: boolean = FqLocalBookStore.isLocalBookId(this.bookId);
    if (isLocalBook) {
      this.titleBarOp = titleBarOf(this.bookTitle);
    } else {
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
      ]);
    }
    this.startChapterIndex = ReaderNavParams.chapterIndex;
    this.listenAlong = ReaderNavParams.listenAlong;
    ReaderNavParams.listenAlong = false;
    FqReaderStore.init(getContext(this));
    FqLocalBookStore.init(getContext(this));
    FqReadStatsStore.init(getContext(this));
    const settings = FqReaderStore.getSettings();
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.themeIndex = settings.themeIndex;
    this.flipIndex = settings.flipIndex;
    this.fontIndex = settings.fontIndex;
    this.syncReaderColorMode();
    this.filesDir = getContext(this).filesDir;
    this.chapterPages = FqReaderStore.getChapterPages(this.bookId);
    this.refreshFooterStatus();
    this.clockTimer = setInterval((): void => {
      this.refreshFooterStatus();
      // 阅读页驻留累计今日已读时长（30s 心跳）
      FqReadStatsStore.addSeconds(30);
    }, 30000);
    this.cachedMetrics = this.buildMetrics();
    this.applySystemBar(false);
    DialogManager.Register((): void => {
      this.settingsDialog.open();
    }, (message: string): void => {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    }, (): void => {
      this.settingsDialog.close();
    });
    this.load();
  }

  aboutToDisappear(): void {
    this.restoreSystemColorMode();
    this.applySystemBar(true);
    this.loadToken += 1;
    this.saveProgressNow();
    try {
      this.settingsDialog.close();
    } catch (error) {
      // 弹窗可能未打开
    }
    DialogManager.Unregister();
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  build() {
    CommonNav({
      hideTitleBar: !this.menuVisible,
      titleBarOp: this.titleBarOp,
      pageBackgroundColor: this.theme().background,
      showBrandGradient: false,
      scrollMaskExtraHeight: 0,
      tabMaskHeight: 0,
      isShowBar: true,
      isShowBarController: this.menuVisible,
      readBarKind: 'reader',
      readerBarClick: (key: string): void => {
        this.onReadBarAction(key);
      },
      backPressed: (): boolean => this.handleBackPressed(),
    }) {
      Stack() {
        FqReaderFlip({
          flipMode: this.flipIndex,
          hasPrev: this.flipHasPrev(),
          hasNext: this.flipHasNext(),
          bubbles: this.curBubbles(),
          headerZoneVp: this.cachedMetrics.headerZoneVp,
          footerZoneVp: this.cachedMetrics.footerZoneVp,
          pageBgColor: this.theme().background,
          pageRenderer: (slot: number): void => {
            this.pageOf(slot);
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
          onBubbleTap: (paraIndex: number): void => {
            this.openParaSheet(paraIndex);
          },
        })
        .bindSheet(this.commentSheetVisible, this.CommentSheet(), FqSheetOptions((): void => {
          this.onCommentSheetClose();
        }, fqCommentSheetHeightVp()))

        // 段评半模态宿主（0 尺寸稳定节点）
        Column()
          .width(0)
          .height(0)
          .bindSheet(this.paraSheetVisible, this.ParaSheet(), FqSheetOptions((): void => {
            this.onParaSheetClose();
          }, this.paraSheetHeightVp()))

        if (this.loadingState) {
          Column({ space: 12 }) {
            CommonLoading({ sizeValue: 36, loadColor: FQ_ACCENT })
            Text('正在加载本章内容')
              .fontSize(14)
              .fontColor(this.theme().fontColor)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.theme().background)
        } else if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor(this.theme().fontColor)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .backgroundColor(FQ_ACCENT)
              .onClick(() => this.retry())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.theme().background)
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
      .height('100%')
      .backgroundColor(this.theme().background)
      .bindSheet(this.sheetVisible, this.CatalogSheet(), FqSheetOptions((): void => {
        this.onSheetClose();
      }))
    }
  }

  // ---------------------------------------------------------------------------
  // 自绘渲染：页数据 / 几何 / 分页 / 翻页
  // ---------------------------------------------------------------------------

  /** 翻页容器槽位页数据（slot：-1 / 0 / +1，章内邻页优先，越界取预载邻章页）。 */
  private pageForSlot(slot: number): FqReaderPageData | null {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return null;
    }
    const index: number = this.pageIndex + slot;
    if (index >= 0 && index < layout.pages.length) {
      return layout.pages[index];
    }
    if (index < 0) {
      const prev: FqChapterLayout | null = this.prevLayout;
      if (prev !== null && prev.pages.length > 0) {
        return prev.pages[prev.pages.length - 1];
      }
      return null;
    }
    const next: FqChapterLayout | null = this.nextLayout;
    if (next !== null && next.pages.length > 0) {
      return next.pages[0];
    }
    return null;
  }

  /** 槽位页所属章分页（段评计数随章取，跨章页不串数据）。 */
  private layoutForSlot(slot: number): FqChapterLayout | null {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return null;
    }
    if (slot === 0) {
      return layout;
    }
    if (slot < 0) {
      return this.pageIndex > 0 ? layout : this.prevLayout;
    }
    return this.pageIndex + 1 < layout.pages.length ? layout : this.nextLayout;
  }

  /** 翻页容器当前页气泡命中区。 */
  private curBubbles(): FqPageBubble[] {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return [];
    }
    const page: FqReaderPageData | undefined = layout.pages[this.pageIndex];
    return page !== undefined ? page.bubbles : [];
  }

  private flipHasPrev(): boolean {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return false;
    }
    return this.pageIndex > 0 || (this.chapterIndex > 0 && this.prevLayout !== null);
  }

  private flipHasNext(): boolean {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return false;
    }
    return this.pageIndex + 1 < layout.pages.length
      || (this.chapterIndex + 1 < this.totalChapters && this.nextLayout !== null);
  }

  /** 翻页容器页渲染（三槽位共用同一 Canvas 组件，样式随主题/字体）。 */
  @Builder
  private pageOf(slot: number) {
    FqPageCanvas({
      page: this.pageForSlot(slot),
      metrics: this.cachedMetrics,
      fontColor: this.theme().fontColor,
      pageBgColor: this.theme().background,
     // bubbleBgColor: this.theme().night ? '#23262A' : '#E9E3D5',
     // bubbleFontColor: this.theme().night ? '#9AA0A6' : '#8A8578',
      commentCounts: this.layoutForSlot(slot)?.commentCounts ?? [],
      fontFamily: this.readerFontFamily,
      highlightParaIndex: this.slotHighlightPara(slot),
      highlightColor: this.theme().night ? '#33FF7A3D' : '#1AFF7A3D',
    })
  }

  /** 槽位眉页：章节序号 + 章节名（菜单弹出淡出；空槽位不渲染，随仿真截图卷曲）。 */
  @Builder
  private slotHeader(slot: number) {
    if (!this.menuVisible && this.pageForSlot(slot) !== null) {
      Row({ space: 5 }) {
        Text(this.slotHeaderLabel(slot))
          .fontColor(this.theme().fontColor)
          .fontSize(14)
          .opacity(0.5)
          .fontFamily(this.readerFontFamily)
          .maxLines(1)
        if (this.slotHeaderName(slot).length > 0) {
          Text(this.slotHeaderName(slot))
            .fontColor(this.theme().fontColor)
            .fontSize(14)
            .opacity(0.5)
            .fontFamily(this.readerFontFamily)
            .maxLines(1)
            .layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.cachedMetrics.sidePaddingVp,
        right: this.cachedMetrics.sidePaddingVp,
      })
      .hitTestBehavior(HitTestMode.None)
      .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
    }
  }

  /** 槽位眉脚：左时钟+电量图标，右槽位页整书页码（菜单弹出淡出，随仿真截图卷曲）。 */
  @Builder
  private slotFooter(slot: number) {
    if (!this.menuVisible && this.pageForSlot(slot) !== null) {
      Row({ space: 5 }) {
        Text(this.footerClock)
          .fontColor(this.theme().fontColor)
          .fontSize(12)
          .opacity(0.5)
          .fontFamily(this.readerFontFamily)
          .maxLines(1)
        SymbolGlyph(this.batteryIcon())
          .fontSize(14)
          .fontColor([this.theme().fontColor])
          .opacity(0.5)
        Blank()
        Text(this.slotFooterPages(slot))
          .fontColor(this.theme().fontColor)
          .fontSize(12)
          .opacity(0.5)
          .fontFamily(this.readerFontFamily)
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({
        left: this.cachedMetrics.sidePaddingVp,
        right: this.cachedMetrics.sidePaddingVp,
      })
      .hitTestBehavior(HitTestMode.None)
      .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
    }
  }

  /** 翻页完成：章内翻页或跨章切换（邻章已预载时无缝，未就绪回退整章加载）。 */
  private onFlipTurn(isNext: boolean): void {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return;
    }
    if (isNext) {
      if (this.pageIndex + 1 < layout.pages.length) {
        this.pageIndex += 1;
        this.afterPageShown();
      } else if (this.nextLayout !== null) {
        this.switchToNeighbor(this.nextLayout, 0);
      } else if (this.chapterIndex + 1 < this.totalChapters) {
        this.openChapter(this.chapterIndex + 1, '');
      }
    } else {
      if (this.pageIndex - 1 >= 0) {
        this.pageIndex -= 1;
        this.afterPageShown();
      } else if (this.prevLayout !== null) {
        const lastPage: number = Math.max(0, this.prevLayout.pages.length - 1);
        this.switchToNeighbor(this.prevLayout, lastPage);
      } else if (this.chapterIndex > 0) {
        this.openChapter(this.chapterIndex - 1, '');
      }
    }
  }

  /** 邻章无缝切换（预载就绪后的跨章翻页路径）。 */
  private switchToNeighbor(target: FqChapterLayout, pageIndex: number): void {
    this.refreshChapterEstimate(this.chapterIndex);
    this.curLayout = target;
    this.chapterIndex = target.chapterIndex;
    this.pageIndex = pageIndex;
    this.shownPageOffset = pageIndex;
    this.prevLayout = null;
    this.nextLayout = null;
    this.chapterPages.set(target.chapterIndex, target.pages.length);
    FqReaderStore.saveChapterPages(this.bookId, this.chapterPages);
    this.saveProgressNow();
    this.resetListenState();
    if (this.listenAlong) {
      this.syncListenHighlight();
    }
    this.preloadNeighbors(this.loadToken);
  }

  /** 页展示后：整书页码实测记录 + 进度保存。 */
  private afterPageShown(): void {
    this.shownPageOffset = this.pageIndex;
    const known: number | undefined = this.chapterPages.get(this.chapterIndex);
    if (known === undefined || this.pageIndex + 1 > known) {
      this.chapterPages.set(this.chapterIndex, this.pageIndex + 1);
      FqReaderStore.saveChapterPages(this.bookId, this.chapterPages);
    }
    this.saveProgressNow();
  }

  private saveProgressNow(): void {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || this.pageIndex < 0 || this.pageIndex >= layout.pages.length) {
      return;
    }
    const page: FqReaderPageData = layout.pages[this.pageIndex];
    if (page.startPara < 0) {
      return;
    }
    FqReaderStore.saveProgress(this.bookId, this.chapterIndex, `p2:${page.startPara}:${page.startChar}`);
  }

  /** 排版几何（装页 px = 实际渲染 px：vp 元素 × densityPixels，fp 文本 × scaledDensity）。 */
  private buildMetrics(): FqReaderLayoutMetrics {
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    // fp 文本（Text/measureText）实际渲染 px 含系统字体缩放，vp 边距不含：
    // 两者分离换算，否则字体缩放 ≠ 1 时左右边距/页高预留失真。
    const textDensity: number = displayData.scaledDensity > 0 ? displayData.scaledDensity : density;
    const screenW: number = appState.screenWidth > 0 ? appState.screenWidth : displayData.width;
    const screenH: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
    const metrics: FqReaderLayoutMetrics = new FqReaderLayoutMetrics();
    metrics.density = density;
    metrics.pageWidthPx = screenW;
    metrics.pageHeightPx = screenH;
    const sideVp: number = 20;
    // 眉页/眉脚移入翻页容器槽位三区：眉页区 = 状态栏避让 + 22，眉脚区 = 手势条避让 + 40；
    // 正文上下内边距收紧为 10/10，正文紧贴眉页与眉脚。
    const headerZoneVp: number = Math.max(appState.maxTopRect, 32) + 22;
    const footerZoneVp: number = appState.bottomRect + 40;
    const contentTopVp: number = 10;
    const contentBottomVp: number = 10;
    metrics.sidePaddingVp = sideVp;
    metrics.contentTopVp = contentTopVp;
    metrics.contentBottomVp = contentBottomVp;
    metrics.headerZoneVp = headerZoneVp;
    metrics.footerZoneVp = footerZoneVp;
    metrics.fontSizeFp = this.fontSize;
    metrics.lineHeightFp = Math.round(this.fontSize * this.lineHeight * 10) / 10;
    metrics.fontSizePx = this.fontSize * textDensity;
    // 渲染 .lineHeight(lineHeightFp)：px 必须由取整后的 fp 值换算，装页与渲染逐行严格一致
    metrics.lineHeightPx = metrics.lineHeightFp * textDensity;
    const gapVp: number = Math.max(6, Math.round(this.fontSize * 0.5));
    metrics.paraGapVp = gapVp;
    metrics.paraGapPx = gapVp * density;
    metrics.titleFontFp = Math.round(this.fontSize * 1.26);
    metrics.titleLineFp = Math.round(this.fontSize * 1.26 * 1.4);
    metrics.titleLinePx = metrics.titleLineFp * textDensity;
    const titleTopVp: number = Math.max(4, Math.round(this.fontSize * 0.4));
    metrics.titleTopVp = titleTopVp;
    metrics.titleTopPx = titleTopVp * density;
    const titleBottomVp: number = Math.max(8, Math.round(this.fontSize * 0.7));
    metrics.titleBottomVp = titleBottomVp;
    metrics.titleBottomPx = titleBottomVp * density;
    // 段评气泡随正文字号等比缩放（基准 19fp）：
    // 字号缩小/系统字体放大时胶囊不再以固定高度撑破行高（页底切行的根因之一）
    const bubbleScale: number = Math.max(0.55, this.fontSize / 19);
    metrics.textDensity = textDensity;
    metrics.bubbleScale = bubbleScale;
    metrics.bubbleIconFp = Math.max(8, Math.round(13 * bubbleScale));
    metrics.bubbleTextFp = Math.max(7, Math.round(11 * bubbleScale));
    metrics.bubblePadHVp = Math.max(4, Math.round(9 * bubbleScale));
    metrics.bubblePadVVp = Math.max(2, Math.round(3 * bubbleScale));
    metrics.bubbleRadiusVp = Math.max(6, Math.round(11 * bubbleScale));
    metrics.bubbleSpaceVp = Math.max(2, Math.round(4 * bubbleScale));
    metrics.bubbleGapVp = Math.max(3, Math.round(FQ_BUBBLE_GAP_VP * bubbleScale));
    metrics.bubbleMarginTopVp = Math.max(2, Math.round(4 * bubbleScale));
    const capsuleFpPx: number = Math.max(metrics.bubbleIconFp * 1.25,
      metrics.bubbleTextFp * 1.45) * textDensity;
    metrics.bubbleCapsulePx = Math.ceil(capsuleFpPx) + 2 * metrics.bubblePadVVp * density;
    metrics.bubbleRowPx = metrics.bubbleMarginTopVp * density + metrics.bubbleCapsulePx;
    metrics.bubbleRowVp = metrics.bubbleRowPx / density;
    metrics.contentWidthPx = screenW - sideVp * 2 * density;
    metrics.contentHeightPx = screenH
      - (headerZoneVp + contentTopVp + contentBottomVp + footerZoneVp) * density;
    return metrics;
  }

  /** 章节文本 → 段落数组（首段章题不加缩进，其余段加 '\u3000\u3000' 前缀，幂等）。 */
  private buildParagraphs(text: string): string[] {
    const lines: string[] = text.split('\n');
    const paragraphs: string[] = [];
    for (const line of lines) {
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (paragraphs.length === 0) {
        paragraphs.push(trimmed);
      } else {
        paragraphs.push(`\u3000\u3000${trimmed}`);
      }
    }
    return paragraphs;
  }

  /** 测量回调（UIContext.getMeasureUtils 包装，返回 px）。
   * measureText 仅支持 HarmonyOS Sans（文档明确 fontFamily 只认该字体）：
   * 自定义阅读字体（书宋等）下系统测量偏窄，满行会多切 1 字被渲染端
   * maxLines(1) 裁掉（调大字号后“文字挤左/掉字”根因）。
   * 自定义字体启用时按解析式测量（实测与两种自定义字体渲染步进一致）：
   * 全角字符 1em、弯引号 “ ” 0.5em、其余半角片段走 OffscreenCanvas
   * measureText（默认字体半角步进与自定义字体渲染高度一致：数字 ~0.55em，
   * 远准于 UIContext 测量的 ~0.24em），按「全角恒 1em」自校准换单位。
   * 系统字体模式测量与渲染同源，维持原样。 */
  private measureFn(): FqMeasureFn {
    const customFont: boolean = this.readerFontFamily.length > 0;
    const textDensity: number = this.cachedMetrics.textDensity;
    const utils = this.getUIContext().getMeasureUtils();
    const measureSystem: (text: string, fontSizeFp: number, fontWeight: string) => number =
      (text: string, fontSizeFp: number, fontWeight: string): number => {
        return utils.measureText({
          textContent: text,
          fontSize: fontSizeFp,
          fontWeight: fontWeight,
        });
      };
    if (!customFont) {
      return measureSystem;
    }
    const canvas: OffscreenCanvas = new OffscreenCanvas(64, 64);
    const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d');
    return (text: string, fontSizeFp: number, fontWeight: string): number => {
      const emPx: number = fontSizeFp * textDensity;
      // 校准：默认字体全角恒 1em，canvas 读数单位与 px 的比值随取
      ctx.font = `${emPx.toFixed(2)}px "HarmonyOS Sans"`;
      const wHan: number = ctx.measureText('汉').width;
      const canvasScale: number = wHan > 0 ? emPx / wHan : 0;
      const measureHalf: (run: string) => number = (run: string): number => {
        if (canvasScale > 0) {
          return ctx.measureText(run).width * canvasScale;
        }
        return measureSystem(run, fontSizeFp, fontWeight);
      };
      let width: number = 0;
      let halfRun: string = '';
      for (let pos: number = 0; pos < text.length; pos++) {
        const code: number = text.charCodeAt(pos);
        if (code >= 0xd800 && code <= 0xdbff) {
          // 代理对（扩展区汉字/emoji）按全角 1em
          if (halfRun.length > 0) {
            width += measureHalf(halfRun);
            halfRun = '';
          }
          width += emPx;
          pos += 1;
          continue;
        }
        if (ReaderPage.isFullWidthCode(code)) {
          if (halfRun.length > 0) {
            width += measureHalf(halfRun);
            halfRun = '';
          }
          width += ReaderPage.isHalfQuoteCode(code) ? emPx / 2 : emPx;
        } else {
          halfRun += text.charAt(pos);
        }
      }
      if (halfRun.length > 0) {
        width += measureHalf(halfRun);
      }
      return width;
    };
  }

  /** 全角码位判定（CJK/全角标点/全角空格/破折号/省略号/单弯引号等 → 1em 步进；
   * 双弯引号 “ ” 除外 → 0.5em，见 isHalfQuoteCode）。 */
  private static isFullWidthCode(code: number): boolean {
    return code === 0x00b7                                   // ·（中文间隔号）
      || (code >= 0x2014 && code <= 0x2026)                  // — ‘ ’ ‥ …
      || (code >= 0x2e80 && code <= 0x9fff)                  // CJK 部首/注音/假名/汉字
      || (code >= 0x3000 && code <= 0x303f)                  // 全角空格/CJK 标点/〇
      || (code >= 0xf900 && code <= 0xfaff)                  // CJK 兼容表意
      || (code >= 0xfe30 && code <= 0xfe4f)                  // CJK 兼容形式
      || (code >= 0xff00 && code <= 0xff60);                 // 全角 ASCII 形式
  }

  /** 双弯引号（“ ”）：书宋/黑体实测渲染步进 0.5em。 */
  private static isHalfQuoteCode(code: number): boolean {
    return code === 0x201c || code === 0x201d;
  }

  /** 章节分页（同步，~百 ms 级；调用方保证 loading 遮罩或预载时机）。 */
  private layoutChapter(index: number, paragraphs: string[]): FqChapterLayout {
    const metrics: FqReaderLayoutMetrics = this.cachedMetrics;
    const engine: FqPaginationEngine = new FqPaginationEngine(this.measureFn());
    const chapter: FqChapter | undefined = this.chapters[index];
    const chapterId: string = chapter !== undefined ? chapter.itemId : '';
    const counts: number[] = this.commentProvider.commentCounts(chapterId, paragraphs.length);
    return engine.layout(index, paragraphs, metrics, counts);
  }

  /** 恢复页下标：'p2:段:字符' 进度解析，非法/缺失回退章首。 */
  private restorePageIndex(layout: FqChapterLayout, domPos: string): number {
    if (domPos.startsWith('p2:')) {
      const parts: string[] = domPos.substring(3).split(':');
      if (parts.length === 2) {
        const para: number = parseInt(parts[0], 10);
        const char: number = parseInt(parts[1], 10);
        if (!Number.isNaN(para) && !Number.isNaN(char)) {
          return fqPageIndexForPosition(layout.pages, para, char);
        }
      }
    }
    return 0;
  }

  /** 邻章预载（后台，token 保护；先 next 后 prev）。 */
  private async preloadNeighbors(token: number): Promise<void> {
    const nextIndex: number = this.chapterIndex + 1;
    if (nextIndex < this.totalChapters) {
      try {
        const text: string = await this.fetchChapterText(nextIndex);
        if (token !== this.loadToken || text.trim().length === 0) {
          if (token !== this.loadToken) {
            return;
          }
        } else {
          this.nextLayout = this.layoutChapter(nextIndex, this.buildParagraphs(text));
        }
      } catch (error) {
        // 邻章预载失败不阻断（跨章时回退整章加载路径）
      }
    }
    if (token !== this.loadToken) {
      return;
    }
    const prevIndex: number = this.chapterIndex - 1;
    if (prevIndex >= 0) {
      try {
        const text: string = await this.fetchChapterText(prevIndex);
        if (token === this.loadToken && text.trim().length > 0) {
          this.prevLayout = this.layoutChapter(prevIndex, this.buildParagraphs(text));
        }
      } catch (error) {
        // 邻章预载失败不阻断
      }
    }
  }

  /** 配置变化重排：保持当前页首位置（字号/行距/字体/窗口尺寸变化）。 */
  private relayoutKeepPosition(): void {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || layout.pages.length === 0) {
      return;
    }
    const currentPage: FqReaderPageData | undefined = layout.pages[this.pageIndex];
    const para: number = currentPage !== undefined && currentPage.startPara >= 0 ? currentPage.startPara : 0;
    const char: number = currentPage !== undefined && currentPage.startPara >= 0 ? currentPage.startChar : 0;
    this.cachedMetrics = this.buildMetrics();
    const relaid: FqChapterLayout = this.layoutChapter(this.chapterIndex, layout.paragraphs);
    this.curLayout = relaid;
    this.pageIndex = fqPageIndexForPosition(relaid.pages, para, char);
    this.shownPageOffset = this.pageIndex;
    this.chapterPages.set(this.chapterIndex, relaid.pages.length);
    FqReaderStore.saveChapterPages(this.bookId, this.chapterPages);
    this.prevLayout = null;
    this.nextLayout = null;
    this.saveProgressNow();
    this.preloadNeighbors(this.loadToken);
  }

  // ---------------------------------------------------------------------------
  // 行为（对齐 ReaderPage）
  // ---------------------------------------------------------------------------

  /** 系统深浅色（appState.isDark 的计算映射，供 @Monitor 监听）。 */
  @Computed
  get systemDark(): boolean {
    return appState.isDark;
  }

  @Monitor('systemDark')
  onSystemDarkChange(): void {
    if (this.themeIndex === -1) {
      this.applySettingChange(false);
    }
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

  /** 窗口尺寸变化：重建几何并保位重排。 */
  @Monitor('windowWidth', 'windowHeight')
  onWindowSizeChange(): void {
    if (this.curLayout === null || this.loadingState) {
      return;
    }
    this.relayoutKeepPosition();
  }

  // ---------------------------------------------------------------------------
  // 边听边读：跟随 fqAudioSession 章节与字幕，高亮朗读段落并自动翻页
  // ---------------------------------------------------------------------------

  /** 播放会话当前章下标（供 @Monitor 监听音频换章）。 */
  @Computed
  get audioChapterIndex(): number {
    return fqAudioSession.index;
  }

  /** 播放会话当前位置（ms，供 @Monitor 监听字幕推进）。 */
  @Computed
  get audioPositionMs(): number {
    return Math.round(fqAudioSession.positionSec * 1000);
  }

  /** 音频换章：阅读页跟章（itemId 优先、标题次之、下标兜底）。 */
  @Monitor('audioChapterIndex')
  onAudioChapterChange(): void {
    if (!this.listenAlong || this.chapters.length === 0) {
      return;
    }
    const chapter: FqChapter | undefined = fqAudioSession.chapters[fqAudioSession.index];
    if (chapter === undefined) {
      return;
    }
    let target: number = -1;
    for (let i: number = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].itemId === chapter.itemId) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      for (let i: number = 0; i < this.chapters.length; i++) {
        if (this.chapters[i].title === chapter.title) {
          target = i;
          break;
        }
      }
    }
    if (target < 0 && fqAudioSession.index < this.chapters.length) {
      target = fqAudioSession.index;
    }
    if (target >= 0 && target !== this.chapterIndex) {
      this.openChapter(target, '');
    } else {
      this.syncListenHighlight();
    }
  }

  /** 播放位置推进：刷新段落高亮与跟读翻页。 */
  @Monitor('audioPositionMs')
  onAudioPositionChange(): void {
    this.syncListenHighlight();
  }

  /** 槽位页高亮段（仅当前章页生效，邻章越界页不串高亮）。 */
  private slotHighlightPara(slot: number): number {
    if (!this.listenAlong || this.highlightParaIndex < 0) {
      return -1;
    }
    const layout: FqChapterLayout | null = this.layoutForSlot(slot);
    const cur: FqChapterLayout | null = this.curLayout;
    if (layout === null || cur === null || layout.chapterIndex !== cur.chapterIndex) {
      return -1;
    }
    return this.highlightParaIndex;
  }

  /** 跟读高亮同步：cue 变化才重算；段落匹配失败保留旧高亮。 */
  private syncListenHighlight(): void {
    if (!this.listenAlong) {
      return;
    }
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || this.loadingState) {
      return;
    }
    const track: FqSubtitleTrack = fqAudioSession.subtitleTrack;
    if (track.isEmpty) {
      this.highlightParaIndex = -1;
      return;
    }
    const cueIndex: number = track.indexAt(fqAudioSession.positionSec * 1000);
    if (cueIndex === this.lastCueIndex) {
      return;
    }
    this.lastCueIndex = cueIndex;
    if (cueIndex < 0) {
      this.highlightParaIndex = -1;
      return;
    }
    const cue: FqSubtitleCue | undefined = track.cues[cueIndex];
    if (cue === undefined) {
      return;
    }
    const para: number = this.matchParaForCue(cue.text);
    if (para < 0) {
      return;
    }
    this.highlightParaIndex = para;
    const pageIdx: number = fqPageIndexForPosition(layout.pages, para, 0);
    if (pageIdx !== this.pageIndex) {
      this.pageIndex = pageIdx;
      this.shownPageOffset = pageIdx;
      this.afterPageShown();
    }
  }

  /** 字幕行 → 段落下标（游标向前优先，未中回绕；去空白双向包含匹配）。 */
  private matchParaForCue(text: string): number {
    const normCue: string = ReaderPage.normText(text);
    if (normCue.length === 0) {
      return -1;
    }
    const paras: string[] = this.normParas;
    for (let i: number = this.paraCursor; i < paras.length; i++) {
      if (ReaderPage.cueMatchesPara(normCue, paras[i])) {
        this.paraCursor = i;
        return i;
      }
    }
    for (let i: number = 0; i < this.paraCursor && i < paras.length; i++) {
      if (ReaderPage.cueMatchesPara(normCue, paras[i])) {
        this.paraCursor = i;
        return i;
      }
    }
    return -1;
  }

  /** 章切换/重排后复位跟读匹配态并重建去空白段落缓存。 */
  private resetListenState(): void {
    this.lastCueIndex = -2;
    this.paraCursor = 0;
    this.highlightParaIndex = -1;
    const layout: FqChapterLayout | null = this.curLayout;
    this.normParas = layout === null ? [] : layout.paragraphs.map(
      (p: string): string => ReaderPage.normText(p));
  }

  /** 去除全部空白（含全角空格/换行），供字幕与段落文本对齐匹配。 */
  private static normText(text: string): string {
    return text.replace(/\s+/g, '');
  }

  /** 段落匹配：双向包含（字幕行为段落子串，或短段为字幕行子串）。 */
  private static cueMatchesPara(normCue: string, normPara: string): boolean {
    if (normPara.length === 0) {
      return false;
    }
    return normPara.indexOf(normCue) >= 0 || normCue.indexOf(normPara) >= 0;
  }

  /** ReadBar 悬浮工具条分发：目录 / 设置 / 上一章 / 下一章。 */
  private onReadBarAction(key: string): void {
    if (key === '目录') {
      this.openSheet();
    } else if (key === '设置') {
      DialogManager.OpenDialog('阅读设置');
    } else if (key === '上一章') {
      this.openPrev();
    } else if (key === '下一章') {
      this.openNext();
    }
  }

  /** 系统返回：先关段评/书评/目录半模态，再关菜单，最后放行返回上一页。 */
  private handleBackPressed(): boolean {
    if (this.paraSheetVisible) {
      this.onParaSheetClose();
      return true;
    }
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
    // 返回放行前先恢复系统状态栏：让状态栏在转场开始时即就位（随页面滑动出现），
    // 而非转场结束后突兀弹出（aboutToDisappear 里仍兜底恢复一次）。
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

  /** 实际生效的主题下标：-1 跟随系统（深色 → 夜间，浅色 → 纸白）。 */
  private effectiveThemeIndex(): number {
    return this.themeIndex === -1 ? (this.systemDark ? 2 : 0) : this.themeIndex;
  }

  private theme(): FqReaderTheme {
    return FQ_READER_THEMES[this.effectiveThemeIndex()] ?? FQ_READER_THEMES[0];
  }

  /** 上次已锁定的应用色彩模式（去重，避免重复 setColorMode/刷新）。 */
  private appliedColorMode: ConfigurationConstant.ColorMode | null = null;

  /**
   * 将应用色彩模式锁定为与生效阅读主题一致：阅读页内系统色 chrome（标题栏/工具栏/
   * 设置弹窗卡片/半模态）随阅读主题渲染，避免系统深色 + 浅色主题时白字不可读
   * （或系统浅色 + 夜间主题时黑字不可读）。「跟随系统」主题不锁定（此时生效主题
   * 与系统模式天然一致，保留系统切换的实时响应）。
   */
  private syncReaderColorMode(): void {
    const mode: ConfigurationConstant.ColorMode = this.themeIndex === -1
      ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      : (this.theme().night ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    if (this.appliedColorMode === mode) {
      return;
    }
    this.appliedColorMode = mode;
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(mode);
      if (mode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
        themeUtils.colorModeChange(mode);
      }
    } catch (error) {
      // 设置失败保持现状
    }
  }

  /** 退出阅读页：恢复应用色彩模式跟随系统，并刷新全局系统色绑定。 */
  private restoreSystemColorMode(): void {
    this.appliedColorMode = null;
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      themeUtils.colorModeChange(appState.isDark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (error) {
      // 设置失败保持现状
    }
  }

  /** 槽位页所属章下标（-1 无章）。 */
  private slotChapterIndex(slot: number): number {
    const layout: FqChapterLayout | null = this.layoutForSlot(slot);
    return layout !== null ? layout.chapterIndex : -1;
  }

  /** 槽位页在所属章内的页下标（-1 无页）。 */
  private slotPageInChapter(slot: number): number {
    const layout: FqChapterLayout | null = this.layoutForSlot(slot);
    if (layout === null) {
      return -1;
    }
    const page: FqReaderPageData | null = this.pageForSlot(slot);
    if (page === null) {
      return -1;
    }
    return layout.pages.indexOf(page);
  }

  /** 槽位章标题（空串无章）。 */
  private slotChapterTitle(slot: number): string {
    const index: number = this.slotChapterIndex(slot);
    const chapter: FqChapter | undefined = this.chapters[index];
    return chapter !== undefined ? chapter.title : '';
  }

  /** 槽位眉页序号：标题自带「第N章」前缀取之，否则按章下标生成。 */
  private slotHeaderLabel(slot: number): string {
    const chapterIndex: number = this.slotChapterIndex(slot);
    if (chapterIndex < 0) {
      return '';
    }
    const title: string = this.slotChapterTitle(slot).trim();
    const rest: string = title.replace(FQ_HEADER_PREFIX_RE, '');
    if (title.length > 0 && rest.length < title.length) {
      return title.substring(0, title.length - rest.length);
    }
    return `第${chapterIndex + 1}章`;
  }

  /** 槽位眉页章节名：剥掉「第N章」前缀的标题；无前缀返回完整标题，空标题返回空串。 */
  private slotHeaderName(slot: number): string {
    return this.slotChapterTitle(slot).replace(FQ_HEADER_PREFIX_STRIP_RE, '').trim();
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

  /** 构建整书页数冻结估算：已知章取实测，其余按已知均值（无数据默认 3 页）。 */
  private buildChapterEstimates(): void {
    let knownTotal: number = 0;
    this.chapterPages.forEach((pages: number): void => {
      knownTotal += pages;
    });
    const avg: number = this.chapterPages.size > 0
      ? Math.max(1, Math.round(knownTotal / this.chapterPages.size)) : 3;
    this.chapterEstimate = new Map();
    for (let index: number = 0; index < this.totalChapters; index++) {
      const known: number | undefined = this.chapterPages.get(index);
      this.chapterEstimate.set(index, known !== undefined ? known : avg);
    }
  }

  /** 以实测页数校正某章冻结估算（跨章/跳章时调用，保证整书页码衔接不回跳）。 */
  private refreshChapterEstimate(index: number): void {
    if (index < 0 || index >= this.totalChapters) {
      return;
    }
    const known: number | undefined = this.chapterPages.get(index);
    if (known !== undefined) {
      this.chapterEstimate.set(index, known);
    }
  }

  /** 章节页数（冻结估算值）：会话内稳定，整书页码不随翻页逐页变化。 */
  private estimateChapterPages(index: number): number {
    const estimate: number | undefined = this.chapterEstimate.get(index);
    if (estimate !== undefined) {
      return estimate;
    }
    const known: number | undefined = this.chapterPages.get(index);
    return known !== undefined ? known : 3;
  }

  /** 槽位眉脚整书页码：该槽位页位置（章内页码 + 前序章估算页数）/ 整书估算页数。 */
  private slotFooterPages(slot: number): string {
    if (this.totalChapters <= 0) {
      return '';
    }
    const chapterIndex: number = this.slotChapterIndex(slot);
    const pageInChapter: number = this.slotPageInChapter(slot);
    if (chapterIndex < 0 || pageInChapter < 0) {
      return '';
    }
    let readPages: number = pageInChapter + 1;
    for (let i: number = 0; i < chapterIndex; i++) {
      readPages += this.estimateChapterPages(i);
    }
    let totalPages: number = 0;
    for (let i: number = 0; i < this.totalChapters; i++) {
      totalPages += this.estimateChapterPages(i);
    }
    return `${readPages}/${totalPages}`;
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
    this.getUIContext().animateTo({ duration: 300 }, ()=>{
      this.menuVisible = !this.menuVisible;
    })
  }

  /** 打开书评半模态（数据加载由公共 FqCommentSheet 自理）。 */
  private openCommentSheet(): void {
    this.commentSheetVisible = true;
  }

  private onCommentSheetClose(): void {
    this.commentSheetVisible = false;
  }

  // ---------------------------------------------------------------------------
  // 段评半模态
  // ---------------------------------------------------------------------------

  private openParaSheet(paraIndex: number): void {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || paraIndex < 0 || paraIndex >= layout.paragraphs.length) {
      return;
    }
    this.paraSheetParaIndex = paraIndex;
    this.paraComments = [];
    this.paraError = '';
    this.paraSheetVisible = true;
    this.loadParaComments(paraIndex);
  }

  private onParaSheetClose(): void {
    this.paraSheetVisible = false;
  }

  /** 段评 Sheet 标题：段评 · N。 */
  private paraSheetTitle(): string {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || this.paraSheetParaIndex < 0
      || this.paraSheetParaIndex >= layout.commentCounts.length) {
      return '段评';
    }
    return `段评 · ${layout.commentCounts[this.paraSheetParaIndex]}`;
  }

  /** 段评 Sheet 高度：屏高 60%（vp），异常回退 400。 */
  private paraSheetHeightVp(): number {
    const displayData: display.Display = display.getDefaultDisplaySync();
    const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
    const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
    const height: number = Math.round((screenHeight / density) * 0.6);
    return height > 0 ? height : 400;
  }

  /** 所评段落原文（去缩进前缀，截断展示）。 */
  private paraSheetText(): string {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null || this.paraSheetParaIndex < 0
      || this.paraSheetParaIndex >= layout.paragraphs.length) {
      return '';
    }
    return layout.paragraphs[this.paraSheetParaIndex].trim();
  }

  private async loadParaComments(paraIndex: number): Promise<void> {
    const layout: FqChapterLayout | null = this.curLayout;
    if (layout === null) {
      return;
    }
    const chapter: FqChapter | undefined = this.chapters[this.chapterIndex];
    const chapterId: string = chapter !== undefined ? chapter.itemId : '';
    this.paraLoading = true;
    this.paraError = '';
    try {
      const comments: FqParagraphComment[] =
        await this.commentProvider.fetchComments(chapterId, paraIndex);
      this.paraComments = comments;
    } catch (error) {
      this.paraError = fqErrorMessage(error);
    }
    this.paraLoading = false;
  }

  /** 段评相对时间（刚刚/N分钟前/N小时前/N天前）。 */
  private paraRelativeTime(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const diff: number = Date.now() - ms;
    if (diff < 60 * 1000) {
      return '刚刚';
    }
    if (diff < 60 * 60 * 1000) {
      return `${Math.floor(diff / (60 * 1000))}分钟前`;
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return `${Math.floor(diff / (60 * 60 * 1000))}小时前`;
    }
    return `${Math.floor(diff / (24 * 60 * 60 * 1000))}天前`;
  }

  // ---------------------------------------------------------------------------
  // 字体 / 设置
  // ---------------------------------------------------------------------------

  /** 阅读字体准备：系统字体拷沙箱副本 + 注册为自定义字体族（幂等，独立于 Reader Kit）。
   *  副本完整性校验（大小与源一致）：拷贝中断/损坏时删除重拷，
   *  避免注册坏文件后渲染静默回退系统字体（书宋回退问题）。 */
  private async prepareReaderFont(): Promise<void> {
    const option: FqFontOption | undefined = FQ_FONT_OPTIONS[this.fontIndex];
    if (option === undefined) {
      this.readerFontFamily = '';
      return;
    }
    const target: string = `${this.filesDir}/fq_reader2_font_${this.fontIndex}.ttf`;
    try {
      if (!ReaderPage.fontCopyValid(target, option.candidates)) {
        ReaderPage.deleteFileQuietly(target);
        let copied: boolean = false;
        for (const src of option.candidates) {
          if (!ReaderPage.fileExists(src)) {
            continue;
          }
          await fileIo.copyFile(src, target);
          if (ReaderPage.fontCopyValid(target, option.candidates)) {
            copied = true;
            break;
          }
          ReaderPage.deleteFileQuietly(target);
        }
        if (!copied) {
          this.readerFontFamily = '';
          return;
        }
      }
      this.getUIContext().getFont().registerFont({
        familyName: option.name,
        familySrc: `file://${target}`,
      });
      this.readerFontFamily = option.name;
    } catch (error) {
      hilog.warn(0x0001, 'ReaderPage', 'prepareReaderFont failed');
      this.readerFontFamily = '';
    }
  }

  private static fileExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  /** 沙箱副本完整性：存在且大小与任一候选源一致。 */
  private static fontCopyValid(target: string, candidates: string[]): boolean {
    if (!ReaderPage.fileExists(target)) {
      return false;
    }
    const targetSize: number = ReaderPage.fileSizeQuietly(target);
    if (targetSize <= 0) {
      return false;
    }
    for (const src of candidates) {
      if (ReaderPage.fileSizeQuietly(src) === targetSize) {
        return true;
      }
    }
    return false;
  }

  private static fileSizeQuietly(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (error) {
      return -1;
    }
  }

  private static deleteFileQuietly(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
      // 目标不存在时忽略
    }
  }

  private changeFontSize(delta: number): void {
    const next: number = Math.min(32, Math.max(12, this.fontSize + delta));
    if (next === this.fontSize) {
      return;
    }
    this.fontSize = next;
    hilog.info(0x0001, 'FqReader2', 'fontSize %{public}s -> %{public}d', `${delta}`, next);
    this.applySettingChange(true);
  }

  private changeLineHeight(delta: number): void {
    const next: number = Math.round((this.lineHeight + delta) * 10) / 10;
    if (next === this.lineHeight || next < 1.2 || next > 2.6) {
      return;
    }
    this.lineHeight = next;
    this.applySettingChange(true);
  }

  /** 切换字体档位：先备好新字体沙箱副本并注册，再保位重排。 */
  private async changeFont(index: number): Promise<void> {
    if (index === this.fontIndex || index < 0 || index >= FQ_FONT_OPTIONS.length) {
      return;
    }
    this.fontIndex = index;
    await this.prepareReaderFont();
    this.applySettingChange(true);
  }

  private applySettingChange(needRelayout: boolean): void {
    this.syncReaderColorMode();
    FqReaderStore.saveSettings(this.fontSize, this.lineHeight, this.themeIndex, this.flipIndex,
      this.fontIndex);
    if (needRelayout) {
      this.relayoutKeepPosition();
    }
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
    try {
      // 本地导入书籍：目录/正文均来自本地文件，不请求后端
      if (FqLocalBookStore.isLocalBookId(this.bookId)) {
        const localChapters: FqChapter[] = FqLocalBookStore.chapters(this.bookId);
        if (token !== this.loadToken) {
          return;
        }
        if (localChapters.length === 0) {
          this.errorMsg = '本地书籍文件不可用';
          this.loadingState = false;
          return;
        }
        this.chapters = localChapters;
        this.totalChapters = localChapters.length;
        this.buildChapterEstimates();
        const localProgress: FqReaderProgress = FqReaderStore.getProgress(this.bookId);
        let localIndex: number = this.startChapterIndex;
        let localDomPos: string = '';
        if (localIndex < 0 || localIndex >= localChapters.length) {
          localIndex = localProgress.chapterIndex >= 0 && localProgress.chapterIndex < localChapters.length
            ? localProgress.chapterIndex : 0;
          localDomPos = localIndex === localProgress.chapterIndex ? localProgress.domPos : '';
        }
        await this.openChapter(localIndex, localDomPos);
        return;
      }
      await FqBackend.get().start(getContext(this));
      const chapters: FqChapter[] =
        await FqBackend.get().directoryChapters(this.bookId, fqKindToTab(this.kind));
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
      this.buildChapterEstimates();
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
    hilog.info(0x0001, 'ReaderPage', `openChapter index=${index} domPos=${domPos}`);
    this.menuVisible = false;
    this.onSheetClose();
    this.refreshChapterEstimate(this.chapterIndex);
    this.chapterIndex = index;
    this.loadingState = true;
    this.errorMsg = '';
    try {
      const text: string = await this.fetchChapterText(index);
      if (token !== this.loadToken) {
        return;
      }
      if (text.trim().length === 0) {
        this.errorMsg = '本章内容为空';
        this.loadingState = false;
        return;
      }
      await this.prepareReaderFont();
      if (token !== this.loadToken) {
        return;
      }
      this.cachedMetrics = this.buildMetrics();
      const paragraphs: string[] = this.buildParagraphs(text);
      const layout: FqChapterLayout = this.layoutChapter(index, paragraphs);
      if (token !== this.loadToken) {
        return;
      }
      this.curLayout = layout;
      this.prevLayout = null;
      this.nextLayout = null;
      this.pageIndex = this.restorePageIndex(layout, domPos);
      this.shownPageOffset = this.pageIndex;
      this.chapterPages.set(index, layout.pages.length);
      FqReaderStore.saveChapterPages(this.bookId, this.chapterPages);
      this.loadingState = false;
      this.saveProgressNow();
      this.resetListenState();
      if (this.listenAlong) {
        this.syncListenHighlight();
      }
      this.preloadNeighbors(token);
    } catch (error) {
      if (token === this.loadToken) {
        this.errorMsg = fqErrorMessage(error);
        this.loadingState = false;
      }
    }
  }

  private async fetchChapterText(index: number): Promise<string> {
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return '';
    }
    // 本地导入书籍正文按导入偏移切片
    if (FqLocalBookStore.isLocalBookId(this.bookId)) {
      return FqLocalBookStore.chapterText(this.bookId, index);
    }
    return FqBackend.get().chapterText(chapter.itemId, chapter.title);
  }

  /** 章节已读进度：当前章按页位置计百分比、之前章节 100%、未读章节 0%。 */
  private chapterProgressText(idx: number): string {
    if (idx < this.chapterIndex) {
      return '100%';
    }
    if (idx > this.chapterIndex || this.curLayout === null) {
      return '0%';
    }
    const total: number = this.curLayout.pages.length;
    if (total <= 0) {
      return '0%';
    }
    const pct: number = Math.round(((this.pageIndex + 1) / total) * 100);
    return `${Math.min(Math.max(pct, 1), 100)}%`;
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
  // 半模态 / 弹窗装配
  // ---------------------------------------------------------------------------

  /** 目录半模态：公共 FqCatalogSheet（搜索/排序/定位/进度自理）。 */
  @Builder
  private CatalogSheet() {
    FqCatalogSheet({
      chapters: this.chapters,
      fontColor: this.theme().fontColor,
      currentChapterIndex: this.chapterIndex,
      progressOf: (index: number): string => this.chapterProgressText(index),
      openToken: this.sheetOpenToken,
      contentEndExtra: 56,
      chapterClick: (index: number): void => {
        this.jumpToChapter(index);
      },
    })
  }

  /** 书评半模态：公共 FqCommentSheet（首拉 Loading / 错误重试 / 空态 / 分页列表）。 */
  @Builder
  private CommentSheet() {
    FqCommentSheet({
      bookId: this.bookId,
      fontColor: this.theme().fontColor,
    })
  }

  /** 段评半模态：所评段落原文 + 段评列表（Loading / 错误重试 / 空态）。 */
  @Builder
  private ParaSheet() {
    CommonSheet({
      sheetTitle: this.paraSheetTitle(),
    }) {
      Column() {
        if (this.paraSheetText().length > 0) {
          Text(this.paraSheetText())
            .fontSize(13)
            .lineHeight(21)
            .fontColor(this.theme().fontColor)
            .opacity(0.7)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 12 })
        }
        if (this.paraLoading) {
          Column({ space: 10 }) {
            CommonLoading({ sizeValue: 36, loadColor: FQ_ACCENT })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.paraError.length > 0) {
          Column({ space: 12 }) {
            Text(this.paraError)
              .fontSize(14)
              .fontColor(this.theme().fontColor)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .backgroundColor(FQ_ACCENT)
              .onClick(() => {
                this.loadParaComments(this.paraSheetParaIndex);
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.paraComments.length === 0) {
          Column() {
            Text('本段暂无段评，快来抢沙发吧')
              .fontSize(14)
              .fontColor(this.theme().fontColor)
              .opacity(0.55)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.paraComments, (comment: FqParagraphComment) => {
              ListItem() {
                this.ParaCommentTile(comment)
              }
            }, (comment: FqParagraphComment): string => comment.id)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .contentEndOffset(appState.bottomRect)
          .divider({
            strokeWidth: 0.5,
            color: this.panelDividerColor(),
            startMargin: 20,
            endMargin: 20,
          })
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 单条段评：头像 + 名字/时间 + 正文 + 点赞计数。 */
  @Builder
  private ParaCommentTile(comment: FqParagraphComment) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Stack() {
          Column() {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(15)
              .fontColor([this.theme().fontColor])
              .opacity(0.55)
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          if (comment.userAvatar.length > 0) {
            Image(comment.userAvatar)
              .width(28)
              .height(28)
              .borderRadius(14)
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }
        }
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(comment.userName.length > 0 ? comment.userName : '书友')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme().fontColor)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (comment.isAuthor) {
              Text('作者')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor(FQ_ACCENT)
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            }
          }
          .width('100%')
          if (this.paraRelativeTime(comment.createdAtMs).length > 0) {
            Text(this.paraRelativeTime(comment.createdAtMs))
              .fontSize(11)
              .fontColor(this.theme().fontColor)
              .opacity(0.55)
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')

      Text(comment.text)
        .fontSize(13.5)
        .lineHeight(22)
        .fontColor(this.theme().fontColor)
        .width('100%')

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.hand_thumbsup'))
          .fontSize(13)
          .fontColor([this.theme().fontColor])
          .opacity(0.55)
        Text(fqFormatCountInt(comment.diggCount))
          .fontSize(11)
          .fontColor(this.theme().fontColor)
          .opacity(0.55)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, bottom: 12, left: 20, right: 20 })
  }

  /** 公共弹窗内容装配：按 DialogManager 标识分发内容组件（当前仅「阅读设置」）。 */
  @Builder
  private DialogContentBuilder(key: string) {
    if (key === '阅读设置') {
      ReaderSettingsDialogContent({
        fontSize: this.fontSize,
        lineHeight: this.lineHeight,
        themeIndex: this.themeIndex,
        flipIndex: this.flipIndex,
        fontIndex: this.fontIndex,
        followThemeBg: this.theme().background,
        followThemeFont: this.theme().fontColor,
        fontSizeChange: (delta: number): void => {
          this.changeFontSize(delta);
        },
        lineHeightChange: (delta: number): void => {
          this.changeLineHeight(delta);
        },
        themeChange: (index: number): void => {
          this.themeIndex = index;
          this.applySettingChange(false);
        },
        fontChange: (index: number): void => {
          this.changeFont(index);
        },
        flipChange: (index: number): void => {
          this.flipIndex = index;
          this.applySettingChange(false);
        },
      })
    }
  }

  /** 面板内分隔线颜色（随阅读主题）。 */
  private panelDividerColor(): ResourceColor {
    return $r('sys.color.comp_divider');
  }
}

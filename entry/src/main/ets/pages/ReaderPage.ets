/**
 * 小说阅读页（CommonNav 框架，基于 Reader Kit）：
 * 章节正文（v1 图文接口优先，回退旧版 /api/content）写入沙箱 txt 后交
 * ReadPageComponent 排版渲染；Reader Kit 仅支持本地文件，故每章一文件。
 * 交互：屏幕三分区 —— 左/右点击与横滑翻页（越界自动切换章节），
 * 中间呼出菜单：CommonNav 标题栏（hideTitleBar 随菜单显隐）+ ReadBar
 * 悬浮工具条（目录/上一章/下一章/设置，readBarHeight 随菜单 0/56）；
 * 目录/设置为 bindSheet 半模态公共 sheet（CommonSheet）；阅读时隐藏系统状态栏。
 * 进度（章节 + domPos）与设置（字号/行距/主题/翻页）持久化。
 */

import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { bookParser, ReadPageComponent, readerCore } from '@kit.ReaderKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqChapter, fqKindToTab } from '../model/FqModels';
import { FqReaderProgress, FqReaderStore } from '../core/FqReaderStore';
import { ReaderNavParams } from '../model/FqNavModels';
import { CommonNav, titleBarOf } from '../view/CommonNav';
import { CommonLoading, FQ_ACCENT } from '../view/CommonCom';
import { CommonSheet, FqSheetOptions } from '../view/CommonSheet';
import { appState } from '../entryability/AppState';

/** 阅读主题：themeColor 仅支持 6 位色值（无透明度）。 */
interface FqReaderTheme {
  readonly fontColor: string;
  readonly background: string;
  readonly night: boolean;
  readonly label: string;
}

const FQ_READER_THEMES: FqReaderTheme[] = [
  { fontColor: '#1F2329', background: '#F6F4EF', night: false, label: '纸白' },
  { fontColor: '#3E2F1C', background: '#F0E4C8', night: false, label: '米黄' },
  { fontColor: '#9AA0A6', background: '#151719', night: true, label: '夜间' },
];

const FQ_READER_FLIP_LABELS: string[] = ['仿真', '横滑'];

/** 翻页越界判定超时（ms）：flipPage 后 pageShow 未推进即视为章节边界。 */
const FQ_FLIP_BOUNDARY_TIMEOUT: number = 500;

/** 目录懒加载数据源：持过滤后章节，变更时通知 LazyForEach 刷新。 */
class FqChapterSource implements IDataSource {
  private items: FqChapter[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqChapter[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}

@ComponentV2
export struct ReaderPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local menuVisible: boolean = false;
  @Local sheetVisible: boolean = false;
  @Local sheetSearchActive: boolean = false;
  @Local sheetKeyword: string = '';
  @Local settingsSheetVisible: boolean = false;
  @Local chapterIndex: number = 0;
  @Local totalChapters: number = 0;
  @Local fontSize: number = 19;
  @Local lineHeight: number = 1.9;
  @Local themeIndex: number = 0;
  @Local flipIndex: number = 0;
  private bookId: string = '';
  private kind: string = 'book';
  private bookTitle: string = '';
  private startChapterIndex: number = -1;
  private chapters: FqChapter[] = [];
  private controller: readerCore.ReaderComponentController = new readerCore.ReaderComponentController();
  private controllerResolve: (() => void) | null = null;
  private controllerReady: Promise<void> = new Promise<void>((resolve: () => void) => {
    this.controllerResolve = resolve;
  });
  private loadToken: number = 0;
  private filesDir: string = '';
  private initialized: boolean = false;
  private drawerScroller: Scroller = new Scroller();
  /** 目录懒加载数据源（过滤后章节，搜索时刷新）。 */
  private chapterSource: FqChapterSource = new FqChapterSource();
  /** 最近一次 pageShow 的 startDomPos，用于判断 flipPage 是否推进了页面。 */
  private lastShownStart: string = '';
  /** 待定翻页方向：-1 无，0 上一页，1 下一页。 */
  private pendingFlip: number = -1;
  private flipTimerId: number = -1;

  aboutToAppear(): void {
    this.bookId = ReaderNavParams.id;
    this.kind = ReaderNavParams.kind;
    this.bookTitle = ReaderNavParams.title;
    this.startChapterIndex = ReaderNavParams.chapterIndex;
    FqReaderStore.init(getContext(this));
    const settings = FqReaderStore.getSettings();
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.themeIndex = settings.themeIndex;
    this.flipIndex = settings.flipIndex;
    hilog.info(0x0001, 'ReaderTheme',
      `aboutToAppear stored themeIndex=${settings.themeIndex} appIsDark=${appState.isDark}`);
    this.filesDir = getContext(this).filesDir;
    this.applySystemBar(false);
    this.load();
  }

  aboutToDisappear(): void {
    this.applySystemBar(true);
    this.loadToken += 1;
    this.clearPendingFlip();
    try {
      this.controller.releaseBook();
    } catch (error) {
      // 组件可能尚未就绪
    }
    try {
      const dir: string = `${this.filesDir}/reader`;
      if (this.filesDir.length > 0 && fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (error) {
      // 清理失败不阻断
    }
  }

  build() {
    CommonNav({
      //titleBarOp: this.buildTitleBar(),
      hideTitleBar: !this.menuVisible,
      pageBackgroundColor: this.theme().background,
      showBrandGradient: false,
      isShowBar: true,
      readBarKind: 'reader',
      readBarHeight: this.menuVisible ? 56 : 0,
      readerBarClick: (key: string): void => {
        this.onReadBarAction(key);
      },
      backPressed: (): boolean => this.handleBackPressed(),
    }) {
      Stack() {
        ReadPageComponent({
          controller: this.controller,
          readerCallback: (err: BusinessError, data: readerCore.ReaderComponentController): void => {
            if (err !== undefined && err !== null) {
              this.errorMsg = `阅读组件初始化失败：${err.message}`;
              this.loadingState = false;
              this.resolveController();
              return;
            }
            this.controller = data;
            this.resolveController();
          },
        })
        .width('100%')
        .height('100%')

        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.requestFlip(false))
            .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
              .onActionEnd((event: GestureEvent) => {
                if (event.offsetX < -30) {
                  this.requestFlip(true);
                } else if (event.offsetX > 30) {
                  this.requestFlip(false);
                }
              }))
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.toggleMenu())
            .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
              .onActionEnd((event: GestureEvent) => {
                if (event.offsetX < -30) {
                  this.requestFlip(true);
                } else if (event.offsetX > 30) {
                  this.requestFlip(false);
                }
              }))
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.requestFlip(true))
            .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 30 })
              .onActionEnd((event: GestureEvent) => {
                if (event.offsetX < -30) {
                  this.requestFlip(true);
                } else if (event.offsetX > 30) {
                  this.requestFlip(false);
                }
              }))
        }
        .width('100%')
        .height('100%')
        .bindSheet(this.settingsSheetVisible, this.SettingsSheet(), FqSheetOptions((): void => {
          this.settingsSheetVisible = false;
        }, SheetSize.MEDIUM))

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
              this.settingsSheetVisible = false;
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
  // 标题栏 / ReadBar 分发 / 返回
  // ---------------------------------------------------------------------------

  /** CommonNav 标题栏：章节标题（MINI 模式仅主标题）。 */
  private buildTitleBar(): TitleBarContentOptions {
    const chapterTitle: string = this.currentChapterTitle();
    const options: TitleBarContentOptions = {
      title: {
        mainTitle: chapterTitle.length > 0 ? chapterTitle : this.bookTitle,
      },
    };
    return options;
  }

  /** ReadBar 悬浮工具条分发：目录 / 设置 / 上一章 / 下一章。 */
  private onReadBarAction(key: string): void {
    if (key === '目录') {
      this.openSheet();
    } else if (key === '设置') {
      this.settingsSheetVisible = true;
    } else if (key === '上一章') {
      this.openPrev();
    } else if (key === '下一章') {
      this.openNext();
    }
  }

  /** 系统返回：先关目录半模态，再关菜单，最后放行返回上一页。 */
  private handleBackPressed(): boolean {
    if (this.sheetVisible) {
      this.onSheetClose();
      return true;
    }
    if (this.settingsSheetVisible || this.menuVisible) {
      this.settingsSheetVisible = false;
      this.menuVisible = false;
      return true;
    }
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

  @Builder
  private SettingChip(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.theme().fontColor)
      .width(34)
      .height(34)
      .borderRadius(17)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.theme().night ? '#2A2D30' : '#E8E2D4')
      .onClick(() => action())
  }

  /** 目录半模态：公共 sheet（标题栏+搜索）承载章节列表。 */
  @Builder
  private CatalogSheet() {
    CommonSheet({
      sheetTitle: '目录',
      showSearch: true,
      searchActive: this.sheetSearchActive,
      searchValue: this.sheetKeyword,
      searchPlaceholder: '搜索章节',
      focusId: 'reader_sheet_search',
      searchToggle: (): void => {
        this.sheetSearchActive = !this.sheetSearchActive;
        this.sheetKeyword = '';
        this.refreshCatalogSource();
      },
      searchChange: (value: string): void => {
        this.sheetKeyword = value;
        this.refreshCatalogSource();
      },
      searchSubmit: (value: string): void => {
        this.sheetKeyword = value;
        this.refreshCatalogSource();
      },
    }) {
      List({ scroller: this.drawerScroller }) {
        LazyForEach(this.chapterSource, (chapter: FqChapter) => {
          ListItem() {
            Row({ space: 14 }) {
              Text(`${this.chapterIndexOf(chapter) + 1}`)
                .fontSize(12)
                .fontColor(this.theme().fontColor)
                .opacity(0.5)
                .textAlign(TextAlign.End)
              Text(chapter.title.length > 0 ? chapter.title
                : `第${this.chapterIndexOf(chapter) + 1}章`)
                .fontSize(14)
                .fontColor(this.chapterIndexOf(chapter) === this.chapterIndex
                  ? FQ_ACCENT : this.theme().fontColor)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(14)
            .alignItems(VerticalAlign.Center)
            .onClick(() => this.jumpToChapter(this.chapterIndexOf(chapter)))
          }
        }, (chapter: FqChapter): string => chapter.itemId)
      }
      .contentStartOffset(56)
      .cachedCount(12)
      .contentEndOffset(appState.bottomRect)
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 0.5,
        color: this.panelDividerColor(),
        startMargin: 16,
        endMargin: 16,
      })
    }
  }

  /** 设置面板：公共 sheet（标题栏）承载排版设置，跟随底部工具栏出现。 */
  @Builder
  private SettingsSheet() {
    CommonSheet() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text('字号')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(36)
          this.SettingChip('A-', (): void => {
            this.changeFontSize(-1);
          })
          Text(`${this.fontSize}`)
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(32)
            .textAlign(TextAlign.Center)
          this.SettingChip('A+', (): void => {
            this.changeFontSize(1);
          })
          Blank()
          Text('行距')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
          this.SettingChip('-', (): void => {
            this.changeLineHeight(-0.1);
          })
          Text(`${this.lineHeight.toFixed(1)}`)
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(32)
            .textAlign(TextAlign.Center)
          this.SettingChip('+', (): void => {
            this.changeLineHeight(0.1);
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('主题')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(36)
          Column({ space: 4 }) {
            Column() {
              SymbolGlyph($r('sys.symbol.sun_max'))
                .fontSize(18)
                .fontColor([this.theme().fontColor])
            }
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor(this.theme().background)
            .border({
              width: this.themeIndex === -1 ? 2 : 1,
              color: this.themeIndex === -1 ? FQ_ACCENT : this.theme().fontColor,
            })
            .justifyContent(FlexAlign.Center)
            Text('跟随')
              .fontSize(10)
              .fontColor(this.theme().fontColor)
              .opacity(this.themeIndex === -1 ? 1 : 0.6)
          }
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            this.themeIndex = -1;
            this.applySettingChange();
          })
          ForEach(FQ_READER_THEMES, (theme: FqReaderTheme, index: number) => {
            Column({ space: 4 }) {
              Column()
                .width(34)
                .height(34)
                .borderRadius(17)
                .backgroundColor(theme.background)
                .border({
                  width: this.themeIndex === index ? 2 : 1,
                  color: this.themeIndex === index ? FQ_ACCENT : this.theme().fontColor,
                })
              Text(theme.label)
                .fontSize(10)
                .fontColor(this.theme().fontColor)
                .opacity(this.themeIndex === index ? 1 : 0.6)
            }
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.themeIndex = index;
              this.applySettingChange();
            })
          }, (theme: FqReaderTheme): string => theme.label)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('翻页')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(36)
          ForEach(FQ_READER_FLIP_LABELS, (label: string, index: number) => {
            Text(label)
              .fontSize(12)
              .fontColor(this.flipIndex === index ? '#FFFFFF' : this.theme().fontColor)
              .backgroundColor(this.flipIndex === index ? FQ_ACCENT : 'transparent')
              .borderRadius(13)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                this.flipIndex = index;
                this.applySettingChange();
              })
          }, (label: string): string => label)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(20)
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 面板内分隔线颜色（随阅读主题）。 */
  private panelDividerColor(): string {
    return this.theme().night ? '#2A2D30' : '#E8E2D4';
  }

  // ---------------------------------------------------------------------------
  // 翻页与章节边界
  // ---------------------------------------------------------------------------

  /** 点击/横滑翻页；pageShow 未推进（章节首/末页）时切换章节。 */
  private requestFlip(isNext: boolean): void {
    if (this.menuVisible || this.settingsSheetVisible) {
      this.menuVisible = false;
      this.settingsSheetVisible = false;
      return;
    }
    if (this.loadingState || this.errorMsg.length > 0 || this.chapters.length === 0) {
      return;
    }
    this.armBoundaryTimer(isNext);
    try {
      this.controller.flipPage(isNext);
    } catch (error) {
      this.clearPendingFlip();
    }
  }

  private armBoundaryTimer(isNext: boolean): void {
    this.pendingFlip = isNext ? 1 : 0;
    if (this.flipTimerId >= 0) {
      clearTimeout(this.flipTimerId);
    }
    this.flipTimerId = setTimeout(() => {
      this.flipTimerId = -1;
      if (this.pendingFlip >= 0) {
        const next: boolean = this.pendingFlip === 1;
        this.pendingFlip = -1;
        this.crossBoundary(next);
      }
    }, FQ_FLIP_BOUNDARY_TIMEOUT);
  }

  private clearPendingFlip(): void {
    this.pendingFlip = -1;
    if (this.flipTimerId >= 0) {
      clearTimeout(this.flipTimerId);
      this.flipTimerId = -1;
    }
  }

  private crossBoundary(isNext: boolean): void {
    if (isNext && this.hasNext()) {
      this.openChapter(this.chapterIndex + 1, '');
    } else if (!isNext && this.hasPrev()) {
      this.openChapter(this.chapterIndex - 1, '');
    }
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  private resolveController(): void {
    const resolve: (() => void) | null = this.controllerResolve;
    if (resolve !== null) {
      this.controllerResolve = null;
      resolve();
    }
  }

  /** 系统深浅色（appState.isDark 的计算映射，供 @Monitor 监听）。 */
  @Computed
  get systemDark(): boolean {
    return appState.isDark;
  }

  @Monitor('systemDark')
  onSystemDarkChange(): void {
    if (this.themeIndex === -1) {
      this.applySettingChange();
    }
  }

  /** 实际生效的主题下标：-1 跟随系统（深色 → 夜间，浅色 → 纸白）。 */
  private effectiveThemeIndex(): number {
    return this.themeIndex === -1 ? (this.systemDark ? 2 : 0) : this.themeIndex;
  }

  private theme(): FqReaderTheme {
    return FQ_READER_THEMES[this.effectiveThemeIndex()] ?? FQ_READER_THEMES[0];
  }

  private currentChapterTitle(): string {
    const chapter: FqChapter | undefined = this.chapters[this.chapterIndex];
    if (chapter === undefined) {
      return '';
    }
    return chapter.title;
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
    if (this.settingsSheetVisible) {
      this.settingsSheetVisible = false;
      return;
    }
    this.menuVisible = !this.menuVisible;
    if (!this.menuVisible) {
      this.settingsSheetVisible = false;
    }
  }

  private openSheet(): void {
    this.sheetSearchActive = false;
    this.sheetKeyword = '';
    this.refreshCatalogSource();
    this.sheetVisible = true;
    setTimeout(() => {
      this.drawerScroller.scrollToIndex(this.chapterIndex, false);
    }, 300);
  }

  private onSheetClose(): void {
    this.sheetVisible = false;
    this.sheetSearchActive = false;
    this.sheetKeyword = '';
  }

  /** 目录搜索过滤：空关键字返回全量目录。 */
  private filteredChapters(): FqChapter[] {
    const keyword: string = this.sheetKeyword.trim();
    if (keyword.length === 0) {
      return this.chapters;
    }
    const result: FqChapter[] = [];
    for (const chapter of this.chapters) {
      if (chapter.title.includes(keyword)) {
        result.push(chapter);
      }
    }
    return result;
  }

  /** 按当前关键字刷新目录懒加载数据源。 */
  private refreshCatalogSource(): void {
    this.chapterSource.setItems(this.filteredChapters());
  }

  private chapterIndexOf(chapter: FqChapter): number {
    return this.chapters.indexOf(chapter);
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

  private changeFontSize(delta: number): void {
    const next: number = Math.min(32, Math.max(12, this.fontSize + delta));
    if (next === this.fontSize) {
      return;
    }
    this.fontSize = next;
    this.applySettingChange();
  }

  private changeLineHeight(delta: number): void {
    const next: number = Math.round((this.lineHeight + delta) * 10) / 10;
    if (next === this.lineHeight || next < 1.2 || next > 2.6) {
      return;
    }
    this.lineHeight = next;
    this.applySettingChange();
  }

  private applySettingChange(): void {
    FqReaderStore.saveSettings(this.fontSize, this.lineHeight, this.themeIndex, this.flipIndex);
    try {
      this.controller.setPageConfig(this.buildSetting());
    } catch (error) {
      // 排版引擎可能尚未就绪
    }
  }

  /** Reader Kit 颜色仅接受 6 位十六进制（不带 #）。 */
  private fqKitColor(color: string): string {
    return color.startsWith('#') ? color.substring(1) : color;
  }

  private buildSetting(): readerCore.ReaderSetting {
    const theme: FqReaderTheme = this.theme();
    const displayData: display.Display = display.getDefaultDisplaySync();
    // 排版视口：屏幕物理尺寸（由 EntryAbility 采集于 appState）
    const density: number = displayData.scaledDensity > 0 ? displayData.scaledDensity : 1;
    const screenWidth: number = appState.screenWidth > 0 ? appState.screenWidth : displayData.width;
    const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
    hilog.info(0x0001, 'ReaderTheme',
      `buildSetting viewPort=${screenWidth}x${screenHeight} density=${density}`);
    // Reader Kit 内置上下页边距（约 92/59vp）无配置项：等比放大视口与字号，
    // 组件把视口整页缩放进自身区域，视觉字号不变而页边距等比缩小、每页容纳更多内容
    const viewportScale: number = 1.5;
    const setting: readerCore.ReaderSetting = {
      fontName: '系统字体',
      fontPath: '',
      fontSize: this.fontSize * viewportScale,
      fontWeight: 400,
      fontColor: this.fqKitColor(theme.fontColor),
      lineHeight: this.lineHeight,
      nightMode: theme.night,
      themeColor: this.fqKitColor(theme.background),
      themeBgImg: '',
      flipMode: this.flipIndex === 1 ? '1' : '0',
      scaledDensity: density,
      viewPortWidth: Math.round(screenWidth * viewportScale),
      viewPortHeight: Math.round(screenHeight * viewportScale),
    };
    return setting;
  }

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
      this.chapterSource.setItems(chapters);
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
    this.clearPendingFlip();
    this.menuVisible = false;
    this.onSheetClose();
    this.settingsSheetVisible = false;
    this.chapterIndex = index;
    this.loadingState = true;
    this.errorMsg = '';
    this.lastShownStart = '';
    try {
      await this.controllerReady;
      const text: string = await FqBackend.get().chapterText(chapter.itemId, chapter.title);
      if (token !== this.loadToken) {
        return;
      }
      if (text.trim().length === 0) {
        this.errorMsg = '本章内容为空';
        this.loadingState = false;
        return;
      }
      await this.ensureController();
      if (token !== this.loadToken) {
        return;
      }
      const path: string = this.writeChapterFile(chapter.itemId, text);
      const handler: bookParser.BookParserHandler = await bookParser.getDefaultHandler(path);
      if (token !== this.loadToken) {
        return;
      }
      this.controller.setPageConfig(this.buildSetting());
      this.controller.registerBookParser(handler);
      await this.controller.startPlay(0, domPos);
      // startPlay 会将配置重置为组件默认（浅色），渲染完成后必须重新应用
      this.controller.setPageConfig(this.buildSetting());
      FqReaderStore.saveProgress(this.bookId, index, domPos);
    } catch (error) {
      if (token === this.loadToken) {
        this.errorMsg = fqErrorMessage(error);
        this.loadingState = false;
      }
    }
  }

  private async ensureController(): Promise<void> {
    if (this.initialized) {
      return;
    }
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.controller.init(context);
    this.controller.on('pageShow', (data: readerCore.PageDataInfo): void => {
      if (data.state !== readerCore.PageState.PAGE_ON_SHOW) {
        return;
      }
      if (this.pendingFlip >= 0) {
        const crossed: boolean = data.startDomPos !== this.lastShownStart;
        const isNext: boolean = this.pendingFlip === 1;
        this.clearPendingFlip();
        if (!crossed) {
          this.crossBoundary(isNext);
          return;
        }
      }
      this.lastShownStart = data.startDomPos;
      this.loadingState = false;
      const domPos: string = data.startDomPos;
      if (domPos.length > 0) {
        FqReaderStore.saveProgress(this.bookId, this.chapterIndex, domPos);
      }
    });
    this.initialized = true;
  }

  private writeChapterFile(itemId: string, text: string): string {
    const dir: string = `${this.filesDir}/reader`;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
    const safeBookId: string = this.bookId.replace(/[^a-zA-Z0-9_-]/g, '_');
    const safeItemId: string = itemId.replace(/[^a-zA-Z0-9_-]/g, '_');
    const path: string = `${dir}/${safeBookId}_${safeItemId}.txt`;
    const file: fileIo.File = fileIo.openSync(
      path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, text);
    fileIo.closeSync(file);
    return path;
  }
}

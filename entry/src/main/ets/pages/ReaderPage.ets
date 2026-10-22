/**
 * 小说阅读页（CommonNav 框架，基于 Reader Kit）：
 * 整本书注册一个 FqOnlineParser（目录/书脊与网络目录一一对应），
 * 章节正文由排版引擎经 getSpineItemContent 按需网络拉取；
 * 换章/目录跳转用 startPlay(spineIndex, domPos)，跨章翻页由引擎自行推进。
 * 交互：三列点击触区（左=上一页，中=呼出菜单，右=下一页；触区 Transparent
 * 穿透，滑动直达引擎原生跟手翻页）：
 * CommonNav 标题栏（hideTitleBar 随菜单显隐）+ ReadBar
 * 悬浮工具条（目录/上一章/下一章/设置，readBarHeight 随菜单 0/56）；
 * 目录/设置为 bindSheet 半模态公共 sheet（CommonSheet）；阅读时隐藏系统状态栏。
 * 眉页（章节名）与眉脚（时钟/电量/整书页码）自绘覆盖层
 * （PageDataInfo 页眉/页脚为预留字段暂不支持；整书页码为冻结估算，跨章校正）。
 * 进度（章节 + domPos）与设置（字号/行距/主题/翻页）持久化。
 */

import { common } from '@kit.AbilityKit';
import { curves, display, window } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { ReadPageComponent, readerCore } from '@kit.ReaderKit';
import { BusinessError, batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqChapter, fqKindToTab } from '../model/FqModels';
import { FqReaderProgress, FqReaderStore } from '../core/FqReaderStore';
import { ReaderNavParams } from '../model/FqNavModels';
import { CommonNav, titleBarOf } from '../view/CommonNav';
import { CommonLoading, CommonSearch, FQ_ACCENT } from '../view/CommonCom';
import { CommonSheet, FqSheetOptions } from '../view/CommonSheet';
import { FQ_FONT_OPTIONS, FqFontOption, FqOnlineParser } from '../core/FqOnlineParser';
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

/** 眉页「第N章」前缀匹配（N 支持数字与中文数字，量词：章节回卷集话篇）。 */
const FQ_HEADER_PREFIX_RE: RegExp = new RegExp('^第[0-9零一二三四五六七八九十百千万]+[章节回卷集话篇]');

/** 眉页前缀剥离（含其后空白），用于提取纯章节名。 */
const FQ_HEADER_PREFIX_STRIP_RE: RegExp =
  new RegExp('^第[0-9零一二三四五六七八九十百千万]+[章节回卷集话篇]\\s*');

const TOP_BOTTOM_PADDING: number = 34

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
  /** 目录排序：true 倒序（不持久化，每次打开目录重置为正序）。 */
  @Local sheetDescending: boolean = false;
  @Local settingsSheetVisible: boolean = false;
  @Local chapterIndex: number = 0;
  @Local totalChapters: number = 0;
  @Local fontSize: number = 19;
  @Local lineHeight: number = 1.9;
  @Local themeIndex: number = 0;
  @Local flipIndex: number = 0;
  @Local fontIndex: number = 0;
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
  /** 配置重排后的强制重绘定时器句柄（-1 表示无待执行重绘）。 */
  private redrawTimer: number = -1;
  private filesDir: string = '';
  private initialized: boolean = false;
  private drawerScroller: Scroller = new Scroller();
  /** 目录懒加载数据源（过滤后章节，搜索时刷新）。 */
  private chapterSource: FqChapterSource = new FqChapterSource();
  /** 最近一次显示页的起始 domPos（进度保存/恢复用）。 */
  private lastShownStart: string = '';
  /** 整本书籍解析器：registerBookParser 仅一次，换章靠 startPlay(spineIndex) 定位。 */
  private bookParser: FqOnlineParser | null = null;
  /** 是否已向当前控制器 registerBookParser 过书籍。 */
  private hasRegisteredBook: boolean = false;
  /** register 会把配置重置为 Kit 默认，首个 pageShow 渲染完成后需重应用真实配置。 */
  private pendingConfigReapply: boolean = false;
  /** 待应用的窗口尺寸变化（小窗/全屏切换；章载中暂挂防打断，载后补应用）。 */
  private viewportDirty: boolean = false;
  /** 眉脚时钟文本（HH:mm）。 */
  @Local footerClock: string = '';
  /** 眉脚电量百分比（-1 未知）。 */
  @Local batteryLevel: number = -1;
  /** 时钟/电量刷新定时器（-1 表示未启动）。 */
  private clockTimer: number = -1;
  /** 各章已排版页数（chapterIndex → 页数），整书页码估算与持久化用。 */
  private chapterPages: Map<number, number> = new Map();
  /** 各章页数冻结估算（chapterIndex → 页数）：会话内不随翻页重算，整书页码仅跨章校正。 */
  private chapterEstimate: Map<number, number> = new Map();

  /** 最近一次显示页在章内的页偏移（0 起）。 */
  @Local shownPageOffset: number = 0;

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
    this.fontIndex = settings.fontIndex;
    hilog.info(0x0001, 'ReaderTheme',
      `aboutToAppear stored themeIndex=${settings.themeIndex} appIsDark=${appState.isDark}`);
    this.filesDir = getContext(this).filesDir;
    this.chapterPages = FqReaderStore.getChapterPages(this.bookId);
    this.refreshFooterStatus();
    this.clockTimer = setInterval((): void => {
      this.refreshFooterStatus();
    }, 30000);
    this.applySystemBar(false);
    this.load();
  }

  aboutToDisappear(): void {
    this.applySystemBar(true);
    this.loadToken += 1;
    if (this.redrawTimer >= 0) {
      clearTimeout(this.redrawTimer);
      this.redrawTimer = -1;
    }
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    try {
      this.controller.releaseBook();
      this.controller.off('pageShow')
    } catch (error) {
      // 组件可能尚未就绪
    }
    try {
      const dir: string = `${this.filesDir}/reader`;
      if (this.filesDir.length > 0 && fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (error) {
      // 清理历史遗留的章节文件
    }
  }

  build() {
    CommonNav({
      hideTitleBar: !this.menuVisible,
      pageBackgroundColor: this.theme().background,
      showBrandGradient: false,
      scrollMaskExtraHeight: 0,
      tabMaskHeight: 0,
      navBlurRadius: 0,
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

        // 翻页触区：左=上一页，中=呼出菜单，右=下一页；横向滑动同样翻页
        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.requestFlip(false))
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 300 }, (): void => {
                this.toggleMenu()
              });
            })
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.requestFlip(true))
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .bindSheet(this.settingsSheetVisible, this.SettingsSheet(), FqSheetOptions((): void => {
          this.settingsSheetVisible = false;
        }, 380))

        // 眉页：章节序号 + 章节名常驻顶部（跟随阅读主题，不拦截翻页点击）；
        // 定位用 maxTopRect（状态栏可见期间最大避让高度，覆盖摄像头孔条）
        if (!this.menuVisible) {
          Row({ space: 5 }) {
            Text(this.headerChapterLabel())
              .fontColor(this.theme().fontColor)
              .fontSize(14)
              .opacity(0.5)
              .maxLines(1)
              .hitTestBehavior(HitTestMode.None)
            if (this.headerChapterName().length > 0) {
              Text(this.headerChapterName())
                .fontColor(this.theme().fontColor)
                .fontSize(14)
                .opacity(0.5)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: TOP_BOTTOM_PADDING, right: TOP_BOTTOM_PADDING })
          .position({ top: Math.max(appState.maxTopRect, 32) , left: 0 })
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({duration: 300}))
        }

        // 眉脚：左时钟+电量图标，右整书页码（已看/估算总数）
        if (!this.menuVisible) {
          Row({space: 5}) {
            Text(this.footerClock)
              .fontColor(this.theme().fontColor)
              .fontSize(12)
              .opacity(0.5)
              .maxLines(1)
            SymbolGlyph(this.batteryIcon())
              .fontSize(14)
              .fontColor([this.theme().fontColor])
              .opacity(0.5)
            Blank()
            Text(this.footerPages())
              .fontColor(this.theme().fontColor)
              .fontSize(12)
              .opacity(0.5)
              .maxLines(1)
          }
          .alignItems(VerticalAlign.Center)
          .width('100%')
          .padding({ left: TOP_BOTTOM_PADDING, right: TOP_BOTTOM_PADDING })
          .position({ bottom: appState.bottomRect + 20, left: 0 })
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({duration: 300}))
        }

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
      showLocate: true,
      locateClick: (): void => {
        this.locateCurrentChapter();
      },
      showSort: true,
      sortAscending: !this.sheetDescending,
      sortClick: (): void => {
        this.toggleCatalogOrder();
      },
    }) {
      Column({space: 16}){
        CommonSearch({
          searchValue: this.sheetKeyword,
          isDefaultFocus: false,
          placeholderValue: '搜索章节',
          focusId: 'reader_sheet_search',
          bgColor: '#F5F5F5',
          change: (value: string): void => {
            this.sheetKeyword = value;
            this.refreshCatalogSource();
          },
          submit: (value: string, _event: SubmitEvent): void => {
            this.sheetKeyword = value;
            this.refreshCatalogSource();
          },
          didDelete: (): void => {
            this.sheetKeyword = '';
            this.refreshCatalogSource();
          },
          click: (): void => {
          },
        }).height(36).padding({right: 20, left: 20, bottom: 10 })

        List({ scroller: this.drawerScroller }) {
          LazyForEach(this.chapterSource, (chapter: FqChapter) => {
            ListItem() {
              Row({ space: 14 }) {
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
              .padding({ top: 14, bottom: 14, right: 20, left: 20 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => this.jumpToChapter(this.chapterIndexOf(chapter)))
            }
          }, (chapter: FqChapter): string => chapter.itemId)
        }
        .contentEndOffset(appState.bottomRect + 56)
        .cachedCount(12)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.5,
          color: this.panelDividerColor(),
          startMargin: 20,
          endMargin: 20,
        })
      }.padding({top: 56})
    }
  }

  /** 设置面板：公共 sheet（标题栏 + 右侧关闭）承载排版设置，跟随底部工具栏出现。 */
  @Builder
  private SettingsSheet() {
    CommonSheet({
      sheetTitle: '设置',
      showClose: true,
      closeClick: (): void => {
        this.settingsSheetVisible = false;
      },
    }) {
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
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('行距')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(36)
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
          Text('字体')
            .fontSize(14)
            .fontColor(this.theme().fontColor)
            .width(36)
          ForEach(FQ_FONT_OPTIONS, (option: FqFontOption, index: number) => {
            Text(option.label)
              .fontSize(12)
              .fontColor(this.fontIndex === index ? '#FFFFFF' : this.theme().fontColor)
              .backgroundColor(this.fontIndex === index ? FQ_ACCENT : 'transparent')
              .borderRadius(13)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                this.changeFont(index);
              })
          }, (option: FqFontOption): string => option.label)
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
      .alignItems(HorizontalAlign.Start)
      .padding({top: 76, bottom: appState.bottomRect, right: 20, left: 20})
    }
  }

  /** 面板内分隔线颜色（随阅读主题）。 */
  private panelDividerColor(): string {
    return this.theme().night ? '#2A2D30' : '#E8E2D4';
  }

  /** 点击分区翻页（滑动由引擎原生跟手处理）；跨章由排版引擎在书脊间自行推进。 */
  private requestFlip(isNext: boolean): void {
    if (this.menuVisible || this.settingsSheetVisible) {
      this.menuVisible = false;
      this.settingsSheetVisible = false;
      return;
    }
    if (this.loadingState || this.errorMsg.length > 0 || this.chapters.length === 0) {
      return;
    }
    try {
      this.controller.flipPage(isNext);
    } catch (error) {
      // 排版引擎可能尚未就绪
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

  /** 窗口宽度（appState.screenWidth 的计算映射，供 @Monitor 监听小窗/全屏切换）。 */
  @Computed
  get windowWidth(): number {
    return appState.screenWidth;
  }

  /** 窗口高度（appState.screenHeight 的计算映射，供 @Monitor 监听小窗/全屏切换）。 */
  @Computed
  get windowHeight(): number {
    return appState.screenHeight;
  }

  /** 窗口尺寸变化（EntryAbility 更新 appState 后触发）：重算排版视口并重排。 */
  @Monitor('windowWidth', 'windowHeight')
  onWindowSizeChange(): void {
    this.viewportDirty = true;
    this.applyViewportUpdate();
  }

  /** 应用窗口尺寸变化：setPageConfig 重排（只刷页缓存），重绘当前页靠 scheduleConfigRedraw。 */
  private applyViewportUpdate(): void {
    if (!this.viewportDirty || !this.initialized || this.loadingState) {
      return;
    }
    this.viewportDirty = false;
    hilog.info(0x0001, 'ReaderPage', 'windowSizeChange: setPageConfig to update viewport');
    try {
      this.controller.setPageConfig(this.buildSetting());
    } catch (error) {
      // 排版引擎可能尚未就绪
    }
    this.scheduleConfigRedraw();
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

  /** 眉页序号：标题自带「第N章」前缀取之，否则按章节下标生成。 */
  private headerChapterLabel(): string {
    const title: string = this.currentChapterTitle().trim();
    const rest: string = title.replace(FQ_HEADER_PREFIX_RE, '');
    if (title.length > 0 && rest.length < title.length) {
      return title.substring(0, title.length - rest.length);
    }
    return `第${this.chapterIndex + 1}章`;
  }

  /** 眉页章节名：剥掉「第N章」前缀的标题；无前缀返回完整标题，空标题返回空串。 */
  private headerChapterName(): string {
    const title: string = this.currentChapterTitle().trim();
    return title.replace(FQ_HEADER_PREFIX_STRIP_RE, '').trim();
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

  /** 构建整书页数冻结估算：已知章取实测，其余按已知均值（无数据默认 3 页）。
   * 会话内不再随翻页重算，整书页码不逐页跳动；跨章/跳章时以实测逐章校正。 */
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

  /** 眉脚整书页码：已看页数/整书估算页数。 */
  private footerPages(): string {
    if (this.totalChapters <= 0) {
      return '';
    }
    let readPages: number = this.shownPageOffset + 1;
    for (let i: number = 0; i < this.chapterIndex; i++) {
      readPages += this.estimateChapterPages(i);
    }
    let totalPages: number = 0;
    for (let i: number = 0; i < this.totalChapters; i++) {
      totalPages += this.estimateChapterPages(i);
    }
    return `${readPages}/${totalPages}`;
  }

  /** 目录定位：滚动到当前章节（搜索过滤时按过滤后位置定位）。 */
  private locateCurrentChapter(): void {
    const current: FqChapter | undefined = this.chapters[this.chapterIndex];
    let target: number = this.chapterIndex;
    if (current !== undefined) {
      const pos: number = this.displayChapters().indexOf(current);
      if (pos >= 0) {
        target = pos;
      }
    }
    this.drawerScroller.scrollToIndex(target, true);
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
    // 排序不持久化：每次打开目录恢复正序
    this.sheetDescending = false;
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

  /** 目录显示列表：关键字过滤后按排序输出（倒序时反转）。 */
  private displayChapters(): FqChapter[] {
    const list: FqChapter[] = this.filteredChapters();
    if (!this.sheetDescending) {
      return list;
    }
    const reversed: FqChapter[] = list.slice();
    reversed.reverse();
    return reversed;
  }

  /** 目录排序切换：刷新列表并回到当前章节。 */
  private toggleCatalogOrder(): void {
    this.sheetDescending = !this.sheetDescending;
    this.refreshCatalogSource();
  }

  /** 按当前关键字刷新目录懒加载数据源。 */
  private refreshCatalogSource(): void {
    this.chapterSource.setItems(this.displayChapters());
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

  /** 切换字体档位：先备好新字体沙箱副本，setPageConfig 的 fontPath 才指向新文件。 */
  private async changeFont(index: number): Promise<void> {
    if (index === this.fontIndex || index < 0 || index >= FQ_FONT_OPTIONS.length) {
      return;
    }
    this.fontIndex = index;
    if (this.bookParser !== null) {
      await this.bookParser.prepareFont(this.filesDir, this.fontIndex);
    }
    this.applySettingChange();
  }

  private applySettingChange(): void {
    FqReaderStore.saveSettings(this.fontSize, this.lineHeight, this.themeIndex, this.flipIndex,
      this.fontIndex);
    try {
      this.controller.setPageConfig(this.buildSetting());
    } catch (error) {
      // 排版引擎可能尚未就绪
    }
    // setPageConfig 只重排不重绘当前页，设置变更需强制重绘才能即刻生效
    this.scheduleConfigRedraw();
  }

  /** 配置重排完成后强制重绘当前页：重排只刷新页缓存，可见重绘靠 startPlay 原位触发。 */
  private scheduleConfigRedraw(): void {
    if (this.redrawTimer >= 0) {
      clearTimeout(this.redrawTimer);
    }
    const token: number = this.loadToken;
    this.redrawTimer = setTimeout((): void => {
      this.redrawTimer = -1;
      if (token !== this.loadToken) {
        return;
      }
      hilog.info(0x0001, 'ReaderPage', 'configRedraw: startPlay to redraw current page');
      this.redrawStartPlay();
    }, 800);
  }

  /** 原位重绘当前章：回到最近展示位置，位置失效时回退章首。 */
  private async redrawStartPlay(): Promise<void> {
    const domPos: string = this.lastShownStart;
    try {
      await this.controller.startPlay(this.chapterIndex, domPos);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(0x0001, 'ReaderPage', `configRedraw startPlay failed: ${err.message}`);
      if (domPos.length > 0) {
        try {
          await this.controller.startPlay(this.chapterIndex, '');
        } catch (fallbackError) {
          const fallbackErr: BusinessError = fallbackError as BusinessError;
          hilog.error(0x0001, 'ReaderPage', `configRedraw fallback failed: ${fallbackErr.message}`);
        }
      }
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
    // Reader Kit 内置页边距无配置项：等比放大视口与字号，组件把视口整页缩放进
    // 自身区域，视觉字号不变而边距等比缩小（左右内置约 172.5px 缩至约 20vp）
    const viewportScale: number = 1.5;
    const setting: readerCore.ReaderSetting = {
      fontName: '系统字体',
      // 沙箱字体副本路径：引擎直接采用；若仍以资源请求索取则由解析器供给字节
      fontPath: this.bookParser === null ? '' : this.bookParser.getFontSandboxPath(),
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
      // 整书页码冻结估算：目录就绪后构建一次，会话内不随翻页重算
      this.buildChapterEstimates();
      this.chapterSource.setItems(chapters);
      // 整本书一个解析器：目录/书脊与网络目录一一对应，正文由引擎按需拉取
      this.bookParser = new FqOnlineParser(this.bookTitle, chapters,
        (spineIndex: number): Promise<string> => this.fetchChapterText(spineIndex));
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
    if (chapter === undefined || this.bookParser === null) {
      return;
    }
    const token: number = ++this.loadToken;
    hilog.info(0x0001, 'ReaderPage',
      `openChapter index=${index} domPos=${domPos} registered=${this.hasRegisteredBook}`);
    this.menuVisible = false;
    this.onSheetClose();
    this.settingsSheetVisible = false;
    // 跳章：先以实测校正离场章节的冻结估算，整书页码衔接不回跳
    this.refreshChapterEstimate(this.chapterIndex);
    this.chapterIndex = index;
    this.loadingState = true;
    this.errorMsg = '';
    this.lastShownStart = '';
    try {
      await this.controllerReady;
      // 预取本章正文：前置暴露空章节/网络错误，同时预热解析器缓存，
      // 引擎随后 getSpineItemContent(index) 直接命中
      const text: string = await this.fetchChapterText(index);
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
      // 字体：自定义 handler 没有 Kit 内置字体，先备好当前档位的沙箱字体副本，
      // 引擎请求「系统字体.ttf」时由解析器 getResourceContent 返回字节
      await this.bookParser.prepareFont(this.filesDir, this.fontIndex);
      // 一书只注册一次解析器；换章/跳转仅靠 startPlay(spineIndex, domPos) 定位
      if (!this.hasRegisteredBook) {
        this.controller.setPageConfig(this.buildSetting());
        this.controller.registerBookParser(this.bookParser);
        this.hasRegisteredBook = true;
        this.pendingConfigReapply = true;
      }
      try {
        await this.controller.startPlay(index, domPos);
      } catch (playError) {
        // 旧进度 domPos 可能与当前解析结构不匹配，回退章首重试
        if (domPos.length > 0) {
          await this.controller.startPlay(index, '');
        } else {
          throw new Error(`startPlay failed: ${playError}`);
        }
      }
      // 注册/首播期间 Kit 会以默认配置开始首载；此刻再 setPageConfig 会打断进行中的
      // 首载（load failed 4 → 快照被释放 → 卡加载），真实配置改到首个 pageShow 后应用
      FqReaderStore.saveProgress(this.bookId, index, domPos);
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
    return FqBackend.get().chapterText(chapter.itemId, chapter.title);
  }

  private async ensureController(): Promise<void> {
    if (this.initialized) {
      return;
    }
    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.controller.init(context);
    this.controller.on('pageShow', (data: readerCore.PageDataInfo): void => {
      hilog.info(0x0001, 'ReaderPage',
        `pageShow state=${data.state} resourceIndex=${data.resourceIndex} pageOffset=${data.pageOffset} startDomPos=${data.startDomPos}`);
      if (data.state !== readerCore.PageState.PAGE_ON_SHOW) {
        return;
      }
      this.lastShownStart = data.startDomPos;
      // 引擎跨章翻页后 resourceIndex 即当前章节（书脊索引与章节下标一致）
      if (data.resourceIndex >= 0 && data.resourceIndex < this.totalChapters) {
        if (data.resourceIndex !== this.chapterIndex) {
          // 跨章：以实测校正离场章节的冻结估算，整书页码仅此刻变化
          this.refreshChapterEstimate(this.chapterIndex);
        }
        this.chapterIndex = data.resourceIndex;
      }
      // 眉脚页码：记录当前页章内偏移与本章已见页数（供整书页数估算）
      this.shownPageOffset = data.pageOffset >= 0 ? data.pageOffset : 0;
      const knownPages: number | undefined = this.chapterPages.get(this.chapterIndex);
      if (knownPages === undefined || this.shownPageOffset + 1 > knownPages) {
        this.chapterPages.set(this.chapterIndex, this.shownPageOffset + 1);
        FqReaderStore.saveChapterPages(this.bookId, this.chapterPages);
      }
      const domPos: string = data.startDomPos;
      if (domPos.length > 0) {
        FqReaderStore.saveProgress(this.bookId, this.chapterIndex, domPos);
      }
      if (this.pendingConfigReapply) {
        this.pendingConfigReapply = false;
        hilog.info(0x0001, 'ReaderPage', 'first pageShow: reapply real config');
        this.controller.setPageConfig(this.buildSetting());
        // buildSetting 已采集最新窗口尺寸，暂挂的尺寸变化无需再补应用
        this.viewportDirty = false;
        // Kit 默认（浅色）首载完成的瞬间重排为真实主题，但重排只刷页缓存、不重绘
        // 当前显示页：浅色旧渲染会停留到下次翻页。延后 startPlay 原位强制重绘，
        // 重绘派发的 pageShow 抬起遮罩；兜底定时器防重绘异常时遮罩卡死。
        this.scheduleConfigRedraw();
        const token: number = this.loadToken;
        setTimeout((): void => {
          if (token === this.loadToken && this.loadingState) {
            this.loadingState = false;
          }
        }, 1800);
        return;
      }
      this.loadingState = false;
      // 章载中暂挂的窗口尺寸变化（小窗/全屏切换）在此补应用
      this.applyViewportUpdate();
    });
    // 资源请求兜底：handler.getResourceContent 返回空时，引擎经此回调获取字体等资源
    this.controller.on('resourceRequest', (fileName: string): ArrayBuffer => {
      if (this.bookParser !== null) {
        return this.bookParser.serveFontBytes(fileName);
      }
      return new ArrayBuffer(0);
    });
    this.initialized = true;
  }
}

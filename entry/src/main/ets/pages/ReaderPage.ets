/**
 * 小说阅读页（NavDestination，基于 Reader Kit）：
 * 章节正文（v1 图文接口优先，回退旧版 /api/content）写入沙箱 txt 后交
 * ReadPageComponent 排版渲染；Reader Kit 仅支持本地文件，故每章一文件，
 * 切章重排。进度（章节 + domPos）与设置（字号/行距/主题/翻页）持久化。
 * 交互：左右 1/3 透传给组件原生点按翻页，中间 1/3 弹出菜单。
 */

import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { bookParser, ReadPageComponent, readerCore } from '@kit.ReaderKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqChapter, fqKindToTab } from '../model/FqModels';
import { FqReaderProgress, FqReaderStore } from '../core/FqReaderStore';
import { ReaderNavParams } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { CommonLoading, FQ_ACCENT } from '../view/CommonCom';

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

@ComponentV2
export struct ReaderPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local menuVisible: boolean = false;
  @Local drawerVisible: boolean = false;
  @Local settingsVisible: boolean = false;
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
    this.filesDir = getContext(this).filesDir;
    this.load();
  }

  aboutToDisappear(): void {
    this.loadToken += 1;
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
    NavDestination() {
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
        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
          Column()
            .layoutWeight(1)
            .height('100%')
            .onClick(() => this.toggleMenu())
          Column()
            .layoutWeight(1)
            .height('100%')
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')

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
          Column() {
            this.TopBar()
            Blank()
            if (this.settingsVisible) {
              this.SettingsPanel()
            }
            this.BottomBar()
          }
          .width('100%')
          .height('100%')
        }

        if (this.drawerVisible) {
          this.ChapterDrawer()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme().background)
    }
    .hideTitleBar(true)
    .backgroundColor(this.theme().background)
    .onBackPressed((): boolean => {
      if (this.drawerVisible || this.settingsVisible || this.menuVisible) {
        this.drawerVisible = false;
        this.settingsVisible = false;
        this.menuVisible = false;
        return true;
      }
      return false;
    })
  }

  // ---------------------------------------------------------------------------
  // 菜单 / 抽屉 / 设置
  // ---------------------------------------------------------------------------

  @Builder
  private TopBar() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor([this.theme().fontColor])
        .onClick(() => NavPathUtils.pop())
      Column({ space: 2 }) {
        if (this.bookTitle.length > 0) {
          Text(this.bookTitle)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().fontColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.currentChapterTitle())
          .fontSize(12)
          .fontColor(this.theme().fontColor)
          .opacity(0.7)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(`${this.chapterIndex + 1}/${this.totalChapters}`)
        .fontSize(12)
        .fontColor(this.theme().fontColor)
        .opacity(0.7)
    }
    .width('100%')
    .padding({ left: 16, right: 20, top: 10, bottom: 10 })
    .backgroundColor(this.theme().background)
  }

  @Builder
  private BottomBar() {
    Row({ space: 6 }) {
      this.MenuAction($r('sys.symbol.list_bullet'), '目录', (): void => {
        this.openDrawer();
      })
      this.MenuAction($r('sys.symbol.textformat'), '设置', (): void => {
        this.settingsVisible = !this.settingsVisible;
      })
      Divider()
        .vertical(true)
        .strokeWidth(0.5)
        .height(22)
        .color(this.theme().fontColor)
        .opacity(0.2)
        .margin({ left: 8, right: 8 })
      Text('上一章')
        .fontSize(14)
        .fontColor(this.theme().fontColor)
        .opacity(this.hasPrev() ? 1 : 0.35)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => this.openPrev())
      Text('下一章')
        .fontSize(14)
        .fontColor(this.theme().fontColor)
        .opacity(this.hasNext() ? 1 : 0.35)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => this.openNext())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(this.theme().background)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private MenuAction(icon: Resource, label: string, action: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.theme().fontColor])
      Text(label)
        .fontSize(11)
        .fontColor(this.theme().fontColor)
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
    .onClick(() => action())
  }

  @Builder
  private SettingsPanel() {
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
        Blank()
        Text('翻页')
          .fontSize(14)
          .fontColor(this.theme().fontColor)
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
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .backgroundColor(this.theme().background)
    .alignItems(HorizontalAlign.Start)
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

  @Builder
  private ChapterDrawer() {
    Row() {
      Column()
        .layoutWeight(1)
        .height('100%')
        .onClick(() => {
          this.drawerVisible = false;
        })
      Column() {
        Row({ space: 10 }) {
          Text('目录')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme().fontColor)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([this.theme().fontColor])
            .onClick(() => {
              this.drawerVisible = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 12 })

        List({ scroller: this.drawerScroller }) {
          ForEach(this.chapters, (chapter: FqChapter, index: number) => {
            ListItem() {
              Text(chapter.title.length > 0 ? chapter.title : `第${index + 1}章`)
                .fontSize(14)
                .fontColor(index === this.chapterIndex ? FQ_ACCENT : this.theme().fontColor)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 20, right: 20, top: 11, bottom: 11 })
                .onClick(() => this.jumpToChapter(index))
            }
          }, (chapter: FqChapter): string => chapter.itemId)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.5,
          color: this.theme().fontColor,
          startMargin: 20,
          endMargin: 20,
        })
      }
      .width('78%')
      .height('100%')
      .backgroundColor(this.theme().background)
    }
    .width('100%')
    .height('100%')
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

  private theme(): FqReaderTheme {
    return FQ_READER_THEMES[this.themeIndex] ?? FQ_READER_THEMES[0];
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
    if (this.drawerVisible || this.settingsVisible) {
      this.drawerVisible = false;
      this.settingsVisible = false;
      return;
    }
    this.menuVisible = !this.menuVisible;
  }

  private openDrawer(): void {
    this.drawerVisible = true;
    setTimeout(() => {
      this.drawerScroller.scrollToIndex(this.chapterIndex, false);
    }, 100);
  }

  private openPrev(): void {
    if (!this.hasPrev()) {
      return;
    }
    this.openChapter(this.chapterIndex - 1, '', this.loadToken);
  }

  private openNext(): void {
    if (!this.hasNext()) {
      return;
    }
    this.openChapter(this.chapterIndex + 1, '', this.loadToken);
  }

  private jumpToChapter(index: number): void {
    this.drawerVisible = false;
    if (index < 0 || index >= this.totalChapters || index === this.chapterIndex) {
      return;
    }
    this.openChapter(index, '', this.loadToken);
  }

  private retry(): void {
    if (this.chapters.length === 0) {
      this.load();
    } else {
      this.openChapter(this.chapterIndex, '', this.loadToken);
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

  private buildSetting(): readerCore.ReaderSetting {
    const theme: FqReaderTheme = this.theme();
    const displayData: display.Display = display.getDefaultDisplaySync();
    const setting: readerCore.ReaderSetting = {
      fontName: '系统字体',
      fontPath: '',
      fontSize: this.fontSize,
      fontWeight: 400,
      fontColor: theme.fontColor,
      lineHeight: this.lineHeight,
      nightMode: theme.night,
      themeColor: theme.background,
      themeBgImg: '',
      flipMode: this.flipIndex === 1 ? '1' : '0',
      scaledDensity: displayData.scaledDensity > 0 ? displayData.scaledDensity : 1,
      viewPortWidth: displayData.width,
      viewPortHeight: displayData.height,
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
      const progress: FqReaderProgress = FqReaderStore.getProgress(this.bookId);
      let index: number = this.startChapterIndex;
      let domPos: string = '';
      if (index < 0 || index >= chapters.length) {
        index = progress.chapterIndex >= 0 && progress.chapterIndex < chapters.length
          ? progress.chapterIndex : 0;
        domPos = index === progress.chapterIndex ? progress.domPos : '';
      }
      await this.openChapter(index, domPos, token);
    } catch (error) {
      if (token === this.loadToken) {
        this.errorMsg = fqErrorMessage(error);
        this.loadingState = false;
      }
    }
  }

  private async openChapter(index: number, domPos: string, token: number): Promise<void> {
    const chapter: FqChapter | undefined = this.chapters[index];
    if (chapter === undefined) {
      return;
    }
    this.menuVisible = false;
    this.drawerVisible = false;
    this.settingsVisible = false;
    this.chapterIndex = index;
    this.loadingState = true;
    this.errorMsg = '';
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

/**
 * 详情页（NavDestination）：按原版小说详情布局复刻。
 *
 * 对齐 fqapp lib/pages/detail_page.dart 与 widgets/detail/*（M1 子集）：
 * Hero（封面+标题+元信息+原创标）/作者卡/数据卡/书籍简介展开/标签/
 * 作品 ID（可复制）/查看目录 + 章节试读预览/底部悬浮操作栏（听书/下载/开始阅读）。
 * 阅读器、听书、下载动作在后续版本接入，当前先占位提示。
 */

import pasteboard from '@ohos.pasteboard';
import { promptAction } from '@kit.ArkUI';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqBookDetail, FqChapter, fqEmptyBookDetail, fqKindToTab, fqKindLabel } from '../model/FqModels';
import { FqShelfStore, FqShelfItem } from '../core/FqShelfStore';
import { DetailNavParams, FqTitleBarOptions, ReaderNavParams, ROUTE_READER } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { CommonNav } from '../view/CommonNav';
import { CommonLoading, FQ_ACCENT } from '../view/CommonCom';
import { appState } from '../entryability/AppState';

/** 目录预览行数（对齐 fqapp _previewChapterCount）。 */
const FQ_PREVIEW_CHAPTER_COUNT: number = 3;

/** 简介超过该长度才展示展开/收起。 */
const FQ_DESC_TOGGLE_THRESHOLD: number = 60;

/** 滚动内容起始偏移：标题栏 56（对齐首页 List 避让） */
const FQ_DETAIL_TOP_INSET: number = 56;

/** 滚动内容末尾偏移：悬浮阅读栏 72 + 底部间距 24 */
const FQ_DETAIL_BOTTOM_INSET: number = 96;

@ComponentV2
export struct DetailPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local detail: FqBookDetail = fqEmptyBookDetail();
  @Local headerTitle: string = '详情';
  @Local chapters: FqChapter[] = [];
  @Local previews: Map<string, string> = new Map();
  @Local descExpanded: boolean = false;
  @Local inShelf: boolean = false;
  private itemId: string = '';
  private itemKind: string = 'book';
  private itemCover: string = '';
  private loadToken: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.itemId = DetailNavParams.id;
    this.itemKind = DetailNavParams.kind;
    this.itemCover = DetailNavParams.cover;
    this.headerTitle = `${fqKindLabel(this.itemKind)}详情`;
    FqShelfStore.init(getContext(this));
    this.inShelf = FqShelfStore.contains(this.itemId);
    this.load();
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions(this.headerTitle, false, undefined, (): void => {
        this.load();
      }, false, (): void => {
        this.toggleShelf();
      }, this.inShelf),
      scroller: this.scroller,
      doubleTapToTop: true,
      scrollToTopYOffset: -(appState.topRect + FQ_DETAIL_TOP_INSET),
      isShowBar: true,
      readBarKind: this.itemKind,
      readerBarClick: (key: string): void => { this.onReadBarAction(key) }
    }) {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.loadingState) {
          Column({ space: 12 }) {
            CommonLoading({ sizeValue: 36, loadColor: FQ_ACCENT })
            Text('正在加载书籍与目录')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .backgroundColor('#FF7A3D')
              .onClick(() => this.load())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ scroller: this.scroller, space: 16 }) {
            ListItem(){
              this.Hero()
            }

            if (this.detail.author.length > 0) {
              ListItem(){
                this.AuthorCard()
              }
            }
            if (this.readLabel().length > 0 || this.scoreValue() > 0) {
              ListItem(){
                this.StatsCard()
              }
            }

            ListItem(){
              this.DescriptionBlock()
            }

            if (this.detail.tags.length > 0) {
              ListItem(){
                this.TagChips()
              }
            }
            ListItem(){
              this.IdRow()
            }
            ListItem(){
              this.DirectoryRow()
            }
            ListItem(){
              this.ChapterPreview()
            }
          }
          .padding({ left: 20, right: 20 })
          .scrollBar(BarState.Off)
          .contentStartOffset(appState.topRect + FQ_DETAIL_TOP_INSET)
          .contentEndOffset(appState.bottomRect + FQ_DETAIL_BOTTOM_INSET)
          .width('100%')
          .height('100%')
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 顶部主视觉：封面 + 标题 + 元信息 + 原创标（暖色渐变衬底）。 */
  @Builder
  private Hero() {
    Row({ space: 18 }) {
      if (this.coverUrl().length > 0) {
        Image(this.coverUrl())
          .width(104)
          .height(139)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .autoResize(true)
      } else {
        Column()
          .width(104)
          .height(139)
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_secondary'))
      }
      Column({ space: 8 }) {
        Text(this.detail.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .lineHeight(27)
        if (this.metaLine().length > 0) {
          Text(this.metaLine())
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
        }
        if (this.detail.original) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars'))
              .fontSize(11)
              .fontColor([FQ_ACCENT])
            Text('原创')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(FQ_ACCENT)
          }
          .alignItems(VerticalAlign.Center)
          .padding({ left: 8, right: 8, top: 3.5, bottom: 3.5 })
          .borderRadius(6)
          .backgroundColor('#1AFF7A3D')
          .border({ width: 0.6, color: '#52FF7A3D' })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 10, bottom: 12 })
    .alignItems(VerticalAlign.Top)
  }

  /** 作者卡：头像 + 笔名 + 头衔徽标 + 引导文案。 */
  @Builder
  private AuthorCard() {
    Row({ space: 12 }) {
      if (this.authorAvatarUrl().length > 0) {
        Image(this.authorAvatarUrl())
          .width(38)
          .height(38)
          .borderRadius(19)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .autoResize(true)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(38)
            .height(38)
            .borderRadius(19)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
          SymbolGlyph($r('sys.symbol.person_fill'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_tertiary')])
        }
      }
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.detail.author)
            .fontSize(14.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.detail.authorTitle.length > 0) {
            Text(this.detail.authorTitle)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor('#E9A23B')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor('#24E9A23B')
          }
        }
        .alignItems(VerticalAlign.Center)
        Text('查看作者主页和全部作品')
          .fontSize(11.5)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .alignItems(VerticalAlign.Center)
  }

  /** 数据卡：正在阅读 | 评分 + 星级。 */
  @Builder
  private StatsCard() {
    Row() {
      if (this.readLabel().length > 0) {
        Column({ space: 3 }) {
          Text(this.readLabel())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text('正在阅读')
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        if (this.scoreValue() > 0) {
          Divider()
            .vertical(true)
            .strokeWidth(0.6)
            .height(36)
            .color($r('sys.color.comp_divider'))
        }
      }
      if (this.scoreValue() > 0) {
        Column({ space: 3 }) {
          Text(this.detail.scoreText)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFA000')
          Row({ space: 2 }) {
            ForEach([1, 2, 3, 4, 5], (star: number) => {
              SymbolGlyph(star <= Math.floor(this.scoreValue() / 2) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
                .fontSize(11)
                .fontColor([star <= Math.floor(this.scoreValue() / 2) ? FQ_ACCENT : $r('sys.color.comp_divider')])
            }, (star: number): string => `${star}`)
          }
          .alignItems(VerticalAlign.Center)
          Text('读者评分')
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 16, left: 8, right: 8 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
  }

  /** 书籍简介：标题条 + 三行截断 + 展开/收起。 */
  @Builder
  private DescriptionBlock() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column()
          .width(3.5)
          .height(14)
          .borderRadius(2)
          .backgroundColor(FQ_ACCENT)
        Text('书籍简介')
          .fontSize(16.5)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      .alignItems(VerticalAlign.Center)
      Text(this.detail.abstractText.length > 0 ? this.detail.abstractText : '暂无简介')
        .fontSize(13.5)
        .fontColor(this.detail.abstractText.length > 0 ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
        .lineHeight(25)
        .maxLines(this.descExpanded ? 999 : 3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.detail.abstractText.length > FQ_DESC_TOGGLE_THRESHOLD) {
        Row({ space: 3 }) {
          Text(this.descExpanded ? '收起' : '展开')
            .fontSize(12.5)
            .fontColor(FQ_ACCENT)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([FQ_ACCENT])
            .rotate({ angle: this.descExpanded ? 180 : 0 })
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .justifyContent(FlexAlign.End)
        .onClick(() => {
          this.descExpanded = !this.descExpanded;
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 分类标签药丸。 */
  @Builder
  private TagChips() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
      ForEach(this.detail.tags, (tag: string) => {
        Text(tag)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 13, right: 13, top: 6.5, bottom: 6.5 })
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .border({ width: 0.6, color: $r('sys.color.comp_divider') })
          .margin({ right: 8, bottom: 8 })
      }, (tag: string): string => tag)
    }
    .width('100%')
  }

  /** 作品 ID 行：点击复制，便于 `id:` 搜索找回。 */
  @Builder
  private IdRow() {
    Row({ space: 8 }) {
      Text('#')
        .fontSize(14)
        .fontColor($r('sys.color.font_tertiary'))
      Text(this.detail.bookId.length > 0 ? this.detail.bookId : this.itemId)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
        .fontSize(16)
        .fontColor([$r('sys.color.icon_tertiary')])
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => this.copyId())
  }

  /** 查看目录行：章节单元按 kind 区分 章/集/话。 */
  @Builder
  private DirectoryRow() {
    Row() {
      Column()
        .width(3.5)
        .height(14)
        .borderRadius(2)
        .backgroundColor(FQ_ACCENT)
        .margin({ right: 8 })
      Text('查看目录')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      if (this.directoryTrailing().length > 0) {
        Text(this.directoryTrailing())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([$r('sys.color.icon_tertiary')])
        .margin({ left: 4 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .alignItems(VerticalAlign.Center)
  }

  /** 章节试读预览：序号 + 章节名 + 正文开头摘录。 */
  @Builder
  private ChapterPreview() {
    List() {
      ForEach(this.previewChapters(), (chapter: FqChapter, index: number) => {
        ListItem(){
          Row({ space: 14 }){
            Text(this.padIndex(index + 1))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)

            Column({ space: 10 }) {
              Row({ space: 10 }) {
                Text(chapter.title)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_primary'))
                  .lineHeight(22)
                  .maxLines(1)
                  .layoutWeight(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(15)
                  .fontColor([$r('sys.color.icon_tertiary')])
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .justifyContent(FlexAlign.SpaceBetween)

              if (this.previewOf(chapter.itemId).length > 0) {
                Text(this.previewOf(chapter.itemId))
                  .fontSize(12)
                  .fontColor($r('sys.color.font_tertiary'))
                  .lineHeight(20)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }.width('100%').padding(14).onClick(() => this.openReader(index))
        }
      }, (chapter: FqChapter): string => chapter.itemId)
      if (this.previewChapters().length === 0) {
        ListItem(){
          Text('暂未获取到章节，可以稍后刷新重试')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(16)
        }
      }
    }
    .width('100%')
    .clip(true)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .divider({
      strokeWidth: 0.5,
      startMargin: 42,
      endMargin: 14,
      color: $r('sys.color.comp_divider')
    })
  }

  private coverUrl(): string {
    if (this.detail.cover.length > 0) {
      return FqBackend.get().resourceUrl(this.detail.cover);
    }
    if (this.itemCover.length > 0) {
      return FqBackend.get().resourceUrl(this.itemCover);
    }
    return '';
  }

  private authorAvatarUrl(): string {
    if (this.detail.authorAvatar.length > 0) {
      return FqBackend.get().resourceUrl(this.detail.authorAvatar);
    }
    return '';
  }

  private metaLine(): string {
    const parts: string[] = [];
    if (this.detail.category.length > 0) {
      parts.push(this.detail.category);
    }
    if (this.detail.statusLabel.length > 0) {
      parts.push(this.detail.statusLabel);
    }
    if (this.detail.wordLabel.length > 0) {
      parts.push(this.detail.wordLabel);
    }
    return parts.join(' · ');
  }

  private readLabel(): string {
    return this.detail.readLabel;
  }

  private scoreValue(): number {
    const parsed: number = Number.parseFloat(this.detail.scoreText);
    if (Number.isNaN(parsed) || parsed <= 0 || parsed > 10) {
      return 0;
    }
    return parsed;
  }

  /** 目录行尾注：完结/连载状态 + 共 N 章/集/话。 */
  private directoryTrailing(): string {
    const unit: string = this.chapterUnit();
    const parts: string[] = [];
    if (this.detail.statusLabel.length > 0) {
      parts.push(this.detail.statusLabel);
    }
    if (this.chapters.length > 0) {
      parts.push(`共 ${this.chapters.length} ${unit}`);
    } else if (this.detail.serialCount > 0) {
      parts.push(`共 ${this.detail.serialCount} ${unit}`);
    }
    return parts.join(' ');
  }

  private chapterUnit(): string {
    if (this.itemKind === 'video') {
      return '集';
    }
    if (this.itemKind === 'manga') {
      return '话';
    }
    return '章';
  }

  private previewChapters(): FqChapter[] {
    if (this.chapters.length <= FQ_PREVIEW_CHAPTER_COUNT) {
      return this.chapters;
    }
    return this.chapters.slice(0, FQ_PREVIEW_CHAPTER_COUNT);
  }

  private previewOf(itemId: string): string {
    const text: string | undefined = this.previews.get(itemId);
    if (text === undefined) {
      return '';
    }
    return text;
  }

  private padIndex(index: number): string {
    return index < 10 ? `0${index}` : `${index}`;
  }

  private copyId(): void {
    const id: string = this.detail.bookId.length > 0 ? this.detail.bookId : this.itemId;
    if (id.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, id);
      pasteboard.getSystemPasteboard().setData(data)
        .then(() => {
          promptAction.showToast({ message: '已复制作品 ID', duration: 1500 });
        })
        .catch(() => {
          promptAction.showToast({ message: '复制失败', duration: 1500 });
        });
    } catch (error) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  private toggleShelf(): void {
    const added: boolean = FqShelfStore.toggle(
      new FqShelfItem(this.detail.bookId.length > 0 ? this.detail.bookId : this.itemId,
        this.itemKind, this.detail.title, this.detail.cover));
    this.inShelf = added;
    promptAction.showToast({ message: added ? '已加入书架' : '已移出书架', duration: 1500 });
  }

  private comingSoon(feature: string): void {
    promptAction.showToast({ message: `${feature}功能即将上线`, duration: 1500 });
  }

  /** 底部操作栏：小说"阅读"进阅读器，其余动作占位。 */
  private onReadBarAction(key: string): void {
    if (key === '阅读' && this.itemKind === 'book') {
      this.openReader(-1);
      return;
    }
    this.comingSoon(key);
  }

  private openReader(chapterIndex: number): void {
    ReaderNavParams.id = this.detail.bookId.length > 0 ? this.detail.bookId : this.itemId;
    ReaderNavParams.kind = this.itemKind;
    ReaderNavParams.title = this.detail.title;
    ReaderNavParams.chapterIndex = chapterIndex;
    NavPathUtils.push(ROUTE_READER);
  }

  private async load(): Promise<void> {
    if (this.itemId.length === 0) {
      this.errorMsg = '无效的作品';
      this.loadingState = false;
      return;
    }
    const token: number = ++this.loadToken;
    this.loadingState = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const tab: string = fqKindToTab(this.itemKind);
      const contentId: string = this.detail.bookId.length > 0 ? this.detail.bookId : this.itemId;
      const detail: FqBookDetail = await FqBackend.get().bookDetail(this.itemId, tab);
      if (token !== this.loadToken) {
        return;
      }
      this.detail = detail;
      let chapters: FqChapter[] = [];
      try {
        chapters = await FqBackend.get().directoryChapters(contentId, tab);
      } catch (error) {
        chapters = [];
      }
      if (token !== this.loadToken) {
        return;
      }
      this.chapters = chapters;
      const previewIds: string[] = [];
      for (const chapter of chapters) {
        if (previewIds.length >= FQ_PREVIEW_CHAPTER_COUNT) {
          break;
        }
        if (chapter.itemId.length > 0) {
          previewIds.push(chapter.itemId);
        }
      }
      this.previews = await FqBackend.get().chapterSummaries(contentId, previewIds);
      if (token !== this.loadToken) {
        return;
      }
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loadingState = false;
      }
    }
  }
}

/**
 * 评论公共组件（阅读页/听书页章评半模态与详情页书评预览共用）：
 * - FqCommentSource：评论懒加载数据源（续拉按 comment_id 去重）；
 * - FqCommentTile：单条评论（头像/名字/星级/时间 + 正文 + 图片 + 点赞回复计数），
 *   字体色随宿主主题注入（阅读页传阅读主题墨色，详情页传系统色），正文可限行；
 * - FqCommentSheet：评论半模态内容（CommonSheet 壳 + 首拉 Loading / 错误重试 /
 *   空态 / LazyForEach 触底续拉），aboutToAppear 自动拉第一页；
 *   chapterItemId 非空走章评配方（章末聚合桶 + cursor 分页），空走书评；
 *   cursorLoader 非空走自定义页加载器（播放页集评：弹幕接口 cursor 分页，
 *   加载器自理 cursor，refresh=true 重拉首页）。
 * - fqCommentSheetHeightVp：统一 Sheet 高度（屏高 82%）。
 */

import { display } from '@kit.ArkUI';
import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqBookComment, FqBookCommentPage, FqChapterIdeaMeta, fqFormatCountInt } from '../../model/FqModels';
import { CommonLoading, FQ_ACCENT } from '../CommonCom';
import { CommonSheet } from './CommonSheet';
import { appState } from '../../entryability/AppState';

/** 书评懒加载数据源：持已加载书评，续拉按 comment_id 去重后通知 LazyForEach 刷新。 */
class FqCommentSource implements IDataSource {
  private items: FqBookComment[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqBookComment[]): void {
    this.items = items;
    this.notifyReloaded();
  }

  /** 续拉追加：非空 comment_id 与已有条目去重，避免分页交界重复渲染。 */
  appendItems(items: FqBookComment[]): void {
    for (const item of items) {
      if (item.id.length > 0 && this.containsId(item.id)) {
        continue;
      }
      this.items.push(item);
    }
    this.notifyReloaded();
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

  private containsId(id: string): boolean {
    for (const known of this.items) {
      if (known.id === id) {
        return true;
      }
    }
    return false;
  }

  private notifyReloaded(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 书评 Sheet 高度：屏高 82%（vp），异常回退 600。 */
export function fqCommentSheetHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  const height: number = Math.round((screenHeight / density) * 0.82);
  return height > 0 ? height : 600;
}

/** 单条书评：头像 + 名字/星级/时间 + 正文 + 图片 + 点赞回复计数。 */
@ComponentV2
export struct FqCommentTile {
  @Param comment: FqBookComment =
    new FqBookComment('', '', [], 0, 0, 0, 0, 0, '', '', false);
  /** 字体色随宿主主题（阅读页墨色 / 详情页系统色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 正文最大行数（0 不限；详情页预览传 4）。 */
  @Param textMaxLines: number = 0;
  @Param paddingValue: number = 20

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Stack() {
          Column() {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(16)
              .fontColor([this.fontColor])
              .opacity(0.55)
          }
          .width(30)
          .height(30)
          .borderRadius(15)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          if (this.comment.userAvatar.length > 0) {
            Image(this.comment.userAvatar)
              .width(30)
              .height(30)
              .borderRadius(15)
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }
        }
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(this.comment.userName.length > 0 ? this.comment.userName : '书友')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.fontColor)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.comment.isAuthor) {
              Text('作者')
                .fontSize(9)
                .fontColor(Color.White)
                .backgroundColor(FQ_ACCENT)
                .borderRadius(4)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            }
          }
          .width('100%')
          Row({ space: 8 }) {
            if (this.comment.score > 0) {
              Rating({
                rating: this.comment.stars,
                indicator: true,
              })
            }
            if (this.comment.relativeTime().length > 0) {
              Text(this.comment.relativeTime())
                .fontSize(11)
                .fontColor(this.fontColor)
                .opacity(0.55)
                .maxLines(1)
            }
            if (this.comment.readDurationLabel.length > 0) {
              Text(this.comment.readDurationLabel)
                .fontSize(11)
                .fontColor(this.fontColor)
                .opacity(0.55)
                .maxLines(1)
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')

      Text(this.comment.text)
        .fontSize(13.5)
        .lineHeight(22)
        .fontColor(this.fontColor)
        .width('100%')
        .maxLines(this.textMaxLines > 0 ? this.textMaxLines : 9999)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.comment.imageUrls.length > 0) {
        Row({ space: 6 }) {
          ForEach(this.comment.imageUrls.slice(0, 3), (url: string) => {
            Image(url)
              .width(76)
              .height(76)
              .borderRadius(6)
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }, (url: string): string => url)
        }
        .alignItems(VerticalAlign.Top)
      }

      Row({ space: 14 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.hand_thumbsup'))
            .fontSize(13)
            .fontColor([this.fontColor])
            .opacity(0.55)
          Text(fqFormatCountInt(this.comment.diggCount))
            .fontSize(11)
            .fontColor(this.fontColor)
            .opacity(0.55)
        }
        .alignItems(VerticalAlign.Center)
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(13)
            .fontColor([this.fontColor])
            .opacity(0.55)
          Text(fqFormatCountInt(this.comment.replyCount))
            .fontSize(11)
            .fontColor(this.fontColor)
            .opacity(0.55)
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 14, bottom: 14, left: this.paddingValue, right: this.paddingValue })
  }
}

/** 书评/章评半模态内容：公共 sheet 承载懒加载列表，aboutToAppear 自动拉第一页。 */
@ComponentV2
export struct FqCommentSheet {
  @Param bookId: string = '';
  /** 字体色随宿主主题（阅读页墨色 / 详情页系统色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 评论类型文案（书评 / 章评等，随入口）。 */
  @Param commentLabel: string = '书评';
  /** 章评模式：当前章节 itemId（非空启用章评配方；空走书评）。 */
  @Param chapterItemId: string = '';
  /** 章评模式：当前章节内容版本（章评接口必传）。 */
  @Param chapterVersion: string = '';
  /** 自定义页加载器（集评等 cursor 分页场景）：非空时优先于内置书评/章评配方，
   *  refresh=true 重置拉首页、false 触底续拉，cursor 由加载器自理。 */
  @Param cursorLoader: ((refresh: boolean) => Promise<FqBookCommentPage>) | undefined = undefined;
  /** 打开令牌：宿主每次打开 +1，组件据此重置分页并重拉（兼容内容重建/复用两种挂载）。 */
  @Param openToken: number = 0;
  @Local loading: boolean = false;
  @Local errorMsg: string = '';
  @Local count: number = 0;
  @Local total: number = 0;
  @Local hasMore: boolean = false;
  @Local loadingMore: boolean = false;
  @Local moreFailed: boolean = false;
  private source: FqCommentSource = new FqCommentSource();
  private scroller: Scroller = new Scroller();
  private nextOffset: number = 0;
  /** 章评模式：已解析的章末聚合段键（-1 未解析）。 */
  private resolvedParaIndex: number = -1;
  /** 加载代际：重开重载递增，作废在途请求的迟到写入。 */
  private loadGen: number = 0;

  aboutToAppear(): void {
    this.loadComments(true);
  }

  @Monitor('openToken')
  onOpenTokenChange(): void {
    this.resetForReload();
  }

  /** 重开重载：清列表与分页状态后重拉首页（章评模式同时重解析章末段键）。 */
  private resetForReload(): void {
    this.loadGen += 1;
    this.source.setItems([]);
    this.count = 0;
    this.total = 0;
    this.hasMore = false;
    this.moreFailed = false;
    this.loadingMore = false;
    this.loading = false;
    this.nextOffset = 0;
    this.resolvedParaIndex = -1;
    this.loadComments(true);
  }

  /** Sheet 标题：总数就绪后带计数（章评 · 123）。 */
  private sheetTitle(): string {
    return this.total > 0 ? `${this.commentLabel} · ${this.total}` : this.commentLabel;
  }

  /** 拉取评论一页：refresh 重置分页（首开/重试），否则触底续拉；
   *  cursorLoader 非空走自定义页加载器，章评模式（chapterItemId 非空）走章末聚合桶
   *  配方（无章评桶时落空态），其余走书评配方。 */
  private async loadComments(refresh: boolean): Promise<void> {
    if (this.bookId.length === 0) {
      return;
    }
    const chapterMode: boolean = this.chapterItemId.length > 0;
    if (refresh) {
      if (this.loading) {
        return;
      }
      this.loading = true;
      this.errorMsg = '';
    } else {
      if (this.loading || this.loadingMore || !this.hasMore) {
        return;
      }
      this.loadingMore = true;
      this.moreFailed = false;
    }
    const gen: number = this.loadGen;
    if (chapterMode && this.resolvedParaIndex < 0) {
      let meta: FqChapterIdeaMeta;
      try {
        meta = await FqBackend.get().chapterIdeaMeta(this.chapterItemId);
      } catch (error) {
        if (gen !== this.loadGen) {
          return;
        }
        if (refresh) {
          this.errorMsg = fqErrorMessage(error);
          this.loading = false;
        } else {
          this.loadingMore = false;
          this.moreFailed = true;
        }
        return;
      }
      if (gen !== this.loadGen) {
        return;
      }
      this.resolvedParaIndex = meta.endParaIndex;
      if (this.resolvedParaIndex < 0) {
        // 无章评数据：空态（不请求评论列表）
        if (refresh) {
          this.loading = false;
        } else {
          this.loadingMore = false;
        }
        return;
      }
    }
    const offset: number = refresh ? 0 : this.nextOffset;
    try {
      let page: FqBookCommentPage;
      const loader: ((refresh: boolean) => Promise<FqBookCommentPage>) | undefined = this.cursorLoader;
      if (loader !== undefined) {
        page = await loader(refresh);
      } else if (chapterMode) {
        page = await FqBackend.get().chapterComments(this.bookId, this.chapterItemId,
          this.chapterVersion, this.resolvedParaIndex, 20, refresh ? '' : `${offset}`);
      } else {
        page = await FqBackend.get().bookComments(this.bookId, 20, offset);
      }
      if (gen !== this.loadGen) {
        return;
      }
      if (refresh) {
        this.source.setItems(page.comments);
        this.nextOffset = page.nextOffset > 0 ? page.nextOffset : page.comments.length;
        this.hasMore = page.hasMore && page.comments.length > 0;
        this.loading = false;
      } else {
        this.source.appendItems(page.comments);
        const advanced: number = page.nextOffset > offset ? page.nextOffset : offset + page.comments.length;
        this.nextOffset = advanced;
        this.hasMore = page.hasMore && page.comments.length > 0 && advanced > offset;
        this.loadingMore = false;
      }
      this.total = page.totalCount;
      this.count = this.source.totalCount();
    } catch (error) {
      if (gen !== this.loadGen) {
        return;
      }
      if (refresh) {
        this.errorMsg = fqErrorMessage(error);
        this.loading = false;
      } else {
        this.loadingMore = false;
        this.moreFailed = true;
      }
    }
  }

  build() {
    CommonSheet({
      sheetTitle: this.sheetTitle(),
    }) {
      Column() {
        if (this.loading) {
          Column({ space: 10 }) {
            CommonLoading({ sizeValue: 36, loadColor: FQ_ACCENT })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor(this.fontColor)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .backgroundColor(FQ_ACCENT)
              .onClick(() => {
                this.loadComments(true);
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.count === 0) {
          Column() {
            Text(`暂无${this.commentLabel}`)
              .fontSize(14)
              .fontColor(this.fontColor)
              .opacity(0.55)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.source, (comment: FqBookComment) => {
              ListItem() {
                FqCommentTile({
                  comment: comment,
                  fontColor: this.fontColor,
                })
              }
            }, (comment: FqBookComment): string =>
              comment.id.length > 0 ? comment.id : `c${comment.createdAtMs}_${comment.text.length}`)
            ListItem() {
              this.MoreFooter()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .cachedCount(8)
          .scrollBar(BarState.Off)
          .contentEndOffset(appState.bottomRect)
          .divider({
            strokeWidth: 0.5,
            color: $r('sys.color.comp_divider'),
            startMargin: 20,
            endMargin: 20,
          })
          .onReachEnd((): void => {
            this.loadComments(false);
          })
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 书评列表底态：续拉 Loading / 失败重试 / 没有更多。 */
  @Builder
  private MoreFooter() {
    if (this.loadingMore) {
      Row({ space: 8 }) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(FQ_ACCENT)
        Text('正在加载')
          .fontSize(12)
          .fontColor(this.fontColor)
          .opacity(0.55)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 14, bottom: 14 })
    } else if (this.moreFailed) {
      Text('加载失败，点击重试')
        .fontSize(12)
        .fontColor(this.fontColor)
        .opacity(0.55)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
        .onClick(() => {
          this.loadComments(false);
        })
    } else if (!this.hasMore) {
      Text(`没有更多${this.commentLabel}了`)
        .fontSize(12)
        .fontColor(this.fontColor)
        .opacity(0.55)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
    }
  }
}

/**
 * 评论回复公共组件（书评/章评/漫评/段评共用，对齐 fqapp PR #278 回复展示）：
 * - FqReplySource：回复懒加载数据源（LazyForEach）；
 * - FqReplyTile：单条回复瓦片（评论瓦片同款排版：头像/名字/时间 + 正文（官方括号
 *   表情内联渲染）+ 配图（点击一镜到底全屏放大）+ 点赞；除配图外不可点）；
 * - FqReplySection：评论卡片内「展开 N 条回复」区块（首次点击懒加载 + 失败重试 +
 *   List/LazyForEach 内联回复列表）；展开后「收起」行挪到展开回复的尾部；
 *   回复超出单页（50 条）时尾注提示可点击续拉（count 递增重拉：服务端 cursor
 *   恒空串无翻页，靠加大 count 换更多条目；无新增条目视为已达上限停止续拉）；
 * - fqReplyListMaxHeightVp：展开回复列表最大高度（屏高 55%，超出内滚并联动外层滚动）。
 */

import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../../entryability/AppState';
import { FqCommentReply, FqCommentReplyPage, fqFormatCountInt } from '../../model/FqModels';
import { FqCommentImages } from '../FqImageViewer';
import { FqCommentEmojiText } from '../FqCommentEmoji';

/** 展开回复列表最大高度：屏高 55%（vp），异常回退 420。 */
export function fqReplyListMaxHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  const height: number = Math.round((screenHeight / density) * 0.55);
  return height > 0 ? height : 420;
}

/** 瓦片实例序号（geometryTransition 一镜到底 id 唯一化用）。 */
let fqReplyTileSeq: number = 0;

function fqNextReplyTileSeq(): number {
  fqReplyTileSeq += 1;
  return fqReplyTileSeq;
}

/** 回复懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class FqReplySource implements IDataSource {
  private items: FqCommentReply[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqCommentReply[]): void {
    this.items = items;
    this.notifyReloaded();
  }

  /** 追加一页（LazyForEach 增量通知，不整体重建）。 */
  appendItems(items: FqCommentReply[]): void {
    if (items.length === 0) {
      return;
    }
    const base: number = this.items.length;
    this.items = this.items.concat(items);
    for (let i = 0; i < items.length; i++) {
      this.notifyAdded(base + i);
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

  private notifyReloaded(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  private notifyAdded(index: number): void {
    for (const listener of this.listeners) {
      listener.onDataAdd(index);
    }
  }
}

/** 单条回复瓦片：评论瓦片同款排版；仅配图可点（点击一镜到底放大），其余不可点。 */
@ComponentV2
export struct FqReplyTile {
  @Param reply: FqCommentReply =
    new FqCommentReply('', '', [], 0, 0, '', '');
  /** 字体色随宿主主题（阅读页墨色 / 系统色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  private readonly tileSeq: number = fqNextReplyTileSeq();

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
          if (this.reply.userAvatar.length > 0) {
            Image(this.reply.userAvatar)
              .width(30)
              .height(30)
              .borderRadius(15)
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }
        }
        Column({ space: 4 }) {
          Text(this.reply.userName.length > 0 ? this.reply.userName : '书友')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fontColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.reply.relativeTime().length > 0) {
            Text(this.reply.relativeTime())
              .fontSize(11)
              .fontColor(this.fontColor)
              .opacity(0.55)
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')

      if (this.reply.text.length > 0) {
        FqCommentEmojiText({
          text: this.reply.text,
          fontSize: 13.5,
          fontColor: this.fontColor,
          lineHeight: 22,
        })
      }

      if (this.reply.imageUrls.length > 0) {
        FqCommentImages({
          imageUrls: this.reply.imageUrls,
          geometryPrefix: `r${this.tileSeq}_${this.reply.id}`,
        })
      }

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.hand_thumbsup'))
          .fontSize(13)
          .fontColor([this.fontColor])
          .opacity(0.55)
        Text(fqFormatCountInt(this.reply.diggCount))
          .fontSize(11)
          .fontColor(this.fontColor)
          .opacity(0.55)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 评论卡片内回复区块：展开计数行 + List 懒加载回复列表；展开后「收起」挪到尾部。 */
@ComponentV2
export struct FqReplySection {
  /** 父评论 id（回复加载入参）。 */
  @Param commentId: string = '';
  /** 父评论回复数（计数行展示）。 */
  @Param replyCount: number = 0;
  /** 字体色随宿主主题。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 回复加载器（宿主注入，group_id=book_id=书 id；count 为拉取条数）；未注入保持只读计数不展开。 */
  @Param replyLoader: ((commentId: string, count: number) => Promise<FqCommentReplyPage>) | undefined = undefined;
  @Local expanded: boolean = false;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  @Local loaded: boolean = false;
  @Local loadingMore: boolean = false;
  @Local loadedCount: number = 0;
  @Local total: number = 0;
  @Local hasMore: boolean = false;
  private source: FqReplySource = new FqReplySource();

  /** 展开/收起：首次点击拉取回复后展开，再点切换开合（数据保留秒开）；失败可点击重试。 */
  private toggleReplies(): void {
    if (this.loading) {
      return;
    }
    const loader: ((commentId: string, count: number) => Promise<FqCommentReplyPage>) | undefined = this.replyLoader;
    if (loader === undefined || this.commentId.length === 0) {
      return;
    }
    if (this.loaded) {
      this.expanded = !this.expanded;
      return;
    }
    this.loading = true;
    this.failed = false;
    loader(this.commentId, 50)
      .then((page: FqCommentReplyPage): void => {
        this.loading = false;
        this.loaded = true;
        this.source.setItems(page.replies);
        this.loadedCount = page.replies.length;
        this.total = page.totalCount;
        this.hasMore = page.hasMore;
        this.expanded = true;
      })
      .catch((_error: BusinessError): void => {
        this.loading = false;
        this.failed = true;
      });
  }

  /** 续拉更多回复：cursor 恒空串无翻页，靠 count 递增（已载 + 50）重拉换更多条目；
   *  返回条数无增长（服务端单页上限）即停止续拉。 */
  private loadMoreReplies(): void {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    const loader: ((commentId: string, count: number) => Promise<FqCommentReplyPage>) | undefined = this.replyLoader;
    if (loader === undefined || this.commentId.length === 0) {
      return;
    }
    this.loadingMore = true;
    loader(this.commentId, this.loadedCount + 50)
      .then((page: FqCommentReplyPage): void => {
        this.loadingMore = false;
        if (page.replies.length > this.loadedCount) {
          this.source.appendItems(page.replies.slice(this.loadedCount));
          this.loadedCount = page.replies.length;
          this.total = page.totalCount;
          this.hasMore = page.hasMore;
        } else {
          this.hasMore = false;
        }
      })
      .catch((_error: BusinessError): void => {
        this.loadingMore = false;
      });
  }

  /** 折叠态计数行文案（对齐 fqapp：展开N条回复 / 加载中 / 失败重试）。 */
  private counterLabel(): string {
    if (this.loading) {
      return '加载中';
    }
    if (this.failed) {
      return '回复加载失败，点击重试';
    }
    return `展开${fqFormatCountInt(this.replyCount)}条回复`;
  }

  build() {
    Column({ space: 8 }) {
      if (this.expanded && this.loaded) {
        Column({ space: 8 }) {
          if (this.loadedCount > 0) {
            // 条目间距 16 大于瓦片内元素间距 10，条目分隔清晰
            List({ space: 16 }) {
              LazyForEach(this.source, (reply: FqCommentReply) => {
                ListItem() {
                  FqReplyTile({
                    reply: reply,
                    fontColor: this.fontColor,
                  })
                }
              }, (reply: FqCommentReply): string =>
                reply.id.length > 0 ? reply.id : `r${reply.createdAtMs}_${reply.text.length}`)
            }
            .width('100%')
            .constraintSize({ maxHeight: fqReplyListMaxHeightVp() })
            .nestedScroll({
              scrollForward: NestedScrollMode.SELF_FIRST,
              scrollBackward: NestedScrollMode.SELF_FIRST,
            })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .cachedCount(6)
          } else {
            Text('暂无回复')
              .fontSize(12)
              .fontColor(this.fontColor)
              .opacity(0.55)
          }
          if (this.loadingMore) {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color(appState.accentColor)
              Text('正在加载更多回复')
                .fontSize(11)
                .fontColor(this.fontColor)
                .opacity(0.55)
            }
            .alignItems(VerticalAlign.Center)
          } else if (this.hasMore && this.loadedCount > 0) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(12)
                .fontColor([this.fontColor])
                .opacity(0.55)
                .rotate({ angle: 180 })
              Text(`已显示前${this.loadedCount}条，点击加载更多`)
                .fontSize(11)
                .fontColor(this.fontColor)
                .opacity(0.55)
            }
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.loadMoreReplies();
            })
          } else if (this.total > this.loadedCount) {
            Text(`已显示前${this.loadedCount}条，共${fqFormatCountInt(this.total)}条回复`)
              .fontSize(11)
              .fontColor(this.fontColor)
              .opacity(0.45)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius(10)
        .padding(10)
        this.CollapseToggle()
      } else {
        this.ExpandToggle()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 折叠态计数行（展开 N 条回复 / 加载中 / 失败重试）。 */
  @Builder
  private ExpandToggle() {
    Row({ space: 4 }) {
      if (this.loading) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(appState.accentColor)
      } else {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([this.fontColor])
          .opacity(0.55)
      }
      Text(this.counterLabel())
        .fontSize(12)
        .fontColor(this.fontColor)
        .opacity(0.55)
    }
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.toggleReplies();
    })
  }

  /** 展开态尾部收起行（挪到展开回复的尾部）。 */
  @Builder
  private CollapseToggle() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([this.fontColor])
        .opacity(0.55)
        .rotate({ angle: 180 })
      Text('收起')
        .fontSize(12)
        .fontColor(this.fontColor)
        .opacity(0.55)
    }
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.toggleReplies();
    })
  }
}

/**
 * 评论回复公共组件（书评/章评/漫评/段评共用，对齐 fqapp PR #278 回复展示）：
 * - FqReplySource：回复懒加载数据源（LazyForEach）；
 * - FqReplyTile：单条回复瓦片（评论瓦片同款排版：头像/名字/时间 + 正文 + 配图 + 点赞；
 *   仅配图可点，点击全屏放大（FqImageViewer），其余不可点）；
 * - FqReplySection：评论卡片内「展开 N 条回复」区块（计数行 + 首次点击懒加载 + 开合切换 +
 *   失败重试 + List/LazyForEach 内联回复列表）；回复单页拉取：服务端单页上限 50 条、
 *   后端 cursor 恒空串无翻页，超出部分以「已显示前 N 条」尾注提示；
 * - fqReplyListMaxHeightVp：展开回复列表最大高度（屏高 55%，超出内滚并联动外层滚动）。
 */

import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../../entryability/AppState';
import { FqCommentReply, FqCommentReplyPage, fqFormatCountInt } from '../../model/FqModels';
import { FqImageViewer } from '../FqImageViewer';

/** 展开回复列表最大高度：屏高 55%（vp），异常回退 420。 */
export function fqReplyListMaxHeightVp(): number {
  const displayData: display.Display = display.getDefaultDisplaySync();
  const density: number = displayData.densityPixels > 0 ? displayData.densityPixels : 1;
  const screenHeight: number = appState.screenHeight > 0 ? appState.screenHeight : displayData.height;
  const height: number = Math.round((screenHeight / density) * 0.55);
  return height > 0 ? height : 420;
}

/** 回复懒加载数据源（IDataSource + onDataReloaded 整体通知）。 */
class FqReplySource implements IDataSource {
  private items: FqCommentReply[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: FqCommentReply[]): void {
    this.items = items;
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

  private notifyReloaded(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 单条回复瓦片：评论瓦片同款排版；仅配图可点（点击全屏放大），其余不可点。 */
@ComponentV2
export struct FqReplyTile {
  @Param reply: FqCommentReply =
    new FqCommentReply('', '', [], 0, 0, '', '');
  /** 字体色随宿主主题（阅读页墨色 / 系统色）。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 当前放大配图下标（-1 关闭）。 */
  @Local zoomIndex: number = -1;

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
        Text(this.reply.text)
          .fontSize(13.5)
          .lineHeight(22)
          .fontColor(this.fontColor)
          .width('100%')
      }

      if (this.reply.imageUrls.length > 0) {
        Row({ space: 6 }) {
          ForEach(this.reply.imageUrls.slice(0, 3), (url: string, index: number) => {
            Image(url)
              .width(76)
              .height(76)
              .borderRadius(6)
              .objectFit(ImageFit.Cover)
              .draggable(false)
              .onClick((): void => {
                this.zoomIndex = index;
              })
          }, (url: string, index: number): string => `${index}-${url}`)
        }
        .alignItems(VerticalAlign.Top)
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
    .bindContentCover(this.zoomIndex >= 0, this.ZoomCover(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: (): void => {
        this.zoomIndex = -1;
      },
    })
  }

  /** 放大配图全屏内容（bindContentCover 承载 FqImageViewer）。 */
  @Builder
  private ZoomCover() {
    if (this.zoomIndex >= 0 && this.zoomIndex < this.reply.imageUrls.length) {
      FqImageViewer({
        imageUrl: this.reply.imageUrls[this.zoomIndex],
        requestClose: (): void => {
          this.zoomIndex = -1;
        },
      })
    }
  }
}

/** 评论卡片内回复区块：计数行（展开 N 条回复 / 收起 / 加载中 / 失败重试）+ List 懒加载回复列表。 */
@ComponentV2
export struct FqReplySection {
  /** 父评论 id（回复加载入参）。 */
  @Param commentId: string = '';
  /** 父评论回复数（计数行展示）。 */
  @Param replyCount: number = 0;
  /** 字体色随宿主主题。 */
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  /** 回复加载器（宿主注入，group_id=book_id=书 id）；未注入保持只读计数不展开。 */
  @Param replyLoader: ((commentId: string) => Promise<FqCommentReplyPage>) | undefined = undefined;
  @Local expanded: boolean = false;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  @Local loaded: boolean = false;
  @Local loadedCount: number = 0;
  @Local total: number = 0;
  @Local hasMore: boolean = false;
  private source: FqReplySource = new FqReplySource();

  /** 展开/收起：首次点击拉取回复后展开，再点切换开合（数据保留秒开）；失败可点击重试。 */
  private toggleReplies(): void {
    if (this.loading) {
      return;
    }
    const loader: ((commentId: string) => Promise<FqCommentReplyPage>) | undefined = this.replyLoader;
    if (loader === undefined || this.commentId.length === 0) {
      return;
    }
    if (this.loaded) {
      this.expanded = !this.expanded;
      return;
    }
    this.loading = true;
    this.failed = false;
    loader(this.commentId)
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

  /** 计数行文案（对齐 fqapp：可展开「展开N条回复」/ 已展开「收起」/ 加载中 / 失败重试）。 */
  private counterLabel(): string {
    if (this.loading) {
      return '加载中';
    }
    if (this.failed) {
      return '回复加载失败，点击重试';
    }
    if (this.expanded && this.loaded) {
      return '收起';
    }
    return `展开${fqFormatCountInt(this.replyCount)}条回复`;
  }

  build() {
    Column({ space: 8 }) {
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
            .rotate({ angle: this.expanded && this.loaded ? 180 : 0 })
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

      if (this.expanded && this.loaded) {
        Column({ space: 8 }) {
          if (this.loadedCount > 0) {
            List({ space: 10 }) {
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
          if (this.hasMore && this.loadedCount > 0) {
            Text(`已显示前${this.loadedCount}条，共${fqFormatCountInt(this.total > 0 ? this.total : this.loadedCount)}条回复`)
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
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

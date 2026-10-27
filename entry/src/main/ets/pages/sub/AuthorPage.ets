/**
 * 作者主页（NavDestination）：作者信息头 + 全部作品网格。
 *
 * 对齐 fqapp lib/pages/author_page.dart / lib/models/author_profile.dart：
 * 单请求 GET /api/v1/authors/{id}（上游 /reading/user/basic_info/get/v），
 * 作品取自 data.author_book_info（不走 /bookshelf）；
 * 头像 58 + 笔名 18 加粗 + 等级徽标 + 「X粉丝 · N 部作品」+ 简介 + 3 列封面网格。
 */

import { FqBackend, fqErrorMessage } from '../../core/FqBackend';
import { FqAuthorProfile, FqAuthorWork, FqMediaItem } from '../../model/FqModels';
import { FqMediaCard } from '../../view/FqMediaCard';
import { AuthorNavParams, DetailNavParams, FqTitleBarOptions, ROUTE_DETAIL } from '../../model/FqNavModels';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { CommonNav } from '../../view/CommonNav';
import { CommonLoading } from '../../view/CommonCom';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../../entryability/AppState';

/** 滚动内容起始偏移：标题栏 56。 */
const FQ_AUTHOR_TOP_INSET: number = 56;

/** 滚动内容末尾偏移：底部安全区 + 页脚留白。 */
const FQ_AUTHOR_BOTTOM_INSET: number = 24;

@ComponentV2
export struct AuthorPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local profile: FqAuthorProfile = new FqAuthorProfile('', '', '', '', '', 0, 0, []);
  @Local headerTitle: string = '作者';
  private authorId: string = '';
  private fallbackName: string = '';
  private avatarUrl: string = '';
  private loadToken: number = 0;
  private scroller: Scroller = new Scroller();
  /** 进入页面时捕获的顶部避让（与其他二级页保持一致的 List 顶部内边）。 */
  private stableTopInset: number = 0;

  aboutToAppear(): void {
    this.authorId = AuthorNavParams.authorId;
    this.fallbackName = AuthorNavParams.fallbackName;
    this.avatarUrl = AuthorNavParams.avatar;
    this.headerTitle = this.fallbackName.length > 0 ? this.fallbackName : '作者';
    this.stableTopInset = appState.topRect;
    this.load();
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions(this.headerTitle, false),
      scroller: this.scroller,
      doubleTapToTop: true,
      scrollToTopYOffset: -(this.stableTopInset + FQ_AUTHOR_TOP_INSET),
    }) {
      if (this.loadingState) {
        Column({ space: 12 }) {
          CommonLoading({ sizeValue: 36, loadColor: appState.accentColor })
          Text('正在加载作者信息')
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
            .backgroundColor(appState.accentColor)
            .onClick(() => this.load())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.scroller, space: 20 }) {
          ListItem() {
            this.Header()
          }
          if (this.profile.works.length === 0) {
            ListItem() {
              Text('暂无可展示的作品')
                .fontSize(13)
                .fontColor($r('sys.color.font_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 36, bottom: 36 })
            }
          } else {
            ListItem() {
              List({ space: 14 }) {
                ForEach(this.profile.works, (work: FqAuthorWork) => {
                  ListItem() {
                    FqMediaCard({
                      item: this.mediaItemOf(work),
                      onItemClick: (clicked: FqMediaItem): void => {
                        this.openWork(clicked);
                      },
                    })
                  }
                }, (work: FqAuthorWork, index: number): string => `${index}:${work.id}`)
              }
              .width('100%')
              .lanes(3, 14)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.None)
            }
          }
        }
        .padding({ left: 20, right: 20 })
        .scrollBar(BarState.Off)
        .contentStartOffset(this.stableTopInset + FQ_AUTHOR_TOP_INSET)
        .contentEndOffset(appState.bottomRect + FQ_AUTHOR_BOTTOM_INSET)
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
      }
    }
  }

  /** 作者信息头：头像 + 笔名 + 等级徽标 + 数据行 + 简介 + 全部作品标题。 */
  @Builder
  private Header() {
    Column({ space: 0 }) {
      Row({ space: 14 }) {
        if (this.avatarDisplayUrl().length > 0) {
          Image(this.avatarDisplayUrl())
            .width(58)
            .height(58)
            .borderRadius(29)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .autoResize(true)
            .draggable(false)
        } else {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(58)
              .height(58)
              .borderRadius(29)
              .backgroundColor($r('sys.color.comp_background_tertiary'))
            SymbolGlyph($r('sys.symbol.person_fill'))
              .fontSize(26)
              .fontColor([$r('sys.color.icon_tertiary')])
          }
        }
        Column({ space: 6 }) {
          Row({ space: 7 }) {
            Text(this.displayName())
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.profile.level.length > 0) {
              Text(this.profile.level)
                .fontSize(10.5)
                .fontWeight(FontWeight.Medium)
                .fontColor('#E9A23B')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(4)
                .backgroundColor('#24E9A23B')
            }
          }
          .alignItems(VerticalAlign.Center)
          if (this.factsLine().length > 0) {
            Text(this.factsLine())
              .fontSize(12.5)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')

      if (this.profile.description.length > 0) {
        Text(this.profile.description)
          .fontSize(13.5)
          .fontColor($r('sys.color.font_primary'))
          .lineHeight(23)
          .margin({ top: 16 })
          .width('100%')
      }

      if (this.profile.works.length > 0) {
        Row({ space: 8 }) {
          Text('全部作品')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text(`${this.profile.works.length}`)
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 20 })
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private load(): void {
    if (this.authorId.length === 0) {
      this.loadingState = false;
      this.errorMsg = '作者信息不可用';
      return;
    }
    this.loadToken += 1;
    const token: number = this.loadToken;
    this.loadingState = true;
    this.errorMsg = '';
    FqBackend.get().authorProfile(this.authorId).then((profile: FqAuthorProfile): void => {
      if (token !== this.loadToken) {
        return;
      }
      this.profile = profile;
      this.loadingState = false;
      if (profile.isEmpty) {
        this.errorMsg = '作者信息不可用';
        return;
      }
      this.headerTitle = this.displayName();
      if (profile.avatar.length > 0) {
        this.avatarUrl = profile.avatar;
      }
    }).catch((error: BusinessError): void => {
      if (token !== this.loadToken) {
        return;
      }
      this.loadingState = false;
      this.errorMsg = fqErrorMessage(error);
    });
  }

  private displayName(): string {
    if (this.profile.name.length > 0) {
      return this.profile.name;
    }
    if (this.fallbackName.length > 0) {
      return this.fallbackName;
    }
    return '作者';
  }

  /** 头像：主页结果优先，回退详情页带入的头像。 */
  private avatarDisplayUrl(): string {
    const raw: string = this.profile.avatar.length > 0 ? this.profile.avatar : this.avatarUrl;
    return raw.length > 0 ? FqBackend.get().resourceUrl(raw) : '';
  }

  /** 「2.1万粉丝 · 12 部作品」；上游未报总数时以实际作品数补位。 */
  private factsLine(): string {
    const parts: string[] = [];
    const follower: string = this.profile.followerLabel;
    if (follower.length > 0) {
      parts.push(follower);
    }
    const countLabel: string = this.profile.workCountLabel;
    if (countLabel.length > 0) {
      parts.push(countLabel);
    } else if (this.profile.works.length > 0) {
      parts.push(`${this.profile.works.length} 部作品`);
    }
    return parts.join(' · ');
  }

  private mediaItemOf(work: FqAuthorWork): FqMediaItem {
    return new FqMediaItem(
      work.id,
      work.title,
      work.cover,
      '',
      work.category,
      '',
      'book',
      0,
      work.intro,
      '',
      '',
      0,
    );
  }

  private openWork(item: FqMediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    DetailNavParams.id = item.id;
    DetailNavParams.kind = 'book';
    DetailNavParams.title = item.title;
    DetailNavParams.cover = item.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }
}

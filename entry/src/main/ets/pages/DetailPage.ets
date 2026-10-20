/**
 * 详情页（NavDestination）：/api/detail 展示（M1 信息展示，不含阅读/播放）。
 * 参数经 DetailNavParams 静态类传递（aboutToAppear 读取）。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqBookDetail, fqEmptyBookDetail, fqKindToTab } from '../model/FqModels';
import { DetailNavParams } from '../model/FqNavModels';

@ComponentV2
export struct DetailPage {
  @Local loadingState: boolean = true;
  @Local errorMsg: string = '';
  @Local detail: FqBookDetail = fqEmptyBookDetail();
  @Local headerTitle: string = '详情';
  private itemId: string = '';
  private itemKind: string = 'book';
  private itemCover: string = '';

  aboutToAppear(): void {
    this.itemId = DetailNavParams.id;
    this.itemKind = DetailNavParams.kind;
    this.itemCover = DetailNavParams.cover;
    if (DetailNavParams.title.length > 0) {
      this.headerTitle = DetailNavParams.title;
    }
    this.load();
  }

  build() {
    NavDestination() {
      if (this.loadingState) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#FF7A3D')
          Text('正在加载…')
            .fontSize(14)
            .fontColor('#66000000')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 12 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor('#99000000')
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
        Scroll() {
          Column({ space: 14 }) {
            Row({ space: 14 }) {
              if (this.coverUrl().length > 0) {
                Image(this.coverUrl())
                  .width(100)
                  .height(134)
                  .borderRadius(10)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor('#F1F1F3')
                  .autoResize(true)
              } else {
                Column()
                  .width(100)
                  .height(134)
                  .borderRadius(10)
                  .backgroundColor('#F1F1F3')
              }
              Column({ space: 6 }) {
                Text(this.detail.title)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#E6000000')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.detail.author.length > 0) {
                  Text(this.detail.author)
                    .fontSize(13)
                    .fontColor('#99000000')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                if (this.detail.scoreText.length > 0) {
                  Text(`${this.detail.scoreText} 分`)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFA000')
                }
                if (this.metaLine().length > 0) {
                  Text(this.metaLine())
                    .fontSize(12)
                    .fontColor('#99000000')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            if (this.detail.abstractText.length > 0) {
              Column({ space: 8 }) {
                Text('简介')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#E6000000')
                Text(this.detail.abstractText)
                  .fontSize(13)
                  .fontColor('#99000000')
                  .lineHeight(21)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }

            if (this.detail.serialCount > 0) {
              Text(this.catalogLine())
                .fontSize(13)
                .fontColor('#66000000')
                .width('100%')
            }

            Text('阅读与播放将在后续版本提供')
              .fontSize(12)
              .fontColor('#4D000000')
              .width('100%')
              .padding({ top: 8 })
          }
          .padding(16)
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
      }
    }
    .title(this.headerTitle)
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
    if (this.detail.subInfo.length > 0) {
      parts.push(this.detail.subInfo);
    }
    return parts.join(' · ');
  }

  private catalogLine(): string {
    return `共 ${this.detail.serialCount} 集/章`;
  }

  private async load(): Promise<void> {
    if (this.itemId.length === 0) {
      this.errorMsg = '无效的作品';
      this.loadingState = false;
      return;
    }
    this.loadingState = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const tab: string = fqKindToTab(this.itemKind);
      this.detail = await FqBackend.get().bookDetail(this.itemId, tab);
      if (this.detail.title.length > 0 && this.headerTitle === '详情') {
        this.headerTitle = this.detail.title;
      }
    } catch (error) {
      this.errorMsg = fqErrorMessage(error);
    } finally {
      this.loadingState = false;
    }
  }
}

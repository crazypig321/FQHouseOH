/**
 * 内容卡片：封面 + 标题 + 元信息行。
 */

import { FqBackend } from '../core/FqBackend';
import { FqMediaItem, fqEmptyMediaItem } from '../model/FqModels';

@ComponentV2
export struct FqItemCard {
  @Param item: FqMediaItem = fqEmptyMediaItem();
  @Param onItemClick: (item: FqMediaItem) => void = (item: FqMediaItem): void => {
  };

  build() {
    Row({ space: 12 }) {
      if (this.item.cover.length > 0) {
        Image(FqBackend.get().resourceUrl(this.item.cover))
          .width(78)
          .height(104)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#F1F1F3')
          .autoResize(true)
      } else {
        Column()
          .width(78)
          .height(104)
          .borderRadius(8)
          .backgroundColor('#F1F1F3')
      }
      Column({ space: 6 }) {
        Text(this.item.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E6000000')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          if (this.item.badge.length > 0) {
            Text(this.item.badge)
              .fontSize(11)
              .fontColor('#FF7A3D')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor('#1AFF7A3D')
          }
          if (this.item.score > 0) {
            Text(this.scoreLabel())
              .fontSize(12)
              .fontColor('#FFA000')
          }
          if (this.item.ep.length > 0) {
            Text(this.item.ep)
              .fontSize(12)
              .fontColor('#99000000')
          }
        }
        if (this.item.author.length > 0) {
          Text(this.item.author)
            .fontSize(12)
            .fontColor('#99000000')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.item.intro.length > 0) {
          Text(this.item.intro)
            .fontSize(12)
            .fontColor('#66000000')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.onItemClick(this.item))
  }

  private scoreLabel(): string {
    return `${this.item.score.toFixed(1)}分`;
  }
}

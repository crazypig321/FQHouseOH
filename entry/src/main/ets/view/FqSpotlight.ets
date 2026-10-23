/**
 * 今日焦点轮播（对齐 fqapp HomeSpotlight 简化版）：
 * 头部标题行 + 大图 Swiper（渐变叠层 + 标题/作者/行动药丸）+ 底部页码行。
 */

import { FqBackend } from '../core/FqBackend';
import { FqMediaItem, fqKindLabel } from '../model/FqModels';

const FQ_SPOTLIGHT_ACTIONS: Record<string, string> = {
  'video': '开始追剧',
  'manju': '观看漫剧',
  'audio': '开始听书',
  'manga': '翻开漫画',
};

@ComponentV2
export struct FqSpotlight {
  /** 焦点条目（前 3 项）。 */
  @Param items: FqMediaItem[] = [];
  @Param onOpen: (item: FqMediaItem) => void = (item: FqMediaItem): void => {
  };
  @Local activeIndex: number = 0;
  private swiperController: SwiperController = new SwiperController();

  @Monitor('items')
  onItemsChange(): void {
    this.activeIndex = 0;
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Column()
          .width(4)
          .height(18)
          .borderRadius(2)
          .backgroundColor('#FF7A3D')
        Text('今日焦点')
          .fontSize(21)
          .fontWeight(800)
          .fontColor($r('sys.color.font_primary'))
        Text('HOT')
          .fontSize(10)
          .fontWeight(800)
          .fontColor('#FF7A3D')
          .backgroundColor('#1AFF7A3D')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
        Blank()
        Text('总有一个故事，正合你意')
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 20, right: 20 })

      Swiper(this.swiperController) {
        ForEach(this.items, (item: FqMediaItem) => {
          Stack({ alignContent: Alignment.TopStart }) {
            Image(FqBackend.get().resourceUrl(item.cover))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .autoResize(true)
              .draggable(false)
            Column()
              .width('100%')
              .height('100%')
              .linearGradient({
                angle: 180,
                colors: [
                  ['#250C1513', 0],
                  ['#350C1513', 0.45],
                  ['#B50C1513', 0.75],
                  ['#F60C1513', 1],
                ],
              })
            Row({ space: 5 }) {
              SymbolGlyph(this.kindIcon(item.kind))
                .fontSize(12)
                .fontColor([Color.White])
              Text(fqKindLabel(item.kind))
                .fontSize(11)
                .fontWeight(600)
                .fontColor(Color.White)
              Column()
                .width(1)
                .height(10)
                .backgroundColor('#61FFFFFF')
              Text('精选')
                .fontSize(11)
                .fontColor(Color.White)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .margin(18)
            Column({ space: 6 }) {
              Text(item.title)
                .fontSize(24)
                .fontWeight(800)
                .fontColor(Color.White)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .width('100%')
              if (this.authorEpLabel(item).length > 0) {
                Text(this.authorEpLabel(item))
                  .fontSize(11)
                  .fontColor('#D6FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }
              Row({ space: 4 }) {
                Text(this.actionLabel(item.kind))
                  .fontSize(11)
                  .fontWeight(700)
                  .fontColor('#1E201D')
                SymbolGlyph($r('sys.symbol.arrow_up_right'))
                  .fontSize(14)
                  .fontColor(['#1E201D'])
              }
              .alignItems(VerticalAlign.Center)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(10)
              .backgroundColor(Color.White)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(18)
            .position({ x: 0, y: '100%' })
            .markAnchor({ x: 0, y: '100%' })
          }
          .width('100%')
          .height(228)
          .borderRadius(20)
          .clip(true)
          .onClick(() => this.onOpen(item))
        }, (item: FqMediaItem): string => `${item.kind}:${item.id}`)
      }
      .width('100%')
      .height(228)
      .margin({ top: 12 })
      .padding({ left: 20, right: 20 })
      .loop(true)
      .indicator(false)
      .onSelected((index: number) => {
        this.getUIContext().animateTo({ duration: 250, curve: Curve.Smooth }, (): void => {
          this.activeIndex = index;
        });
      })

      Row({ space: 8 }) {
        Text('为你精选，随心发现')
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
        Blank()
        Row({ space: 5 }) {
          ForEach(this.items, (item: FqMediaItem, index: number) => {
            Column()
              .width(index === this.activeIndex ? 16 : 4)
              .height(4)
              .borderRadius(2)
              .backgroundColor(index === this.activeIndex ? '#FF7A3D' : $r('sys.color.comp_divider'))
          }, (item: FqMediaItem, index: number): string => `${item.kind}:${item.id}:${index}`)
        }
        .alignItems(VerticalAlign.Center)
        Text(this.pageLabel())
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 20, right: 20, top: 10 })
    }
    .width('100%')
  }

  private kindIcon(kind: string): Resource {
    if (kind === 'video') {
      return $r('sys.symbol.video');
    }
    if (kind === 'manju') {
      return $r('sys.symbol.film');
    }
    if (kind === 'manga') {
      return $r('sys.symbol.picture');
    }
    if (kind === 'audio') {
      return $r('sys.symbol.headphones');
    }
    return $r('sys.symbol.book');
  }

  private authorEpLabel(item: FqMediaItem): string {
    const parts: string[] = [];
    if (item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.ep.length > 0) {
      parts.push(item.ep);
    }
    return parts.join(' · ');
  }

  private actionLabel(kind: string): string {
    const action: string | undefined = FQ_SPOTLIGHT_ACTIONS[kind];
    return action !== undefined ? action : '立即阅读';
  }

  private pageLabel(): string {
    return `${this.pad2(this.activeIndex + 1)} / ${this.pad2(this.items.length)}`;
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}

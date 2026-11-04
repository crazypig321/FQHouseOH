/**
 * 网格封面卡：封面 + kind/ep chip + 标题 + 副行
 * （对齐 fqapp HomeMediaCard 简化版：无封面图占位 kind 图标）。
 */

import { FqBackend } from '../core/FqBackend';
import { FqMediaItem, FqMediaTag, fqEmptyMediaItem, fqKindLabel } from '../model/FqModels';
import { appState } from '../entryability/AppState';
import { FqColorUtils } from '../utils/FqColorUtils';

const MARGIN_LABEL: Length = 5

@ComponentV2
export struct FqMediaCard {
  @Param item: FqMediaItem = fqEmptyMediaItem();
  @Param onItemClick: (item: FqMediaItem) => void = (item: FqMediaItem): void => {
  };
  /** 多选模式：封面左上角显示勾选圈、隐藏角标。 */
  @Param batchMode: boolean = false;
  @Param selected: boolean = false;
  /** 角标文案覆盖（非空时替代 kind 标签，如本地书"本地书籍"）。 */
  @Param chipText: string = '';
  /** 整书阅读百分比 0..100（封面右上角渐变角标）；-1 = 无进度不显示。 */
  @Param badgePercent: number = -1;

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          if (this.item.cover.length > 0) {
            Image(FqBackend.get().resourceUrl(this.item.cover))
              .width('100%')
              .aspectRatio(5 / 7)
              .objectFit(ImageFit.Cover)
              .autoResize(true)
              .draggable(false)
          } else {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph(this.kindIcon())
                .fontSize(22)
                .fontColor([$r('sys.color.icon_tertiary')])
            }
            .width('100%')
            .aspectRatio(5 / 7)
            .backgroundColor($r('sys.color.comp_background_secondary'))
          }

          if (!this.batchMode && this.item.score){
            Text(){
              Span('评分 ')
              Span(`${this.item.score}`)
            }
            .fontSize(9)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor('#B81C1B1A')
            .margin(MARGIN_LABEL)
          }
        }
        if (this.batchMode && this.selected) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#59000000')
            .transition(TransitionEffect.OPACITY)
        }
        if (this.batchMode) {
          SymbolGlyph(this.selected ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
            .fontSize(22)
            .fontColor([this.selected ? appState.accentColor : $r('sys.color.icon_tertiary')])
            .margin(6)
            .transition(TransitionEffect.OPACITY)
        }
        if (!this.batchMode && (this.item.kind.length > 0 || this.chipText.length > 0)) {
          Text(this.chipText.length > 0 ? this.chipText : fqKindLabel(this.item.kind))
            .fontSize(9)
            .fontColor(Color.White)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor('#A61C1B1A')
            .margin(MARGIN_LABEL)
            .transition(TransitionEffect.OPACITY)
        }
        if (!this.batchMode && this.badgePercent >= 0) {
          Column() {
            Text(`${this.badgePercent}%`)
              .fontSize(9)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .constraintSize({ minWidth: 26 })
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor(appState.accentColor)
          }
          .width('100%')
          .alignItems(HorizontalAlign.End)
          .padding(MARGIN_LABEL)
          .transition(TransitionEffect.OPACITY)
        }
        if (!this.batchMode && this.item.ep.length > 0) {
          // 集数/章节文案：移到封面右下角（fqapp HomeMediaCard ep 位置）
          Column() {
            Text(this.item.ep)
              .fontSize(9)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor('#B81C1B1A')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
          .padding(MARGIN_LABEL)
          .transition(TransitionEffect.OPACITY)
        }
        if (!this.batchMode && this.item.tag !== null && this.item.tag.hasColors()) {
          // 促销角标（tag_info：上新/爆款）：封面右上角，上游渐变配色
          Column() {
            Text(this.item.tag.text)
              .fontSize(9)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5)
              .linearGradient({ angle: 90, colors: this.tagGradientStops() })
          }
          .width('100%')
          .alignItems(HorizontalAlign.End)
          .padding(MARGIN_LABEL)
          .transition(TransitionEffect.OPACITY)
        }
      }
      .width('100%')
      .aspectRatio(5 / 7)
      .borderRadius(12)
      .clip(true)
      .border({ width: 0.5, color: $r('sys.color.comp_divider') })

      Text(this.item.title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
        .width('100%')

      Text(this.subLabel())
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.onItemClick(this.item))
  }

  private kindIcon(): Resource {
    if (this.item.kind === 'video') {
      return $r('sys.symbol.video');
    }
    if (this.item.kind === 'manju') {
      return $r('sys.symbol.film');
    }
    if (this.item.kind === 'manga') {
      return $r('sys.symbol.picture');
    }
    if (this.item.kind === 'audio') {
      return $r('sys.symbol.headphones');
    }
    return $r('sys.symbol.book');
  }

  private subLabel(): string {
    if (this.chipText.length > 0) {
      return this.chipText;
    }
    if (this.item.author.length > 0) {
      return this.item.author;
    }
    if (this.item.badge.length > 0) {
      return this.item.badge;
    }
    return fqKindLabel(this.item.kind);
  }

  /**
   * 促销角标渐变 stops（fqapp CoverTagChip）：水平（angle 90）铺 tag 配色；
   * 单色重复为首尾两站呈实心；无色时退中性深底不进渐变。
   */
  private tagGradientStops(): [ResourceColor, number][] {
    const stops: [ResourceColor, number][] = [];
    const tag: FqMediaTag | null = this.item.tag;
    if (tag === null) {
      return stops;
    }
    const colors: string[] = tag.colorsFor(appState.isDark);
    if (colors.length === 0) {
      return stops;
    }
    if (colors.length === 1) {
      stops.push([colors[0], 0.0]);
      stops.push([colors[0], 1.0]);
      return stops;
    }
    const step: number = 1 / (colors.length - 1);
    for (let i = 0; i < colors.length; i++) {
      stops.push([colors[i], i * step]);
    }
    return stops;
  }
}

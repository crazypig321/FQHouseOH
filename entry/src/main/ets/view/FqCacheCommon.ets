/**
 * 缓存管理公共组件（章节缓存页/剧集缓存页共用，对齐 fqapp formatCacheBytes
 * 与统计卡/空态样式；卡片壳对齐设置页/关于页 FqAboutCard）。
 */

import { FqColorUtils } from '../utils/FqColorUtils';
import { appState } from '../entryability/AppState';

/** 字节数格式化（fqapp formatCacheBytes 同款：B/KB/MB，<10 保留一位小数）。 */
export function fqFormatCacheBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kib: number = bytes / 1024;
  if (kib < 1024) {
    return `${kib.toFixed(kib < 10 ? 1 : 0)} KB`;
  }
  const mib: number = kib / 1024;
  return `${mib.toFixed(mib < 10 ? 1 : 0)} MB`;
}

@Builder
function fqCacheEmptyBuilder() {
}

/** 统计卡：彩色图标块 + 标题/副标题 + 尾随自定义内容（清空按钮、按钮组）。 */
@ComponentV2
export struct FqCacheStatsCard {
  @Param icon: Resource = $r('sys.symbol.book');
  @Param tint: string = '#FF3B82F6';
  @Param title: string = '';
  @Param subtitle: string = '';
  @BuilderParam trailing: () => void = fqCacheEmptyBuilder;

  build() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(this.icon)
          .fontSize(22)
          .fontColor([this.tint])
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor(FqColorUtils.withOpacity(this.tint, 0.12))

      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      this.trailing()
    }
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }
}

/** 空态：圆形图标底（tint 0.12）+ 标题 + 提示小字，居中。 */
@ComponentV2
export struct FqCacheEmptyView {
  @Param icon: Resource = $r('sys.symbol.download');
  @Param tint: string = '#FF3B82F6';
  @Param title: string = '';
  @Param subtitle: string = '';

  build() {
    Column({ space: 16 }) {
      Stack() {
        SymbolGlyph(this.icon)
          .fontSize(32)
          .fontColor([this.tint])
      }
      .width(64)
      .height(64)
      .borderRadius(32)
      .backgroundColor(FqColorUtils.withOpacity(this.tint, 0.12))

      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))

      Text(this.subtitle)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(20)
        .padding({ left: 16, right: 16 })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
  }
}

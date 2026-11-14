import { MenuItem, MENU_CONFIG, fqVisibleTabIndexes, fqPhysicalIndexOf } from '../../model/FqTabsModels';
import { appState } from '../../entryability/AppState';

/**
 * PC 侧边导航栏（对齐 musicfreeOH PcSideBar，参考 BiliMusic Sidebar 思路）：
 * - 主页面导航项（复用 MENU_CONFIG，与手机底部 tab 同源；按「我的、设置页面显示样式」过滤）；
 *   搜索入口统一由顶部 PcTitleBar 承载
 * - 展开显示 图标+页面名（220vp），收起仅显示图标（72vp）
 * - 导航项支持 hover/选中态，选中项以主题色高亮（选中态按逻辑下标的物理位置比对 currTabsIndex）
 * - 底部折叠开关切换展开/收起
 */
@ComponentV2
export struct PcSideBar {
  @Param expanded: boolean = true;
  /** hover 导航项逻辑下标（-1 表示无） */
  @Local hoverIndex: number = -1;
  @Event onSelect: (index: number) => void = (_index: number): void => {
  };
  @Event onToggle: () => void = (): void => {
  };

  /** 主页面导航项（index 为逻辑下标） */
  @Builder
  NavItem(item: MenuItem, index: number) {
    Row({ space: 12 }) {
      SymbolGlyph(item.icon)
        .fontSize(22)
        .fontColor([appState.currTabsIndex === fqPhysicalIndexOf(index, appState.mineSettingsStyle) ?
          appState.accentColor : $r('sys.color.icon_primary')])
      if (this.expanded) {
        Text(item.label)
          .fontSize(15)
          .fontWeight(appState.currTabsIndex === fqPhysicalIndexOf(index, appState.mineSettingsStyle)
            ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(appState.currTabsIndex === fqPhysicalIndexOf(index, appState.mineSettingsStyle) ?
            appState.accentColor : $r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height(46)
    .borderRadius(12)
    .justifyContent(this.expanded ? FlexAlign.Start : FlexAlign.Center)
    .padding({ left: this.expanded ? 13 : 0, right: this.expanded ? 13 : 0 })
    .backgroundColor(appState.currTabsIndex === fqPhysicalIndexOf(index, appState.mineSettingsStyle) ?
      $r('sys.color.comp_background_tertiary') :
      (this.hoverIndex === index ? $r('sys.color.interactive_hover') : Color.Transparent))
    .onHover((hover: boolean): void => {
      this.hoverIndex = hover ? index : -1;
    })
    .onClick((): void => {
      this.onSelect(index);
    })
  }

  build() {
    Column() {
      // 主页面导航项
      Column({ space: 4 }) {
        ForEach(fqVisibleTabIndexes(appState.mineSettingsStyle), (logicalIndex: number) => {
          this.NavItem(MENU_CONFIG[logicalIndex], logicalIndex)
        }, (logicalIndex: number) => 'pcside_' + logicalIndex.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Blank()

      // 底部：展开/收起开关
      Column() {
        Row() {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_left') : $r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('sys.color.icon_secondary')])
        }
        .width(34)
        .height(34)
        .borderRadius(100)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.onToggle();
        })
      }
      .width('100%')
      .alignItems(this.expanded ? HorizontalAlign.Start : HorizontalAlign.Center)
      .margin({ bottom: 4 })
    }
    .width(this.expanded ? 220 : 72)
    .height('100%')
    .padding({
      top: appState.topRect > 0 ? appState.topRect + 8 : 12,
      bottom: appState.bottomRect > 0 ? appState.bottomRect : 12,
      left: 10,
      right: 10
    })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .border({ width: { right: 1 }, color: $r('sys.color.comp_divider') })
    .animation({ duration: 250, curve: Curve.Smooth })
  }
}

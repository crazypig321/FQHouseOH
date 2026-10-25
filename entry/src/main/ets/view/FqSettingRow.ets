/**
 * 公共设置列表行（配合 List/ListItem 使用，divider 建议由 List 统一绘制）：
 * 左侧图标（SymbolGlyph）+ 标题文本，右侧内容经尾随闭包插槽传入
 * （跳转箭头 / 开关 / 滑杆 / 值文本等）；整行点击经 click 回调。
 */
@ComponentV2
export struct FqSettingRow {
  /** 左侧图标（SymbolGlyph 资源）。 */
  @Param icon: Resource = $r('sys.symbol.chevron_right')
  /** 标题文本。 */
  @Param title: string = ''
  /** 图标与标题颜色。 */
  @Param tintColor: ResourceColor = $r('sys.color.font')
  /** 整行点击（未传时行点击为空操作）。 */
  @Event click: () => void = (): void => {
  }
  /** 右侧内容插槽（尾随闭包传入：箭头/开关/滑杆等）。 */
  @BuilderParam rightSlot: () => void = fqSettingRowEmptySlot

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.icon)
        .fontSize(22)
        .fontColor([this.tintColor])
      Text(this.title)
        .fontSize(15)
        .fontColor(this.tintColor)
        .layoutWeight(1)
      this.rightSlot()
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.click();
    })
  }
}

/** 右侧插槽缺省内容（空）。 */
@Builder
function fqSettingRowEmptySlot() {
}

/**
 * 当前页书签标识（阅读页/漫画页正文右上角 bookmark_fill 图标）：
 * 当前页已收藏时由宿主条件渲染；占满父容器自定位右上角（不依赖父 Stack 对齐），
 * 纯展示（点击穿透），颜色随主题 accent。
 */

@ComponentV2
export struct FqBookmarkRibbon {
  /** 图标颜色（主题 accent）。 */
  @Param color: ResourceColor = $r('sys.color.font_primary');
  /** 图标字号（vp）。 */
  @Param sizeVp: number = 24;
  /** 距正文右缘间距（vp）。 */
  @Param rightInsetVp: number = 30;
  /** 距正文顶缘间距（vp）。 */
  @Param topInsetVp: number = 0;

  build() {
    Column() {
      SymbolGlyph($r('sys.symbol.bookmark_fill'))
        .fontSize(this.sizeVp)
        .fontColor([this.color])
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.End)
    .padding({ top: this.topInsetVp, right: this.rightInsetVp })
    .hitTestBehavior(HitTestMode.None)
  }
}

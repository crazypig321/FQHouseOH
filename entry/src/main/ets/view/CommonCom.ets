import { SymbolGlyphModifier } from '@kit.ArkUI';
import { searchImmersiveModifier } from '../utils/UiUtils';
import { appState } from '../entryability/AppState';

/**
 * 公共搜索组件（移植 musicfreeOH CommonSearch）。
 */
@ComponentV2
export struct CommonSearch {
  private controller: SearchController = new SearchController();
  @Param searchValue: string = '';
  @Param placeholderValue: ResourceStr = '';
  @Param isFocusable: boolean = true;
  @Param isDefaultFocus: boolean = true;
  @Param bgColor: ResourceColor = Color.Transparent
  /**
   * 焦点定位 id：必须由使用方传入且保持稳定。
   * 标题栏等 titleBar 内容变化会使 HdsTitleBar 重新执行底部插槽 builder，
   * 导致本组件被卸载重建；稳定 id 保证提交/清空后延时 requestFocus 仍能命中重建出的新节点。
   */
  @Param focusId: string = '';
  /** 组件 id 序列（未传 focusId 时生成兜底 id）。 */
  private static focusIdSeq: number = 0;
  /** 本实例的焦点定位 id。 */
  private myFocusId: string = '';

  @Event submit: (searchContent: string, event: SubmitEvent) => void
  @Event change: (value: string) => void
  @Event click: () => void
  @Event didDelete: () => void

  aboutToAppear(): void {
    if (this.focusId.length > 0) {
      this.myFocusId = this.focusId;
    } else {
      CommonSearch.focusIdSeq++;
      this.myFocusId = 'common_search_' + CommonSearch.focusIdSeq.toString();
    }
  }

  build() {
    Search({ value: this.searchValue, placeholder: this.placeholderValue, controller: this.controller })
      .id(this.myFocusId)
      .searchIcon(new SymbolGlyphModifier($r('sys.symbol.magnifyingglass')).fontColor([$r('sys.color.font')]))
      .cancelButton({
        style: CancelButtonStyle.INPUT,
        icon: new SymbolGlyphModifier($r('sys.symbol.xmark')).fontColor([$r('sys.color.font_tertiary')])
      })
      .searchButton('搜索', { fontColor: appState.accentColor })
      .attributeModifier(searchImmersiveModifier)
      .placeholderColor($r('sys.color.font_tertiary'))
      .placeholderFont({ size: 14, weight: 400 })
      .backgroundColor(this.bgColor)
      .textFont({ size: 14, weight: 400 })
      .onSubmit((searchContent: string, event: SubmitEvent) => {
        this.submit(searchContent, event)
        // 提交后收起软键盘：清除残留焦点，避免输入法重新挂载导致键盘回弹
        const focusController = this.getUIContext().getFocusController();
        setTimeout((): void => {
          try {
            focusController.clearFocus();
          } catch (e) {
            // 焦点控制器不可用时忽略
          }
        }, 200);
      })
      .onChange((value: string) => {
        if (value.length > 0) {
          this.change(value)
        } else {
          this.didDelete()
          // 文本被清空（× 或退格删空）后重新请求焦点，确保软键盘不退出；
          // 清空可能触发标题栏插槽重建（新节点），稳定 id 保证仍能命中
          const focusController = this.getUIContext().getFocusController();
          setTimeout((): void => {
            try {
              focusController.requestFocus(this.myFocusId);
            } catch (e) {
              // 组件已卸载或不可聚焦时忽略
            }
          }, 100);
        }
      })
      .onClick(() => {
        this.click()
      })
      .focusable(this.isFocusable)// 无法获焦则无法呼出软键盘
      .defaultFocus(this.isDefaultFocus)
  }
}


/**
 * 公共加载组件
 */
@ComponentV2
export struct CommonLoading {
  @Param sizeValue: Length = 28
  @Param loadColor: ResourceColor = $r('sys.color.icon')

  build() {
    LoadingProgress()
      .width(this.sizeValue)
      .height(this.sizeValue)
      .color(this.loadColor)
  }
}

/** 手动刷新时的全屏加载覆盖层。 */
@ComponentV2
export struct RefreshOverlay {

  build() {
    Stack() {
      Column({ space: 10 }) {
        CommonLoading({ sizeValue: 36, loadColor: appState.accentColor })
        Text('正在刷新')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .padding({
        left: 30,
        right: 30,
        top: 22,
        bottom: 26
      })
      .borderRadius(24)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .shadow({ radius: 24, color: '#1A000000' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
    .alignContent(Alignment.Center)
  }
}



/**
 * 底部公共渐变模糊组件
 */
@ComponentV2
export struct CommonBlur{
  @Param heightValue: Length = 116
  @Param gradientDirection: GradientDirection = GradientDirection.Bottom

  build() {
    Column()
      .width('100%')
      .height(this.heightValue)
      .linearGradientBlur(30,
        { fractionStops: [[0, 0], [0.9, 0.15], [1, 0.3], [1, 1]], direction: this.gradientDirection })
  }
}
/**
 * 通用半模态 Sheet（配合 bindSheet 使用）：
 * - FqSheetOptions：统一生成 bindSheet 参数（拖拽条 + 关闭回调 + 高度）。
 * - CommonSheet：Sheet 内容壳，内部引用 CommonNav 组件承载标题栏
 *   （主标题 + 可选右侧搜索按钮；搜索展开时 bottomBuilder 挂
 *   CommonSearch 搜索框，样式对齐主页搜索行）。
 */

import { HdsNavigationMenuItemOptions, TitleBarContentOptions } from '@kit.UIDesignKit';
import { CommonSearch } from './CommonCom';
import { CommonNav } from './CommonNav';

/** 通用 bindSheet 参数：拖拽条 + 关闭回调 + 可选高度（默认大高度半模态）。 */
export function FqSheetOptions(onClose: () => void, height?: SheetSize | Length): SheetOptions {
  const options: SheetOptions = {
    height: 300,
    dragBar: true,
    showClose: false,
    preferType: SheetType.CENTER,
    shouldDismiss: (sheetDismiss: SheetDismiss): void => {
      sheetDismiss.dismiss();
      onClose();
    },
    onDisappear: (): void => {
      onClose();
    },
  };
  return options;
}

@ComponentV2
export struct CommonSheet {
  @Param sheetTitle: ResourceStr = '';
  /** 标题栏右侧是否显示搜索按钮。 */
  @Param showSearch: boolean = false;
  /** 搜索框是否展开（bottomBuilder）。 */
  @Param searchActive: boolean = false;
  @Param searchValue: string = '';
  @Param searchPlaceholder: ResourceStr = '搜索';
  /** CommonSearch 焦点定位 id（使用方传入且保持稳定）。 */
  @Param focusId: string = 'common_sheet_search';
  @Event searchToggle: () => void = (): void => {};
  @Event searchChange: (value: string) => void = (_value: string): void => {};
  @Event searchSubmit: (value: string) => void = (_value: string): void => {};
  @BuilderParam content: () => void;

  build() {
    CommonNav({
      titleBarOp: this.titleBarContent(),
      isHideBackButton: true,
      avoidLayoutSafeArea: false,
      showBrandGradient: false,
    }) {
      this.content()
    }
  }

  private titleBarContent(): TitleBarContentOptions {
    const content: TitleBarContentOptions = {
      title: { mainTitle: this.sheetTitle },
    };
    if (this.showSearch) {
      const menus: HdsNavigationMenuItemOptions[] = [{
        content: {
          icon: $r('sys.symbol.magnifyingglass'),
          label: 'search',
          action: (): void => {
            this.searchToggle();
          },
        },
      }];
      content.menu = { value: menus };
      if (this.searchActive) {
        content.bottomBuilder = {
          builder: (): void => {
            this.SearchBar();
          },
          height: 52,
        };
      }
    }
    return content;
  }

  /** 标题栏 bottomBuilder：CommonSearch 搜索框（对齐主页搜索行）。 */
  @Builder
  private SearchBar() {
    Column() {
      CommonSearch({
        searchValue: this.searchValue,
        placeholderValue: this.searchPlaceholder,
        focusId: this.focusId,
        change: (value: string): void => {
          this.searchChange(value);
        },
        submit: (value: string, _event: SubmitEvent): void => {
          this.searchSubmit(value);
        },
        didDelete: (): void => {
          this.searchChange('');
        },
        click: (): void => {
        },
      })
        .height(36)
    }
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .width('100%')
  }
}

/**
 * 通用半模态 Sheet（配合 bindSheet 使用）：
 * - FqSheetOptions：统一生成 bindSheet 参数（拖拽条 + 关闭回调 + 高度）。
 * - CommonSheet：Sheet 内容壳，内部引用 CommonNav 组件承载标题栏
 *   （主标题 + 可选右侧搜索按钮；搜索展开时 bottomBuilder 挂
 *   CommonSearch 搜索框，样式对齐主页搜索行）。
 */

import { HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuItemOptions, TitleBarContentOptions } from '@kit.UIDesignKit';
import { themeUtils } from '../utils/ThemeUtils';
import { CommonSearch } from './CommonCom';
import { CommonNav } from './CommonNav';

/** 通用 bindSheet 参数：拖拽条 + 关闭回调 + 可选高度（默认 300）。 */
export function FqSheetOptions(onClose: () => void, height?: SheetSize | Length): SheetOptions {
  const options: SheetOptions = {
    height: height === undefined ? 600 : height,
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
  /** 标题栏右侧是否显示定位按钮（目录滚动到当前章节）。 */
  @Param showLocate: boolean = false;
  /** 标题栏右侧是否显示关闭按钮。 */
  @Param showClose: boolean = false;
  @Event searchToggle: () => void = (): void => {};
  @Event searchChange: (value: string) => void = (_value: string): void => {};
  @Event searchSubmit: (value: string) => void = (_value: string): void => {};
  @Event locateClick: () => void = (): void => {};
  @Event closeClick: () => void = (): void => {};
  @BuilderParam content: () => void;

  build() {
    HdsNavDestination() {
      this.content()
    }
    .titleBar({
      content: this.titleBarContent(),
      style: {
        originalStyle: {
          contentStyle: {
            // 深浅模式切换时由 themeUtils 触发重渲染（HDS 不会自动刷新系统色）
            titleStyle: { mainTitleColor: themeUtils.textColor, subTitleColor: themeUtils.terTextColor },
            backIconStyle: { iconColor: themeUtils.textColor },
            menuStyle: {
              iconColor: themeUtils.textColor
            },
            subIconStyle: {
              iconColor: themeUtils.textColor
            }
          },
        },
        scrollEffectOpts: {
          enableScrollEffect: false,
        },
      },
      avoidLayoutSafeArea: false,
    })
    .hideBackButton(true)
    .titleMode(HdsNavDestinationTitleMode.MODAL)
  }

  private titleBarContent(): TitleBarContentOptions {
    const content: TitleBarContentOptions = {
      title: { mainTitle: this.sheetTitle },
    };
    const menus: HdsNavigationMenuItemOptions[] = [];
    if (this.showSearch) {
      menus.push({
        content: {
          icon: $r('sys.symbol.magnifyingglass'),
          label: 'search',
          action: (): void => {
            this.searchToggle();
          },
        },
      });
    }
    if (this.showLocate) {
      menus.push({
        content: {
          icon: $r('sys.symbol.scope'),
          label: 'locate',
          action: (): void => {
            this.locateClick();
          },
        },
      });
    }
    if (this.showClose) {
      menus.push({
        content: {
          icon: $r('sys.symbol.xmark'),
          label: 'close',
          action: (): void => {
            this.closeClick();
          },
        },
      });
    }
    if (menus.length > 0) {
      content.menu = { value: menus };
    }
    if (this.showSearch && this.searchActive) {
      content.bottomBuilder = {
        builder: (): void => {
          this.SearchBar();
        },
        height: 52,
      };
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
    }
    .padding({ left: 16, right: 16 })
    .width('100%')
  }
}

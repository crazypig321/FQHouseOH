/**
 * 通用半模态 Sheet（配合 bindSheet 使用）：
 * - FqSheetOptions：统一生成 bindSheet 参数（拖拽条 + 关闭回调 + 高度）。
 * - CommonSheet：Sheet 内容壳，内部引用 CommonNav 组件承载标题栏
 *   （主标题 + 可选右侧搜索/定位/排序/关闭按钮；搜索展开时 bottomBuilder 挂
 *   CommonSearch 搜索框，样式对齐主页搜索行）。
 */

import {
  BlurStrategy,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuItemOptions, TitleBarContentOptions } from '@kit.UIDesignKit';
import { appState } from '../entryability/AppState';
import { themeUtils } from '../utils/ThemeUtils';
import { CommonSearch } from './CommonCom';
import { CommonNav } from './CommonNav';
import { uiMaterial } from '@kit.ArkUI';

/** 通用 bindSheet 参数：拖拽条 + 关闭回调 + 可选高度（默认 600）；前景光感模糊可选关闭。 */
export function FqSheetOptions(onClose: () => void, height?: SheetSize | Length,
  foregroundBlur: boolean = true): SheetOptions {
  const options: SheetOptions = {
    height: height === undefined ? 600 : height,
    dragBar: true,
    showClose: false,
    preferType: SheetType.CENTER,
    backgroundColor: Color.Transparent,
    systemMaterial: new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THICK,
    }),
    shouldDismiss: (sheetDismiss: SheetDismiss): void => {
      sheetDismiss.dismiss();
      onClose();
    },
    onWillSpringBackWhenDismiss: ()=>{},
    onWillAppear: () => {
      if (foregroundBlur) {
        appState.isForegroundBlur = true
      }
    },
    onWillDisappear: (): void => {
      onClose();
      if (foregroundBlur) {
        appState.isForegroundBlur = false
      }
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
  /** 标题栏右侧是否显示排序按钮（正/倒序切换）。 */
  @Param showSort: boolean = false;
  /** 当前是否正序（控制排序按钮箭头方向）。 */
  @Param sortAscending: boolean = true;
  /** 标题栏右侧是否显示关闭按钮。 */
  @Param showClose: boolean = false;
  @Event searchToggle: () => void = (): void => {};
  @Event searchChange: (value: string) => void = (_value: string): void => {};
  @Event searchSubmit: (value: string) => void = (_value: string): void => {};
  @Event locateClick: () => void = (): void => {};
  @Event sortClick: () => void = (): void => {};
  @Event closeClick: () => void = (): void => {};
  @BuilderParam content: () => void;

  build() {
    HdsNavDestination() {
      Column() {
        this.content()
      }
      .width('100%')
      .height('100%')
      .padding({ top: 66 })
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
        blurStrategy: BlurStrategy.ADAPTIVE,
        systemMaterialEffect: {
          materialType: appState.materialType,
          materialLevel: appState.materialLevel
        },
      },
      avoidLayoutSafeArea: false,
    })
    .hideBackButton(true)
    .titleMode(HdsNavDestinationTitleMode.MODAL)
    // 内容层透明：sheet 材质（blurStyle/systemMaterial）即唯一可见层，
    // 否则 HdsNavDestination 默认不透明底色盖住材质层，视觉成「两层」
    .backgroundColor(Color.Transparent)
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
    if (this.showSort) {
      menus.push({
        content: {
          icon: this.sortAscending ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down'),
          label: 'sort',
          action: (): void => {
            this.sortClick();
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

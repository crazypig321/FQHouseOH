/**
 * 路由名常量 + 静态跳转参数类
 * （对齐 musicfreeOH NavModels 模式：push 纯路由名，参数由来源页赋静态字段）。
 */

import { BottomBuilderParams, TitleBarContentOptions } from '@kit.UIDesignKit';
import { NavPathUtils } from '../utils/NavPathUtils';

export const ROUTE_SEARCH: string = 'search';
export const ROUTE_DETAIL: string = 'detail';
export const ROUTE_RANK: string = 'rank';

/** 详情页跳转参数（push 前由来源页赋值，详情页 aboutToAppear 读取）。 */
export class DetailNavParams {
  static id: string = '';
  static kind: string = 'book';
  static title: string = '';
  static cover: string = '';
}

/**
 * HDS 标题栏内容配置（样式统一由 view/CommonNav 的 CommonNav 提供）：
 * 标题 + 可选搜索/排行菜单 + 可选 bottomBuilder。
 */
export function FqTitleBarOptions(mainTitle: ResourceStr, showSearch: boolean,
  bottomBuilder?: BottomBuilderParams): TitleBarContentOptions {
  const content: TitleBarContentOptions = {
    title: {
      mainTitle: mainTitle,
    },
  };
  if (showSearch) {
    content.menu = {
      value: [{
        content: {
          icon: $r('sys.symbol.magnifyingglass'),
          label: 'search',
          action: (): void => {
            NavPathUtils.push(ROUTE_SEARCH);
          },
        },
      }, {
        content: {
          icon: $r('sys.symbol.medal'),
          label: 'rank',
          action: (): void => {
            NavPathUtils.push(ROUTE_RANK);
          },
        },
      }],
    };
  }
  if (bottomBuilder !== undefined) {
    content.bottomBuilder = bottomBuilder;
  }
  return content;
}

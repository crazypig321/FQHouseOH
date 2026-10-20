/**
 * 路由名常量 + 静态跳转参数类
 * （对齐 musicfreeOH NavModels 模式：push 纯路由名，参数由来源页赋静态字段）。
 */

import { BlurStrategy, BottomBuilderParams, HdsNavigationTitleBarOptions, ScrollEffectType, TitleBarContentOptions } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
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
 * HDS 标题栏配置（对齐 musicfreeOH CommonNav）：
 * 标题栏背景延伸至状态栏（avoidLayoutSafeArea），内容区从标题栏下方起排，
 * 中间内容自然避让状态栏；滚动时标题栏渐变模糊。
 */
export function FqTitleBarOptions(mainTitle: ResourceStr, showSearch: boolean,
  bottomBuilder?: BottomBuilderParams): HdsNavigationTitleBarOptions {
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
  return {
    content: content,
    style: {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(80),
      },
      blurStrategy: BlurStrategy.ADAPTIVE,
    },
    avoidLayoutSafeArea: true,
  };
}

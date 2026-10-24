/**
 * 路由名常量 + 静态跳转参数类
 * （对齐 musicfreeOH NavModels 模式：push 纯路由名，参数由来源页赋静态字段）。
 */

import { BottomBuilderParams, HdsNavigationMenuItemOptions, HdsNavigationTitle, TitleBarContentOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { NavPathUtils } from '../utils/NavPathUtils';
import { FqChapter } from './FqModels';
import { FQ_ACCENT } from '../view/CommonCom';

export const ROUTE_SEARCH: string = 'search';
export const ROUTE_DETAIL: string = 'detail';
export const ROUTE_RANK: string = 'rank';
/** 作者主页。 */
export const ROUTE_AUTHOR: string = 'author';
/** 自定义阅读页（ReaderPage，自绘分页引擎版）。 */
export const ROUTE_READER2: string = 'reader2';
/** 听书页（ListenPage，应用级播放会话）。 */
export const ROUTE_LISTEN: string = 'listen';
/** 视频播放页（PlayerPage，mpv 全屏播放器）。 */
export const ROUTE_PLAYER: string = 'player';

/** 详情页跳转参数（push 前由来源页赋值，详情页 aboutToAppear 读取）。 */
export class DetailNavParams {
  static id: string = '';
  static kind: string = 'book';
  static title: string = '';
  static cover: string = '';
}

/** 阅读页跳转参数。 */
export class ReaderNavParams {
  static id: string = '';
  static kind: string = 'book';
  static title: string = '';
  /** 定位章节下标；-1 表示跟随上次阅读进度。 */
  static chapterIndex: number = -1;
  /** 边听边读模式：跟随 fqAudioSession 高亮朗读段落（消费后由阅读页复位）。 */
  static listenAlong: boolean = false;
}

/** 作者主页跳转参数。 */
export class AuthorNavParams {
  static authorId: string = '';
  static fallbackName: string = '';
  /** 详情页作者头像（加载完成前的占位显示）。 */
  static avatar: string = '';
}

/** 听书页跳转参数。 */
export class ListenNavParams {
  static bookId: string = '';
  /** 详情 tab（fqKindToTab：小说='小说'，听书='听书'），决定目录语义。 */
  static tab: string = '听书';
  static title: string = '';
  static cover: string = '';
  /** 详情页预载章节（小说传其自身章节，TTS 按章生成音频；为空则听书页自行拉目录）。 */
  static chapters: FqChapter[] = [];
}

/** 播放页跳转参数（短剧/漫剧，mpv 播放器）。 */
export class PlayerNavParams {
  /** 剧集内容 id（目录请求用，通常为 seriesId）。 */
  static contentId: string = '';
  /** 内容类型（video/manju），决定 fqKindToTab 的取流 tab。 */
  static kind: string = 'video';
  static title: string = '';
  static cover: string = '';
  /** 详情页预载剧集目录；为空则播放页自行拉目录。 */
  static chapters: FqChapter[] = [];
  /** 起播集下标。 */
  static startIndex: number = 0;
  /** 剧集状态（FqBookDetail.creationStatus：0 完结 / 1 连载中；-1 未知）。 */
  static creationStatus: number = -1;
}

/**
 * HDS 标题栏内容配置（样式统一由 view/CommonNav 的 CommonNav 提供）：
 * 标题 + 可选书架（onShelf，shelfActive 控制实心图标）/刷新（onRefresh）/
 * 搜索（showSearch）/排行（showRank）菜单 + 可选 bottomBuilder。
 */
export function FqTitleBarOptions(mainTitle: ResourceStr, showSearch: boolean,
  bottomBuilder?: BottomBuilderParams, onRefresh?: () => void,
  showRank?: boolean, onShelf?: () => void, shelfActive?: boolean,
  subTitle?: ResourceStr): TitleBarContentOptions {
  const title: HdsNavigationTitle = {
    mainTitle: mainTitle,
  };
  if (subTitle !== undefined) {
    title.subTitle = subTitle;
  }
  const content: TitleBarContentOptions = {
    title: title,
  };
  const menus: HdsNavigationMenuItemOptions[] = [];
  if (onShelf !== undefined) {
    menus.push({
      content: {
        // 已在书架时用主题橙高亮（SymbolGlyphModifier 携带 fontColor）
        icon: shelfActive === true
          ? new SymbolGlyphModifier($r('sys.symbol.bookshelf_badge_checkmark_fill'))
            .fontColor([FQ_ACCENT])
          : $r('sys.symbol.bookshelf_badge_plus'),
        label: 'shelf',
        action: onShelf,
      },
    });
  }
  if (showSearch) {
    menus.push({
      content: {
        icon: $r('sys.symbol.magnifyingglass'),
        label: 'search',
        action: (): void => {
          NavPathUtils.push(ROUTE_SEARCH);
        },
      },
    });
  }
  if (onRefresh !== undefined) {
    menus.push({
      content: {
        icon: $r('sys.symbol.arrow_clockwise'),
        label: 'refresh',
        action: onRefresh,
      },
    });
  }
  if (showRank === true) {
    menus.push({
      content: {
        icon: $r('sys.symbol.medal'),
        label: 'rank',
        action: (): void => {
          NavPathUtils.push(ROUTE_RANK);
        },
      },
    });
  }
  if (menus.length > 0) {
    content.menu = { value: menus };
  }
  if (bottomBuilder !== undefined) {
    content.bottomBuilder = bottomBuilder;
  }
  return content;
}

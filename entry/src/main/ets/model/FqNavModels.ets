/**
 * 路由名常量 + 静态跳转参数类
 * （对齐 musicfreeOH NavModels 模式：push 纯路由名，参数由来源页赋静态字段）。
 */

import { BottomBuilderParams, HdsNavigationMenuItemOptions, HdsNavigationTitle, TitleBarContentOptions } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { NavPathUtils } from '../utils/NavPathUtils';
import { FqChapter } from './FqModels';
import { appState } from '../entryability/AppState';

export const ROUTE_SEARCH: string = 'search';
export const ROUTE_DETAIL: string = 'detail';
export const ROUTE_RANK: string = 'rank';
/** 作者主页。 */
export const ROUTE_AUTHOR: string = 'author';
/** 自定义阅读页（ReaderPage，自绘分页引擎版）。 */
export const ROUTE_READER2: string = 'reader2';
/** 漫画阅读页（ComicPage，整页图片 + 仿真/覆盖/上下翻页）。 */
export const ROUTE_COMIC: string = 'comic';
/** 听书页（ListenPage，应用级播放会话）。 */
export const ROUTE_LISTEN: string = 'listen';
/** 视频播放页（PlayerPage，mpv 全屏播放器）。 */
export const ROUTE_PLAYER: string = 'player';
/** 听视频页（ListenVideoPage，播放页「听视频」进入的听剧模式）。 */
export const ROUTE_LISTEN_VIDEO: string = 'listenVideo';
/** 关于我们页（我的-关于我们，占位）。 */
export const ROUTE_ABOUT: string = 'about';
/** 章节缓存页（我的-章节缓存，占位）。 */
export const ROUTE_CACHED_BOOKS: string = 'cachedBooks';
/** 剧集缓存页（我的-剧集缓存，占位）。 */
export const ROUTE_CACHED_DRAMAS: string = 'cachedDramas';
/** 听书缓存页（设置-听书缓存，离线音频管理）。 */
export const ROUTE_CACHED_AUDIO: string = 'cachedAudio';
/** 漫画缓存页（设置-漫画缓存，离线漫画管理）。 */
export const ROUTE_CACHED_COMICS: string = 'cachedComics';
/** 日志页（设置-服务-日志，应用/核心运行日志查看）。 */
export const ROUTE_LOGS: string = 'logs';
/** 备份与恢复页（设置-数据-备份与恢复，书架/记录跨设备迁移）。 */
export const ROUTE_BACKUP: string = 'backup';

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
  /** 封面（阅读页→听书页透传，听书页封面显示用）。 */
  static cover: string = '';
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
  /** 定位章节下标（详情页目录点击进页播对应章）；-1 跟随会话/历史（消费后由听书页复位）。 */
  static chapterIndex: number = -1;
  /** 阅读页带入的当前段原文：听书页拉章节字幕后匹配定位起播秒（消费后由听书页复位）。 */
  static startCueText: string = '';
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
  /** 起播集下标；-1 未指定（走续播/从头），>=0 显式起播集（详情目录点击，跳过续播）。 */
  static startIndex: number = -1;
  /** 剧集状态（FqBookDetail.creationStatus：0 完结 / 1 连载中；-1 未知）。 */
  static creationStatus: number = -1;
  /** 剧简介（FqBookDetail.abstractText，选集面板头部小字展示）。 */
  static intro: string = '';
}

/** 听视频页跳转参数（播放页「听视频」进入；退出结果由播放页 onShown 消费）。 */
export class ListenVideoNavParams {
  /** 剧集内容 id（已看/续播持久化键，与播放页同键）。 */
  static contentId: string = '';
  /** 内容类型（video/manju），决定 fqKindToTab 的取流 tab。 */
  static kind: string = 'video';
  static title: string = '';
  static cover: string = '';
  /** 预载剧集目录（播放页 episodes）。 */
  static chapters: FqChapter[] = [];
  /** 起听集下标。 */
  static startIndex: number = 0;
  /** 起听位置（秒；播放页当前视频位置续听）。 */
  static startPositionSec: number = 0;
  /** 退出回传：听到的集下标（-1 未听）。 */
  static resultIndex: number = -1;
  /** 退出回传：听到位置（秒）。 */
  static resultPositionSec: number = 0;
}

/** 漫画页跳转参数。 */
export class ComicNavParams {
  static id: string = '';
  /** 定位章节下标；-1 表示跟随上次阅读进度。 */
  static chapterIndex: number = -1;
  static title: string = '';
}

/**
 * 单自定义菜单标题栏配置（FqTitleBarOptions 固定菜单组合的轻量替代）：
 * 标题 + 右上角单个自定义图标菜单（听视频页语速菜单等）。
 */
export function FqTitleBarMenuOptions(mainTitle: ResourceStr, menuIcon: Resource,
  menuLabel: string, menuAction: () => void): TitleBarContentOptions {
  const title: HdsNavigationTitle = {
    mainTitle: mainTitle,
  };
  const menus: HdsNavigationMenuItemOptions[] = [{
    content: {
      icon: menuIcon,
      label: menuLabel,
      action: menuAction,
    },
  }];
  const content: TitleBarContentOptions = {
    title: title,
    menu: { value: menus },
  };
  return content;
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
            .fontColor([appState.accentColor])
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

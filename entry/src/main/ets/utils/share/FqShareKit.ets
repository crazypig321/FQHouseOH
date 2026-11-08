/**
 * 分享功能工具（Deep Linking fqhouse:// scheme + 系统分享面板 systemShare）：
 * - 源端：shareRead/shareListen/shareVideo/shareListenVideo（四页分享直达）与
 *   shareShelf（书架多选/整架分享）构建 fqhouse://open?d=<JSON> 链接，拉起
 *   系统分享面板（华为分享跨设备 / 复制 / 第三方渠道）；
 * - 目标端：parseUri() 在 EntryAbility onCreate/onNewWant 解析分享链接存为
 *   待处理载荷，applyPending() 四场景直达对应页面（内容按 id 自行拉取，
 *   进度取本机记录），书架载荷直接幂等导入书架（fqStoreBus 自动通知刷新）；
 * - 本机导入书（内容仅本机可取）与书旗来源（第三方只读）不参与分享；
 * - module.json5 skills 注册 scheme fqhouse + host open（action viewData）。
 */

import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { url } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appState } from '../../entryability/AppState';
import { FqShelfItem, FqShelfStore } from '../../core/FqShelfStore';
import { FqLocalBookStore } from '../../core/FqLocalBookStore';
import { FqBackend } from '../../core/FqBackend';
import { fqAudioSession } from '../../core/FqAudioSession';
import { fqParseObject, fqStr, fqAsArray, fqAsRecord, fqEmptyRecord } from '../../core/FqJson';
import { FqChapter, fqKindToTab } from '../../model/FqModels';
import {
  ReaderNavParams,
  ListenNavParams,
  PlayerNavParams,
  ListenVideoNavParams,
  ROUTE_READER2,
  ROUTE_LISTEN,
  ROUTE_PLAYER,
  ROUTE_LISTEN_VIDEO,
} from '../../model/FqNavModels';
import { NavPathUtils } from '../NavPathUtils';

const DOMAIN = 0x0000;
/** 分享链接协议（module.json5 skills 注册）。 */
const FQ_SHARE_SCHEME: string = 'fqhouse';
/** 分享链接 host（与 skills 注册一致）。 */
const FQ_SHARE_HOST: string = 'open';
/** 场景：阅读（小说）。 */
const FQ_SHARE_SCENE_READ: string = 'read';
/** 场景：听书（kind 直接为听书 tab）。 */
const FQ_SHARE_SCENE_LISTEN: string = 'listen';
/** 场景：视频（短剧 / 漫剧）。 */
const FQ_SHARE_SCENE_VIDEO: string = 'video';
/** 场景：听视频（听剧模式）。 */
const FQ_SHARE_SCENE_LISTEN_VIDEO: string = 'listenVideo';
/** 场景：书架书单（目标端导入书架）。 */
const FQ_SHARE_SCENE_SHELF: string = 'shelf';
/** 书旗只读来源 id 前缀（内容仅第三方只读，不参与分享）。 */
const FQ_SHUQI_ID_PREFIX: string = 'shuqi:';
/** 单次书架分享条目上限（链接载荷保护，超出截断）。 */
const FQ_SHARE_MAX_BOOKS: number = 300;

/** 分享功能（源端构建链接拉起分享面板 / 目标端解析导入）。 */
export class FqShareKit {
  /** 目标端待处理分享载荷（onCreate / onNewWant 解析，Index 挂载后消费）。 */
  private static pendingPayload: Record<string, Object> | null = null;

  /** 目标端是否存在待处理的分享载荷。 */
  public static hasPending(): boolean {
    return FqShareKit.pendingPayload !== null;
  }

  /** 作品是否可分享（本机导入书与书旗来源内容不可迁移，跳过）。 */
  public static isShareableId(id: string): boolean {
    return id.length > 0 && !id.startsWith(FQ_SHUQI_ID_PREFIX) && !FqLocalBookStore.isLocalBookId(id);
  }

  /**
   * 阅读页分享：直达目标设备阅读页（目标端按 id 拉目录正文，跟随本机阅读进度）。
   * 返回 false 表示当前书籍不可分享（本地导入 / 书旗来源）。
   */
  public static shareRead(): boolean {
    return FqShareKit.shareContent(FQ_SHARE_SCENE_READ, ReaderNavParams.id,
      ReaderNavParams.kind, ReaderNavParams.title, ReaderNavParams.cover);
  }

  /** 听书页分享：直达目标设备听书页（目标端按 id 拉目录，跟随本机收听历史）。 */
  public static shareListen(): boolean {
    return FqShareKit.shareContent(FQ_SHARE_SCENE_LISTEN, fqAudioSession.bookId,
      fqAudioSession.tab, fqAudioSession.title, fqAudioSession.cover);
  }

  /** 播放页分享：直达目标设备播放页（目标端按 id 拉剧集，跟随本机观看记录）。 */
  public static shareVideo(): boolean {
    return FqShareKit.shareContent(FQ_SHARE_SCENE_VIDEO, PlayerNavParams.contentId,
      PlayerNavParams.kind, PlayerNavParams.title, PlayerNavParams.cover);
  }

  /** 听视频页分享：直达目标设备听视频页（目标端按 id 拉剧集起听）。 */
  public static shareListenVideo(): boolean {
    return FqShareKit.shareContent(FQ_SHARE_SCENE_LISTEN_VIDEO, ListenVideoNavParams.contentId,
      ListenVideoNavParams.kind, ListenVideoNavParams.title, ListenVideoNavParams.cover);
  }

  /**
   * 书架分享（多选 / 整架）：目标端打开链接后书签直接幂等导入书架。
   * 不可分享条目（本地导入 / 书旗）自动过滤；全部不可分享返回 false。
   */
  public static shareShelf(items: FqShelfItem[], title: string): boolean {
    const books: Record<string, Object>[] = [];
    for (const item of items) {
      if (!FqShareKit.isShareableId(item.id)) {
        continue;
      }
      if (books.length >= FQ_SHARE_MAX_BOOKS) {
        break;
      }
      const rec: Record<string, Object> = fqEmptyRecord();
      rec['i'] = item.id;
      rec['k'] = item.kind;
      rec['t'] = item.title;
      rec['c'] = item.cover;
      books.push(rec);
    }
    if (books.length === 0) {
      return false;
    }
    const payload: Record<string, Object> = fqEmptyRecord();
    payload['s'] = FQ_SHARE_SCENE_SHELF;
    payload['b'] = books;
    return FqShareKit.openSharePanel(FqShareKit.buildUri(payload),
      `${title}·共 ${books.length} 部`);
  }

  /**
   * 目标端：解析 fqhouse:// 分享链接（EntryAbility onCreate / onNewWant 调用）。
   * 解析成功存为待处理载荷（仅消费一次），返回是否命中分享链接。
   */
  public static parseUri(want: Want): boolean {
    const uri: string = want.uri ?? '';
    if (!uri.startsWith(`${FQ_SHARE_SCHEME}://`)) {
      return false;
    }
    FqShareKit.pendingPayload = null;
    try {
      const parsed: url.URL = url.URL.parseURL(uri);
      const text: string | null = parsed.params.get('d');
      if (text === null || text.length === 0) {
        return false;
      }
      const rec: Record<string, Object> | null = fqParseObject(text);
      if (rec === null || fqStr(rec, 's').length === 0) {
        hilog.warn(DOMAIN, 'FqShare', '%{public}s', 'share payload invalid, skip');
        return false;
      }
      FqShareKit.pendingPayload = rec;
      hilog.info(DOMAIN, 'FqShare', 'share link parsed: scene=%{public}s', fqStr(rec, 's'));
      return true;
    } catch (error) {
      hilog.error(DOMAIN, 'FqShare', 'parse uri failed: %{public}s', `${error}`);
      return false;
    }
  }

  /**
   * 目标端：消费待处理分享载荷——四场景直达对应页面（内容按 id 自取，
   * 进度跟随目标端本机记录），书架书单幂等导入书架并切换到书架 tab。
   * 冷启动由 Index aboutToAppear 延时调用，热启动由 EntryAbility onNewWant 延时调用；
   * 载荷消费即清空，重复调用安全。
   */
  public static applyPending(): void {
    const rec: Record<string, Object> | null = FqShareKit.pendingPayload;
    if (rec === null) {
      return;
    }
    FqShareKit.pendingPayload = null;
    const scene: string = fqStr(rec, 's');
    if (scene === FQ_SHARE_SCENE_SHELF) {
      FqShareKit.applyShelf(rec);
      return;
    }
    FqShareKit.applyContent(rec, scene);
  }

  /** 四页分享：构建链接载荷并拉起系统分享面板。 */
  private static shareContent(scene: string, id: string, kind: string,
    title: string, cover: string): boolean {
    if (!FqShareKit.isShareableId(id)) {
      hilog.info(DOMAIN, 'FqShare', '%{public}s', 'content not shareable, skip');
      return false;
    }
    const payload: Record<string, Object> = fqEmptyRecord();
    payload['s'] = scene;
    payload['i'] = id;
    payload['k'] = kind;
    payload['t'] = title;
    payload['c'] = cover;
    return FqShareKit.openSharePanel(FqShareKit.buildUri(payload),
      title.length > 0 ? title : '番茄之家分享');
  }

  /** 构建分享链接：fqhouse://open?d=<encodeURIComponent(JSON)>。 */
  private static buildUri(payload: Record<string, Object>): string {
    return `${FQ_SHARE_SCHEME}://${FQ_SHARE_HOST}?d=${encodeURIComponent(JSON.stringify(payload))}`;
  }

  /** 拉起系统分享面板（HYPERLINK 记录：链接 + 标题）。 */
  private static openSharePanel(uri: string, title: string): boolean {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return false;
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: utd.UniformDataType.HYPERLINK,
        content: uri,
        title: title,
        description: '番茄之家',
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(context, {}).catch((error: BusinessError): void => {
        hilog.error(DOMAIN, 'FqShare', 'panel failed: %{public}s', `${error.code} ${error.message}`);
      });
      return true;
    } catch (error) {
      hilog.error(DOMAIN, 'FqShare', 'panel error: %{public}s', `${error}`);
      return false;
    }
  }

  /** 四场景直达：设静态跳转参数并推入对应页面（页面按 id 拉内容、按本机记录续位）。 */
  private static applyContent(rec: Record<string, Object>, scene: string): void {
    const id: string = fqStr(rec, 'i');
    if (id.length === 0) {
      return;
    }
    const kind: string = fqStr(rec, 'k');
    const title: string = fqStr(rec, 't');
    const cover: string = fqStr(rec, 'c');
    if (scene === FQ_SHARE_SCENE_READ) {
      ReaderNavParams.id = id;
      ReaderNavParams.kind = kind.length > 0 ? kind : 'book';
      ReaderNavParams.title = title;
      ReaderNavParams.cover = cover;
      ReaderNavParams.chapterIndex = -1;
      ReaderNavParams.listenAlong = false;
      ReaderNavParams.readOnly = false;
      ReaderNavParams.presetChapters = [];
      ReaderNavParams.chapterLoader = null;
      NavPathUtils.push(ROUTE_READER2);
      return;
    }
    if (scene === FQ_SHARE_SCENE_LISTEN) {
      ListenNavParams.bookId = id;
      ListenNavParams.tab = kind.length > 0 ? kind : '听书';
      ListenNavParams.title = title;
      ListenNavParams.cover = cover;
      ListenNavParams.chapters = [];
      ListenNavParams.chapterIndex = -1;
      ListenNavParams.startCueText = '';
      NavPathUtils.push(ROUTE_LISTEN);
      return;
    }
    if (scene === FQ_SHARE_SCENE_VIDEO) {
      PlayerNavParams.contentId = id;
      PlayerNavParams.kind = kind.length > 0 ? kind : 'video';
      PlayerNavParams.title = title;
      PlayerNavParams.cover = cover;
      PlayerNavParams.chapters = [];
      PlayerNavParams.startIndex = -1;
      PlayerNavParams.creationStatus = -1;
      PlayerNavParams.intro = '';
      NavPathUtils.push(ROUTE_PLAYER);
      return;
    }
    if (scene === FQ_SHARE_SCENE_LISTEN_VIDEO) {
      // 听视频页无自拉目录逻辑：先取剧集目录再推入
      FqShareKit.applyListenVideo(id, kind.length > 0 ? kind : 'video', title, cover)
        .catch((error: BusinessError): void => {
          hilog.error(DOMAIN, 'FqShare', 'listenVideo apply failed: %{public}s',
            `${error.code} ${error.message}`);
        });
    }
  }

  /** 听视频直达：先拉剧集目录（页面无自拉），从头起听。 */
  private static async applyListenVideo(id: string, kind: string,
    title: string, cover: string): Promise<void> {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return;
    }
    await FqBackend.get().start(context);
    const episodes: FqChapter[] = await FqBackend.get().directoryChapters(id, fqKindToTab(kind));
    if (episodes.length === 0) {
      hilog.warn(DOMAIN, 'FqShare', '%{public}s', 'listenVideo episodes empty, skip');
      return;
    }
    ListenVideoNavParams.contentId = id;
    ListenVideoNavParams.kind = kind;
    ListenVideoNavParams.title = title;
    ListenVideoNavParams.cover = cover;
    ListenVideoNavParams.chapters = episodes;
    ListenVideoNavParams.startIndex = -1;
    ListenVideoNavParams.startPositionSec = 0;
    ListenVideoNavParams.resultIndex = -1;
    ListenVideoNavParams.resultPositionSec = 0;
    NavPathUtils.push(ROUTE_LISTEN_VIDEO);
  }

  /** 书架书单导入：幂等加入书架（fqStoreBus 通知书架页实时刷新）+ 切到书架 tab。 */
  private static applyShelf(rec: Record<string, Object>): void {
    const booksRaw: Object[] | null = fqAsArray(rec['b']);
    if (booksRaw === null) {
      return;
    }
    let added: number = 0;
    for (const raw of booksRaw) {
      const bookRec: Record<string, Object> | null = fqAsRecord(raw);
      if (bookRec === null) {
        continue;
      }
      const id: string = fqStr(bookRec, 'i');
      if (id.length === 0) {
        continue;
      }
      if (FqShelfStore.addIfAbsent(new FqShelfItem(id, fqStr(bookRec, 'k'),
        fqStr(bookRec, 't'), fqStr(bookRec, 'c')))) {
        added++;
      }
    }
    if (added > 0) {
      const switchTab: ((index: number) => void) | null = appState.switchMainTab;
      if (switchTab !== null) {
        switchTab(1);
      }
    }
    FqShareKit.toast(added > 0 ? `已导入 ${added} 部作品到书架` : '分享的作品已在书架');
  }

  /** 静态上下文 Toast（经主窗口 UIContext 弹出）。 */
  private static toast(message: string): void {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    }).catch((_error: BusinessError): void => {
      // 窗口获取失败仅日志，不打断导入
      hilog.warn(DOMAIN, 'FqShare', '%{public}s', 'toast window unavailable');
    });
  }
}

/**
 * 分享功能工具（Deep Linking fqhouse:// scheme + 系统分享面板 systemShare）：
 * - 源端：shareRead/shareListen/shareComic/shareVideo/shareListenVideo（五页分享
 *   直达）与 shareShelf（书架多选/整架分享）构建 fqhouse://open?d=<JSON> 链接，
 *   拉起系统分享面板（华为分享跨设备 / 复制 / 第三方渠道）；书架批量分享时
 *   在线作品生成书单链接、本地导入书以正文文件本体一并进面板；书旗来源
 *   目标端同款后端可按 id 自取，正常分享；
 * - 碰一碰 / 隔空手势（握拳）分享：setupHarmonyShare() 进程内一次注册
 *   harmonyShare 事件，触发时按导航栈顶页面构建分享内容；五页在线内容
 *   带封面缩略图（下载压缩 32KB 内），书架 Tab 多选分享所选、普通态整架
 *   （书单链接按编码长度预算截断，防 want 超限分享服务拉起失败）；
 *   构建异常 / 无内容统一 reject，避免分享 UI 悬挂卡死；
 * - 目标端：parseUri() 在 EntryAbility onCreate/onNewWant 解析分享链接、
 *   parseFileUri() 解析文件打开（本地书 .txt/.epub，skills FileOpen），
 *   applyPending() 四场景直达对应页面（内容按 id 自行拉取，进度取本机记录；
 *   书旗走 openShuqiReader 只读链路），书架载荷幂等导入书架（fqStoreBus
 *   自动通知刷新），本地书文件导入书架并直达阅读页；
 * - module.json5 skills 注册 scheme fqhouse + host open（action viewData）
 *   与 file 打开（general.plain-text / general.epub，linkFeature FileOpen）。
 */

import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { systemShare, harmonyShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
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
import { FqShuqiToc } from '../../model/FqShuqiModels';
import {
  ReaderNavParams,
  ListenNavParams,
  PlayerNavParams,
  ListenVideoNavParams,
  ComicNavParams,
  ROUTE_READER2,
  ROUTE_LISTEN,
  ROUTE_PLAYER,
  ROUTE_LISTEN_VIDEO,
  ROUTE_COMIC,
} from '../../model/FqNavModels';
import { NavPathUtils } from '../NavPathUtils';

const DOMAIN = 0x0000;
/** 分享链接协议（module.json5 skills 注册）。 */
const FQ_SHARE_SCHEME: string = 'fqhouse';
/** 分享链接 host（与 skills 注册一致）。 */
const FQ_SHARE_HOST: string = 'open';
/** 场景：阅读（小说）。 */
const FQ_SHARE_SCENE_READ: string = 'read';
/** 场景：漫画阅读。 */
const FQ_SHARE_SCENE_COMIC: string = 'comic';
/** 场景：听书（kind 直接为听书 tab）。 */
const FQ_SHARE_SCENE_LISTEN: string = 'listen';
/** 场景：视频（短剧 / 漫剧）。 */
const FQ_SHARE_SCENE_VIDEO: string = 'video';
/** 场景：听视频（听剧模式）。 */
const FQ_SHARE_SCENE_LISTEN_VIDEO: string = 'listenVideo';
/** 场景：书架书单（目标端导入书架）。 */
const FQ_SHARE_SCENE_SHELF: string = 'shelf';
/** 书旗只读来源 id 前缀（目标端按 raw id 拉目录正文）。 */
const FQ_SHUQI_ID_PREFIX: string = 'shuqi:';
/** 单次书架分享条目上限（链接载荷保护，超出截断）。 */
const FQ_SHARE_MAX_BOOKS: number = 300;
/** 单次书架分享本地书文件上限（超出截断，避免一次传输过大）。 */
const FQ_SHARE_MAX_LOCAL_BOOKS: number = 10;
/** 书单链接编码后长度上限（want 分发有体积阈值，超限分享服务拉起失败，超出截断）。 */
const FQ_SHARE_SHELF_LINK_MAX: number = 16000;
/** 分享缩略图短边压缩目标（px）。 */
const FQ_SHARE_THUMB_SIZE: number = 128;
/** 分享缩略图体积上限（SDK 约束 32KB 内，超限弃用缩略图退默认图标）。 */
const FQ_SHARE_THUMB_MAX_BYTES: number = 30 * 1024;

/** 栈顶分享构建结果：分享记录集 + 首链接封面（面板 / 碰一碰预览缩略图用）。 */
class FqTopShareResult {
  /** 分享记录集（空数组 = 无可分享内容，reject 无内容）。 */
  records: systemShare.SharedRecord[] = [];
  /** 首链接记录封面 URL（缩略图下载用；无封面为空串）。 */
  coverUrl: string = '';
}

/** 分享功能（源端构建链接拉起分享面板 / 目标端解析导入）。 */
export class FqShareKit {
  /** 目标端待处理分享载荷（onCreate / onNewWant 解析，Index 挂载后消费）。 */
  private static pendingPayload: Record<string, Object> | null = null;
  /** 目标端待处理本地书文件 URI（文件打开 skills 命中，Index 挂载后消费）。 */
  private static pendingFileUri: string | null = null;
  /** 碰一碰 / 隔空手势分享是否已注册（进程内一次）。 */
  private static harmonyShareReady: boolean = false;

  /** 目标端是否存在待处理的分享载荷。 */
  public static hasPending(): boolean {
    return FqShareKit.pendingPayload !== null || FqShareKit.pendingFileUri !== null;
  }

  /** 作品是否可分享（书旗目标端按 id 自取、本地书走文件分享，均可分享）。 */
  public static isShareableId(id: string): boolean {
    return id.length > 0;
  }

  /**
   * 阅读页分享：直达目标设备阅读页（目标端按 id 拉目录正文，跟随本机阅读进度）。
   * 本地导入书改分享正文文件本体；返回 false 表示当前书籍不可分享。
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

  /** 漫画阅读页分享：直达目标设备漫画页（目标端按 id 拉目录图片，跟随本机阅读进度）。 */
  public static shareComic(): boolean {
    return FqShareKit.shareContent(FQ_SHARE_SCENE_COMIC, ComicNavParams.id,
      'manga', ComicNavParams.title, ComicNavParams.cover);
  }

  /**
   * 书架分享（多选 / 整架）：在线作品生成书单链接（目标端打开直接幂等导入
   * 书架），本地导入书以正文文件本体一并进入分享面板（接收方用本应用打开
   * 自动导入书架，单次最多 10 本）；全部无内容返回 false。
   */
  public static shareShelf(items: FqShelfItem[], title: string): boolean {
    const records: systemShare.SharedRecord[] = FqShareKit.buildShelfRecords(items, title);
    if (records.length === 0) {
      return false;
    }
    return FqShareKit.showRecords(records);
  }

  /** 书架分享记录集：在线作品书单链接 + 本地导入书正文文件（各自上限截断）。 */
  private static buildShelfRecords(items: FqShelfItem[],
    title: string): systemShare.SharedRecord[] {
    const books: Record<string, Object>[] = [];
    const localIds: string[] = [];
    let linkLen: number = 0;
    for (const item of items) {
      if (item.id.length === 0) {
        continue;
      }
      if (FqLocalBookStore.isLocalBookId(item.id)) {
        if (localIds.length < FQ_SHARE_MAX_LOCAL_BOOKS) {
          localIds.push(item.id);
        }
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
      // 链接经 want 分发有体积阈值，编码后超限会导致分享服务拉起失败：按预算截断
      const enc: number = encodeURIComponent(JSON.stringify(rec)).length + 1;
      if (linkLen + enc > FQ_SHARE_SHELF_LINK_MAX) {
        break;
      }
      linkLen += enc;
      books.push(rec);
    }
    const records: systemShare.SharedRecord[] = [];
    if (books.length > 0) {
      const payload: Record<string, Object> = fqEmptyRecord();
      payload['s'] = FQ_SHARE_SCENE_SHELF;
      payload['b'] = books;
      const linkRecord: systemShare.SharedRecord = {
        utd: utd.UniformDataType.HYPERLINK,
        content: FqShareKit.buildUri(payload),
        title: `${title}·共 ${books.length} 部`,
        description: '番茄之家',
      };
      records.push(linkRecord);
    }
    for (const id of localIds) {
      const fileRecord: systemShare.SharedRecord | null = FqShareKit.buildLocalFileRecord(id);
      if (fileRecord !== null) {
        records.push(fileRecord);
      }
    }
    return records;
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
    FqShareKit.pendingFileUri = null;
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
   * 目标端：解析文件打开 want（本地书 .txt / .epub 文件分享接收，skills FileOpen）。
   * 命中存为待处理文件 URI（仅消费一次），返回是否本地书文件。
   */
  public static parseFileUri(want: Want): boolean {
    const uri: string = want.uri ?? '';
    if (!uri.startsWith('file://')) {
      return false;
    }
    const lower: string = uri.toLowerCase();
    if (!lower.endsWith('.txt') && !lower.endsWith('.epub')) {
      return false;
    }
    FqShareKit.pendingPayload = null;
    FqShareKit.pendingFileUri = uri;
    hilog.info(DOMAIN, 'FqShare', 'file open parsed: %{public}s', uri);
    return true;
  }

  /**
   * 目标端：消费待处理分享载荷——四场景直达对应页面（内容按 id 自取，
   * 进度跟随目标端本机记录），书架书单幂等导入书架并切换到书架 tab，
   * 本地书文件导入书架并直达阅读页。
   * 冷启动由 Index aboutToAppear 延时调用，热启动由 EntryAbility onNewWant 延时调用；
   * 载荷消费即清空，重复调用安全。
   */
  public static applyPending(): void {
    const fileUriStr: string | null = FqShareKit.pendingFileUri;
    if (fileUriStr !== null) {
      FqShareKit.pendingFileUri = null;
      FqShareKit.applyLocalBookFile(fileUriStr).catch((error: BusinessError): void => {
        hilog.error(DOMAIN, 'FqShare', 'local book import failed: %{public}s', `${error.message}`);
        FqShareKit.toast(`导入失败：${error.message}`);
      });
      return;
    }
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

  /**
   * 注册碰一碰 / 隔空手势（握拳）分享（Index 挂载后调用一次，进程内常驻）。
   * 触发时按当前导航栈顶页面构建分享内容（链接 / 本地书文件，带封面缩略图）；
   * 书架 Tab（无压栈页）多选模式分享所选、普通态分享整架书单；
   * 构建异常 / 无内容统一 reject，交系统提示，避免分享 UI 悬挂卡死。
   */
  public static setupHarmonyShare(): void {
    if (FqShareKit.harmonyShareReady) {
      return;
    }
    FqShareKit.harmonyShareReady = true;
    const callback = (target: harmonyShare.SharableTarget): void => {
      const result: FqTopShareResult = new FqTopShareResult();
      try {
        const built: FqTopShareResult = FqShareKit.buildTopShareRecords();
        result.records = built.records;
        result.coverUrl = built.coverUrl;
      } catch (error) {
        hilog.error(DOMAIN, 'FqShare', 'harmony share build error: %{public}s', `${error}`);
        FqShareKit.rejectNoContent(target);
        return;
      }
      if (result.records.length === 0) {
        FqShareKit.rejectNoContent(target);
        return;
      }
      if (result.coverUrl.length > 0) {
        FqShareKit.fetchThumbnail(result.coverUrl).then((thumb: Uint8Array | null): void => {
          FqShareKit.sendToTarget(target, result.records, thumb);
        }).catch((_error: BusinessError): void => {
          FqShareKit.sendToTarget(target, result.records, null);
        });
        return;
      }
      FqShareKit.sendToTarget(target, result.records, null);
    };
    try {
      harmonyShare.on('knockShare', callback);
      harmonyShare.on('gesturesShare', callback);
    } catch (error) {
      hilog.error(DOMAIN, 'FqShare', 'harmony share register failed: %{public}s', `${error}`);
    }
  }

  /** 无可分享内容统一 reject（系统提示引导，防分享 UI 悬挂）。 */
  private static rejectNoContent(target: harmonyShare.SharableTarget): void {
    target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR)
      .catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, 'FqShare', 'reject failed: %{public}s', `${error.code}`);
      });
  }

  /** 碰一碰 / 隔空手势记录集发送：缩略图挂首记录，经 target 跨设备分享。 */
  private static sendToTarget(target: harmonyShare.SharableTarget,
    records: systemShare.SharedRecord[], thumb: Uint8Array | null): void {
    try {
      if (thumb !== null && records.length > 0) {
        records[0].thumbnail = thumb;
      }
      const data: systemShare.SharedData = new systemShare.SharedData(records[0]);
      for (let i: number = 1; i < records.length; i++) {
        data.addRecord(records[i]);
      }
      target.share(data).catch((error: BusinessError): void => {
        hilog.error(DOMAIN, 'FqShare', 'harmony share failed: %{public}s',
          `${error.code} ${error.message}`);
      });
    } catch (error) {
      hilog.error(DOMAIN, 'FqShare', 'harmony share send error: %{public}s', `${error}`);
    }
  }

  /** 四页分享：构建链接载荷并拉起系统分享面板（本地书改走正文文件分享）。 */
  private static shareContent(scene: string, id: string, kind: string,
    title: string, cover: string): boolean {
    if (FqLocalBookStore.isLocalBookId(id)) {
      return FqShareKit.shareLocalBookFile(id);
    }
    const record: systemShare.SharedRecord | null =
      FqShareKit.buildLinkRecord(scene, id, kind, title, cover);
    if (record === null) {
      hilog.info(DOMAIN, 'FqShare', '%{public}s', 'content not shareable, skip');
      return false;
    }
    FqShareKit.showRecordWithCover(record, cover);
    return true;
  }

  /** 封面缩略图就绪后拉起分享面板（下载/压缩失败退回默认图标照常分享）。 */
  private static showRecordWithCover(record: systemShare.SharedRecord, coverUrl: string): void {
    FqShareKit.fetchThumbnail(coverUrl).then((thumb: Uint8Array | null): void => {
      if (thumb !== null) {
        record.thumbnail = thumb;
      }
      FqShareKit.showRecord(record);
    }).catch((_error: BusinessError): void => {
      FqShareKit.showRecord(record);
    });
  }

  /** 下载封面并压缩为分享缩略图（短边 128px JPEG、32KB 内；失败/无封面返回 null）。 */
  private static async fetchThumbnail(coverUrl: string): Promise<Uint8Array | null> {
    if (coverUrl.length === 0 || !coverUrl.startsWith('http')) {
      return null;
    }
    const client: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await client.request(coverUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 1500,
        readTimeout: 1500,
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      const raw: string | Object | ArrayBuffer = resp.result;
      if (!(raw instanceof ArrayBuffer) || raw.byteLength === 0) {
        return null;
      }
      const source: image.ImageSource = image.createImageSource(raw);
      const pixel: image.PixelMap = await source.createPixelMap();
      const info: image.ImageInfo = await pixel.getImageInfo();
      const maxSide: number = Math.max(info.size.width, info.size.height);
      if (maxSide > FQ_SHARE_THUMB_SIZE) {
        const scale: number = FQ_SHARE_THUMB_SIZE / maxSide;
        await pixel.scale(scale, scale);
      }
      const packer: image.ImagePacker = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packToData(pixel, {
        format: 'image/jpeg',
        quality: 65,
      });
      packer.release();
      pixel.release();
      source.release();
      if (packed.byteLength === 0 || packed.byteLength >= FQ_SHARE_THUMB_MAX_BYTES) {
        return null;
      }
      return new Uint8Array(packed);
    } catch (error) {
      hilog.warn(DOMAIN, 'FqShare', 'thumbnail fetch failed: %{public}s', `${error}`);
      return null;
    } finally {
      client.destroy();
    }
  }

  /** 四页链接记录构建：id 为空 / 本地书返回 null（本地书走文件记录）。 */
  private static buildLinkRecord(scene: string, id: string, kind: string,
    title: string, cover: string): systemShare.SharedRecord | null {
    if (id.length === 0 || FqLocalBookStore.isLocalBookId(id)) {
      return null;
    }
    const payload: Record<string, Object> = fqEmptyRecord();
    payload['s'] = scene;
    payload['i'] = id;
    payload['k'] = kind;
    payload['t'] = title;
    payload['c'] = cover;
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: FqShareKit.buildUri(payload),
      title: title.length > 0 ? title : '番茄之家分享',
      description: '番茄之家',
    };
    return record;
  }

  /** 本地书分享：沙箱正文文件本体经系统分享面板（接收方用本应用打开自动导入书架）。 */
  private static shareLocalBookFile(bookId: string): boolean {
    const record: systemShare.SharedRecord | null = FqShareKit.buildLocalFileRecord(bookId);
    if (record === null) {
      hilog.warn(DOMAIN, 'FqShare', '%{public}s', 'local book file missing, skip');
      return false;
    }
    return FqShareKit.showRecord(record);
  }

  /** 本地书文件记录构建：沙箱正文路径转 file URI（App file URI 支持跨设备分享）。 */
  private static buildLocalFileRecord(bookId: string): systemShare.SharedRecord | null {
    const path: string = FqLocalBookStore.bookFilePath(bookId);
    if (path.length === 0) {
      return null;
    }
    const title: string = FqLocalBookStore.bookTitle(bookId);
    try {
      const record: systemShare.SharedRecord = {
        utd: utd.UniformDataType.PLAIN_TEXT,
        uri: fileUri.getUriFromPath(path),
        title: `${title.length > 0 ? title : '本地书籍'}.txt`,
        description: '番茄之家·本地书籍（用番茄之家打开自动导入书架）',
      };
      return record;
    } catch (error) {
      hilog.error(DOMAIN, 'FqShare', 'file uri failed: %{public}s', `${error}`);
      return null;
    }
  }

  /**
   * 按导航栈顶页面构建分享记录集（碰一碰 / 隔空手势回调）：
   * 五页按页内身份构建（链接 / 本地书文件，在线内容带封面）；书架 Tab
   * （无压栈页）多选模式分享所选、普通态分享整架书单；其余返回空记录集。
   */
  private static buildTopShareRecords(): FqTopShareResult {
    const result: FqTopShareResult = new FqTopShareResult();
    const names: string[] = appState.pageInfos.getAllPathName();
    const top: string = names.length > 0 ? names[names.length - 1] : '';
    if (top === ROUTE_READER2) {
      const id: string = ReaderNavParams.id;
      if (FqLocalBookStore.isLocalBookId(id)) {
        result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLocalFileRecord(id));
        return result;
      }
      result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLinkRecord(FQ_SHARE_SCENE_READ,
        id, ReaderNavParams.kind, ReaderNavParams.title, ReaderNavParams.cover));
      result.coverUrl = ReaderNavParams.cover;
      return result;
    }
    if (top === ROUTE_LISTEN) {
      const id: string = fqAudioSession.bookId;
      if (FqLocalBookStore.isLocalBookId(id)) {
        result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLocalFileRecord(id));
        return result;
      }
      result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLinkRecord(FQ_SHARE_SCENE_LISTEN,
        id, fqAudioSession.tab, fqAudioSession.title, fqAudioSession.cover));
      result.coverUrl = fqAudioSession.cover;
      return result;
    }
    if (top === ROUTE_COMIC) {
      result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLinkRecord(FQ_SHARE_SCENE_COMIC,
        ComicNavParams.id, 'manga', ComicNavParams.title, ComicNavParams.cover));
      result.coverUrl = ComicNavParams.cover;
      return result;
    }
    if (top === ROUTE_PLAYER) {
      result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLinkRecord(FQ_SHARE_SCENE_VIDEO,
        PlayerNavParams.contentId, PlayerNavParams.kind, PlayerNavParams.title,
        PlayerNavParams.cover));
      result.coverUrl = PlayerNavParams.cover;
      return result;
    }
    if (top === ROUTE_LISTEN_VIDEO) {
      result.records = FqShareKit.recordsOrEmpty(FqShareKit.buildLinkRecord(
        FQ_SHARE_SCENE_LISTEN_VIDEO, ListenVideoNavParams.contentId, ListenVideoNavParams.kind,
        ListenVideoNavParams.title, ListenVideoNavParams.cover));
      result.coverUrl = ListenVideoNavParams.cover;
      return result;
    }
    // 书架 Tab（主 Tab 无压栈页）：多选模式分享所选，普通态分享整架书单
    if (names.length === 0 && appState.currTabsIndex === 1) {
      result.records = FqShareKit.buildShelfRecordsForGesture();
      return result;
    }
    return result;
  }

  /** 书架 Tab 手势/碰一碰分享记录集：多选模式分享所选（未选返回空），普通态整架。 */
  private static buildShelfRecordsForGesture(): systemShare.SharedRecord[] {
    if (appState.isBatchMode) {
      const selected: FqShelfItem[] = [];
      for (const entry of FqShelfStore.all()) {
        if (appState.batchSelectedIds.indexOf(entry.id) !== -1) {
          selected.push(new FqShelfItem(entry.id, entry.kind, entry.title, entry.cover));
        }
      }
      if (selected.length > 0) {
        return FqShareKit.buildShelfRecords(selected, '书单分享');
      }
      return [];
    }
    return FqShareKit.buildShelfRecords(FqShelfStore.all(), '书架');
  }

  /** 单记录转记录集（null 转空数组）。 */
  private static recordsOrEmpty(record: systemShare.SharedRecord | null): systemShare.SharedRecord[] {
    return record !== null ? [record] : [];
  }

  /** 构建分享链接：fqhouse://open?d=<encodeURIComponent(JSON)>。 */
  private static buildUri(payload: Record<string, Object>): string {
    return `${FQ_SHARE_SCHEME}://${FQ_SHARE_HOST}?d=${encodeURIComponent(JSON.stringify(payload))}`;
  }

  /** 拉起系统分享面板（通用单记录）。 */
  private static showRecord(record: systemShare.SharedRecord): boolean {
    return FqShareKit.showRecords([record]);
  }

  /** 拉起系统分享面板（多记录：首记录为面板主记录，其余 addRecord 追加）。 */
  private static showRecords(records: systemShare.SharedRecord[]): boolean {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null || records.length === 0) {
      return false;
    }
    try {
      const data: systemShare.SharedData = new systemShare.SharedData(records[0]);
      for (let i: number = 1; i < records.length; i++) {
        data.addRecord(records[i]);
      }
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
      if (id.startsWith(FQ_SHUQI_ID_PREFIX)) {
        // 书旗来源：目标端后端按 raw id 拉目录 + 只读阅读器
        FqShareKit.openShuqiReader(id.substring(FQ_SHUQI_ID_PREFIX.length), title, cover)
          .catch((error: BusinessError): void => {
            hilog.error(DOMAIN, 'FqShare', 'shuqi read apply failed: %{public}s',
              `${error.code} ${error.message}`);
          });
        return;
      }
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
    if (scene === FQ_SHARE_SCENE_COMIC) {
      ComicNavParams.id = id;
      ComicNavParams.chapterIndex = -1;
      ComicNavParams.title = title;
      ComicNavParams.cover = cover;
      NavPathUtils.push(ROUTE_COMIC);
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

  /**
   * 书旗阅读直达（分享目标端 / 流转恢复复用）：拉目录 + 只读阅读器，
   * 对齐 DetailPage.openShuqiReader 链路（chapterIndex -1 按本机进度续读）。
   */
  public static async openShuqiReader(rawId: string, title: string, cover: string): Promise<void> {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null || rawId.length === 0) {
      return;
    }
    await FqBackend.get().start(context);
    const toc: FqShuqiToc = await FqBackend.get().shuqiToc(rawId);
    const chapters: FqChapter[] = toc.toReaderChapters();
    if (chapters.length === 0) {
      hilog.warn(DOMAIN, 'FqShare', '%{public}s', 'shuqi toc empty, skip');
      return;
    }
    ReaderNavParams.id = `${FQ_SHUQI_ID_PREFIX}${rawId}`;
    ReaderNavParams.kind = 'book';
    ReaderNavParams.title = title;
    ReaderNavParams.cover = cover;
    ReaderNavParams.chapterIndex = -1;
    ReaderNavParams.listenAlong = false;
    ReaderNavParams.readOnly = true;
    ReaderNavParams.presetChapters = chapters;
    ReaderNavParams.chapterLoader = (chapter: FqChapter): Promise<string> => {
      return FqBackend.get().shuqiChapterText(rawId, chapter.itemId);
    };
    NavPathUtils.push(ROUTE_READER2);
  }

  /** 分享文件接收：本地书文件导入书架 + 直达阅读页（同内容幂等复用同一本书）。 */
  private static async applyLocalBookFile(uri: string): Promise<void> {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return;
    }
    FqLocalBookStore.init(context);
    const item: FqShelfItem = await FqLocalBookStore.importFromUri(context, uri);
    const added: boolean = FqShelfStore.addIfAbsent(item);
    FqShareKit.toast(added ? `已导入《${item.title}》` : `《${item.title}》已在书架`);
    ReaderNavParams.id = item.id;
    ReaderNavParams.kind = 'book';
    ReaderNavParams.title = item.title;
    ReaderNavParams.cover = '';
    ReaderNavParams.chapterIndex = -1;
    ReaderNavParams.listenAlong = false;
    ReaderNavParams.readOnly = false;
    ReaderNavParams.presetChapters = [];
    ReaderNavParams.chapterLoader = null;
    NavPathUtils.push(ROUTE_READER2);
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

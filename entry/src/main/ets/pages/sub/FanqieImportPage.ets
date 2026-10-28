/**
 * 导入番茄书架页（备份与恢复-其他来源，对齐 fqapp FanqieHistoryImportPage 流程）：
 * - 从番茄账号读取：应用内 Web 打开官方登录页（域名白名单拦截主框架跳转），
 *   登录成功（Cookie 含会话标识）自动关闭并采集书架/文件夹/进度/历史；
 * - 从历史文件导入：系统文件选择器选 fqapp 采集 JSON 或官方 read_history 单页响应；
 * - 采集/解析结果就地预览（统计 + 前 6 本），确认后合并到本机（只补缺失，可重复导入）；
 * - busy 期间禁用操作，采集/解析可取消（已采集数据保留）；标题栏菜单可退出网页登录。
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarMenuOptions } from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import {
  FqFanqieBook,
  FqFanqieCapture,
  FqFanqieCaptureStore,
  FqFanqieCollector,
  FqFanqieImportPreview,
  FqFanqieImportService,
  FqFanqieMergeResult,
} from '../../core/FqFanqieImport';
import { fqExportTextFile } from '../../core/FqCacheExport';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_FANQIE_IMPORT_TOP_INSET: number = 56;
/** 滚动内容末尾偏移。 */
const FQ_FANQIE_IMPORT_BOTTOM_INSET: number = 40;
/** 行内分割线左右避让（与备份页行一致）。 */
const FQ_FANQIE_IMPORT_ROW_DIVIDER_INSET: number = 60;
/** 官方网页登录地址。 */
const FQ_FANQIE_LOGIN_URL: string = 'https://fanqienovel.com/main/writer/login';
/** 导入文件大小上限（与采集文档一致）。 */
const FQ_FANQIE_IMPORT_MAX_BYTES: number = 16 * 1024 * 1024;
/** 采集文件导出目录（展示文案）。 */
const FQ_FANQIE_EXPORT_DIR_TEXT: string = 'Download/FQHouseOH';
/** 登录页主框架跳转域名白名单（后缀匹配）。 */
const FQ_FANQIE_LOGIN_DOMAINS: string[] =
  ['fanqienovel.com', 'snssdk.com', 'bytedance.com', 'zijieapi.com'];

/** 两位补零。 */
function fqFanqieImportPad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 毫秒时间戳 → 'yyyy-MM-dd HH:mm'。 */
function fqFanqieImportDateTime(ms: number): string {
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${fqFanqieImportPad(date.getMonth() + 1)}-${fqFanqieImportPad(date.getDate())}` +
    ` ${fqFanqieImportPad(date.getHours())}:${fqFanqieImportPad(date.getMinutes())}`;
}

/** ISO 时间 → 'yyyy-MM-dd HH:mm'（无效返回空串）。 */
function fqFanqieImportFormatIso(iso: string): string {
  if (iso.length === 0) {
    return '';
  }
  const ms: number = new Date(iso).getTime();
  if (Number.isNaN(ms)) {
    return '';
  }
  return fqFanqieImportDateTime(ms);
}

/** 采集文档创建时间（ISO 原文）。 */
function fqFanqieImportCreatedAt(capture: FqFanqieCapture): string {
  const value: Object | undefined = capture.document['createdAt'];
  return typeof value === 'string' ? value : '';
}

/** 导出文件名时间戳（yyyyMMdd_HHmmss，与备份页一致）。 */
function fqFanqieImportFileStamp(now: Date): string {
  return `${now.getFullYear()}${fqFanqieImportPad(now.getMonth() + 1)}${fqFanqieImportPad(now.getDate())}` +
    `_${fqFanqieImportPad(now.getHours())}${fqFanqieImportPad(now.getMinutes())}${fqFanqieImportPad(now.getSeconds())}`;
}

@Builder
function fqFanqieImportEmptyContent() {
}

/** 卡片壳（与备份页 FqBackupCard 同体系）。 */
@ComponentV2
struct FqFanqieImportCard {
  @BuilderParam content: () => void = fqFanqieImportEmptyContent;

  build() {
    Column() {
      this.content()
    }
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({ width: 0.6, color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent })
    .width('100%')
  }
}

@ComponentV2
export struct FanqieImportPage {
  private scroller: Scroller = new Scroller();
  private webController: webview.WebviewController = new webview.WebviewController();
  /** 进行中的采集器（非空时取消键中断在途请求）。 */
  private collector: FqFanqieCollector | null = null;
  /** 最近一次采集（内存持有，「解析并导入」复用）。 */
  private lastCapture: FqFanqieCapture | null = null;
  /** 解析阶段取消标记。 */
  private cancelRequested: boolean = false;
  /** 非空 = 进行中（登录/采集/选择/解析），期间禁用全部操作。 */
  @Local busy: string = '';
  /** busy 可取消（采集/解析阶段显示取消键）。 */
  @Local cancellable: boolean = false;
  /** 就地结果/错误消息。 */
  @Local message: string = '';
  @Local messageIsError: boolean = false;
  /** 网页登录浮层显隐。 */
  @Local loginVisible: boolean = false;
  /** 解析通过的导入预览（待确认合并）。 */
  @Local preview: FqFanqieImportPreview | null = null;
  /** 最近一次采集摘要（时间/响应数/停止原因）。 */
  @Local captureInfo: string = '';
  /** 网页登录态（Cookie 含会话标识；标题栏图标区分）。 */
  @Local loggedIn: boolean = false;

  aboutToAppear(): void {
    this.loggedIn = this.readLoginCookie().length > 0;
    // 恢复本机留存的最近一次采集（filesDir 持久化，退出页面不丢失）
    const capture: FqFanqieCapture | null = FqFanqieCaptureStore.load(getContext(this));
    if (capture !== null) {
      this.lastCapture = capture;
      this.captureInfo = this.captureSummary(capture);
    }
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarMenuOptions(this.loginVisible ? '登录番茄账号' : '导入番茄书架',
        this.loggedIn ? $r('sys.symbol.person_text_rectangle_fill') : $r('sys.symbol.person_text_rectangle'),
        '退出网页登录', (): void => {
          this.confirmLogout();
        }, this.loginVisible ? '登录后自动开始采集' : undefined),
      scroller: this.scroller,
      backPressed: (): boolean => this.handleBack(),
    }) {
      Stack() {
        List({ space: 12, scroller: this.scroller }) {
          ListItem() {
            this.SectionHeader('导入来源')
          }
          ListItem() {
            FqFanqieImportCard() {
              this.ActionRow($r('sys.symbol.person_crop_circle_fill'), '#FF3B82F6', '从番茄账号读取',
                '网页登录番茄账号，采集书架与阅读进度', (): void => {
                  this.openLogin();
                })
              this.RowDivider()
              this.ActionRow($r('sys.symbol.doc_plaintext'), '#FF10B981', '从历史文件导入',
                '选择番茄书架采集 JSON 或官方历史响应文件', (): void => {
                  this.runFileImport();
                })
            }
          }

          if (this.captureInfo.length > 0) {
            ListItem() {
              this.SectionHeader('最近一次采集')
            }
            ListItem() {
              FqFanqieImportCard() {
                Column({ space: 12 }) {
                  Text(this.captureInfo)
                    .fontSize(13)
                    .lineHeight(20)
                    .fontColor($r('sys.color.font_secondary'))
                    .width('100%')
                  Button('解析并导入')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .backgroundColor(appState.accentColor)
                    .height(42)
                    .borderRadius(12)
                    .width('100%')
                    .enabled(this.busy.length === 0)
                    .onClick((): void => {
                      this.runPrepareFromLast();
                    })
                  Button('导出采集文件')
                    .fontSize(14)
                    .fontColor(appState.accentColor)
                    .backgroundColor(Color.Transparent)
                    .border({ width: 1, color: FqColorUtils.withOpacity(appState.accentColor, 0.5) })
                    .height(38)
                    .borderRadius(12)
                    .width('100%')
                    .margin({ top: 8 })
                    .enabled(this.busy.length === 0)
                    .onClick((): void => {
                      this.confirmExportCapture();
                    })
                }
                .padding(16)
                .width('100%')
              }
            }
          }

          if (this.preview !== null) {
            ListItem() {
              this.SectionHeader('导入预览')
            }
            ListItem() {
              FqFanqieImportCard() {
                this.PreviewContent(this.preview)
              }
            }
          }

          if (this.message.length > 0) {
            ListItem() {
              FqFanqieImportCard() {
                Text(this.message)
                  .fontSize(13)
                  .lineHeight(20)
                  .fontColor(this.messageIsError
                    ? '#FFF43F5E'
                    : $r('sys.color.font_secondary'))
                  .padding(16)
                  .width('100%')
              }
            }
          }

          if (this.busy.length > 0) {
            ListItem() {
              Row({ space: 10 }) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(appState.accentColor)
                Text(this.busy)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .layoutWeight(1)
                if (this.cancellable) {
                  Button('取消')
                    .fontSize(13)
                    .height(30)
                    .padding({ left: 14, right: 14 })
                    .fontColor(appState.accentColor)
                    .backgroundColor(Color.Transparent)
                    .borderRadius(15)
                    .onClick((): void => {
                      this.requestCancel();
                    })
                }
              }
              .width('100%')
            }
          }

          ListItem() {
            this.SectionHeader('说明')
          }
          ListItem() {
            FqFanqieImportCard() {
              Column({ space: 8 }) {
                Text('如何导入番茄书架？')
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%')
                Text('方式一：点「从番茄账号读取」，在打开的网页中登录番茄小说账号，' +
                  '登录成功后会自动采集书架、文件夹与阅读进度，并在完成后自动解析。\n\n' +
                  '方式二：选择 FQHouseOH 等工具导出的番茄书架采集 JSON，' +
                  '或官方 read_history 接口的完整单页响应文件，点「从历史文件导入」。\n\n' +
                  '导入采用合并方式：书架只补充本机缺少的书籍，阅读进度仅在本机没有记录时写入，' +
                  '可重复导入。采集与解析可随时取消，已采集的部分会保留。')
                  .fontSize(13)
                  .lineHeight(21)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
              }
              .padding(16)
              .width('100%')
            }
          }
        }
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentStartOffset(appState.topRect + FQ_FANQIE_IMPORT_TOP_INSET)
        .contentEndOffset(appState.bottomRect)
        .width('100%')
        .height('100%')

        if (this.loginVisible) {
          this.LoginOverlay()
        }
      }
      .width('100%')
      .height('100%')
    }
  }

  // ---------------------------------------------------------------------------
  // 流程
  // ---------------------------------------------------------------------------

  /** 打开应用内网页登录浮层。 */
  private openLogin(): void {
    if (this.busy.length > 0) {
      return;
    }
    this.message = '';
    this.loginVisible = true;
  }

  /** 关闭登录浮层（未开始采集时允许）。 */
  private closeLogin(): void {
    if (this.busy.length > 0) {
      return;
    }
    this.loginVisible = false;
  }

  /** 登录页加载完成：检测到会话 Cookie 即关闭浮层并开始采集。 */
  private onLoginPageEnd(): void {
    if (this.busy.length > 0) {
      return;
    }
    const cookie: string = this.readLoginCookie();
    if (cookie.length === 0) {
      return;
    }
    this.loggedIn = true;
    this.loginVisible = false;
    this.runCollect(cookie);
  }

  /** 采集：白名单只读接口分页拉取 → 本机留存摘要 → 自动解析预览。 */
  private async runCollect(cookie: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    const collector: FqFanqieCollector = new FqFanqieCollector(cookie);
    this.collector = collector;
    this.cancelRequested = false;
    this.cancellable = true;
    this.busy = '正在连接番茄账号…';
    this.message = '';
    this.messageIsError = false;
    this.preview = null;
    try {
      const capture: FqFanqieCapture =
        await collector.collect((msg: string): void => {
          this.busy = msg;
        });
      this.collector = null;
      this.lastCapture = capture;
      let saveNote: string = '';
      try {
        FqFanqieCaptureStore.save(getContext(this), capture);
      } catch (error) {
        saveNote = '采集结果超过 16 MB，未能在本机留存';
      }
      let info: string = this.captureSummary(capture);
      if (saveNote.length > 0) {
        info += `\n${saveNote}`;
      }
      this.captureInfo = info;
      await this.runPrepare(capture, '网页采集');
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '采集失败，请重试';
    } finally {
      this.collector = null;
      this.cancellable = false;
      this.busy = '';
    }
  }

  /** 文件导入：系统选择器 → 读取 → 格式识别 → 解析预览。 */
  private async runFileImport(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = '请选择导入文件…';
    this.message = '';
    this.messageIsError = false;
    this.preview = null;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['json'],
      });
      if (uris.length === 0) {
        this.message = '已取消选择';
        return;
      }
      this.busy = '正在读取文件…';
      const text: string = this.readImportFile(uris[0]);
      const capture: FqFanqieCapture = FqFanqieImportService.parseFileText(text);
      this.lastCapture = capture;
      await this.runPrepare(capture, '采集文件');
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '读取文件失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 解析最近一次采集（「解析并导入」入口）。 */
  private async runPrepareFromLast(): Promise<void> {
    const capture: FqFanqieCapture | null = this.lastCapture;
    if (capture === null || this.busy.length > 0) {
      return;
    }
    await this.runPrepare(capture, '最近一次采集');
  }

  /** 解析 + 章节定位 → 预览（可取消）。 */
  private async runPrepare(capture: FqFanqieCapture, label: string): Promise<void> {
    this.cancelRequested = false;
    this.cancellable = true;
    this.busy = '正在解析采集结果…';
    this.message = '';
    this.messageIsError = false;
    this.preview = null;
    try {
      const service: FqFanqieImportService = new FqFanqieImportService();
      this.preview = await service.prepare(capture, label,
        (msg: string): void => {
          this.busy = msg;
        },
        (): boolean => this.cancelRequested);
    } catch (error) {
      const err = error as BusinessError;
      if (err.message === '读取已取消') {
        this.messageIsError = false;
        this.message = '已取消解析，采集结果已保留，可稍后点「解析并导入」继续。';
      } else {
        this.messageIsError = true;
        this.message = err.message.length > 0 ? err.message : '解析失败，请重试';
      }
    } finally {
      this.cancellable = false;
      this.busy = '';
    }
  }

  /** 合并到本机（只补缺失），结果统计就地提示。 */
  private runMerge(): void {
    const preview: FqFanqieImportPreview | null = this.preview;
    if (preview === null || this.busy.length > 0) {
      return;
    }
    const service: FqFanqieImportService = new FqFanqieImportService();
    const result: FqFanqieMergeResult = service.merge(preview);
    this.preview = null;
    this.messageIsError = false;
    this.message = `导入完成：新增书架 ${result.shelfAdded} 本、补全封面 ${result.coverFilled} 本、` +
      `写入阅读进度 ${result.progressAdded} 本。\n本机已有记录保持不变，可重复导入。`;
  }

  /** 导出前弹窗确认（DialogManager 公共确认弹窗）。 */
  private confirmExportCapture(): void {
    if (this.busy.length > 0 || this.lastCapture === null) {
      return;
    }
    DialogManager.ShowConfirm('导出采集文件',
      `采集结果将导出为 JSON 文件（不含登录凭证），保存到 ${FQ_FANQIE_EXPORT_DIR_TEXT} 目录；` +
        '传到其他设备后，可在本页通过「从历史文件导入」解析合并。',
      '导出', (): void => {
        this.runExportCapture();
      });
  }

  /** 导出最近一次采集 JSON 到下载目录（对齐 fqapp「导出原始数据」）。 */
  private async runExportCapture(): Promise<void> {
    const capture: FqFanqieCapture | null = this.lastCapture;
    if (capture === null || this.busy.length > 0) {
      return;
    }
    this.busy = '正在导出采集文件…';
    try {
      const name: string = `fanqie-library-${fqFanqieImportFileStamp(new Date())}.json`;
      await fqExportTextFile(getContext(this), name, capture.encode());
      this.messageIsError = false;
      this.message = `采集文件已保存到 ${FQ_FANQIE_EXPORT_DIR_TEXT}/${name}`;
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '导出失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 采集摘要文案（时间/响应数/停止原因）。 */
  private captureSummary(capture: FqFanqieCapture): string {
    const stamp: string = fqFanqieImportFormatIso(fqFanqieImportCreatedAt(capture));
    let info: string = stamp.length > 0 ? `采集于 ${stamp}` : '已完成采集';
    info += `\n收到 ${capture.receivedCount()} 个有效响应`;
    if (capture.failedCount() > 0) {
      info += `，${capture.failedCount()} 个未成功`;
    }
    if (capture.stopReason().length > 0) {
      info += `\n${capture.stopReason()}`;
    }
    return info;
  }

  /** 取消：采集中断在途请求（已收数据保留），解析置取消标记。 */
  private requestCancel(): void {
    if (this.collector !== null) {
      this.collector.cancel();
      this.busy = '正在取消，保留已采集的数据…';
      return;
    }
    if (this.cancellable) {
      this.cancelRequested = true;
      this.busy = '正在取消解析…';
    }
  }

  /** 退出网页登录：清 Cookie（不影响已导入数据）。 */
  private confirmLogout(): void {
    if (this.busy.length > 0) {
      return;
    }
    DialogManager.ShowConfirm('退出网页登录',
      '将清除已保存的网页登录状态（Cookie），不影响已导入本机的数据。',
      '退出', (): void => {
        webview.WebCookieManager.clearAllCookiesSync();
        this.loggedIn = false;
        this.messageIsError = false;
        this.message = '已退出网页登录，下次导入需重新登录。';
      });
  }

  /** 返回拦截：登录浮层优先关闭；可取消的 busy 先取消。 */
  private handleBack(): boolean {
    if (this.loginVisible) {
      this.closeLogin();
      return true;
    }
    if (this.cancellable) {
      this.requestCancel();
      return true;
    }
    return false;
  }

  /** 读取登录 Cookie：含会话标识（sessionid/sessionid_ss/sid_tt）才视为已登录。 */
  private readLoginCookie(): string {
    const cookies: string = webview.WebCookieManager.fetchCookieSync('https://fanqienovel.com/');
    if (cookies.length === 0) {
      return '';
    }
    const parts: string[] = cookies.split(';');
    for (const part of parts) {
      const entry: string = part.trim();
      const eq: number = entry.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = entry.substring(0, eq);
      if (key === 'sessionid' || key === 'sessionid_ss' || key === 'sid_tt') {
        return cookies;
      }
    }
    return '';
  }

  /** 主框架跳转白名单：仅放行官方/字节系域名（子资源不拦截）。 */
  private allowNavUrl(url: string): boolean {
    const match: RegExpExecArray | null = /^https?:\/\/([^/?#]+)/.exec(url);
    if (match === null) {
      return true;
    }
    const host: string = match[1].toLowerCase();
    for (const domain of FQ_FANQIE_LOGIN_DOMAINS) {
      if (host === domain || host.endsWith(`.${domain}`)) {
        return true;
      }
    }
    return false;
  }

  /** 读取导入文件（≤16MB），UTF-8 解码为文本。 */
  private readImportFile(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > FQ_FANQIE_IMPORT_MAX_BYTES) {
        throw new Error('导入文件超过 16 MB 或不可读');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
      return decoder.decodeWithStream(new Uint8Array(buffer), { stream: false });
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        // 关闭失败忽略
      }
    }
  }

  /** 预览前 6 本（最近阅读优先）。 */
  private topRecords(): FqFanqieBook[] {
    const preview: FqFanqieImportPreview | null = this.preview;
    return preview === null ? [] : preview.records.slice(0, 6);
  }

  /** 预览行副标题：作者 · 阅读位置。 */
  private bookSubtitle(book: FqFanqieBook): string {
    const parts: string[] = [];
    if (book.author.length > 0) {
      parts.push(book.author);
    }
    if (book.epText.length > 0) {
      parts.push(book.epText);
    } else if (book.chapterId.length > 0) {
      parts.push('进度未定位');
    }
    return parts.join(' · ');
  }

  // ---------------------------------------------------------------------------
  // 视图
  // ---------------------------------------------------------------------------

  /** 应用内网页登录浮层（Web 官方登录页，双指捏合可缩放，标题/副标题由 UI 标题栏展示）。 */
  @Builder
  private LoginOverlay() {
    Web({ src: FQ_FANQIE_LOGIN_URL, controller: this.webController })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .mixedMode(MixedMode.None)
      .zoomAccess(true)
      .forceEnableZoom(true)
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
        const request: WebResourceRequest = event.data;
        if (!request.isMainFrame()) {
          return false;
        }
        return !this.allowNavUrl(request.getRequestUrl());
      })
      .onPageEnd((): void => {
        this.onLoginPageEnd();
      })
      .width('100%')
      .height('100%')
  }

  @Builder
  private SectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(3.5)
        .height(15)
        .borderRadius(2)
        .backgroundColor(appState.accentColor)
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
    }
    .width('100%')
  }

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: FQ_FANQIE_IMPORT_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 操作行（彩色图标块 + 标题/副标题 + 箭头；busy 期间禁用）。 */
  @Builder
  private ActionRow(icon: Resource, tint: string, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([tint])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity(tint, 0.12))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .enabled(this.busy.length === 0)
    .onClick(onTap)
  }

  /** 导入预览卡内容：来源 + 统计 + 前 6 本 + 说明 + 合并按钮。 */
  @Builder
  private PreviewContent(preview: FqFanqieImportPreview) {
    Column({ space: 14 }) {
      Text(`来源：${preview.sourceLabel}`)
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        this.StatCell(`${preview.records.length}`, '小说')
        this.StatCell(`${preview.matched}`, '进度已定位')
        this.StatCell(`${preview.unresolved}`, '进度未定位')
        this.StatCell(`${preview.skipped}`, '已跳过')
      }
      .width('100%')

      if (this.topRecords().length > 0) {
        Column() {
          ForEach(this.topRecords(), (book: FqFanqieBook) => {
            this.BookRow(book)
          }, (book: FqFanqieBook) => book.id)
        }
        .width('100%')
      }

      Text('合并只补充本机缺少的书籍；阅读进度仅在本机没有记录时写入，' +
        '进度未定位的书从第 1 章开始阅读。')
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')

      Button('合并到本机书架')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(appState.accentColor)
        .height(42)
        .borderRadius(12)
        .width('100%')
        .enabled(this.busy.length === 0)
        .onClick((): void => {
          this.runMerge();
        })
    }
    .padding(16)
    .width('100%')
  }

  /** 预览统计单元（数值 + 标签）。 */
  @Builder
  private StatCell(countText: string, label: string) {
    Column({ space: 3 }) {
      Text(countText)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(label)
        .fontSize(11.5)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('25%')
    .padding({ top: 4, bottom: 4 })
  }

  /** 预览书籍行（书名 + 作者 · 阅读位置）。 */
  @Builder
  private BookRow(book: FqFanqieBook) {
    Row({ space: 10 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(15)
          .fontColor(['#FF3B82F6'])
      }
      .width(30)
      .height(30)
      .borderRadius(8)
      .backgroundColor(FqColorUtils.withOpacity('#FF3B82F6', 0.1))

      Column({ space: 3 }) {
        Text(book.title.length > 0 ? book.title : '未知作品')
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.bookSubtitle(book))
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .padding({ top: 7, bottom: 7 })
    .width('100%')
  }
}

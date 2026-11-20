/**
 * 导入红果云端收藏页（备份与恢复-其他来源）：
 * - 登录：扫码（轮询确认）；手机验证码登录暂被红果滑块风控拦截，UI 已注释
 *   （协议实现保留，见 LoginContent，待指纹对齐后恢复）；
 * - 读取：POST /api/v1/account/hongguo/favorites（本地签名请求云端收藏，归一化返回）；
 * - 持久化：登录 cookie 与最近一次收藏预览存 filesDir（FqHongguoSessionStore），
 *   重进页面不丢登录态与预览；
 * - 结果就地预览（统计 + 前 6 部），确认后合并到本机书架（只补缺失，可重复导入）；
 * - busy 期间禁用操作，读取可取消；标题栏菜单可退出登录（清除本机登录态，不影响已导入数据）。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarMenuOptions } from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqShelfStore } from '../../core/FqShelfStore';
import {
  FqHongguoFavorite,
  FqHongguoImportService,
  FqHongguoMergeResult,
  FqHongguoSavedSession,
  FqHongguoSessionStore,
} from '../../core/FqHongguoImport';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_HONGGUO_IMPORT_TOP_INSET: number = 56;
/** 扫码状态轮询间隔（ms，hongguoTV 同款节奏）。 */
const FQ_HONGGUO_LOGIN_POLL_MS: number = 2000;
/** 二维码展示尺寸。 */
const FQ_HONGGUO_QR_SIZE: number = 200;

/** 两位补零。 */
function fqHongguoImportPad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 毫秒时间戳 → 'yyyy-MM-dd'。 */
function fqHongguoImportDate(ms: number): string {
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${fqHongguoImportPad(date.getMonth() + 1)}-${fqHongguoImportPad(date.getDate())}`;
}

@Builder
function fqHongguoImportEmptyContent() {
}

/** 卡片壳（与备份页 FqBackupCard 同体系）。 */
@ComponentV2
struct FqHongguoImportCard {
  @BuilderParam content: () => void = fqHongguoImportEmptyContent;

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
export struct HongguoImportPage {
  private scroller: Scroller = new Scroller();
  private readonly service: FqHongguoImportService = new FqHongguoImportService();
  /** 扫码轮询定时器（-1 = 未启动）。 */
  private qrPollTimer: number = -1;
  /** 二维码过期倒计时定时器（-1 = 未启动）。 */
  private qrCountdownTimer: number = -1;
  /** 短信重发倒计时定时器（-1 = 未启动）。 */
  private smsCountdownTimer: number = -1;
  /** 登录 cookie（内存持有，filesDir 持久化）。 */
  private cookie: string = '';
  /** 非空 = 进行中（登录/读取），期间禁用全部操作。 */
  @Local busy: string = '';
  /** busy 可取消（读取阶段显示取消键）。 */
  @Local cancellable: boolean = false;
  /** 就地结果/错误消息。 */
  @Local message: string = '';
  @Local messageIsError: boolean = false;
  /** 登录面板显隐。 */
  @Local loginVisible: boolean = false;
  /** 登录方式：'qr' 扫码 | 'sms' 验证码。 */
  @Local loginMode: string = 'qr';
  /** 红果账号登录态（标题栏图标区分）。 */
  @Local loggedIn: boolean = false;
  /** 扫码登录：二维码 data URL（空 = 未获取）。 */
  @Local qrImage: string = '';
  /** 二维码剩余有效秒数。 */
  @Local qrExpiresIn: number = 0;
  /** 二维码已失效（过期/轮询出错，展示刷新按钮）。 */
  @Local qrExpired: boolean = false;
  /** 验证码登录：手机号输入。 */
  @Local mobileInput: string = '';
  /** 验证码登录：验证码输入。 */
  @Local codeInput: string = '';
  /** 验证码已发送（平台回显的打码号码）。 */
  @Local smsSent: boolean = false;
  @Local smsMaskedMobile: string = '';
  /** 短信重发倒计时（秒，0 = 可重发）。 */
  @Local smsCountdown: number = 0;
  /** 读取成功的云端收藏（待确认合并）。 */
  @Local favorites: FqHongguoFavorite[] | null = null;

  aboutToAppear(): void {
    // 恢复本机留存的登录态与最近一次收藏预览（filesDir 持久化，退出页面不丢失）
    const saved: FqHongguoSavedSession | null = FqHongguoSessionStore.load(getContext(this));
    if (saved !== null) {
      this.cookie = saved.cookie;
      this.loggedIn = true;
      if (saved.favorites.length > 0) {
        this.favorites = saved.favorites;
      }
    }
  }

  aboutToDisappear(): void {
    this.stopQrTimers();
    this.stopSmsCountdown();
    this.service.cancel();
  }

  /** 标题栏常驻「退出登录」菜单（与导入番茄书架页同款图标/形式，登录态区分填充）。 */
  private titleBarOp(): TitleBarContentOptions {
    const logoutIcon: Resource = this.loggedIn
      ? $r('sys.symbol.person_text_rectangle_fill')
      : $r('sys.symbol.person_text_rectangle');
    return FqTitleBarMenuOptions('导入红果收藏', logoutIcon, '退出红果登录', (): void => {
      this.confirmLogout();
    });
  }

  build() {
    CommonNav({
      titleBarOp: this.titleBarOp(),
      scroller: this.scroller,
      backPressed: (): boolean => this.handleBack(),
    }) {
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
          this.SectionHeader('导入来源')
        }
        ListItem() {
          FqHongguoImportCard() {
            Column() {
              this.ActionRow($r('sys.symbol.person_crop_circle_fill'), '#FF3B82F6', '从红果账号读取',
                this.loggedIn ? '已登录红果账号，点此重新读取云端收藏'
                  : '扫码登录红果账号，读取云端收藏的短剧与漫剧', (): void => {
                  if (this.loggedIn) {
                    this.runFetch(this.cookie);
                  } else {
                    this.openLogin();
                  }
                })
              if (this.loginVisible) {
                this.CardDivider()
                this.LoginContent()
              }
            }
            .width('100%')
          }
        }

        if (this.favorites !== null) {
          ListItem() {
            this.SectionHeader('导入预览')
          }
          ListItem() {
            FqHongguoImportCard() {
              this.PreviewContent()
            }
          }
        }

        if (this.message.length > 0) {
          ListItem() {
            FqHongguoImportCard() {
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
          FqHongguoImportCard() {
            Column({ space: 8 }) {
              Text('如何导入红果云端收藏？')
                .fontSize(14.5)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
              Text('点「从红果账号读取」，扫码登录红果账号，' +
                '登录成功后会自动读取云端收藏的短剧与漫剧。\n\n' +
                '导入采用合并方式：书架只补充本机缺少的内容，不改动本机已有的观看记录，' +
                '可重复导入。云端接口为只读，不会修改红果账号里的数据。')
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
      .contentStartOffset(appState.topRect + FQ_HONGGUO_IMPORT_TOP_INSET)
      .contentEndOffset(appState.bottomRect)
      .width('100%')
      .height('100%')
    }
  }

  // ---------------------------------------------------------------------------
  // 流程
  // ---------------------------------------------------------------------------

  /** 打开登录面板（默认扫码，进入即取二维码）。 */
  private openLogin(): void {
    if (this.busy.length > 0) {
      return;
    }
    this.message = '';
    this.messageIsError = false;
    this.loginVisible = true;
    if (this.loginMode === 'qr') {
      this.startQrLogin();
    }
  }

  /** 收起登录面板（不影响已发送的短信倒计时状态）。 */
  private closeLogin(): void {
    if (this.busy.length > 0) {
      return;
    }
    this.stopQrTimers();
    this.loginVisible = false;
  }

  /** 切换登录方式：离开扫码停轮询，切回扫码重新取码。 */
  private switchMode(mode: string): void {
    if (this.busy.length > 0 || mode === this.loginMode) {
      return;
    }
    this.loginMode = mode;
    this.message = '';
    this.messageIsError = false;
    if (mode === 'qr') {
      this.stopQrTimers();
      this.qrImage = '';
      this.qrExpired = false;
      this.startQrLogin();
    } else {
      this.stopQrTimers();
    }
  }

  /** 获取登录二维码并启动轮询 + 过期倒计时。 */
  private async startQrLogin(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.stopQrTimers();
    this.busy = '正在获取二维码…';
    this.message = '';
    this.messageIsError = false;
    this.qrExpired = false;
    try {
      const qr = await this.service.requestQr();
      this.qrImage = qr.image;
      this.qrExpiresIn = qr.expiresIn;
      this.qrCountdownTimer = setInterval((): void => {
        this.qrExpiresIn--;
        if (this.qrExpiresIn <= 0) {
          this.stopQrTimers();
          this.qrExpired = true;
        }
      }, 1000);
      this.qrPollTimer = setInterval((): void => {
        this.pollQrOnce();
      }, FQ_HONGGUO_LOGIN_POLL_MS);
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '获取二维码失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 轮询扫码状态：确认后自动登录并读取收藏。 */
  private async pollQrOnce(): Promise<void> {
    if (this.busy.length > 0 || this.qrExpired || !this.loginVisible) {
      return;
    }
    try {
      const cookie: string = await this.service.pollQr();
      if (cookie.length === 0) {
        return;
      }
      this.stopQrTimers();
      this.cookie = cookie;
      this.loggedIn = true;
      this.loginVisible = false;
      this.persistSession();
      this.runFetch(cookie);
    } catch (error) {
      const err = error as BusinessError;
      this.stopQrTimers();
      this.qrExpired = true;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '扫码登录失败，请刷新二维码重试';
    }
  }

  private stopQrTimers(): void {
    if (this.qrPollTimer >= 0) {
      clearInterval(this.qrPollTimer);
      this.qrPollTimer = -1;
    }
    if (this.qrCountdownTimer >= 0) {
      clearInterval(this.qrCountdownTimer);
      this.qrCountdownTimer = -1;
    }
  }

  /** 发送短信验证码（后端校验手机号并回传打码号码与重发倒计时）。 */
  private async requestSms(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    const mobile: string = this.mobileInput.trim();
    if (mobile.length === 0) {
      this.messageIsError = true;
      this.message = '请输入手机号';
      return;
    }
    this.busy = '正在发送验证码…';
    this.message = '';
    this.messageIsError = false;
    try {
      const sent = await this.service.sendSms(mobile);
      this.smsSent = true;
      this.smsMaskedMobile = sent.maskedMobile;
      this.smsCountdown = sent.retrySeconds;
      this.codeInput = '';
      this.startSmsCountdown();
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '发送验证码失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  private startSmsCountdown(): void {
    this.stopSmsCountdown();
    this.smsCountdownTimer = setInterval((): void => {
      this.smsCountdown--;
      if (this.smsCountdown <= 0) {
        this.stopSmsCountdown();
        this.smsCountdown = 0;
      }
    }, 1000);
  }

  private stopSmsCountdown(): void {
    if (this.smsCountdownTimer >= 0) {
      clearInterval(this.smsCountdownTimer);
      this.smsCountdownTimer = -1;
    }
  }

  /** 验证码登录：成功后关闭面板并读取收藏。 */
  private async loginWithSms(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    const code: string = this.codeInput.trim();
    if (!/^[0-9]{4,8}$/.test(code)) {
      this.messageIsError = true;
      this.message = '请输入 4—8 位数字验证码';
      return;
    }
    this.busy = '正在登录…';
    this.message = '';
    this.messageIsError = false;
    try {
      const cookie: string = await this.service.verifySms(code);
      this.stopSmsCountdown();
      this.cookie = cookie;
      this.loggedIn = true;
      this.loginVisible = false;
      this.persistSession();
      this.runFetch(cookie);
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '登录失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 读取云端收藏 → 预览。 */
  private async runFetch(cookie: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.cancellable = true;
    this.busy = '正在读取云端收藏…';
    this.message = '';
    this.messageIsError = false;
    this.favorites = null;
    try {
      const favorites: FqHongguoFavorite[] = await this.service.fetch(cookie);
      this.favorites = favorites;
      this.persistSession();
      if (favorites.length === 0) {
        this.message = '云端收藏为空，没有可导入的内容。';
      }
    } catch (error) {
      const err = error as BusinessError;
      if (err.message === '请求已取消') {
        this.message = '已取消读取，可重新点「从红果账号读取」再试。';
      } else {
        this.messageIsError = true;
        this.message = err.message.length > 0 ? err.message : '读取云端收藏失败，请重试';
      }
    } finally {
      this.cancellable = false;
      this.busy = '';
    }
  }

  /** 登录态/收藏预览落盘（filesDir，重进页面可恢复）。 */
  private persistSession(): void {
    const favorites: FqHongguoFavorite[] | null = this.favorites;
    FqHongguoSessionStore.save(getContext(this), this.cookie,
      favorites === null ? [] : favorites);
  }

  /** 合并到本机书架（只补缺失），结果统计就地提示。 */
  private runMerge(): void {
    const favorites: FqHongguoFavorite[] | null = this.favorites;
    if (favorites === null || favorites.length === 0 || this.busy.length > 0) {
      return;
    }
    const result: FqHongguoMergeResult = this.service.merge(favorites);
    this.favorites = null;
    this.messageIsError = false;
    this.message = `导入完成：新增收藏 ${result.added} 部、补全封面 ${result.coverFilled} 部。\n` +
      '本机已有记录保持不变，可重复导入。';
  }

  /** 取消读取（中断在途请求）。 */
  private requestCancel(): void {
    if (!this.cancellable) {
      return;
    }
    this.service.cancel();
    this.busy = '正在取消…';
  }

  /** 退出登录：清除本机登录态与收藏预览（不影响已导入数据）。 */
  private confirmLogout(): void {
    if (this.busy.length > 0) {
      return;
    }
    DialogManager.ShowConfirm('退出红果账号',
      '将清除本机保留的登录状态与收藏预览，不影响已导入本机的数据。',
      '退出', (): void => {
        this.stopQrTimers();
        this.stopSmsCountdown();
        this.service.cancel();
        FqHongguoSessionStore.clear(getContext(this));
        this.cookie = '';
        this.loggedIn = false;
        this.loginVisible = false;
        this.favorites = null;
        this.qrImage = '';
        this.qrExpired = false;
        this.mobileInput = '';
        this.codeInput = '';
        this.smsSent = false;
        this.smsMaskedMobile = '';
        this.smsCountdown = 0;
        this.messageIsError = false;
        this.message = '已退出红果账号，下次导入需重新登录。';
      });
  }

  /** 返回拦截：优先关登录面板；可取消的 busy 先取消。 */
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

  // ---------------------------------------------------------------------------
  // 视图
  // ---------------------------------------------------------------------------

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

  /** 卡片内分割线。 */
  @Builder
  private CardDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: 14, right: 14 })
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

  /** 登录面板：暂仅扫码（验证码登录被红果滑块风控拦截，UI 注释保留，修好后恢复）。 */
  @Builder
  private LoginContent() {
    Column({ space: 14 }) {
      // TODO 验证码登录恢复点：红果 send_code 命中 1105 滑块风控（换流量也复现，
      //  待传输层指纹（TLS/HTTP-2）与官方客户端对齐后去掉注释即可恢复。
      // Row({ space: 8 }) {
      //   this.ModePill('扫码登录', 'qr')
      //   this.ModePill('验证码登录', 'sms')
      // }
      // .justifyContent(FlexAlign.Center)
      // .width('100%')
      //
      // if (this.loginMode === 'qr') {
      //   this.QrLoginContent()
      // } else {
      //   this.SmsLoginContent()
      // }
      this.QrLoginContent()
    }
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .width('100%')
  }

  /** 登录方式切换胶囊。 */
  @Builder
  private ModePill(label: string, mode: string) {
    Text(label)
      .fontSize(13.5)
      .fontWeight(this.loginMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.loginMode === mode ? Color.White : $r('sys.color.font_secondary'))
      .backgroundColor(this.loginMode === mode
        ? appState.accentColor
        : $r('sys.color.comp_background_tertiary'))
      .height(32)
      .padding({ left: 18, right: 18 })
      .borderRadius(16)
      .enabled(this.busy.length === 0)
      .onClick((): void => {
        this.switchMode(mode);
      })
  }

  /** 扫码登录：二维码 + 提示 + 过期倒计时/刷新。 */
  @Builder
  private QrLoginContent() {
    Column({ space: 12 }) {
      if (this.qrImage.length > 0) {
        Image(this.qrImage)
          .width(FQ_HONGGUO_QR_SIZE)
          .height(FQ_HONGGUO_QR_SIZE)
          .backgroundColor(Color.White)
          .borderRadius(12)
          .draggable(false)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(64)
            .fontColor([$r('sys.color.font_tertiary')])
        }
        .width(FQ_HONGGUO_QR_SIZE)
        .height(FQ_HONGGUO_QR_SIZE)
        .borderRadius(12)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .justifyContent(FlexAlign.Center)
      }

      Text(this.qrExpired
        ? '二维码已失效，请刷新后重新扫码'
        : (this.qrExpiresIn > 0 ? `打开红果 App 扫码登录（${this.qrExpiresIn} 秒后过期）`
          : '打开红果 App 扫码登录'))
        .fontSize(12.5)
        .fontColor(this.qrExpired ? '#FFF43F5E' : $r('sys.color.font_secondary'))

      Button(this.qrExpired ? '刷新二维码' : '刷新')
        .fontSize(13.5)
        .height(34)
        .padding({ left: 20, right: 20 })
        .fontColor(appState.accentColor)
        .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))
        .borderRadius(17)
        .enabled(this.busy.length === 0 && this.qrImage.length > 0)
        .onClick((): void => {
          this.startQrLogin();
        })
    }
    .alignItems(HorizontalAlign.Center)
    .width('100%')
  }

  /** 验证码登录：手机号 + 验证码 + 登录按钮。 */
  @Builder
  private SmsLoginContent() {
    Column({ space: 12 }) {
      TextInput({ text: this.mobileInput, placeholder: '手机号（境外号码如 +886 0912…）' })
        .width('100%')
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .type(InputType.PhoneNumber)
        .maxLength(32)
        .enabled(this.busy.length === 0)
        .onChange((value: string): void => {
          this.mobileInput = value;
        })

      Row({ space: 10 }) {
        TextInput({ text: this.codeInput, placeholder: '验证码' })
          .layoutWeight(1)
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .placeholderColor($r('sys.color.font_tertiary'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .type(InputType.Number)
          .maxLength(8)
          .enabled(this.busy.length === 0)
          .onChange((value: string): void => {
            this.codeInput = value;
          })
        Button(this.smsCountdown > 0 ? `重新发送(${this.smsCountdown}s)` : '获取验证码')
          .fontSize(13)
          .height(40)
          .padding({ left: 14, right: 14 })
          .fontColor(appState.accentColor)
          .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))
          .borderRadius(12)
          .enabled(this.busy.length === 0 && this.smsCountdown === 0 && this.mobileInput.trim().length > 0)
          .onClick((): void => {
            this.requestSms();
          })
      }
      .width('100%')

      if (this.smsSent) {
        Text(`验证码已发送至 ${this.smsMaskedMobile}`)
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      Button('登录')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(appState.accentColor)
        .height(42)
        .borderRadius(12)
        .width('100%')
        .enabled(this.busy.length === 0 && this.smsSent && /^[0-9]{4,8}$/.test(this.codeInput.trim()))
        .onClick((): void => {
          this.loginWithSms();
        })
    }
    .width('100%')
  }

  /** 导入预览卡内容：统计 + 前 6 部 + 说明 + 合并按钮。 */
  @Builder
  private PreviewContent() {
    Column({ space: 14 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        this.StatCell(`${this.favorites === null ? 0 : this.favorites.length}`, '云端收藏')
        this.StatCell(`${this.favorites === null ? 0 : this.favorites.length - this.manjuCount()}`, '短剧')
        this.StatCell(`${this.manjuCount()}`, '漫剧')
        this.StatCell(`${this.onShelfCount()}`, '已在书架')
      }
      .width('100%')

      if (this.topFavorites().length > 0) {
        Column() {
          ForEach(this.topFavorites(), (favorite: FqHongguoFavorite) => {
            this.FavoriteRow(favorite)
          }, (favorite: FqHongguoFavorite) => favorite.id)
        }
        .width('100%')
      }

      Text('合并只补充本机书架缺少的内容，不改动本机已有的观看记录。')
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

  /** 预览收藏行（剧名 + 标签 · 集数 · 收藏日期）。 */
  @Builder
  private FavoriteRow(favorite: FqHongguoFavorite) {
    Row({ space: 10 }) {
      Stack() {
        SymbolGlyph(this.favoriteKindOf(favorite) === 'manju'
          ? $r('sys.symbol.book_pages') : $r('sys.symbol.film'))
          .fontSize(15)
          .fontColor(['#FFF97316'])
      }
      .width(30)
      .height(30)
      .borderRadius(8)
      .backgroundColor(FqColorUtils.withOpacity('#FFF97316', 0.1))

      Column({ space: 3 }) {
        Text(favorite.title.length > 0 ? favorite.title : '未知作品')
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.favoriteSubtitle(favorite))
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

  // ---------------------------------------------------------------------------
  // 预览辅助
  // ---------------------------------------------------------------------------

  /** 合并 kind 启发式：标签含「漫剧/漫画」归为漫剧，其余为短剧。 */
  private favoriteKindOf(favorite: FqHongguoFavorite): string {
    return /漫剧|漫画/.test(favorite.tags) ? 'manju' : 'video';
  }

  private manjuCount(): number {
    const list: FqHongguoFavorite[] | null = this.favorites;
    if (list === null) {
      return 0;
    }
    let count: number = 0;
    for (const favorite of list) {
      if (this.favoriteKindOf(favorite) === 'manju') {
        count++;
      }
    }
    return count;
  }

  private onShelfCount(): number {
    const list: FqHongguoFavorite[] | null = this.favorites;
    if (list === null) {
      return 0;
    }
    const ids: Set<string> = new Set<string>();
    for (const item of FqShelfStore.all()) {
      ids.add(item.id);
    }
    let count: number = 0;
    for (const favorite of list) {
      if (ids.has(favorite.id)) {
        count++;
      }
    }
    return count;
  }

  /** 预览前 6 部。 */
  private topFavorites(): FqHongguoFavorite[] {
    const list: FqHongguoFavorite[] | null = this.favorites;
    return list === null ? [] : list.slice(0, 6);
  }

  /** 预览行副标题：标签 · 集数 · 收藏日期。 */
  private favoriteSubtitle(favorite: FqHongguoFavorite): string {
    const parts: string[] = [];
    if (favorite.tags.length > 0) {
      parts.push(favorite.tags);
    }
    if (favorite.episodes > 0) {
      parts.push(`全 ${favorite.episodes} 集`);
    }
    if (favorite.collectedAt > 0) {
      parts.push(`收藏于 ${fqHongguoImportDate(favorite.collectedAt)}`);
    }
    return parts.join(' · ');
  }
}

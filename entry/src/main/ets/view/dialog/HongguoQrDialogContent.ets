/**
 * 「红果扫码登录」弹窗内容（导入红果收藏页 → DialogManager.ShowHongguoQrLogin 打开，
 * 由宿主页 Index 的 CustomContentDialog 装配）：
 * 自包含扫码登录流程：进入取码 + 过期倒计时 + 2 秒轮询，底部「刷新二维码」按钮；
 * 轮询确认经 DialogManager.ConfirmHongguoQrLogin 回调打开页（回传 cookie）并关弹窗；
 * 关闭/点外部取消：停止轮询并中断在途请求（aboutToDisappear 清理）。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { FqHongguoImportService, FqHongguoQr } from '../../core/FqHongguoImport';

/** 扫码状态轮询间隔（ms，hongguoTV 同款节奏）。 */
const FQ_HONGGUO_LOGIN_POLL_MS: number = 2000;
/** 二维码展示尺寸。 */
const FQ_HONGGUO_QR_SIZE: number = 200;

@ComponentV2
export struct HongguoQrDialogContent {
  private readonly service: FqHongguoImportService = new FqHongguoImportService();
  /** 扫码轮询定时器（-1 = 未启动）。 */
  private pollTimer: number = -1;
  /** 二维码过期倒计时定时器（-1 = 未启动）。 */
  private countdownTimer: number = -1;
  /** 扫码已确认（回调页面的收藏读取随即发起，销毁时不再取消在途请求，避免误杀）。 */
  private confirmed: boolean = false;
  /** 正在获取二维码。 */
  @Local busy: boolean = false;
  /** 二维码 data URL（空 = 未获取）。 */
  @Local qrImage: string = '';
  /** 二维码剩余有效秒数。 */
  @Local qrExpiresIn: number = 0;
  /** 二维码失效/获取失败（展示失败态与刷新引导）。 */
  @Local qrExpired: boolean = false;
  /** 获取/轮询失败消息（空 = 无错误）。 */
  @Local failedMessage: string = '';

  aboutToAppear(): void {
    this.startQr();
  }

  aboutToDisappear(): void {
    this.stopTimers();
    if (!this.confirmed) {
      this.service.cancel();
    }
  }

  build() {
    Column({ space: 14 }) {
      if (this.qrImage.length > 0) {
        Image(this.qrImage)
          .width(FQ_HONGGUO_QR_SIZE)
          .height(FQ_HONGGUO_QR_SIZE)
          .backgroundColor(Color.White)
          .borderRadius(12)
          .draggable(false)
      } else {
        Column() {
          if (this.busy) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color(appState.accentColor)
          } else {
            SymbolGlyph($r('sys.symbol.person'))
              .fontSize(64)
              .fontColor([$r('sys.color.font_tertiary')])
          }
        }
        .width(FQ_HONGGUO_QR_SIZE)
        .height(FQ_HONGGUO_QR_SIZE)
        .borderRadius(12)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .justifyContent(FlexAlign.Center)
      }

      Text(this.statusText())
        .fontSize(12.5)
        .fontColor(this.qrExpired ? '#FFF43F5E' : $r('sys.color.font_secondary'))

      Text('请使用安卓或 iOS 端红果 App 扫码，鸿蒙端红果 App 暂不支持扫码登录')
        .fontSize(11.5)
        .fontColor($r('sys.color.font_tertiary'))

      Button('刷新二维码')
        .fontSize(14)
        .fontColor(appState.accentColor)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: FqColorUtils.withOpacity(appState.accentColor, 0.5) })
        .height(38)
        .borderRadius(12)
        .width('100%')
        .enabled(!this.busy)
        .onClick((): void => {
          this.startQr();
        })
    }
    .width('100%')
  }

  /** 状态文案：失败消息 > 失效引导 > 倒计时提示。 */
  private statusText(): string {
    if (this.failedMessage.length > 0) {
      return this.failedMessage;
    }
    if (this.qrExpired) {
      return '二维码已失效，请刷新后重新扫码';
    }
    return this.qrExpiresIn > 0
      ? `打开红果 App 扫码登录（${this.qrExpiresIn} 秒后过期）`
      : '打开红果 App 扫码登录';
  }

  /** 获取登录二维码并启动过期倒计时 + 轮询。 */
  private async startQr(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.stopTimers();
    this.busy = true;
    this.qrExpired = false;
    this.failedMessage = '';
    try {
      const qr: FqHongguoQr = await this.service.requestQr();
      this.qrImage = qr.image;
      this.qrExpiresIn = qr.expiresIn;
      this.countdownTimer = setInterval((): void => {
        this.qrExpiresIn--;
        if (this.qrExpiresIn <= 0) {
          this.stopTimers();
          this.qrExpired = true;
        }
      }, 1000);
      this.pollTimer = setInterval((): void => {
        this.pollQrOnce();
      }, FQ_HONGGUO_LOGIN_POLL_MS);
    } catch (error) {
      const err = error as BusinessError;
      this.qrExpired = true;
      this.failedMessage = err.message.length > 0 ? err.message : '获取二维码失败，请刷新重试';
    } finally {
      this.busy = false;
    }
  }

  /** 轮询扫码状态：确认后回传 cookie 并关弹窗。 */
  private async pollQrOnce(): Promise<void> {
    if (this.busy || this.qrExpired) {
      return;
    }
    try {
      const cookie: string = await this.service.pollQr();
      if (cookie.length === 0) {
        return;
      }
      this.stopTimers();
      this.confirmed = true;
      DialogManager.ConfirmHongguoQrLogin(cookie);
    } catch (error) {
      const err = error as BusinessError;
      this.stopTimers();
      this.qrExpired = true;
      this.failedMessage = err.message.length > 0 ? err.message : '扫码登录失败，请刷新二维码重试';
    }
  }

  private stopTimers(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
  }
}

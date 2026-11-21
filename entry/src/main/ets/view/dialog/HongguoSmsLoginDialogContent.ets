/**
 * 「红果验证码登录」弹窗内容（导入红果收藏页菜单「验证码登录」→
 * DialogManager.ShowHongguoSmsLogin 打开，由宿主页 Index 的 CustomContentDialog 装配）：
 * 单屏布局：区号 Select + 手机号输入、验证码输入 + 内联「发送验证码」（重发倒计时）、
 * 底部「确认登录」；成功经 DialogManager.ConfirmHongguoSmsLogin 回调打开页
 * （回传 cookie）并关弹窗；关闭/点外部取消：中断在途请求（aboutToDisappear 清理）。
 * 注意：后端走官方签名移动端点（security.snssdk.com），失败消息就地展示并引导改用扫码。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { FqHongguoImportService, FqHongguoSmsSent } from '../../core/FqHongguoImport';

/** 区号数字（与 FQ_HONGGUO_SMS_CC_OPTIONS 下标一一对应）。 */
const FQ_HONGGUO_SMS_CC_DIGITS: string[] = [
  '86', '852', '853', '886', '1', '44', '49', '33', '7', '61',
  '65', '60', '66', '81', '82', '84', '91', '63', '62',
];

/** 区号 Select 选项文案。 */
const FQ_HONGGUO_SMS_CC_OPTIONS: SelectOption[] = [
  { value: '+86' }, { value: '+852' }, { value: '+853' }, { value: '+886' },
  { value: '+1' }, { value: '+44' }, { value: '+49' }, { value: '+33' }, { value: '+7' },
  { value: '+61' }, { value: '+65' }, { value: '+60' }, { value: '+66' },
  { value: '+81' }, { value: '+82' }, { value: '+84' }, { value: '+91' },
  { value: '+63' }, { value: '+62' },
];

@ComponentV2
export struct HongguoSmsLoginDialogContent {
  private readonly service: FqHongguoImportService = new FqHongguoImportService();
  /** 登录已确认（回调页面的收藏读取随即发起，销毁时不再取消在途请求，避免误杀）。 */
  private confirmed: boolean = false;
  /** 重发倒计时定时器（-1 = 未启动）。 */
  private countdownTimer: number = -1;
  /** 发送/登录请求进行中。 */
  @Local busy: boolean = false;
  /** 区号下标。 */
  @Local ccIndex: number = 0;
  /** 手机号数字输入（发送成功后锁定）。 */
  @Local mobile: string = '';
  /** 验证码输入。 */
  @Local code: string = '';
  /** 已发送：脱敏手机号（非空 = 已发送，可确认登录）。 */
  @Local maskedMobile: string = '';
  /** 重发剩余秒数。 */
  @Local resendIn: number = 0;
  /** 失败消息（空 = 无错误）。 */
  @Local failedMessage: string = '';

  aboutToDisappear(): void {
    this.stopTimer();
    if (!this.confirmed) {
      this.service.cancel();
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Select(FQ_HONGGUO_SMS_CC_OPTIONS)
          .selected(this.ccIndex)
          .value(FQ_HONGGUO_SMS_CC_OPTIONS[this.ccIndex].value)
          .font({ size: 15 })
          .fontColor($r('sys.color.font_primary'))
          .selectedOptionFont({ size: 15 })
          .optionFont({ size: 15 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius(12)
          .height(44)
          .width(92)
          .enabled(this.maskedMobile.length === 0 && !this.busy)
          .onSelect((index: number): void => {
            this.ccIndex = index;
          })

        TextInput({ placeholder: '请输入手机号', text: this.mobile })
          .type(InputType.Number)
          .maxLength(15)
          .height(44)
          .fontSize(15)
          .borderRadius(12)
          .layoutWeight(1)
          .enabled(this.maskedMobile.length === 0 && !this.busy)
          .onChange((value: string): void => {
            this.mobile = value;
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        TextInput({ placeholder: '请输入验证码', text: this.code })
          .type(InputType.Number)
          .maxLength(8)
          .height(44)
          .fontSize(15)
          .borderRadius(12)
          .layoutWeight(1)
          .enabled(!this.busy)
          .onChange((value: string): void => {
            this.code = value;
          })

        Button(this.sendButtonText())
          .fontSize(13)
          .fontColor(this.canSend() ? appState.accentColor : $r('sys.color.font_tertiary'))
          .backgroundColor(Color.Transparent)
          .border({
            width: 1,
            color: this.canSend()
              ? FqColorUtils.withOpacity(appState.accentColor, 0.5)
              : $r('sys.color.comp_divider')
          })
          .height(44)
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .enabled(this.canSend())
          .onClick((): void => {
            this.sendCode();
          })
      }
      .width('100%')

      if (this.maskedMobile.length > 0) {
        Text(`验证码已发送到 ${this.maskedMobile}，请注意查收`)
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      Button(this.busy ? '正在登录…' : '确认登录')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(appState.accentColor)
        .height(42)
        .borderRadius(12)
        .width('100%')
        .enabled(this.maskedMobile.length > 0 && this.code.trim().length >= 4 && !this.busy)
        .onClick((): void => {
          this.verifyCode();
        })

      if (this.failedMessage.length > 0) {
        Text(this.failedMessage)
          .fontSize(12.5)
          .lineHeight(19)
          .fontColor('#FFF43F5E')
          .width('100%')
      }
    }
    .width('100%')
  }

  /** 发送按钮文案：倒计时 > 重新发送 > 发送验证码。 */
  private sendButtonText(): string {
    if (this.resendIn > 0) {
      return `${this.resendIn} 秒后重发`;
    }
    return this.maskedMobile.length > 0 ? '重新发送' : '发送验证码';
  }

  /** 可发送：非 busy、无倒计时、手机号符合当前区号格式。 */
  private canSend(): boolean {
    if (this.busy || this.resendIn > 0) {
      return false;
    }
    const digits: string = this.mobile.trim();
    if (FQ_HONGGUO_SMS_CC_DIGITS[this.ccIndex] === '86') {
      return /^1\d{10}$/.test(digits);
    }
    return digits.length >= 4;
  }

  /** 平台手机号：大陆 11 位原样，境外 `+区号 号码`（后端归一化）。 */
  private composedMobile(): string {
    const digits: string = this.mobile.trim();
    const cc: string = FQ_HONGGUO_SMS_CC_DIGITS[this.ccIndex];
    if (cc === '86') {
      return digits;
    }
    return `+${cc} ${digits}`;
  }

  /** 发送验证码：成功锁定手机号并启动重发倒计时。 */
  private async sendCode(): Promise<void> {
    const mobile: string = this.composedMobile();
    if (mobile.length === 0 || !this.canSend()) {
      return;
    }
    this.stopTimer();
    this.busy = true;
    this.failedMessage = '';
    try {
      const sent: FqHongguoSmsSent = await this.service.sendSms(mobile);
      this.maskedMobile = sent.maskedMobile;
      this.code = '';
      this.startCountdown(sent.retrySeconds);
    } catch (error) {
      const err = error as BusinessError;
      this.failedMessage = err.message.length > 0 ? err.message : '发送验证码失败，请重试';
    } finally {
      this.busy = false;
    }
  }

  /** 校验验证码：成功回传 cookie 并关弹窗。 */
  private async verifyCode(): Promise<void> {
    const code: string = this.code.trim();
    if (code.length < 4 || this.busy) {
      return;
    }
    this.busy = true;
    this.failedMessage = '';
    try {
      const cookie: string = await this.service.verifySms(code);
      this.stopTimer();
      this.confirmed = true;
      DialogManager.ConfirmHongguoSmsLogin(cookie);
    } catch (error) {
      const err = error as BusinessError;
      this.failedMessage = err.message.length > 0 ? err.message : '登录失败，请重试';
    } finally {
      this.busy = false;
    }
  }

  private startCountdown(seconds: number): void {
    this.resendIn = seconds > 0 ? seconds : 60;
    this.countdownTimer = setInterval((): void => {
      this.resendIn--;
      if (this.resendIn <= 0) {
        this.stopTimer();
      }
    }, 1000);
  }

  private stopTimer(): void {
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
    this.resendIn = 0;
  }
}

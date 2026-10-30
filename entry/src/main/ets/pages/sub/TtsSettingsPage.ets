/**
 * 离线朗读设置页（设置-阅读与播放-离线朗读入口）：
 * - 朗读音色：系统朗读引擎（小艺语音）音色列表，已安装点选即时生效，
 *   未安装点「下载」经系统弹窗确认后下载（进度实时显示）；
 * - 朗读语速：0.75~2 档直选（与听书页离线朗读共用，全局持久化）；
 * - 说明：音色来源与中文音色数量说明。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { fqAudioSession, FqTtsVoice } from '../../core/FqAudioSession';
import { FqAppSettingsStore } from '../../core/FqAppSettingsStore';
import { appState } from '../../entryability/AppState';
import { FqColorUtils } from '../../utils/FqColorUtils';

/** 朗读语速档（与听书页倍速档一致）。 */
const FQ_TTS_RATES: number[] = [0.75, 1, 1.25, 1.5, 1.75, 2];
/** 标题栏下方内容起始偏移。 */
const FQ_TTS_TOP_INSET: number = 56;
/** 行内分割线左侧避让：行 padding 14 + 头像 34 + 间距 12。 */
const FQ_TTS_ROW_DIVIDER_INSET: number = 60;

@ComponentV2
export struct TtsSettingsPage {
  /** 当前朗读语速档。 */
  @Local rate: number = 1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.rate = FqAppSettingsStore.getTtsRate();
    // 强刷音色列表：拿到最新安装状态（其他入口下载完成后进页可见）
    fqAudioSession.refreshTtsVoices(true);
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('离线朗读', false),
      scroller: this.scroller,
    }) {
      List({ space: 12 }) {
        ListItem() {
          this.SectionHeader('朗读音色')
        }
        ListItem() {
          this.VoiceCard()
        }
        ListItem() {
          this.SectionHeader('朗读语速')
        }
        ListItem() {
          this.RateCard()
        }
        ListItem() {
          this.SectionHeader('说明')
        }
        ListItem() {
          this.NoteCard()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 40 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_TTS_TOP_INSET)
      .contentEndOffset(appState.bottomRect + 24)
    }
  }

  /** 音色卡片：音色行列表 + 系统列表获取失败提示。 */
  @Builder
  private VoiceCard() {
    Column() {
      ForEach(fqAudioSession.ttsVoices, (voice: FqTtsVoice, index: number) => {
        if (index > 0) {
          this.RowDivider()
        }
        this.VoiceRow(voice)
      }, (voice: FqTtsVoice) => `tts_voice_${voice.person}_${voice.installed}`)
      if (!fqAudioSession.ttsVoicesFromSystem) {
        this.RowDivider()
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_secondary')])
          Text('音色信息暂未获取到，请联网后重试')
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .maxLines(2)
          Text('重试')
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(appState.accentColor)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))
            .onClick((): void => {
              fqAudioSession.refreshTtsVoices(true);
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({
      width: 0.6,
      color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent,
    })
    .width('100%')
  }

  /** 单个音色行：文字头像 + 名称/描述 + 选中勾 / 下载按钮 / 下载进度。 */
  @Builder
  private VoiceRow(voice: FqTtsVoice) {
    Row({ space: 12 }) {
      Text(voice.name.length > 0 ? voice.name.substring(0, 1) : '音')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(appState.accentColor)
        .width(34)
        .height(34)
        .borderRadius(17)
        .textAlign(TextAlign.Center)
        .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))

      Column({ space: 3 }) {
        Text(voice.name)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.voiceSubtitle(voice))
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (fqAudioSession.ttsVoiceDownloading === voice.person) {
        Progress({
          value: fqAudioSession.ttsVoiceDownloadPercent >= 0 ? fqAudioSession.ttsVoiceDownloadPercent : 0,
          total: 100,
          type: ProgressType.Linear,
        })
          .width(54)
          .height(4)
          .borderRadius(2)
          .color(appState.accentColor)
          .style({ strokeWidth: 4 })
      } else if (voice.installed) {
        if (voice.person === fqAudioSession.ttsVoicePerson) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(15)
            .fontColor([appState.accentColor])
        }
      } else {
        Text('下载')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(appState.accentColor)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(15)
          .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.12))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onVoiceTap(voice);
    })
  }

  /** 语速卡片：档位 chip 直选。 */
  @Builder
  private RateCard() {
    Flex({
      direction: FlexDirection.Row,
      wrap: FlexWrap.Wrap,
      justifyContent: FlexAlign.Start,
    }) {
      ForEach(FQ_TTS_RATES, (rate: number) => {
        Text(`${rate}x`)
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(rate === this.rate ? appState.accentColor : $r('sys.color.font_primary'))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(17)
          .margin({ right: 8, top: 6, bottom: 6 })
          .backgroundColor(rate === this.rate
            ? FqColorUtils.withOpacity(appState.accentColor, 0.12)
            : $r('sys.color.comp_background_tertiary'))
          .onClick((): void => {
            this.onRateTap(rate);
          })
      }, (rate: number) => `rate_${rate}`)
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 6, bottom: 6 })
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({
      width: 0.6,
      color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent,
    })
  }

  /** 说明卡片。 */
  @Builder
  private NoteCard() {
    Column({ space: 8 }) {
      this.NoteText('离线朗读由系统朗读引擎（小艺语音）驱动，无需网络即可将小说正文朗读成语音，与在线听书共享章节进度，随时互切。')
      this.NoteText('中文提供「聆小珊」女声与「凌飞哲」男声两款音色；未安装的音色点击下载音色包后即可使用，下载需联网。')
      this.NoteText('音色与语速为全局设置，听书页离线朗读与此处同步生效。')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({
      width: 0.6,
      color: appState.isDark ? $r('sys.color.comp_divider') : Color.Transparent,
    })
  }

  /** 说明段落文本（统一样式）。 */
  @Builder
  private NoteText(message: string) {
    Text(message)
      .fontSize(12.5)
      .fontColor($r('sys.color.font_secondary'))
      .lineHeight(19)
      .width('100%')
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
      .margin({ left: FQ_TTS_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 音色行副标题（下载态 / 未安装 / 描述）。 */
  private voiceSubtitle(voice: FqTtsVoice): string {
    if (fqAudioSession.ttsVoiceDownloading === voice.person) {
      const percent: number = fqAudioSession.ttsVoiceDownloadPercent;
      return percent >= 0 ? `正在下载音色 ${percent}%` : '正在下载音色…';
    }
    if (!voice.installed) {
      return `${voice.description}（未安装，点击下载）`;
    }
    return voice.description;
  }

  private onVoiceTap(voice: FqTtsVoice): void {
    if (fqAudioSession.ttsVoiceDownloading === voice.person) {
      return;
    }
    if (!voice.installed) {
      fqAudioSession.downloadTtsVoice(voice.person);
      return;
    }
    fqAudioSession.applyTtsVoiceChoice(voice.person);
  }

  private onRateTap(rate: number): void {
    this.rate = rate;
    if (fqAudioSession.hasSession && fqAudioSession.ttsMode) {
      fqAudioSession.setTtsRate(rate);
    } else {
      FqAppSettingsStore.setTtsRate(rate);
    }
  }
}

/**
 * 「自定义主题编辑」弹窗内容（经 DialogManager.ShowReaderThemeEditor 打开，
 * 独立宿主弹窗叠加于「阅读设置」之上）：
 * 浅色/深色模式滑块切换 + 图片位点击选图（即选即拷沙箱，取消自动清理）+
 * 名称（实时写回主题行标签）/ 字色（默认 + 预设色点 + 弹窗式 HSB 取色器）/
 * 字号 / 行距 / 字体（0/-1/空 = 跟随全局），均按当前模式独立；
 * 编辑值经 @Local 驱动刷新、onChange 同步回 DialogManager（保存按钮经其统一读取）；
 * 本页 UI 一律内联写法，禁用 @Builder 传参（按值传参不刷新，选中态会冻结在初始值）；
 * 「删除该主题」仅编辑模式显示，先关编辑弹窗再回调（回调内可再开通用确认弹窗）。
 */
import { promptAction } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { DialogManager } from '../../utils/DialogUtils';
import { fqNormalizeThemeFontColor, FqReaderStore } from '../../core/FqReaderStore';
import { FQ_FONT_OPTIONS, FqFontOption } from '../../core/FqOnlineParser';
import { appState } from '../../entryability/AppState';
import { themeUtils } from '../../utils/ThemeUtils';
import { rowImmersiveModifier } from '../../utils/ModifierUtils';

/** 编辑弹窗预设字色（配合自定义背景：深色 4 档 + 浅色 1 档）。 */
const FQ_EDITOR_FONT_COLORS: string[] = ['#1F2329', '#5B4636', '#33506B', '#3D5A4C', '#E8E6E1'];
const FQ_EDITOR_FONT_COLOR_LABELS: string[] = ['墨黑', '深棕', '黛蓝', '墨绿', '米白'];

@ComponentV2
export struct ReaderThemeEditorContent {
  /** 当前编辑模式：0 浅色 / 1 深色。 */
  @Local editorMode: number = 0;
  @Local editorName: string = '';
  @Local editorLightBg: string = '';
  @Local editorLightFontColor: string = '';
  @Local editorLightFontSize: number = 0;
  @Local editorLightFontIndex: number = -1;
  @Local editorLightLineHeight: number = 0;
  @Local editorDarkBg: string = '';
  @Local editorDarkFontColor: string = '';
  @Local editorDarkFontSize: number = 0;
  @Local editorDarkFontIndex: number = -1;
  @Local editorDarkLineHeight: number = 0;

  aboutToAppear(): void {
    this.editorName = DialogManager.readerThemeName;
    this.editorLightBg = DialogManager.readerThemeLightBg;
    this.editorLightFontColor = DialogManager.readerThemeLightFontColor;
    this.editorLightFontSize = DialogManager.readerThemeLightFontSize;
    this.editorLightFontIndex = DialogManager.readerThemeLightFontIndex;
    this.editorLightLineHeight = DialogManager.readerThemeLightLineHeight;
    this.editorDarkBg = DialogManager.readerThemeDarkBg;
    this.editorDarkFontColor = DialogManager.readerThemeDarkFontColor;
    this.editorDarkFontSize = DialogManager.readerThemeDarkFontSize;
    this.editorDarkFontIndex = DialogManager.readerThemeDarkFontIndex;
    this.editorDarkLineHeight = DialogManager.readerThemeDarkLineHeight;
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('50%')
            .height(34)
            .borderRadius(8)
            .layoutGravity(this.editorMode === 0 ? LocalizedAlignment.START : LocalizedAlignment.END)// stack组件中子组件对齐位置
            .backgroundColor($r('sys.color.comp_background_list_card'))

          Row() {
            Text('浅色模式')
              .fontSize(13)
              .fontWeight(this.editorMode === 0 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.editorMode === 0 ? appState.accentColor : $r('sys.color.font_tertiary'))
              .height(26)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.switchEditorMode(0);
              })
            Text('深色模式')
              .fontSize(13)
              .fontWeight(this.editorMode === 1 ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.editorMode === 1 ? appState.accentColor : $r('sys.color.font_tertiary'))
              .height(26)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.switchEditorMode(1);
              })
          }
          .width('100%')
        }
        .width('100%')
        .borderRadius(10)
        .backgroundColor($r('app.color.reader_chip_bg'))
        .padding(3)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Row({ space: 10 }) {
        Column({ space: 3 }) {
          if (this.curBg().length > 0) {
            Image(`file://${this.curBg()}`)
              .objectFit(ImageFit.Cover)
              .width(40)
              .height(40)
              .borderRadius(8)
              .clip(true)
              .draggable(false)
          } else {
            Column()
              .width(40)
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.reader_chip_bg'))
              .border({
                width: 1,
                color: themeUtils.terTextColor,
                style: BorderStyle.Dashed,
              })
              .justifyContent(FlexAlign.Center)
          }
          Text(this.curBg().length > 0 ? '换图' : '选图')
            .fontSize(9)
            .fontColor(themeUtils.textColor)
            .opacity(0.6)
        }
        .alignItems(HorizontalAlign.Center)
        .onClick((): void => {
          void this.pickImage();
        })

        Column({ space: 3 }) {
          TextInput({ text: this.editorName, placeholder: '主题名称' })
            .maxLength(12)
            .height(40)
            .fontSize(14)
            .fontColor(themeUtils.textColor)
            .placeholderColor(themeUtils.terTextColor)
            .backgroundColor($r('app.color.reader_chip_bg'))
            .borderRadius(10)
            .onChange((value: string): void => {
              this.editorName = value;
              DialogManager.readerThemeName = value;
              DialogManager.LiveReaderThemeName(value);
            })

          Text('自定义名称')
            .fontSize(9)
            .fontColor(themeUtils.textColor)
            .opacity(0.6)
        }.alignItems(HorizontalAlign.Center).layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Text('字色')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Column({ space: 3 }) {
          Column()
            .width(24)
            .height(24)
            .borderRadius(12)
            .backgroundColor($r('app.color.reader_chip_bg'))
            .border({
              width: this.curFontColor().length === 0 ? 2 : 1,
              color: this.curFontColor().length === 0 ? appState.accentColor : themeUtils.terTextColor,
            })
          Text('默认')
            .fontSize(9)
            .fontColor(themeUtils.textColor)
            .opacity(this.curFontColor().length === 0 ? 1 : 0.6)
        }
        .alignItems(HorizontalAlign.Center)
        .onClick((): void => {
          this.applyCurFontColor('');
        })
        ForEach(FQ_EDITOR_FONT_COLORS, (color: string, index: number) => {
          Column({ space: 3 }) {
            Column()
              .width(24)
              .height(24)
              .borderRadius(12)
              .backgroundColor(color)
              .border({
                width: this.curFontColor() === color ? 2 : 1,
                color: this.curFontColor() === color ? appState.accentColor : themeUtils.terTextColor,
              })
            Text(FQ_EDITOR_FONT_COLOR_LABELS[index])
              .fontSize(9)
              .fontColor(themeUtils.textColor)
              .opacity(this.curFontColor() === color ? 1 : 0.6)
          }
          .alignItems(HorizontalAlign.Center)
          .onClick((): void => {
            this.applyCurFontColor(color);
          })
        }, (color: string): string => color)
        Column({ space: 3 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(14)
              .fontColor([themeUtils.terTextColor])
              .opacity(this.isCustomPickedColor() ? 0 : 1)
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor(this.isCustomPickedColor() ? this.curFontColor()
            : $r('app.color.reader_chip_bg'))
          .border({
            width: this.isCustomPickedColor() ? 2 : 1,
            color: this.isCustomPickedColor() ? appState.accentColor : themeUtils.terTextColor,
          })
          .justifyContent(FlexAlign.Center)
          Text('自定义')
            .fontSize(9)
            .fontColor(themeUtils.textColor)
            .opacity(this.isCustomPickedColor() ? 1 : 0.6)
        }
        .alignItems(HorizontalAlign.Center)
        .onClick((): void => {
          DialogManager.ShowCustomColorPicker(
            this.curFontColor().length > 0 ? this.curFontColor() : '#1F2329',
            (hex: string): void => {
              this.applyCurFontColor(fqNormalizeThemeFontColor(hex));
            });
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('字号')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Text('跟随')
          .fontSize(12)
          .fontColor(this.curFontSize() <= 0 ? '#FFFFFF' : themeUtils.textColor)
          .backgroundColor(this.curFontSize() <= 0 ? appState.accentColor : 'transparent')
          .borderRadius(13)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick((): void => {
            this.applyCurFontSize(0);
          })
        Text('A-')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(themeUtils.textColor)
          .width(28)
          .height(28)
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.reader_chip_bg'))
          .onClick((): void => {
            this.stepCurFontSize(-1);
          })
        Text(this.curFontSize() > 0 ? `${this.curFontSize()}` : '跟随')
          .fontSize(13)
          .fontColor(themeUtils.textColor)
          .width(36)
          .textAlign(TextAlign.Center)
        Text('A+')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(themeUtils.textColor)
          .width(28)
          .height(28)
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.reader_chip_bg'))
          .onClick((): void => {
            this.stepCurFontSize(1);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('行距')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Text('跟随')
          .fontSize(12)
          .fontColor(this.curLineHeight() <= 0 ? '#FFFFFF' : themeUtils.textColor)
          .backgroundColor(this.curLineHeight() <= 0 ? appState.accentColor : 'transparent')
          .borderRadius(13)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick((): void => {
            this.applyCurLineHeight(0);
          })
        Text('-')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(themeUtils.textColor)
          .width(28)
          .height(28)
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.reader_chip_bg'))
          .onClick((): void => {
            this.stepCurLineHeight(-0.1);
          })
        Text(this.curLineHeight() > 0 ? this.curLineHeight().toFixed(1) : '跟随')
          .fontSize(13)
          .fontColor(themeUtils.textColor)
          .width(36)
          .textAlign(TextAlign.Center)
        Text('+')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(themeUtils.textColor)
          .width(28)
          .height(28)
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.reader_chip_bg'))
          .onClick((): void => {
            this.stepCurLineHeight(0.1);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text('字体')
          .fontSize(14)
          .fontColor(themeUtils.textColor)
          .width(36)
        Text('跟随')
          .fontSize(12)
          .fontColor(this.curFontIndex() <= -1 ? '#FFFFFF' : themeUtils.textColor)
          .backgroundColor(this.curFontIndex() <= -1 ? appState.accentColor : 'transparent')
          .borderRadius(13)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .onClick((): void => {
            this.applyCurFontIndex(-1);
          })
        ForEach(FQ_FONT_OPTIONS, (option: FqFontOption, index: number) => {
          Text(option.label)
            .fontSize(12)
            .fontColor(this.curFontIndex() === index ? '#FFFFFF' : themeUtils.textColor)
            .backgroundColor(this.curFontIndex() === index ? appState.accentColor : 'transparent')
            .borderRadius(13)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .onClick((): void => {
              this.applyCurFontIndex(index);
            })
        }, (option: FqFontOption): string => option.label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (DialogManager.IsReaderThemeEditorEdit()) {
        Text('删除该主题')
          .fontSize(13)
          .fontColor('#E5443C')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 2, bottom: 2 })
          .onClick((): void => {
            DialogManager.RequestReaderThemeEditorDelete();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 当前模式背景图路径。 */
  private curBg(): string {
    return this.editorMode === 0 ? this.editorLightBg : this.editorDarkBg;
  }

  /** 当前模式字色。 */
  private curFontColor(): string {
    return this.editorMode === 0 ? this.editorLightFontColor : this.editorDarkFontColor;
  }

  /** 当前模式字号。 */
  private curFontSize(): number {
    return this.editorMode === 0 ? this.editorLightFontSize : this.editorDarkFontSize;
  }

  /** 当前模式字体档位。 */
  private curFontIndex(): number {
    return this.editorMode === 0 ? this.editorLightFontIndex : this.editorDarkFontIndex;
  }

  /** 当前模式行距。 */
  private curLineHeight(): number {
    return this.editorMode === 0 ? this.editorLightLineHeight : this.editorDarkLineHeight;
  }

  /** 切换浅色/深色编辑模式（滑块位移动画）。 */
  private switchEditorMode(mode: number): void {
    if (this.editorMode === mode) {
      return;
    }
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseInOut }, (): void => {
      this.editorMode = mode;
    });
  }

  /** 图片位点击选图：图库选图 → 拷入沙箱 → 记入未保存清单 → 预览当前模式。 */
  private async pickImage(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (result.photoUris.length === 0) {
        return;
      }
      const previous: string = this.curBg();
      const path: string = FqReaderStore.importThemeImage(result.photoUris[0]);
      if (path.length === 0) {
        promptAction.showToast({ message: '背景图导入失败，请重试', duration: 2000 });
        return;
      }
      DialogManager.TrackReaderThemeBgImport(previous, path);
      if (this.editorMode === 0) {
        this.editorLightBg = path;
        DialogManager.readerThemeLightBg = path;
      } else {
        this.editorDarkBg = path;
        DialogManager.readerThemeDarkBg = path;
      }
    } catch (error) {
      // 用户取消选图或选择器异常，保持现状
    }
  }

  /** 当前字色是否为取色器自定义色（非空且不在预设内）。 */
  private isCustomPickedColor(): boolean {
    const color: string = this.curFontColor();
    return color.length > 0 && FQ_EDITOR_FONT_COLORS.indexOf(color) < 0;
  }

  private applyCurFontColor(color: string): void {
    if (this.editorMode === 0) {
      this.editorLightFontColor = color;
      DialogManager.readerThemeLightFontColor = color;
    } else {
      this.editorDarkFontColor = color;
      DialogManager.readerThemeDarkFontColor = color;
    }
  }

  private applyCurFontSize(size: number): void {
    if (this.editorMode === 0) {
      this.editorLightFontSize = size;
      DialogManager.readerThemeLightFontSize = size;
    } else {
      this.editorDarkFontSize = size;
      DialogManager.readerThemeDarkFontSize = size;
    }
  }

  private stepCurFontSize(delta: number): void {
    const base: number = this.curFontSize() > 0 ? this.curFontSize() : 19;
    this.applyCurFontSize(Math.min(32, Math.max(12, base + delta)));
  }

  private applyCurFontIndex(index: number): void {
    if (this.editorMode === 0) {
      this.editorLightFontIndex = index;
      DialogManager.readerThemeLightFontIndex = index;
    } else {
      this.editorDarkFontIndex = index;
      DialogManager.readerThemeDarkFontIndex = index;
    }
  }

  private applyCurLineHeight(value: number): void {
    if (this.editorMode === 0) {
      this.editorLightLineHeight = value;
      DialogManager.readerThemeLightLineHeight = value;
    } else {
      this.editorDarkLineHeight = value;
      DialogManager.readerThemeDarkLineHeight = value;
    }
  }

  private stepCurLineHeight(delta: number): void {
    const base: number = this.curLineHeight() > 0 ? this.curLineHeight() : 1.9;
    this.applyCurLineHeight(Math.min(2.6, Math.max(1.2, Math.round((base + delta) * 10) / 10)));
  }
}

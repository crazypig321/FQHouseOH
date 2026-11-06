/**
 * 播放设置半模态内容壳（CommonSheet 包裹）：
 * 主设置页（FqPlayerSettingsPanel）与二级「弹幕设置」页（FqDanmakuSettingsPanel）
 * 按 page 切换——标题栏随页切换：主设置页 = 标题 + 关闭；弹幕设置页 =
 * HDS 返回按钮（回主设置）+ 标题 + 右上「恢复默认」+ 关闭。
 * 业务状态与回调全部经 @Param/@Event 桥接宿主（PlayerPage）。
 */
import { CommonSheet } from '../sheet/CommonSheet';
import { FqDanmakuSettingsPanel } from './FqDanmakuSettingsPanel';
import { FqPlayerSettingsPanel } from './FqPlayerSettingsPanel';

@ComponentV2
export struct FqPlayerSettingsSheet {
  /** 二级页（'' 播放设置 / 'danmaku' 弹幕设置）。 */
  @Param page: string = '';
  // ---- 播放设置参数 ----
  /** mpv 当前倍速。 */
  @Param speed: number = 1;
  /** 倍速拖动预览值（-1 未拖动）。 */
  @Param speedPreview: number = -1;
  /** 弹幕开关。 */
  @Param danmakuOn: boolean = true;
  // ---- 弹幕设置参数 ----
  /** 「显示区域」行语义：true 横屏片源；false 竖屏片源。 */
  @Param danmakuIsLandscape: boolean = false;
  /** 弹幕不透明度（%，20-100）。 */
  @Param alphaPercent: number = 100;
  /** 弹幕速度档（1-5）。 */
  @Param speedTier: number = 3;
  /** 竖屏弹幕行数（1-4）。 */
  @Param lineCount: number = 4;
  /** 横屏弹幕显示区域档（1-4）。 */
  @Param lineSpaceTier: number = 2;
  /** 弹幕字号档（1-5）。 */
  @Param sizeTier: number = 3;
  /** 弹幕背景透明开关。 */
  @Param bgTransparent: boolean = false;
  // ---- 播放设置事件 ----
  @Event speedCommit: (value: number) => void = (_value: number): void => {};
  @Event speedPreviewChange: (value: number) => void = (_value: number): void => {};
  @Event danmakuToggle: (on: boolean) => void = (_on: boolean): void => {};
  @Event rowClick: (key: string) => void = (_key: string): void => {};
  // ---- 弹幕设置事件 ----
  @Event alphaChange: (value: number) => void = (_value: number): void => {};
  @Event speedTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event lineCountChange: (count: number) => void = (_count: number): void => {};
  @Event lineSpaceTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event sizeTierChange: (tier: number) => void = (_tier: number): void => {};
  @Event bgTransparentChange: (on: boolean) => void = (_on: boolean): void => {};
  // ---- 标题栏事件 ----
  /** 二级页返回按钮（回播放设置主页）。 */
  @Event backClick: () => void = (): void => {};
  /** 「恢复默认」标题栏按钮（fqapp 语义：落默认值 + Toast「设置成功」）。 */
  @Event resetClick: () => void = (): void => {};
  /** 关闭按钮（收起 sheet）。 */
  @Event closeClick: () => void = (): void => {};

  build() {
    CommonSheet({
      sheetTitle: this.page === 'danmaku' ? '弹幕设置' : '播放设置',
      showBack: this.page === 'danmaku',
      backClick: (): void => {
        this.backClick();
      },
      showReset: this.page === 'danmaku',
      resetClick: (): void => {
        this.resetClick();
      },
      showClose: true,
      closeClick: (): void => {
        this.closeClick();
      },
      content: (): void => {
        this.SheetBody();
      },
    })
  }

  /** 两级页内容切换（浅色配色）。 */
  @Builder
  private SheetBody() {
    if (this.page === 'danmaku') {
      FqDanmakuSettingsPanel({
        dark: false,
        isLandscape: this.danmakuIsLandscape,
        alphaPercent: this.alphaPercent,
        speedTier: this.speedTier,
        lineCount: this.lineCount,
        lineSpaceTier: this.lineSpaceTier,
        sizeTier: this.sizeTier,
        bgTransparent: this.bgTransparent,
        alphaChange: (value: number): void => {
          this.alphaChange(value);
        },
        speedTierChange: (tier: number): void => {
          this.speedTierChange(tier);
        },
        lineCountChange: (count: number): void => {
          this.lineCountChange(count);
        },
        lineSpaceTierChange: (tier: number): void => {
          this.lineSpaceTierChange(tier);
        },
        sizeTierChange: (tier: number): void => {
          this.sizeTierChange(tier);
        },
        bgTransparentChange: (on: boolean): void => {
          this.bgTransparentChange(on);
        },
      })
    } else {
      FqPlayerSettingsPanel({
        dark: false,
        speed: this.speed,
        speedPreview: this.speedPreview,
        danmakuOn: this.danmakuOn,
        speedCommit: (value: number): void => {
          this.speedCommit(value);
        },
        speedPreviewChange: (value: number): void => {
          this.speedPreviewChange(value);
        },
        danmakuToggle: (on: boolean): void => {
          this.danmakuToggle(on);
        },
        rowClick: (key: string): void => {
          this.rowClick(key);
        },
      })
    }
  }
}

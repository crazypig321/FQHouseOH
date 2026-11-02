/**
 * 缓存与管理页（设置-数据-缓存与管理）：
 * 集中罗列四类离线缓存入口（章节 / 剧集 / 听书 / 漫画），实时显示各类占用，
 * 点击进入对应缓存管理页；底部提供「清空全部离线缓存」一键清理入口。
 */

import { CommonNav } from '../../view/CommonNav';
import {
  FqTitleBarOptions,
  ROUTE_CACHED_BOOKS,
  ROUTE_CACHED_DRAMAS,
  ROUTE_CACHED_AUDIO,
  ROUTE_CACHED_COMICS,
} from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { NavPathUtils } from '../../utils/NavPathUtils';
import { appState } from '../../entryability/AppState';
import { DialogManager } from '../../utils/DialogUtils';
import { FqChapterCacheStore } from '../../core/FqChapterCacheStore';
import { FqDramaCacheStore } from '../../core/FqDramaCacheStore';
import { FqAudioCacheStore } from '../../core/FqAudioCacheStore';
import { FqComicCacheStore } from '../../core/FqComicCacheStore';
import { FqStoreBus, fqStoreBus } from '../../core/FqStoreBus';
import { fqFormatCacheBytes } from '../../view/FqCacheCommon';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_CACHE_MANAGE_TOP_INSET: number = 56;
/** 滚动内容末尾偏移。 */
const FQ_CACHE_MANAGE_BOTTOM_INSET: number = 40;
/** 行内分割线左右避让（与设置页行一致）。 */
const FQ_CACHE_MANAGE_ROW_DIVIDER_INSET: number = 60;

@Builder
function fqCacheManageEmptyContent() {
}

/** 卡片壳（与设置页 FqSettingsCard 同体系：comp_background_list_card + 深色描边）。 */
@ComponentV2
struct FqCacheManageCard {
  @BuilderParam content: () => void = fqCacheManageEmptyContent;

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
export struct CacheManagePage {
  private scroller: Scroller = new Scroller();
  /** store 版本总线（缓存增删时实时刷新占用）。 */
  @Local storeBus: FqStoreBus = fqStoreBus;
  @Local chapterBytes: number = 0;
  @Local dramaBytes: number = 0;
  @Local audioBytes: number = 0;
  @Local comicBytes: number = 0;

  aboutToAppear(): void {
    this.refreshSizes();
  }

  /** 任一类缓存变更（下载完成/删除/清空）时重算占用。 */
  @Monitor('storeBus.chapterCacheVersion', 'storeBus.dramaCacheVersion',
    'storeBus.audioCacheVersion', 'storeBus.comicCacheVersion')
  onCacheChanged(): void {
    this.refreshSizes();
  }

  private refreshSizes(): void {
    let chapterBytes: number = 0;
    for (const summary of FqChapterCacheStore.books()) {
      chapterBytes += summary.byteCount;
    }
    this.chapterBytes = chapterBytes;
    let dramaBytes: number = 0;
    for (const drama of FqDramaCacheStore.dramas()) {
      dramaBytes += drama.byteCount;
    }
    this.dramaBytes = dramaBytes;
    let audioBytes: number = 0;
    for (const summary of FqAudioCacheStore.books()) {
      audioBytes += summary.byteCount;
    }
    this.audioBytes = audioBytes;
    let comicBytes: number = 0;
    for (const summary of FqComicCacheStore.books()) {
      comicBytes += summary.byteCount;
    }
    this.comicBytes = comicBytes;
  }

  /** 行副标题：固定说明 + 实时占用（无缓存时只显示说明）。 */
  private sizeSubtitle(bytes: number): string {
    return bytes > 0 ? ` · ${fqFormatCacheBytes(bytes)}` : '';
  }

  /** 清空四类离线缓存（确认弹窗）。 */
  private confirmClearAll(): void {
    DialogManager.ShowConfirm('清空全部离线缓存',
      '章节、剧集、听书、漫画的已下载内容会全部删除，联网后可重新缓存。', '清空',
      (): void => {
        FqChapterCacheStore.clearAll();
        FqDramaCacheStore.clearAll();
        FqAudioCacheStore.clearAll();
        FqComicCacheStore.clearAll();
        this.refreshSizes();
        this.getUIContext().getPromptAction().showToast({ message: '已清空全部离线缓存', duration: 2000 });
      });
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('缓存与管理', false),
      scroller: this.scroller,
    }) {
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
          this.SectionHeader('离线缓存')
        }
        ListItem() {
          FqCacheManageCard() {
            this.CacheRow($r('sys.symbol.book'), '#FF3B82F6', '章节缓存',
              '已下载的书籍章节' + this.sizeSubtitle(this.chapterBytes), (): void => {
                NavPathUtils.push(ROUTE_CACHED_BOOKS);
              })
            this.RowDivider()
            this.CacheRow($r('sys.symbol.film'), '#FFEF5038', '剧集缓存',
              '已下载的剧集视频' + this.sizeSubtitle(this.dramaBytes), (): void => {
                NavPathUtils.push(ROUTE_CACHED_DRAMAS);
              })
            this.RowDivider()
            this.CacheRow($r('sys.symbol.waveform_headphones'), '#FF10B981', '听书缓存',
              '已下载的听书音频' + this.sizeSubtitle(this.audioBytes), (): void => {
                NavPathUtils.push(ROUTE_CACHED_AUDIO);
              })
            this.RowDivider()
            this.CacheRow($r('sys.symbol.picture'), '#FF0EA5E9', '漫画缓存',
              '已下载的漫画图片' + this.sizeSubtitle(this.comicBytes), (): void => {
                NavPathUtils.push(ROUTE_CACHED_COMICS);
              })
          }
        }
        if (this.chapterBytes + this.dramaBytes + this.audioBytes + this.comicBytes > 0) {
          ListItem() {
            this.SectionHeader('清理')
          }
          ListItem() {
            FqCacheManageCard() {
              this.DangerRow('清空全部离线缓存', '删除章节 / 剧集 / 听书 / 漫画的全部已下载内容', (): void => {
                this.confirmClearAll();
              })
            }
          }
        }
      }
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_CACHE_MANAGE_TOP_INSET)
      .contentEndOffset(appState.bottomRect)
      .width('100%')
      .height('100%')
    }
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
      .margin({ left: FQ_CACHE_MANAGE_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 缓存入口行（彩色图标块 + 标题/副标题 + 箭头）。 */
  @Builder
  private CacheRow(icon: Resource, tint: string, title: string, subtitle: string, onTap: () => void) {
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
    .onClick(onTap)
  }

  /** 危险操作行（红色图标块 + 标题/副标题，无箭头）。 */
  @Builder
  private DangerRow(title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(17)
          .fontColor(['#FFEF4444'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FFEF4444', 0.12))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFEF4444')
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick(onTap)
  }
}

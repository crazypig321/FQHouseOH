/**
 * 首页：频道条 + 推荐流（/api/v1/recommend/homepage）。
 * 端点语义对齐 fqapp ApiClient.homepagePage 第一段。
 * 长列表使用 LazyForEach + FqMediaDataSource 懒加载。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqHomePage, FqMediaItem } from '../model/FqModels';
import { FqMediaDataSource } from '../core/FqMediaDataSource';
import { FqItemCard } from '../component/FqItemCard';
import { DetailNavParams, ROUTE_DETAIL, FqTitleBarOptions } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { HideMode, HdsNavDestination } from '@kit.UIDesignKit';
import { appState } from '../entryability/AppState';

interface FqChannelDef {
  readonly label: string;
  readonly tabType: number;
}

const FQ_CHANNELS: FqChannelDef[] = [
  { label: '小说', tabType: 2 },
  { label: '短剧', tabType: 8 },
  { label: '漫剧', tabType: 24 },
  { label: '听书', tabType: 5 },
  { label: '视频', tabType: 16 },
];

/** 列表内容起始偏移：标题栏 56 + 频道条 44 + 间隙 8 */
const FQ_HOME_TOP_INSET: number = 108;

@ComponentV2
export struct HomePage {
  @Local channelIndex: number = 0;
  @Local itemCount: number = 0;
  @Local loading: boolean = false;
  @Local loadingMore: boolean = false;
  @Local refreshing: boolean = false;
  @Local errorMsg: string = '';
  private dataSource: FqMediaDataSource = new FqMediaDataSource();
  private scroller: Scroller = new Scroller();
  private nextOffset: number = -1;
  private sessionId: string = '';
  private loadToken: number = 0;

  aboutToAppear(): void {
    this.load(true);
  }

  build() {
    HdsNavDestination() {
      if (this.loading && this.itemCount === 0) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#FF7A3D')
          Text('正在加载…')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: appState.topRect + FQ_HOME_TOP_INSET })
      } else if (this.errorMsg.length > 0 && this.itemCount === 0) {
        Column({ space: 12 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor($r('sys.color.font_tertiary'))
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          Button('重试')
            .backgroundColor('#FF7A3D')
            .onClick(() => this.load(true))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: appState.topRect + FQ_HOME_TOP_INSET })
      } else if (this.itemCount === 0) {
        Column() {
          Text('暂无内容')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: appState.topRect + FQ_HOME_TOP_INSET })
      } else {
        Refresh({ refreshing: this.refreshing!! }) {
          List({ space: 0, scroller: this.scroller }) {
            LazyForEach(this.dataSource, (item: FqMediaItem) => {
              ListItem() {
                FqItemCard({
                  item: item,
                  onItemClick: (clicked: FqMediaItem): void => {
                    this.openDetail(clicked);
                  },
                })
              }
            }, (item: FqMediaItem): string => `${item.kind}:${item.id}`)
            if (this.loadingMore) {
              ListItem() {
                Row({ space: 8 }) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color('#FF7A3D')
                  Text('加载中…')
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding(12)
              }
            } else if (this.nextOffset > 0) {
              ListItem() {
                Text('上拉加载更多')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(12)
              }
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .contentStartOffset(appState.topRect + FQ_HOME_TOP_INSET)
          .contentEndOffset(appState.bottomRect + 60)
          .divider({
            strokeWidth: 0.5,
            color: $r('sys.color.comp_divider'),
            startMargin: 16,
            endMargin: 16,
          })
          .onReachEnd(() => this.load(false))
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => this.load(true))
      }
    }
    .titleBar(FqTitleBarOptions($r('app.string.app_name'), true, {
      builder: (): void => {
        this.ChannelStrip();
      },
    }))
    .dynamicHideTitleBar({
      hideBottomBuilder: true,
      mode: HideMode.SCROLL_UP_TO,
    })
    .bindToScrollable([this.scroller])
    .hideBackButton(true)
    .width('100%')
    .height('100%')
  }

  @Builder
  private ChannelStrip() {
    Scroll() {
      Row({ space: 2 }) {
        ForEach(FQ_CHANNELS, (channel: FqChannelDef, index: number) => {
          Text(channel.label)
            .fontSize(16)
            .fontWeight(this.channelWeight(index))
            .fontColor(this.channelColor(index))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => this.selectChannel(index))
        }, (channel: FqChannelDef): string => channel.label)
      }
      .padding({ left: 8, right: 8 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(44)
  }

  private channelWeight(index: number): FontWeight {
    return this.channelIndex === index ? FontWeight.Bold : FontWeight.Normal;
  }

  private channelColor(index: number): ResourceColor {
    return this.channelIndex === index ? '#FF7A3D' : $r('sys.color.font_secondary');
  }

  private selectChannel(index: number): void {
    if (this.channelIndex === index) {
      return;
    }
    this.channelIndex = index;
    this.dataSource.reset();
    this.itemCount = 0;
    this.errorMsg = '';
    this.nextOffset = -1;
    this.sessionId = '';
    this.load(true);
  }

  private openDetail(item: FqMediaItem): void {
    DetailNavParams.id = item.id;
    DetailNavParams.kind = item.kind;
    DetailNavParams.title = item.title;
    DetailNavParams.cover = item.cover;
    NavPathUtils.push(ROUTE_DETAIL);
  }

  private async load(reset: boolean): Promise<void> {
    // 翻页与在途请求互斥；刷新允许抢占（loadToken 使旧结果失效）。
    if (!reset) {
      if (this.loading || this.loadingMore || this.nextOffset <= 0) {
        return;
      }
    }
    const channel: FqChannelDef = FQ_CHANNELS[this.channelIndex];
    let offset: number = 0;
    if (reset) {
      offset = 0;
    } else {
      offset = this.nextOffset;
    }
    const token: number = ++this.loadToken;
    if (reset) {
      this.loading = true;
      this.errorMsg = '';
    } else {
      this.loadingMore = true;
    }
    try {
      await FqBackend.get().start(getContext(this));
      const page: FqHomePage = await FqBackend.get().homepagePage(
        channel.tabType,
        offset,
        reset ? '' : this.sessionId,
      );
      if (token !== this.loadToken) {
        return;
      }
      if (reset) {
        this.dataSource.reset();
        this.itemCount = 0;
      }
      this.dataSource.append(page.items);
      this.itemCount = this.dataSource.totalCount();
      this.nextOffset = page.nextOffset;
      if (page.sessionId.length > 0) {
        this.sessionId = page.sessionId;
      }
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
      }
    }
  }
}

/**
 * 短剧页（主 Tab 第 2 位，对齐 fqapp drama_page.dart 五频道结构）：
 * - 频道条：推荐 / 看剧 / 漫剧 / 最近 / 收藏（tab 16→24sp 动画 + 底部指示条）；
 *   顶部悬浮搜索行（漫剧频道进搜索漫剧类目，其余进短剧类目）；
 * - 推荐：全屏竖向 Swiper 逐卡切换（mpv surface 静态铺底 contain 居中，
 *   活动卡封面隐藏露出画面，触底预取；频道切走整体隐藏并暂停存档、
 *   切回续播，surface 不销毁保活）；
 *   信息层（官方 cjc.xml）：药丸行（观看全集 / 选集）+ 剧名行（进详情）+
 *   类型 chips + 「第N集丨」简介展开 + AI 声明；选集走 FqStoryPanel 半模态；
 * - 看剧 / 漫剧：t8 / t24 海报网格（3 列深色卡片，点击直进播放页）；
 * - 最近：观看历史（FqWatchedStore historyAll，全部/短剧/漫剧筛选，
 *   「已看到第N集」副标题）；收藏：书架短剧/漫剧（同款筛选与卡片）；
 * - 已看/续播直接写 FqWatchedStore，播放位置同时记入观看历史
 *   （recordHistory upsert，最近频道数据源，与播放页/听书视频页同链路）；
 * - 自动播放仅限「短剧主 Tab + 推荐频道 + 页面可见 + 应用前台」：
 *   主 Tab 切走经 @Monitor(currTabsIndex) 暂停（tabPaused 复位续播）；
 *   切频道 / 路由压顶分别经 channelPaused / visibilityPaused 暂停复位；
 *   条件不满足时加载完成只 open 不起播（open(media, false)）；
 *   切后台走 backgroundPauseHandlers（不自动恢复）；常亮跟随可见性。
 */

import { window } from '@kit.ArkUI';
import { CommonNav } from '../view/CommonNav';
import { CommonLoading } from '../view/CommonCom';
import { FqMediaItem, FqChapter, fqKindToTab } from '../model/FqModels';
import { PlayerNavParams, SearchNavParams, fqPushBookOrDetail, ROUTE_PLAYER, ROUTE_SEARCH } from '../model/FqNavModels';
import { FqHomeFeed, FqHomeSource, FQ_SOURCE_SEARCH_PAGED, FQ_SOURCE_SEARCH } from '../core/FqHomeFeed';
import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqWatchedStore, FqWatchedProgress, FqWatchHistoryRecord } from '../core/FqWatchedStore';
import { FqShelfStore } from '../core/FqShelfStore';
import { FqAppSettingsStore } from '../core/FqAppSettingsStore';
import { fqAudioSession } from '../core/FqAudioSession';
import { NavPathUtils } from '../utils/NavPathUtils';
import { appState, AppState } from '../entryability/AppState';
import { FqStoryPanel } from '../view/FqStoryPanel';
import { FqSheetOptions } from '../view/sheet/CommonSheet';
import { Player, PlayerSurface, Media, PlayerConfig } from '@mpv-ohos/mpv-arkts';

/** 频道名（下标即频道：0 推荐 / 1 看剧 / 2 漫剧 / 3 最近 / 4 收藏）。 */
const FQ_DRAMA_CHANNELS: string[] = ['推荐', '看剧', '漫剧', '最近', '收藏'];

/** 最近频道筛选（0 全部 / 1 短剧 / 2 漫剧）。 */
const FQ_RECENT_FILTERS: string[] = ['全部', '短剧', '漫剧'];

/** 顶部搜索行高（fqapp _dramaSearchRowHeight）。 */
const FQ_DRAMA_SEARCH_ROW_HEIGHT: number = 51;

/** 频道条高（fqapp _dramaStripBaseHeight）。 */
const FQ_DRAMA_STRIP_HEIGHT: number = 38;

/** 顶部悬浮层总高（搜索行 + 频道条）。 */
const FQ_DRAMA_CHROME_HEIGHT: number = FQ_DRAMA_SEARCH_ROW_HEIGHT + FQ_DRAMA_STRIP_HEIGHT;

/** 最近/收藏卡片数据（历史记录与书架条目统一成卡片模型）。 */
class FqDramaHistoryCardData {
  readonly id: string;
  readonly kind: string;
  readonly title: string;
  readonly cover: string;
  readonly subtitle: string;

  constructor(id: string, kind: string, title: string, cover: string, subtitle: string) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.cover = cover;
    this.subtitle = subtitle;
  }
}

/** 看剧/漫剧网格频道状态（@Trace 供子组件观察；feed/token 等非渲染字段不追踪）。 */
@ObservedV2
class FqDramaGridState {
  @Trace items: FqMediaItem[] = [];
  @Trace loading: boolean = false;
  @Trace errorMsg: string = '';
  @Trace hasMore: boolean = false;
  feed: FqHomeFeed | null = null;
  token: number = 0;
  moreInFlight: boolean = false;
  loaded: boolean = false;
}

/** 海报卡副标题（fqapp「分类·集数」：首个分类 + 集数，空回退类型名）。 */
function fqDramaGridSubLabel(item: FqMediaItem): string {
  const parts: string[] = [];
  if (item.categories.length > 0 && item.categories[0].length > 0) {
    parts.push(item.categories[0]);
  }
  const parsed: number = Number.parseInt(item.ep, 10);
  if (!Number.isNaN(parsed) && parsed > 0) {
    parts.push(`${parsed}集`);
  }
  if (parts.length === 0) {
    return item.kind === 'manju' ? '漫剧' : '短剧';
  }
  return parts.join('·');
}

/** 看剧/漫剧海报网格（深色卡：封面 + 剧名 + 「分类·集数」；点击直进播放页）。 */
@ComponentV2
struct FqDramaPosterGrid {
  @Param grid: FqDramaGridState = new FqDramaGridState();
  @Param lanes: number = 2;
  @Param emptyText: string = '暂无内容';
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param retryClick: () => void = (): void => {};
  @Param loadMoreClick: () => void = (): void => {};
  @Param itemClick: (item: FqMediaItem) => void = (_item: FqMediaItem): void => {};

  build() {
    if (this.grid.loading && this.grid.items.length === 0) {
      Column({ space: 12 }) {
        CommonLoading()
        Text('正在加载…')
          .fontSize(14)
          .fontColor('#B3FFFFFF')
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.grid.errorMsg.length > 0 && this.grid.items.length === 0) {
      Column({ space: 16 }) {
        Text(this.grid.errorMsg)
          .fontSize(14)
          .fontColor('#B3FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
        Button('重试')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .borderRadius(17)
          .border({ width: 1, color: '#80FFFFFF' })
          .padding({ left: 22, right: 22, top: 6, bottom: 6 })
          .onClick((): void => {
            this.retryClick();
          })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.grid.items.length === 0) {
      Column() {
        Text(this.emptyText)
          .fontSize(14)
          .fontColor('#B3FFFFFF')
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ space: 12 }) {
        ForEach(this.grid.items, (item: FqMediaItem) => {
          ListItem() {
            Column() {
              Image(FqBackend.get().resourceUrl(item.cover))
                .width('100%')
                .aspectRatio(0.72)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
                .draggable(false)
                .backgroundColor('#1AFFFFFF')
              Text(item.title)
                .fontSize(13)
                .fontColor('#E6FFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .width('100%')
                .margin({ top: 6 })
              Text(fqDramaGridSubLabel(item))
                .fontSize(11)
                .fontColor('#80FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .width('100%')
                .margin({ top: 2 })
            }
            .onClick((): void => {
              this.itemClick(item);
            })
          }
        }, (item: FqMediaItem) => `${item.kind}:${item.id}`)
        if (this.grid.hasMore) {
          ListItem() {
            Column() {
              CommonLoading()
            }
            .height(48)
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
        }
      }
      .width('100%')
      .height('100%')
      .lanes(this.lanes, 12)
      .padding({ left: 16, right: 16 })
      .contentStartOffset(this.topInset)
      .contentEndOffset(this.bottomInset)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd((): void => {
        this.loadMoreClick();
      })
    }
  }
}

/** 最近/收藏网格（fqapp _HistoryCard：封面 + 中央播放 + 漫剧角标 + 「已看到第N集」）。 */
@ComponentV2
struct FqDramaHistoryGrid {
  @Param cards: FqDramaHistoryCardData[] = [];
  @Param lanes: number = 3;
  @Param emptyText: string = '暂无内容';
  @Param topInset: number = 0;
  @Param bottomInset: number = 0;
  @Param cardClick: (card: FqDramaHistoryCardData) => void =
    (_card: FqDramaHistoryCardData): void => {};

  build() {
    if (this.cards.length === 0) {
      Column() {
        Text(this.emptyText)
          .fontSize(14)
          .fontColor('#B3FFFFFF')
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topInset })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ space: 12 }) {
        ForEach(this.cards, (card: FqDramaHistoryCardData) => {
          ListItem() {
            Column() {
              Stack() {
                Image(FqBackend.get().resourceUrl(card.cover))
                  .width('100%')
                  .aspectRatio(0.714)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
                  .draggable(false)
                  .backgroundColor('#1AFFFFFF')
                Row() {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontSize(18)
                    .fontColor([Color.White])
                }
                .width(36)
                .height(36)
                .borderRadius(18)
                .backgroundColor('#66000000')
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .layoutGravity(LocalizedAlignment.CENTER)
                if (card.kind === 'manju') {
                  Text('漫剧')
                    .fontSize(10)
                    .fontColor(Color.White)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(4)
                    .backgroundColor('#66000000')
                    .layoutGravity(LocalizedAlignment.TOP_START)
                    .margin(6)
                }
              }
              .width('100%')
              Text(card.title)
                .fontSize(13)
                .fontColor('#E6FFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .width('100%')
                .margin({ top: 6 })
              if (card.subtitle.length > 0) {
                Text(card.subtitle)
                  .fontSize(11)
                  .fontColor('#80FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
                  .width('100%')
                  .margin({ top: 2 })
              }
            }
            .onClick((): void => {
              this.cardClick(card);
            })
          }
        }, (card: FqDramaHistoryCardData) => `${card.kind}:${card.id}`)
      }
      .width('100%')
      .height('100%')
      .lanes(this.lanes, 12)
      .padding({ left: 16, right: 16 })
      .contentStartOffset(this.topInset)
      .contentEndOffset(this.bottomInset)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }
}

@ComponentV2
export struct DramaPage {
  /** mpv 播放器（@ObservedV2；state 经 @Trace 驱动本页渲染）。 */
  @Local player: Player = new Player(new PlayerConfig({
    onReady: (): void => this.onSurfaceReady(),
    hwdec: FqAppSettingsStore.isVideoHwdec(),
  }));
  /** surface 是否已挂载（PlayerSurface 首帧构建后为 true）。 */
  private surfaceReady: boolean = false;
  /** surface 未就绪时暂存的起播媒体（onReady 回调补 open）。 */
  private pendingOpenMedia: Media | null = null;
  /** 当前频道（0 推荐 / 1 看剧 / 2 漫剧 / 3 最近 / 4 收藏）。 */
  @Local channelIndex: number = 0;
  /** 看剧频道网格状态（t8 短剧，2 列）。 */
  @Local watchGrid: FqDramaGridState = new FqDramaGridState();
  /** 漫剧频道网格状态（t24 漫剧，3 列）。 */
  @Local manjuGrid: FqDramaGridState = new FqDramaGridState();
  /** 最近频道卡片（FqWatchedStore 观看历史）。 */
  @Local recentCards: FqDramaHistoryCardData[] = [];
  /** 最近频道筛选下标（FQ_RECENT_FILTERS 序）。 */
  @Local recentFilterIndex: number = 0;
  /** 收藏频道卡片（书架短剧/漫剧 + 观看历史副标题）。 */
  @Local favoriteCards: FqDramaHistoryCardData[] = [];
  /** 收藏频道筛选下标（FQ_RECENT_FILTERS 序）。 */
  @Local favoriteFilterIndex: number = 0;
  /** 选集半模态显隐（推荐频道信息层「选集」药丸）。 */
  @Local catalogSheetVisible: boolean = false;
  /** 切离推荐频道时的自暂停（切回自动续播；用户手动暂停不置位）。 */
  private channelPaused: boolean = false;
  /** 主 Tab 切走时的自暂停（切回短剧主 Tab 自动续播）。 */
  private tabPaused: boolean = false;
  /** 页面当前可见（onVisibleAreaChange 维护；起播 guard 用）。 */
  private pageVisible: boolean = true;
  /** surface 未就绪时暂存媒体的起播方式（onReady 补播用）。 */
  private pendingOpenAutoplay: boolean = true;
  /** 全局状态引用（@Monitor 监听 currTabsIndex 路径用）。 */
  @Local appStateUse: AppState = appState;
  /** feed 流条目（FqHomeFeed 聚合，触底翻页整体替换）。 */
  @Local feedItems: FqMediaItem[] = [];
  /** feed 首屏加载中。 */
  @Local feedLoading: boolean = true;
  /** feed 首屏错误文案（空 = 无错）。 */
  @Local feedErrorMsg: string = '';
  /** feed 控制器（短剧频道单源：homepage t8 + 搜索兜底）。 */
  private feed: FqHomeFeed = new FqHomeFeed([
    FqHomeSource.homepageFallback(8, 'video', FQ_SOURCE_SEARCH_PAGED, '短剧', 0),
  ]);
  /** feed 首屏加载令牌（销毁后旧请求作废）。 */
  private feedToken: number = 0;
  /** 翻页进行中（触底预取防重入）。 */
  private loadMoreInFlight: boolean = false;
  /** 竖向滑动控制器。 */
  private swiperController: SwiperController = new SwiperController();
  /** 活动卡下标（feedItems 序；-1 未激活）。 */
  @Local activeIndex: number = -1;
  /** 活动剧内容 id（已看/续播持久化键，= feed 条目 id）。 */
  private activeContentId: string = '';
  /** 活动剧目录加载中。 */
  @Local directoryLoading: boolean = false;
  /** 活动剧集目录（空 = 未拉到/拉取失败）。 */
  @Local activeEpisodes: FqChapter[] = [];
  /** 当前集下标（-1 未起播）。 */
  @Local activeEpisodeIndex: number = -1;
  /** 集流取流中（/api/content）。 */
  @Local episodeLoading: boolean = false;
  /** 集流/目录错误文案（空 = 无错；重试按钮按层分派）。 */
  @Local episodeErrorMsg: string = '';
  /** 当前集已实际播放（position > 0；已看/续播 guard）。 */
  private hasDisplayed: boolean = false;
  /** 当前集已出画面（position > 0；封面隐藏时机，fqapp firstFrame 语义）。 */
  @Local videoStarted: boolean = false;
  /** 异步加载令牌（activate/loadActiveEpisode 共用，切卡/切集/销毁作废旧请求）。 */
  private loadToken: number = 0;
  /** 进度条拖动预览（-1 未拖动）。 */
  @Local seekPreview: number = -1;
  /** 中央播放/暂停反馈图标显隐。 */
  @Local feedbackVisible: boolean = false;
  /** 反馈图标对应的新播放态。 */
  @Local feedbackPlaying: boolean = false;
  /** 反馈图标自动隐藏定时器（0 无任务）。 */
  private feedbackTimer: number = 0;
  /** 已展开简介的条目 id（点击「展开/收起」增删）。 */
  @Local expandedIntroIds: string[] = [];
  /** 可见性自暂停（切 Tab/路由压顶）：回到可见自动续播；用户手动暂停不置位。 */
  private visibilityPaused: boolean = false;
  /** 切后台主动暂停回调（EntryAbility onBackground 调用）。 */
  private backgroundPause: () => void = (): void => {};
  /** 主窗口（常亮开关用）。 */
  private mainWin: window.Window | null = null;
  /** 页面布局宽（vp；视频 contain 矩形用）。 */
  @Local layoutW: number = 0;
  /** 页面布局高（vp）。 */
  @Local layoutH: number = 0;

  aboutToAppear(): void {
    FqWatchedStore.init(getContext(this));
    FqShelfStore.init(getContext(this));
    this.player.stream.eof.listen((eof: boolean): void => {
      if (eof) {
        this.onEpisodeEnd();
      }
    });
    this.player.stream.position.listen((pos: number): void => {
      if (pos > 0 && !this.episodeLoading) {
        this.hasDisplayed = true;
        this.videoStarted = true;
      }
    });
    // 切后台主动暂停（图标/状态一致，回前台不自动恢复）
    this.backgroundPause = (): void => {
      this.player.pause();
      this.saveCurrentProgress();
    };
    appState.backgroundPauseHandlers.push(this.backgroundPause);
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.mainWin = win;
    }).catch((): void => {
      // 常亮设置失败不影响播放
    });
    this.loadFeed();
  }

  aboutToDisappear(): void {
    const bgHandlerIdx: number = appState.backgroundPauseHandlers.indexOf(this.backgroundPause);
    if (bgHandlerIdx >= 0) {
      appState.backgroundPauseHandlers.splice(bgHandlerIdx, 1);
    }
    this.loadToken += 1;
    this.feedToken += 1;
    this.watchGrid.token += 1;
    this.manjuGrid.token += 1;
    if (this.feedbackTimer !== 0) {
      clearTimeout(this.feedbackTimer);
      this.feedbackTimer = 0;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.setKeepScreenOn(false);
    this.player.stop();
    this.player.destroy();
  }

  /** feed 首屏：加载第一页并激活首卡。 */
  private async loadFeed(): Promise<void> {
    const token: number = ++this.feedToken;
    this.feedLoading = true;
    this.feedErrorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      await this.feed.loadFirst();
      if (token !== this.feedToken) {
        return;
      }
      this.feedItems = this.feed.items();
      this.feedLoading = false;
      if (this.feedItems.length > 0) {
        this.activate(0);
      }
    } catch (error) {
      if (token !== this.feedToken) {
        return;
      }
      this.feedLoading = false;
      this.feedErrorMsg = fqErrorMessage(error);
    }
  }

  /** feed 翻页预取（邻卡触发；静默失败）。 */
  private async loadMoreFeed(): Promise<void> {
    if (this.loadMoreInFlight || !this.feed.hasMore) {
      return;
    }
    this.loadMoreInFlight = true;
    const token: number = this.feedToken;
    try {
      await this.feed.loadMore();
      if (token !== this.feedToken) {
        return;
      }
      const items: FqMediaItem[] = this.feed.items();
      if (items.length > this.feedItems.length) {
        this.feedItems = items;
      }
    } catch (error) {
      // 翻页失败静默，下次触底重试
    } finally {
      this.loadMoreInFlight = false;
    }
  }

  /** 看剧/漫剧网格频道：首次进入建源并拉首屏。 */
  private ensureGrid(grid: FqDramaGridState, sources: FqHomeSource[]): void {
    if (grid.loaded) {
      return;
    }
    grid.loaded = true;
    grid.feed = new FqHomeFeed(sources);
    this.loadGridFirst(grid);
  }

  /** 看剧/漫剧网格首屏（重试复用）。 */
  private async loadGridFirst(grid: FqDramaGridState): Promise<void> {
    const feed: FqHomeFeed | null = grid.feed;
    if (feed === null) {
      return;
    }
    const token: number = ++grid.token;
    grid.loading = true;
    grid.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      await feed.loadFirst();
      if (token !== grid.token) {
        return;
      }
      grid.items = feed.items();
      grid.hasMore = feed.hasMore;
    } catch (error) {
      if (token !== grid.token) {
        return;
      }
      grid.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === grid.token) {
        grid.loading = false;
      }
    }
  }

  /** 看剧/漫剧网格触底翻页（静默失败）。 */
  private async loadGridMore(grid: FqDramaGridState): Promise<void> {
    const feed: FqHomeFeed | null = grid.feed;
    if (feed === null || grid.moreInFlight || !grid.hasMore) {
      return;
    }
    grid.moreInFlight = true;
    const token: number = grid.token;
    try {
      await feed.loadMore();
      if (token !== grid.token) {
        return;
      }
      grid.items = feed.items();
      grid.hasMore = feed.hasMore;
    } catch (error) {
      // 翻页失败静默，下次触底重试
    } finally {
      grid.moreInFlight = false;
    }
  }

  /** 主 Tab 切换：切走暂停存档（tabPaused），切回短剧主 Tab 自动续播。 */
  @Monitor('appStateUse.currTabsIndex')
  onMainTabChange(): void {
    if (appState.currTabsIndex === 1) {
      if (this.tabPaused) {
        this.tabPaused = false;
        if (this.channelIndex === 0) {
          this.player.play();
        }
      }
      return;
    }
    if (this.player.state.playing) {
      this.tabPaused = true;
      this.player.pause();
      this.saveCurrentProgress();
    } else {
      this.tabPaused = false;
    }
  }

  /** 切换频道：离开推荐暂停存档、切回续播；目标频道懒加载数据。 */
  private selectChannel(index: number): void {
    if (index === this.channelIndex) {
      return;
    }
    const wasFeed: boolean = this.channelIndex === 0;
    this.channelIndex = index;
    if (wasFeed) {
      if (this.player.state.playing) {
        this.channelPaused = true;
        this.player.pause();
        this.saveCurrentProgress();
      } else {
        this.channelPaused = false;
      }
    } else if (index === 0 && (this.channelPaused || this.visibilityPaused)) {
      this.channelPaused = false;
      this.visibilityPaused = false;
      this.player.play();
    }
    if (index === 1) {
      this.ensureGrid(this.watchGrid, [FqHomeSource.homepageFallback(8, 'video', FQ_SOURCE_SEARCH_PAGED, '短剧', 0)]);
    } else if (index === 2) {
      this.ensureGrid(this.manjuGrid, [FqHomeSource.homepageFallback(24, 'manju', FQ_SOURCE_SEARCH, '漫剧', 11)]);
    } else if (index === 3) {
      this.refreshRecentCards();
    } else if (index === 4) {
      this.refreshFavoriteCards();
    }
  }

  /** 最近频道：观看历史 → 卡片（按筛选过滤，「已看到第N集」副标题）。 */
  private refreshRecentCards(): void {
    const kindFilters: string[] = ['', 'video', 'manju'];
    const kindFilter: string = kindFilters[this.recentFilterIndex];
    const cards: FqDramaHistoryCardData[] = [];
    for (const record of FqWatchedStore.historyAll()) {
      if (kindFilter.length > 0 && record.kind !== kindFilter) {
        continue;
      }
      cards.push(new FqDramaHistoryCardData(record.id, record.kind, record.title, record.cover,
        record.episodeIndex >= 0 ? `已看到第${record.episodeIndex + 1}集` : ''));
    }
    this.recentCards = cards;
  }

  /** 收藏频道：书架短剧/漫剧 → 卡片（按筛选过滤；观看历史补「已看到第N集」副标题）。 */
  private refreshFavoriteCards(): void {
    const kindFilters: string[] = ['', 'video', 'manju'];
    const kindFilter: string = kindFilters[this.favoriteFilterIndex];
    const historyById: Map<string, FqWatchHistoryRecord> = new Map<string, FqWatchHistoryRecord>();
    for (const record of FqWatchedStore.historyAll()) {
      historyById.set(record.id, record);
    }
    const cards: FqDramaHistoryCardData[] = [];
    for (const entry of FqShelfStore.all()) {
      if (entry.kind !== 'video' && entry.kind !== 'manju') {
        continue;
      }
      if (kindFilter.length > 0 && entry.kind !== kindFilter) {
        continue;
      }
      const record: FqWatchHistoryRecord | undefined = historyById.get(entry.id);
      const subtitle: string = record !== undefined && record.episodeIndex >= 0
        ? `已看到第${record.episodeIndex + 1}集` : '';
      cards.push(new FqDramaHistoryCardData(entry.id, entry.kind, entry.title, entry.cover, subtitle));
    }
    this.favoriteCards = cards;
  }

  /** 收藏频道筛选切换。 */
  private selectFavoriteFilter(index: number): void {
    if (index === this.favoriteFilterIndex) {
      return;
    }
    this.favoriteFilterIndex = index;
    this.refreshFavoriteCards();
  }

  /** 收藏频道空态文案（按筛选类目）。 */
  private favoriteEmptyText(): string {
    if (this.favoriteFilterIndex === 1) {
      return '暂无收藏的短剧';
    }
    if (this.favoriteFilterIndex === 2) {
      return '暂无收藏的漫剧';
    }
    return '暂无收藏';
  }

  /** 最近频道筛选切换。 */
  private selectRecentFilter(index: number): void {
    if (index === this.recentFilterIndex) {
      return;
    }
    this.recentFilterIndex = index;
    this.refreshRecentCards();
  }

  /** 顶部搜索行：进搜索页（漫剧频道初始漫剧类目，其余初始短剧类目）。 */
  private openSearch(): void {
    SearchNavParams.initialCategoryIndex = this.channelIndex === 2 ? 3 : 2;
    NavPathUtils.push(ROUTE_SEARCH);
  }

  /** 网格卡 → 播放页（目录由播放页自拉，进度续播同 contentId 键）。 */
  private openGridPlayer(item: FqMediaItem): void {
    PlayerNavParams.contentId = item.id;
    PlayerNavParams.kind = item.kind;
    PlayerNavParams.title = item.title;
    PlayerNavParams.cover = item.cover;
    PlayerNavParams.chapters = [];
    PlayerNavParams.startIndex = -1;
    PlayerNavParams.startPositionSec = -1;
    PlayerNavParams.creationStatus = -1;
    PlayerNavParams.intro = item.intro;
    PlayerNavParams.previewNoSave = false;
    NavPathUtils.push(ROUTE_PLAYER);
  }

  /** 最近/收藏卡 → 播放页（同 contentId 续播）。 */
  private openHistoryCard(card: FqDramaHistoryCardData): void {
    PlayerNavParams.contentId = card.id;
    PlayerNavParams.kind = card.kind;
    PlayerNavParams.title = card.title;
    PlayerNavParams.cover = card.cover;
    PlayerNavParams.chapters = [];
    PlayerNavParams.startIndex = -1;
    PlayerNavParams.startPositionSec = -1;
    PlayerNavParams.creationStatus = -1;
    PlayerNavParams.intro = '';
    PlayerNavParams.previewNoSave = false;
    NavPathUtils.push(ROUTE_PLAYER);
  }

  /** Swiper 卡片切换：激活新卡 + 倒数第 2 卡预取下一页。 */
  private onSwiperChange(index: number): void {
    if (index === this.activeIndex) {
      return;
    }
    if (index >= this.feedItems.length - 2 && this.feed.hasMore) {
      this.loadMoreFeed();
    }
    this.activate(index);
  }

  /** 激活一卡：结算旧剧进度 → 拉目录 → 定位续播集 → 起播。 */
  private async activate(index: number): Promise<void> {
    const item: FqMediaItem | undefined = this.feedItems[index];
    if (item === undefined) {
      return;
    }
    // 离开的旧剧：实际播放过才标已看/存续播（activeContentId 尚未切换）
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.player.stop();
    const token: number = ++this.loadToken;
    this.activeIndex = index;
    this.activeContentId = item.id;
    this.activeEpisodes = [];
    this.activeEpisodeIndex = -1;
    this.hasDisplayed = false;
    this.videoStarted = false;
    this.seekPreview = -1;
    this.episodeErrorMsg = '';
    this.directoryLoading = true;
    try {
      await FqBackend.get().start(getContext(this));
      // fqapp loadVideoCatalogue：目录失败/为空回退 feed 条目自带首集（episodeId）单集目录
      let chapters: FqChapter[] = [];
      let directoryErrorMsg: string = '';
      try {
        chapters = await FqBackend.get().directoryChapters(item.id, fqKindToTab(item.kind));
      } catch (error) {
        directoryErrorMsg = fqErrorMessage(error);
      }
      if (token !== this.loadToken) {
        return;
      }
      this.directoryLoading = false;
      if (chapters.length === 0 && item.episodeId.length > 0) {
        chapters = [new FqChapter(item.episodeId, item.title)];
      }
      if (chapters.length === 0) {
        this.episodeErrorMsg = directoryErrorMsg.length > 0 ? directoryErrorMsg : '暂无剧集';
        return;
      }
      this.activeEpisodes = chapters;
      // 续播定位：FqWatchedStore 续播记录命中集 itemId → 该集 + 记录位置；否则第 1 集
      let startIdx: number = 0;
      let startSec: number = -1;
      const progress: FqWatchedProgress | null = FqWatchedStore.progress(item.id);
      if (progress !== null) {
        for (let i: number = 0; i < chapters.length; i++) {
          if (chapters[i].itemId === progress.episodeId) {
            startIdx = i;
            startSec = progress.position > 0 ? progress.position : -1;
            break;
          }
        }
      }
      this.loadActiveEpisode(startIdx, startSec);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.directoryLoading = false;
      this.episodeErrorMsg = fqErrorMessage(error);
    }
  }

  /** 加载并起播一集（episodeSource 取流 → mpv open；startSec > 0 偏移起播）。 */
  private async loadActiveEpisode(index: number, startSec: number): Promise<void> {
    const item: FqMediaItem | undefined = this.feedItems[this.activeIndex];
    const episode: FqChapter | undefined = this.activeEpisodes[index];
    if (item === undefined || episode === undefined) {
      return;
    }
    // 离开的旧集：实际播放过才标已看/存续播（activeEpisodeIndex 尚未切换）
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.player.stop();
    const token: number = ++this.loadToken;
    this.activeEpisodeIndex = index;
    this.episodeLoading = true;
    this.episodeErrorMsg = '';
    this.hasDisplayed = false;
    this.videoStarted = false;
    this.seekPreview = -1;
    try {
      await FqBackend.get().start(getContext(this));
      const source = await FqBackend.get().episodeSource(episode.itemId,
        fqKindToTab(item.kind), FqAppSettingsStore.getVideoQualityPref());
      if (token !== this.loadToken) {
        return;
      }
      this.episodeLoading = false;
      // 播放视频即停止听书（fqAudioSession 完整关闭链路）
      if (fqAudioSession.hasSession) {
        fqAudioSession.close();
      }
      this.startPlayback(source.url, startSec);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.episodeLoading = false;
      this.episodeErrorMsg = fqErrorMessage(error);
    }
  }

  /** 自动起播上下文：短剧主 Tab + 推荐频道 + 页面可见 + 应用前台；
    * 条件不满足时加载完成只 open 不起播（避免切页/切频道后仍有声音）。 */
  private shouldAutoPlay(): boolean {
    return this.channelIndex === 0
      && appState.currTabsIndex === 1
      && this.pageVisible
      && !appState.appInBackground;
  }

  /** 起播公共尾段：surface 就绪立即 open，未就绪暂存待 onReady 补播；
    * 非自动播放上下文 open(media, false) 并按拦截源置恢复标记。 */
  private startPlayback(url: string, startSec: number): void {
    const media: Media = startSec > 0 ? new Media(url, { start: startSec }) : new Media(url);
    const autoplay: boolean = this.shouldAutoPlay();
    if (this.surfaceReady) {
      this.player.open(media, autoplay);
    } else {
      this.pendingOpenMedia = media;
      this.pendingOpenAutoplay = autoplay;
    }
    if (!autoplay) {
      if (this.channelIndex !== 0) {
        this.channelPaused = true;
      } else if (appState.currTabsIndex !== 1) {
        this.tabPaused = true;
      } else if (!this.pageVisible) {
        this.visibilityPaused = true;
      }
      // 后台拦截不置标记：回前台不自动恢复，用户手动续播
    }
  }

  /** surface 挂载回调（PlayerConfig.onReady）：标记就绪并补播暂存媒体。 */
  private onSurfaceReady(): void {
    this.surfaceReady = true;
    const pending: Media | null = this.pendingOpenMedia;
    if (pending !== null) {
      this.pendingOpenMedia = null;
      this.player.open(pending, this.pendingOpenAutoplay);
    }
  }

  /** 播放/暂停切换（手势层单击）：eof 态重播，暂停即存续播。 */
  private togglePlay(): void {
    if (this.episodeErrorMsg.length > 0 || this.directoryLoading || this.episodeLoading) {
      return;
    }
    const wasPlaying: boolean = this.player.state.playing;
    if (this.player.state.eof) {
      this.player.play();
    } else {
      this.player.playOrPause();
    }
    this.showFeedback(!wasPlaying);
    if (wasPlaying) {
      this.saveCurrentProgress();
    }
  }

  /** 中央播放/暂停反馈图标（600ms 自动隐藏）。 */
  private showFeedback(playing: boolean): void {
    this.feedbackPlaying = playing;
    this.feedbackVisible = true;
    if (this.feedbackTimer !== 0) {
      clearTimeout(this.feedbackTimer);
    }
    this.feedbackTimer = setTimeout((): void => {
      this.feedbackVisible = false;
      this.feedbackTimer = 0;
    }, 600);
  }

  /**
    * 播完回调：取流中忽略（stop 后旧流残余事件）；未起播的 eof（mpv 打不开流
    * 同样触发）出错误态；同剧下一集连播，末集切下一卡，末卡停在末尾。
    */
  private onEpisodeEnd(): void {
    if (this.episodeLoading || this.directoryLoading) {
      return;
    }
    if (!this.hasDisplayed) {
      if (this.episodeErrorMsg.length === 0) {
        this.episodeErrorMsg = '视频加载失败，请重试';
      }
      return;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
    if (this.activeEpisodeIndex + 1 < this.activeEpisodes.length) {
      this.loadActiveEpisode(this.activeEpisodeIndex + 1, -1);
      return;
    }
    if (this.activeIndex + 1 < this.feedItems.length) {
      this.swiperController.changeIndex(this.activeIndex + 1, true);
    }
  }

  /** 「观看全集」药丸：进播放页全屏续看（同 contentId 续播键，进度无缝衔接）。 */
  private openPlayer(): void {
    const item: FqMediaItem | undefined = this.feedItems[this.activeIndex];
    if (item === undefined) {
      return;
    }
    this.markCurrentWatched();
    this.saveCurrentProgress();
    this.player.pause();
    PlayerNavParams.contentId = this.activeContentId;
    PlayerNavParams.kind = item.kind;
    PlayerNavParams.title = item.title;
    PlayerNavParams.cover = item.cover;
    PlayerNavParams.chapters = this.activeEpisodes;
    PlayerNavParams.startIndex = -1;
    PlayerNavParams.startPositionSec = -1;
    PlayerNavParams.creationStatus = -1;
    PlayerNavParams.intro = item.intro;
    PlayerNavParams.previewNoSave = false;
    NavPathUtils.push(ROUTE_PLAYER);
  }

  /** 剧名行：进剧集详情页。 */
  private openDetail(): void {
    const item: FqMediaItem | undefined = this.feedItems[this.activeIndex];
    if (item === undefined) {
      return;
    }
    this.player.pause();
    this.saveCurrentProgress();
    fqPushBookOrDetail(item.id, item.kind, item.title, item.cover);
  }

  /** 「选集」药丸：打开选集半模态（目录未就绪不响应）。 */
  private openCatalogSheet(): void {
    if (this.activeEpisodes.length === 0) {
      return;
    }
    this.catalogSheetVisible = true;
  }

  /** 关闭选集半模态。 */
  private closeCatalogSheet(): void {
    this.catalogSheetVisible = false;
  }

  /** 重试：feed 失败重拉首屏；目录失败重激活本卡；集流失败重拉本集。 */
  private retryActive(): void {
    if (this.feedItems.length === 0) {
      this.loadFeed();
      return;
    }
    if (this.activeEpisodes.length === 0) {
      this.activate(this.activeIndex >= 0 ? this.activeIndex : 0);
      return;
    }
    this.loadActiveEpisode(this.activeEpisodeIndex >= 0 ? this.activeEpisodeIndex : 0, -1);
  }

  /** 标记当前集已看（实际播放过才标，与播放页同键）。 */
  private markCurrentWatched(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const episode: FqChapter | undefined = this.activeEpisodes[this.activeEpisodeIndex];
    if (episode === undefined || episode.itemId.length === 0) {
      return;
    }
    FqWatchedStore.mark(this.activeContentId, episode.itemId);
  }

  /** 保存当前集续播进度（与播放页同键：FqWatchedStore，按集 itemId 记录）；
    * 同时 upsert 观看历史（最近频道数据源）。 */
  private saveCurrentProgress(): void {
    if (!this.hasDisplayed) {
      return;
    }
    const item: FqMediaItem | undefined = this.feedItems[this.activeIndex];
    const episode: FqChapter | undefined = this.activeEpisodes[this.activeEpisodeIndex];
    if (item === undefined || episode === undefined || episode.itemId.length === 0) {
      return;
    }
    const percent: number = this.seriesPercent(this.episodeFraction());
    FqWatchedStore.saveProgress(this.activeContentId,
      new FqWatchedProgress(episode.itemId,
        this.player.state.position, this.player.state.duration, percent));
    FqWatchedStore.recordHistory(new FqWatchHistoryRecord(
      this.activeContentId, item.kind, item.title, item.cover,
      episode.itemId, this.activeEpisodeIndex,
      this.player.state.position, this.player.state.duration, percent, Date.now()));
  }

  /** 整剧百分比 0..100（书架角标）：(当前集下标 + 集内比例)/总集数；无效返回 -1。 */
  private seriesPercent(fraction: number): number {
    const total: number = this.activeEpisodes.length;
    if (total <= 0 || this.activeEpisodeIndex < 0 || this.activeEpisodeIndex >= total) {
      return -1;
    }
    const value: number = Math.round(((this.activeEpisodeIndex + fraction) / total) * 100);
    return Math.min(100, Math.max(0, value));
  }

  /** 当前集内播放比例 0..1（时长未知 0）。 */
  private episodeFraction(): number {
    const duration: number = this.player.state.duration;
    if (duration <= 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.player.state.position / duration));
  }

  /** 简介是否已展开（按条目 id）。 */
  private introExpanded(item: FqMediaItem): boolean {
    return this.expandedIntroIds.indexOf(item.id) >= 0;
  }

  /** 展开/收起简介。 */
  private toggleIntroExpanded(item: FqMediaItem): void {
    const idx: number = this.expandedIntroIds.indexOf(item.id);
    if (idx >= 0) {
      this.expandedIntroIds.splice(idx, 1);
    } else {
      this.expandedIntroIds.push(item.id);
    }
  }

  /** 活动卡简介前缀文案（当前集下标 + 1；未起播按第 1 集）。 */
  private episodeIntroText(): string {
    const idx: number = this.activeEpisodeIndex >= 0 ? this.activeEpisodeIndex + 1 : 1;
    return `第${idx}集丨`;
  }

  /** 活动剧条目（无激活返回 null）。 */
  private activeItem(): FqMediaItem | null {
    const item: FqMediaItem | undefined = this.feedItems[this.activeIndex];
    return item === undefined ? null : item;
  }

  /** 药丸集数文案（fqapp nk3.c.d：episodeCnt > 1 → 「观看全集·N集」，否则「观看全片」）。 */
  private pillLabel(item: FqMediaItem): string {
    const parsed: number = Number.parseInt(item.ep, 10);
    const count: number = Number.isNaN(parsed) ? 0 : parsed;
    return count > 1 ? `观看全集·${count}集` : '观看全片';
  }

  /** 底部避让（悬浮 Tab 栏 28 边距 + 56 高 + 手势区）。 */
  private bottomInset(): number {
    return appState.bottomRect + 84;
  }

  /** 网格频道顶部避让（状态栏 + 顶部悬浮层 + 间距）。 */
  private gridTopInset(): number {
    return appState.topRect + FQ_DRAMA_CHROME_HEIGHT + 8;
  }

  /** 画面 contain 矩形宽（整页区域，比例回退 9:16）。 */
  private videoRectWidth(): number {
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    const ratioW: number = dw > 0 && dh > 0 ? dw : 9;
    const ratioH: number = dw > 0 && dh > 0 ? dh : 16;
    const byHeight: number = this.layoutH / ratioH * ratioW;
    return Math.max(1, Math.min(this.layoutW, byHeight));
  }

  /** 画面 contain 矩形高（与 videoRectWidth 同一 contain 约束的另一边）。 */
  private videoRectHeight(): number {
    const dw: number = this.player.state.videoParams.dw;
    const dh: number = this.player.state.videoParams.dh;
    const ratioW: number = dw > 0 && dh > 0 ? dw : 9;
    const ratioH: number = dw > 0 && dh > 0 ? dh : 16;
    const byWidth: number = this.layoutW / ratioW * ratioH;
    return Math.max(1, Math.min(this.layoutH, byWidth));
  }

  /** 常亮开关（失败静默）。 */
  private setKeepScreenOn(on: boolean): void {
    if (this.mainWin !== null) {
      this.mainWin.setWindowKeepScreenOn(on).catch((): void => {
        // 常亮设置失败不影响播放
      });
    }
  }

  /** 可见性变化：隐藏时自暂停（visibilityPaused 置位）+ 关常亮；可见时续播 + 开常亮；
    * 最近/收藏频道顺带刷新（从播放页返回进度/历史可能已变）。 */
  private onVisibleAreaChanged(currentRatio: number): void {
    this.pageVisible = currentRatio > 0;
    if (this.pageVisible) {
      this.setKeepScreenOn(true);
      if (this.visibilityPaused && this.channelIndex === 0 && appState.currTabsIndex === 1) {
        this.visibilityPaused = false;
        this.player.play();
      }
      if (this.channelIndex === 3) {
        this.refreshRecentCards();
      } else if (this.channelIndex === 4) {
        this.refreshFavoriteCards();
      }
      return;
    }
    this.setKeepScreenOn(false);
    if (this.player.state.playing) {
      this.visibilityPaused = true;
      this.player.pause();
      this.saveCurrentProgress();
    }
  }

  /** NavDestination onShown：最近/收藏频道刷新（从播放页返回）。 */
  private onPageShown(): void {
    if (this.channelIndex === 3) {
      this.refreshRecentCards();
    } else if (this.channelIndex === 4) {
      this.refreshFavoriteCards();
    }
  }

  @Builder
  private pageContent() {
    Stack() {
      // 推荐频道（常驻保活：视频/激活态/进度不因切频道丢失）
      this.FeedChannel()
      // 其余频道（覆盖在推荐之上，黑底）
      if (this.channelIndex === 1) {
        this.WatchGridChannel()
      } else if (this.channelIndex === 2) {
        this.ManjuGridChannel()
      } else if (this.channelIndex === 3) {
        this.RecentChannel()
      } else if (this.channelIndex === 4) {
        this.FavoriteChannel()
      }
      // 顶部悬浮层（搜索行 + 频道条）
      this.TopChrome()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .bindSheet(this.catalogSheetVisible, this.CatalogSheetBuilder(),
      FqSheetOptions((): void => {
        this.closeCatalogSheet();
      }, 600, false))
    .onVisibleAreaChange([0.0], (_isVisible: boolean, currentRatio: number) => {
      this.onVisibleAreaChanged(currentRatio)
    })
  }

  /** 推荐频道：加载/错误/视频流三分支（非推荐频道整体隐藏，surface 保活不销毁）。 */
  @Builder
  private FeedChannel() {
    Column() {
      if (this.feedLoading) {
      Column({ space: 12 }) {
        CommonLoading()
        Text('正在加载短剧…')
          .fontSize(14)
          .fontColor('#B3FFFFFF')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.feedErrorMsg.length > 0) {
      Column({ space: 16 }) {
        Text(this.feedErrorMsg)
          .fontSize(14)
          .fontColor('#B3FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
        Button('重试')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(Color.Transparent)
          .borderRadius(17)
          .border({ width: 1, color: '#80FFFFFF' })
          .padding({ left: 22, right: 22, top: 6, bottom: 6 })
          .onClick((): void => {
            this.loadFeed();
          })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      Stack() {
        // 视频层（静态铺底）：活动卡封面隐藏后露出画面；contain 矩形整页居中
        if (this.activeIndex >= 0) {
          Stack() {
            PlayerSurface({ player: this.player, ignoreSafeArea: false })
          }
          .width(this.videoRectWidth())
          .height(this.videoRectHeight())
        }
        Swiper(this.swiperController) {
          ForEach(this.feedItems, (item: FqMediaItem, index: number) => {
            this.DramaCard(item, index)
          }, (item: FqMediaItem) => `${item.kind}:${item.id}`)
        }
        .width('100%')
        .height('100%')
        .index(this.activeIndex >= 0 ? this.activeIndex : 0)
        .vertical(true)
        .loop(false)
        .indicator(false)
        .duration(300)
        .cachedCount(1)
        .onChange((index: number) => {
          this.onSwiperChange(index)
        })
        // 中央播放/暂停反馈图标（不拦截手势）
        if (this.feedbackVisible) {
          Column() {
            SymbolGlyph(this.feedbackPlaying ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'))
              .fontSize(64)
              .fontColor([Color.White])
          }
          .width(96)
          .height(96)
          .borderRadius(48)
          .backgroundColor('#66000000')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .layoutGravity(LocalizedAlignment.CENTER)
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        if (typeof newArea.width === 'number') {
          this.layoutW = newArea.width;
        }
        if (typeof newArea.height === 'number') {
          this.layoutH = newArea.height;
        }
      })
    }
    }
    .width('100%')
    .height('100%')
    .visibility(this.channelIndex === 0 ? Visibility.Visible : Visibility.Hidden)
  }

  /** 看剧频道：t8 短剧海报网格（3 列，与漫剧同款布局）。 */
  @Builder
  private WatchGridChannel() {
    FqDramaPosterGrid({
      grid: this.watchGrid,
      lanes: 3,
      emptyText: '暂无短剧',
      topInset: this.gridTopInset(),
      bottomInset: this.bottomInset(),
      retryClick: (): void => {
        this.loadGridFirst(this.watchGrid);
      },
      loadMoreClick: (): void => {
        this.loadGridMore(this.watchGrid);
      },
      itemClick: (item: FqMediaItem): void => {
        this.openGridPlayer(item);
      },
    })
  }

  /** 漫剧频道：t24 漫剧海报网格（3 列）。 */
  @Builder
  private ManjuGridChannel() {
    FqDramaPosterGrid({
      grid: this.manjuGrid,
      lanes: 3,
      emptyText: '暂无漫剧',
      topInset: this.gridTopInset(),
      bottomInset: this.bottomInset(),
      retryClick: (): void => {
        this.loadGridFirst(this.manjuGrid);
      },
      loadMoreClick: (): void => {
        this.loadGridMore(this.manjuGrid);
      },
      itemClick: (item: FqMediaItem): void => {
        this.openGridPlayer(item);
      },
    })
  }

  /** 最近频道：筛选 chips + 观看历史网格（3 列）。 */
  @Builder
  private RecentChannel() {
    Column() {
      Row({ space: 8 }) {
        ForEach(FQ_RECENT_FILTERS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontWeight(this.recentFilterIndex === index ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.recentFilterIndex === index ? Color.White : '#80FFFFFF')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
            .backgroundColor(this.recentFilterIndex === index ? '#33FFFFFF' : Color.Transparent)
            .onClick((): void => {
              this.selectRecentFilter(index);
            })
        }, (label: string) => label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      FqDramaHistoryGrid({
        cards: this.recentCards,
        lanes: 3,
        emptyText: '暂无观看记录',
        bottomInset: this.bottomInset(),
        cardClick: (card: FqDramaHistoryCardData): void => {
          this.openHistoryCard(card);
        },
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: appState.topRect + FQ_DRAMA_CHROME_HEIGHT + 4 })
  }

  /** 收藏频道：筛选 chips + 书架短剧/漫剧网格（3 列）。 */
  @Builder
  private FavoriteChannel() {
    Column() {
      Row({ space: 8 }) {
        ForEach(FQ_RECENT_FILTERS, (label: string, index: number) => {
          Text(label)
            .fontSize(12)
            .fontWeight(this.favoriteFilterIndex === index ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.favoriteFilterIndex === index ? Color.White : '#80FFFFFF')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
            .backgroundColor(this.favoriteFilterIndex === index ? '#33FFFFFF' : Color.Transparent)
            .onClick((): void => {
              this.selectFavoriteFilter(index);
            })
        }, (label: string) => label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      FqDramaHistoryGrid({
        cards: this.favoriteCards,
        lanes: 3,
        emptyText: this.favoriteEmptyText(),
        bottomInset: this.bottomInset(),
        cardClick: (card: FqDramaHistoryCardData): void => {
          this.openHistoryCard(card);
        },
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: appState.topRect + FQ_DRAMA_CHROME_HEIGHT + 4 })
  }

  /** 顶部悬浮层：搜索行（51）+ 频道条（38），状态栏下对齐。 */
  @Builder
  private TopChrome() {
    Column() {
      // 搜索行（fqapp _TopBar：半透明胶囊，漫剧频道提示语不同）
      Row() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(15)
            .fontColor(['#99FFFFFF'])
          Text(this.channelIndex === 2 ? '搜索漫剧' : '搜索短剧')
            .fontSize(13)
            .fontColor('#99FFFFFF')
        }
        .layoutWeight(1)
        .height(36)
        .borderRadius(18)
        .backgroundColor('#2E000000')
        .border({ width: 0.5, color: '#26FFFFFF' })
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.openSearch();
        })
      }
      .width('100%')
      .height(FQ_DRAMA_SEARCH_ROW_HEIGHT)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.openSearch();
      })
      // 频道条（fqapp：tab 16→24sp 动画 180ms easeOutCubic + 3dp 指示条）
      Scroll() {
        Row() {
          ForEach(FQ_DRAMA_CHANNELS, (label: string, index: number) => {
            this.ChannelTab(label, index)
          }, (label: string) => label)
        }
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height(FQ_DRAMA_STRIP_HEIGHT)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .padding({ top: appState.topRect })
    .layoutGravity(LocalizedAlignment.TOP)
  }

  /** 频道条单 tab（字号/指示条动画）。 */
  @Builder
  private ChannelTab(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(this.channelIndex === index ? 24 : 16)
        .fontWeight(this.channelIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.channelIndex === index ? Color.White : '#99FFFFFF')
        .maxLines(1)
        .animation({ duration: 180, curve: Curve.EaseOut })
        .height(32)
      Row()
        .width(16)
        .height(3)
        .borderRadius(2)
        .backgroundColor(this.channelIndex === index ? Color.White : Color.Transparent)
        .animation({ duration: 180, curve: Curve.EaseOut })
    }
    .padding({ left: 14, right: 14 })
    .alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      this.selectChannel(index);
    })
  }

  /** 选集半模态：FqStoryPanel（剧信息头 + 已看标记 + 30 集分页 + 选集切集）。 */
  @Builder
  private CatalogSheetBuilder() {
    FqStoryPanel({
      episodes: this.activeEpisodes,
      currentIndex: this.activeEpisodeIndex >= 0 ? this.activeEpisodeIndex : 0,
      watchedIds: FqWatchedStore.ids(this.activeContentId),
      seriesTitle: this.activeTitle(),
      seriesCover: this.activeCover(),
      seriesIntro: this.activeIntro(),
      episodeLabel: `共${this.activeEpisodes.length}集`,
      onSelectEpisode: (index: number): void => {
        this.closeCatalogSheet();
        this.loadActiveEpisode(index, -1);
      },
    })
  }

  /** 活动剧名（选集面板头部）。 */
  private activeTitle(): string {
    const item: FqMediaItem | null = this.activeItem();
    return item === null ? '' : item.title;
  }

  /** 活动剧封面（选集面板头部）。 */
  private activeCover(): string {
    const item: FqMediaItem | null = this.activeItem();
    return item === null ? '' : item.cover;
  }

  /** 活动剧简介（选集面板头部）。 */
  private activeIntro(): string {
    const item: FqMediaItem | null = this.activeItem();
    return item === null ? '' : item.intro;
  }

  /** 单张短剧卡（官方 cjc.xml：封面/渐变/手势层/进度条/信息层/加载/错误）。 */
  @Builder
  private DramaCard(item: FqMediaItem, index: number) {
    Stack() {
      // 封面（活动卡出画面后隐藏露出底层视频画面，fqapp firstFrame 语义）
      Image(FqBackend.get().resourceUrl(item.cover))
        .objectFit(ImageFit.Cover)
        .draggable(false)
        .backgroundColor(Color.Black)
        .visibility(index === this.activeIndex && this.videoStarted
          && this.episodeErrorMsg.length === 0
          ? Visibility.Hidden : Visibility.Visible)
      // 底部渐变遮罩（官方 yp：#01000000 → #80000000）
      Column()
        .width('100%')
        .height(280 + this.bottomInset())
        .linearGradient({
          angle: 180,
          colors: [['#01000000', 0], ['#80000000', 1]],
        })
        .layoutGravity(LocalizedAlignment.BOTTOM)
      // 手势层（活动卡）：单击播放/暂停（信息层/进度条在后，点击优先）
      if (index === this.activeIndex && this.episodeErrorMsg.length === 0) {
        Column()
          .width('100%')
          .height('100%')
          .onClick((): void => {
            this.togglePlay();
          })
      }
      // 细进度条（官方 cjt：活动卡专属，悬浮 Tab 栏之上）
      if (index === this.activeIndex && this.episodeErrorMsg.length === 0
        && this.activeEpisodeIndex >= 0) {
        Slider({
          value: this.seekPreview >= 0 ? this.seekPreview : this.player.state.position,
          min: 0,
          max: this.player.state.duration > 0 ? this.player.state.duration : 1,
          step: 1,
        })
          .width('100%')
          .height(16)
          .padding({ left: 16, right: 16 })
          .trackThickness(2)
          .trackColor('#4DFFFFFF')
          .selectedColor('#1AFFFFFF')
          .blockColor(Color.White)
          .blockSize({ width: 8, height: 8 })
          .layoutGravity(LocalizedAlignment.BOTTOM)
          .margin({ bottom: this.bottomInset() })
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.seekPreview = value;
            } else {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.player.seek(value);
                this.saveCurrentProgress();
              }
              this.seekPreview = -1;
            }
          })
      }
      // 信息层（官方 cj3：药丸行 + 剧名行 + 类型 chips + 简介行 + AI 声明）
      Column({ space: 10 }) {
        if (index === this.activeIndex) {
          // 药丸行：观看全集 + 选集（同款 _QuickCatalogButton 样式）
          Row({ space: 8 }) {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(12)
                .fontColor([Color.White])
              Text(this.pillLabel(item))
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .height(32)
            .padding({ left: 12, right: 12 })
            .borderRadius(20)
            .backgroundColor('#2E000000')
            .border({ width: 0.5, color: '#38FFFFFF' })
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.openPlayer();
            })
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                .fontSize(12)
                .fontColor([Color.White])
              Text('选集')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .height(32)
            .padding({ left: 12, right: 12 })
            .borderRadius(20)
            .backgroundColor('#2E000000')
            .border({ width: 0.5, color: '#38FFFFFF' })
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.openCatalogSheet();
            })
          }
          .justifyContent(FlexAlign.Center)
        }
        Row()
          .width('100%')
          .onClick((): void => {
            this.openDetail();
          }) {
          Text(item.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#73000000' })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor(['#B3FFFFFF'])
        }
        // 类型 chips（fqapp：#33FFFFFF 底 + 0.5 #26FFFFFF 边框，最多 3 个）
        if (item.categories.length > 0) {
          Row({ space: 6 }) {
            ForEach(item.categories.slice(0, 3), (category: string) => {
              Text(category)
                .fontSize(11)
                .fontColor(Color.White)
                .padding({ left: 6, right: 6, top: 2.5, bottom: 2.5 })
                .borderRadius(4)
                .backgroundColor('#33FFFFFF')
                .border({ width: 0.5, color: '#26FFFFFF' })
            }, (category: string) => category)
          }
          .width('100%')
        }
        // 简介：活动卡「第N集丨」前缀，展开后纯简介全文
        if (item.intro.length > 0) {
          Row() {
            if (this.introExpanded(item)) {
              Text(item.intro)
                .fontSize(14)
                .lineHeight(18)
                .fontColor('#CCFFFFFF')
                .maxLines(20)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('收起')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .margin({ left: 8 })
            } else {
              Text(index === this.activeIndex
                ? `${this.episodeIntroText()}${item.intro}` : `第1集丨${item.intro}`)
                .fontSize(14)
                .lineHeight(18)
                .fontColor('#CCFFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('展开')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          .onClick((): void => {
            this.toggleIntroExpanded(item);
          })
        }
        // AI 声明（fqapp ai_usage_type）
        if (item.aiGenerated) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(13)
              .fontColor(['#99FFFFFF'])
            Text('作者声明：内容由AI生成')
              .fontSize(12)
              .fontColor('#99FFFFFF')
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .layoutGravity(LocalizedAlignment.BOTTOM)
      .padding({ left: 12, right: 12, bottom: this.bottomInset() + 16 })
      // 加载遮罩（官方 opening：目录/集流取流中）
      if (index === this.activeIndex && (this.directoryLoading || this.episodeLoading)) {
        Column({ space: 14 }) {
          CommonLoading()
          Text('视频加载中，请稍后')
            .fontSize(13)
            .fontColor('#B3FFFFFF')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#8C000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      // 错误遮罩（目录/集流失败：重试按层分派）
      if (index === this.activeIndex && this.episodeErrorMsg.length > 0) {
        Column({ space: 16 }) {
          Text(this.episodeErrorMsg)
            .fontSize(14)
            .fontColor('#B3FFFFFF')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('重试')
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor(Color.Transparent)
            .borderRadius(17)
            .border({ width: 1, color: '#80FFFFFF' })
            .padding({ left: 22, right: 22, top: 6, bottom: 6 })
            .onClick((): void => {
              this.retryActive();
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#8C000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    CommonNav({
      embedded: true,
      hideTitleBar: true,
      showBrandGradient: false,
      pageBackgroundColor: Color.Black,
      onShown: (): void => {
        this.onPageShown();
      },
    }) {
      this.pageContent()
    }
  }
}

/**
 * 首页排行榜卡片（原生 ArkUI 实现，替代 Canvas 立体书架）：
 * - 手机布局：大封面 + 名次角标 + 书名/作者/简介/在读人数的 Swiper 卡片，左右滑动切换；
 *   底部行对齐今日焦点同款：标语 + 指示点 + 页码；
 * - PC 侧边栏布局：卡片改多列网格（按实测宽度自适应 2~4 列、至多两行，
 *   每列约一张手机卡宽，不再单行拉满整屏；更多进「完整榜单」）；
 * - 榜单只随首页频道切换（短剧/漫剧 → 同名剧集榜，其余 → 默认榜）；
 * - 头部「完整榜单」入口；
 * - 数据链路：FqBackend.rankCatalog（30s TTL）→ rankBoard（首页榜单）→ FqRankEntry[]；
 * - 条目打开对齐 RankPage.openDetail（剧集走 seriesId，其余按书打开）。
 */

import { FqBackend, fqErrorMessage } from '../core/FqBackend';
import { FqHomeCache } from '../core/FqHomeCache';
import {
  FqRankBoard,
  FqRankCatalog,
  FqRankEntry,
  FqRankTab,
  fqEmptyRankCatalog,
  fqFormatCountInt,
} from '../model/FqModels';
import { fqPushBookOrDetail, ROUTE_RANK } from '../model/FqNavModels';
import { NavPathUtils } from '../utils/NavPathUtils';
import { useSidebarLayout } from '../utils/BreakpointUtils';
import { CommonLoading } from './CommonCom';
import { appState } from '../entryability/AppState';
import { FqColorUtils } from '../utils/FqColorUtils';

/** 卡片封面固定尺寸（3:4 比例上下留裕）。 */
const FQ_RANK_COVER_WIDTH: number = 106;
const FQ_RANK_COVER_HEIGHT: number = 148;
/** 底部指示点最多渲染数（超出走以当前页为锚的滑动窗口，防止溢出屏幕）。 */
const FQ_RANK_MAX_DOTS: number = 7;
/** PC 多列网格：列间/行间距（vp）。 */
const FQ_RANK_GRID_GAP_X: number = 16;
const FQ_RANK_GRID_GAP_Y: number = 14;
/** PC 多列网格：单列目标宽度（≈ 手机卡宽，vp）。 */
const FQ_RANK_GRID_COLUMN_WIDTH: number = 360;
/** PC 多列网格：启用多列的最小实测宽度与列数上限（左右留白 20×2 计入）。 */
const FQ_RANK_GRID_MIN_WIDTH: number = 760;
const FQ_RANK_GRID_MAX_COLUMNS: number = 4;

@ComponentV2
export struct FqHomeRank {
  /** 首页当前频道名（推荐/小说/短剧/漫剧/漫画/听书）：短剧/漫剧频道自动跟随对应剧集榜。 */
  @Param channelLabel: string = '';
  @Local entries: FqRankEntry[] = [];
  @Local boardIndex: number = 0;
  /** Swiper 当前页（0 基）。 */
  @Local current: number = 0;
  @Local loading: boolean = true;
  @Local errorMsg: string = '';
  /** 实测内容宽（vp，onAreaChange 捕获；0 = 未测量）。PC 多列列数据此自适应。 */
  @Local areaWidthVp: number = 0;
  private catalog: FqRankCatalog = fqEmptyRankCatalog();
  private loadToken: number = 0;

  aboutToAppear(): void {
    FqHomeCache.init(getContext(this));
    // 冷启动：有持久化目录/榜单直接展示（不自动刷新，对齐首页频道列表缓存策略）；
    // 切换首页频道时触发网络刷新并回写缓存。
    const cachedCatalog: FqRankCatalog | null = FqHomeCache.loadRankCatalog();
    if (cachedCatalog !== null && !cachedCatalog.isEmpty) {
      this.catalog = cachedCatalog;
      this.boardIndex = this.preferredTabIndex();
      const tab: FqRankTab = this.catalog.tabs[this.boardIndex];
      if (tab !== undefined) {
        const cachedEntries: FqRankEntry[] =
          FqHomeCache.loadRankBoard(this.catalog.rankId, tab.algo, this.categoryIdOf(tab));
        if (cachedEntries.length > 0) {
          this.entries = cachedEntries;
          this.current = 0;
          this.loading = false;
          return;
        }
      }
    }
    this.bootstrap();
  }

  build() {
    Column() {
      this.HeaderRow()
      if (this.loading && this.entries.length === 0) {
        Column({ space: 12 }) {
          CommonLoading({ sizeValue: 24, loadColor: appState.accentColor })
          Text('正在加载榜单')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .padding({ top: 40, bottom: 40 })
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0 && this.entries.length === 0) {
        Column({ space: 12 }) {
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
            .textAlign(TextAlign.Center)
          Button('重试')
            .backgroundColor(appState.accentColor)
            .onClick((): void => {
              this.bootstrap();
            })
        }
        .width('100%')
        .padding({ top: 36, bottom: 36 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.entries.length > 0) {
        if (this.rankColumns() >= 2) {
          // PC 侧边栏布局：多列网格（宽屏不再单行拉满；无翻页/指示点）
          this.RankGrid()
        } else {
          this.SwiperCard()
          this.FooterRow()
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      // Area.width 运行时为 vp 数值，先归一化
      const widthVp: number = typeof newArea.width === 'number' ? newArea.width : 0;
      if (widthVp > 0) {
        this.areaWidthVp = widthVp;
      }
    })
  }

  /** 区块头：accent 竖条 + 排行榜 + 当前榜单名 + 「完整榜单」入口。 */
  @Builder
  private HeaderRow() {
    Row({ space: 8 }) {
      Column()
        .width(4)
        .height(18)
        .borderRadius(2)
        .backgroundColor(appState.accentColor)
      Text('排行榜')
        .fontSize(18)
        .fontWeight(800)
        .fontColor($r('sys.color.font_primary'))
      if (this.currentTabName().length > 0) {
        Text(this.currentTabName())
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      Blank()
      Row({ space: 2 }) {
        Text('完整榜单')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([$r('sys.color.icon_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        NavPathUtils.push(ROUTE_RANK);
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** 排行榜卡片：大封面 + 信息列（手机 Swiper 单页与 PC 多列网格共用），点击直达详情。 */
  @Builder
  private RankCard(entry: FqRankEntry, index: number) {
    Row({ space: 13 }) {
      this.CoverImage(entry)
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          Text(`NO.${this.pad2(index + 1)}`)
            .fontSize(10.5)
            .fontWeight(600)
            .fontColor(appState.accentColor)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(999)
            .backgroundColor(FqColorUtils.withOpacity(appState.accentColor, 0.14))
          if (entry.readCount > 0) {
            Text(`${fqFormatCountInt(entry.readCount)}人在读`)
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
          }
        }
        .alignItems(VerticalAlign.Center)

        Text(entry.title)
          .fontSize(16.5)
          .fontWeight(700)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(entry.metaLabel)
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (entry.abstractText.length > 0) {
          Text(entry.abstractText)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
            .layoutWeight(1)
        } else {
          Blank()
        }

        Row({ space: 2 }) {
          Text('查看详情')
            .fontSize(11)
            .fontColor(appState.accentColor)
          SymbolGlyph($r('sys.symbol.arrow_up_right'))
            .fontSize(12)
            .fontColor([appState.accentColor])
        }
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .height(FQ_RANK_COVER_HEIGHT)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(FQ_RANK_COVER_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.openEntry(index);
    })
  }

  /** 手机布局：Swiper 每页一卡（左右滑动切换）。 */
  @Builder
  private SwiperCard() {
    Swiper() {
      ForEach(this.entries, (entry: FqRankEntry, index: number) => {
        Column() {
          this.RankCard(entry, index)
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }, (entry: FqRankEntry, index: number): string => `${entry.id}:${index}`)
    }
    .width('100%')
    .height(FQ_RANK_COVER_HEIGHT)
    .index(this.current)
    .loop(true)
    .autoPlay(false)
    .indicator(false)
    .duration(320)
    .cachedCount(1)
    .onAnimationStart((index: number, targetIndex: number, extraInfo: SwiperAnimationEvent)=>{
      this.getUIContext().animateTo({ duration: 250, curve: Curve.Smooth }, (): void => {
        this.current = targetIndex;
      });
    })
  }

  /** PC 侧边栏布局：排行榜多列网格（列数按实测宽自适应，至多两行，更多进「完整榜单」）。 */
  @Builder
  private RankGrid() {
    Grid() {
      ForEach(this.gridEntries(), (entry: FqRankEntry, index: number) => {
        GridItem() {
          this.RankCard(entry, index)
        }
      }, (entry: FqRankEntry, index: number): string => `${entry.id}:${index}`)
    }
    .columnsTemplate(this.repeatFr(this.rankColumns()))
    .rowsTemplate(this.repeatFr(this.gridRowCount()))
    .columnsGap(FQ_RANK_GRID_GAP_X)
    .rowsGap(FQ_RANK_GRID_GAP_Y)
    .width('100%')
    .height(this.gridRowCount() * FQ_RANK_COVER_HEIGHT
      + (this.gridRowCount() - 1) * FQ_RANK_GRID_GAP_Y)
    .padding({ left: 20, right: 20 })
  }

  /** PC 多列列数：仅侧边栏布局且实测够宽时启用（每列 ≈ 手机卡宽），2~4 列；
   *  手机/窄窗口恒 1 列 → 保持原单卡 Swiper。
   *  列数推导：n 列需 n×360 + (n-1)×16 ≤ 实测宽 - 40（网格左右留白 20×2）。 */
  private rankColumns(): number {
    if (!useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp)
      || this.areaWidthVp < FQ_RANK_GRID_MIN_WIDTH) {
      return 1;
    }
    const usable: number = this.areaWidthVp - 40 + FQ_RANK_GRID_GAP_X;
    const columns: number =
      Math.floor(usable / (FQ_RANK_GRID_COLUMN_WIDTH + FQ_RANK_GRID_GAP_X));
    return Math.max(2, Math.min(FQ_RANK_GRID_MAX_COLUMNS, columns));
  }

  /** PC 网格展示条目：列数 × 至多两行。 */
  private gridEntries(): FqRankEntry[] {
    return this.entries.slice(0, this.rankColumns() * 2);
  }

  /** PC 网格行数：条目不足整行时收成单行，不留空行占位。 */
  private gridRowCount(): number {
    const columns: number = this.rankColumns();
    const count: number = Math.min(this.entries.length, columns * 2);
    return Math.max(1, Math.ceil(count / columns));
  }

  /** '1fr 1fr …' 模板串（Grid columnsTemplate/rowsTemplate 用）。 */
  private repeatFr(count: number): string {
    const parts: string[] = [];
    for (let index: number = 0; index < count; index++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /** 封面（无图时 kind 图标占位），系统级柔和阴影。 */
  @Builder
  private CoverImage(entry: FqRankEntry) {
    if (entry.cover.length > 0) {
      Image(FqBackend.get().resourceUrl(entry.cover))
        .width(FQ_RANK_COVER_WIDTH)
        .height(FQ_RANK_COVER_HEIGHT)
        .borderRadius(12)
        .objectFit(ImageFit.Cover)
        .autoResize(true)
        .draggable(false)
        //.shadow(ShadowStyle.OUTER_DEFAULT_MD)
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(26)
          .fontColor([$r('sys.color.icon_tertiary')])
      }
      .width(FQ_RANK_COVER_WIDTH)
      .height(FQ_RANK_COVER_HEIGHT)
      .borderRadius(12)
      .backgroundColor($r('sys.color.comp_background_secondary'))
      .justifyContent(FlexAlign.Center)
      .shadow(ShadowStyle.OUTER_DEFAULT_MD)
    }
  }

  /** 底部行（对齐今日焦点：左标语 + 右指示点/页码）。 */
  @Builder
  private FooterRow() {
    Row({ space: 8 }) {
      Text('好书在榜，人气之选')
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      Row({ space: 5 }) {
        ForEach(this.dotIndices(), (index: number) => {
          Column()
            .width(index === this.current ? 16 : 4)
            .height(4)
            .borderRadius(2)
            .backgroundColor(index === this.current ? appState.accentColor
              : $r('sys.color.comp_divider'))
        }, (index: number): string => `${index}`)
      }
      .alignItems(VerticalAlign.Center)
      Text(this.pageLabel())
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 20, right: 20, top: 10 })
  }

  /** 首页频道切换 → 排行榜跟随（目录就位后生效；未就位时 bootstrap 会按频道选榜）。 */
  @Monitor('channelLabel')
  private onChannelChange(): void {
    if (this.catalog.isEmpty) {
      return;
    }
    const next: number = this.preferredTabIndex();
    if (next !== this.boardIndex) {
      const token: number = ++this.loadToken;
      this.boardIndex = next;
      this.current = 0;
      this.loadBoard(token);
    }
  }

  /**
   * 频道 → 榜单 tab 映射：短剧/漫剧频道定位同名剧集榜，其余频道回到默认榜 0。
   */
  private preferredTabIndex(): number {
    const tabs: FqRankTab[] = this.catalog.tabs;
    const wantDrama: string =
      this.channelLabel.indexOf('短剧') >= 0 ? '短剧'
        : (this.channelLabel.indexOf('漫剧') >= 0 ? '漫剧' : '');
    if (wantDrama.length > 0) {
      for (let i: number = 0; i < tabs.length; i++) {
        if (tabs[i].name.indexOf(wantDrama) >= 0) {
          return i;
        }
      }
      return 0;
    }
    return 0;
  }

  /** 目录加载 + 首个榜单装载（对齐 RankPage.bootstrap）。 */
  private async bootstrap(): Promise<void> {
    const token: number = ++this.loadToken;
    this.loading = true;
    this.errorMsg = '';
    try {
      await FqBackend.get().start(getContext(this));
      const catalog: FqRankCatalog = await FqBackend.get().rankCatalog();
      if (token !== this.loadToken) {
        return;
      }
      if (catalog.isEmpty) {
        this.errorMsg = '排行榜暂时不可用';
        return;
      }
      this.catalog = catalog;
      this.boardIndex = this.preferredTabIndex();
      await this.loadBoard(token);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      this.errorMsg = fqErrorMessage(error);
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
      }
    }
  }

  /** 当前榜单装载（默认分类；原榜单保留展示直至新榜单就位）。 */
  private async loadBoard(token: number): Promise<void> {
    const tab: FqRankTab = this.catalog.tabs[this.boardIndex];
    if (tab === undefined) {
      return;
    }
    const categoryId: number = this.categoryIdOf(tab);
    try {
      const board: FqRankBoard = await FqBackend.get().rankBoard(
        this.catalog.rankId,
        tab.algo,
        categoryId,
        0,
        1,
        tab.genreTab,
        tab.forcedKind,
      );
      if (token !== this.loadToken) {
        return;
      }
      this.entries = board.entries;
      this.current = 0;
      // 回写持久化缓存（目录 + 榜单内容），供下次冷启动秒显
      FqHomeCache.saveRankCatalog(this.catalog);
      FqHomeCache.saveRankBoard(this.catalog.rankId, tab.algo, categoryId, this.entries);
    } catch (error) {
      if (token !== this.loadToken) {
        return;
      }
      if (this.entries.length === 0) {
        this.errorMsg = fqErrorMessage(error);
      }
    }
  }

  /** 榜单分类：剧集榜 0（genre_tab 区分），书籍榜取默认分类。 */
  private categoryIdOf(tab: FqRankTab): number {
    if (tab.isDrama) {
      return 0;
    }
    return this.catalog.categories.length > 0 ? this.catalog.categories[0].id : 0;
  }

  /** 打开条目（对齐 RankPage.openDetail：剧集走 seriesId，其余按书打开）。 */
  private openEntry(index: number): void {
    if (index < 0 || index >= this.entries.length) {
      return;
    }
    const entry: FqRankEntry = this.entries[index];
    if (entry.kind === 'video' || entry.kind === 'manju') {
      fqPushBookOrDetail(entry.seriesId.length > 0 ? entry.seriesId : entry.id, entry.kind,
        entry.title, entry.cover);
      return;
    }
    fqPushBookOrDetail(entry.id, 'book', entry.title, entry.cover);
  }

  private currentTabName(): string {
    if (this.boardIndex >= 0 && this.boardIndex < this.catalog.tabs.length) {
      return this.catalog.tabs[this.boardIndex].name;
    }
    return '';
  }

  /** 底部页码：01 / 12。 */
  private pageLabel(): string {
    const total: number = this.entries.length;
    if (total === 0) {
      return '00 / 00';
    }
    const shown: number = Math.min(total, Math.max(0, this.current) + 1);
    return `${this.pad2(shown)} / ${this.pad2(total)}`;
  }

  /** 指示点下标窗口：总数不超上限全量展示；超限以当前页为锚滑动（靠前/靠尾时对齐边缘），
   *  防止条目过多的榜单把点列撑出屏幕。 */
  private dotIndices(): number[] {
    const total: number = this.entries.length;
    if (total <= FQ_RANK_MAX_DOTS) {
      const all: number[] = [];
      for (let i: number = 0; i < total; i++) {
        all.push(i);
      }
      return all;
    }
    let start: number = this.current - Math.floor(FQ_RANK_MAX_DOTS / 2);
    if (start < 0) {
      start = 0;
    }
    if (start + FQ_RANK_MAX_DOTS > total) {
      start = total - FQ_RANK_MAX_DOTS;
    }
    const window: number[] = [];
    for (let i: number = 0; i < FQ_RANK_MAX_DOTS; i++) {
      window.push(start + i);
    }
    return window;
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}

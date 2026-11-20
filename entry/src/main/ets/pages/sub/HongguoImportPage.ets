/**
 * 导入红果云端收藏页（备份与恢复-其他来源）：
 * - 登录：扫码弹窗（DialogManager.ShowHongguoQrLogin，自包含取码/倒计时/轮询 +
 *   底部刷新，确认回传 cookie）；手机验证码登录暂被红果滑块风控拦截，UI 未开放
 *   （协议与服务层保留，修复后另行恢复）；
 * - 读取：POST /api/v1/account/hongguo/favorites（本地签名请求云端收藏，归一化返回）；
 * - 持久化：登录 cookie 与最近一次收藏预览存 filesDir（FqHongguoSessionStore），
 *   重进页面不丢登录态与预览；
 * - 从历史文件导入：选择本页导出的收藏 JSON 解析预览；「导出收藏文件」把
 *   当前收藏列表存到 Download 目录（不含登录凭证），可传其他设备导入；
 * - 结果就地预览（统计 + 前 6 部），确认后合并到本机书架（只补缺失，可重复导入）；
 * - busy 期间禁用操作，读取可取消；标题栏菜单可退出登录（清除本机登录态，不影响已导入数据）。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { TitleBarContentOptions } from '@kit.UIDesignKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarMenuOptions } from '../../model/FqNavModels';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqShelfStore } from '../../core/FqShelfStore';
import { fqExportDirName, fqExportTextFile } from '../../core/FqCacheExport';
import {
  FqHongguoFavorite,
  FqHongguoImportService,
  FqHongguoMergeResult,
  FqHongguoSavedSession,
  FqHongguoSessionStore,
} from '../../core/FqHongguoImport';

/** 顶部内容起始偏移（标题栏下方）。 */
const FQ_HONGGUO_IMPORT_TOP_INSET: number = 56;
/** 导入文件大小上限（与番茄导入页一致）。 */
const FQ_HONGGUO_IMPORT_MAX_BYTES: number = 16 * 1024 * 1024;

/** 两位补零。 */
function fqHongguoImportPad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 毫秒时间戳 → 'yyyy-MM-dd'。 */
function fqHongguoImportDate(ms: number): string {
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${fqHongguoImportPad(date.getMonth() + 1)}-${fqHongguoImportPad(date.getDate())}`;
}

/** 导出文件名时间戳（yyyyMMdd_HHmmss，与番茄导入页一致）。 */
function fqHongguoImportFileStamp(now: Date): string {
  return `${now.getFullYear()}${fqHongguoImportPad(now.getMonth() + 1)}${fqHongguoImportPad(now.getDate())}` +
    `_${fqHongguoImportPad(now.getHours())}${fqHongguoImportPad(now.getMinutes())}${fqHongguoImportPad(now.getSeconds())}`;
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
  /** 登录 cookie（内存持有，filesDir 持久化）。 */
  private cookie: string = '';
  /** 非空 = 进行中（登录/读取），期间禁用全部操作。 */
  @Local busy: string = '';
  /** busy 可取消（读取阶段显示取消键）。 */
  @Local cancellable: boolean = false;
  /** 就地结果/错误消息。 */
  @Local message: string = '';
  @Local messageIsError: boolean = false;
  /** 红果账号登录态（标题栏图标区分）。 */
  @Local loggedIn: boolean = false;
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
    // 扫码弹窗未关先关（弹窗自含轮询，宿主页面销毁即无回调对象）
    if (DialogManager.dialogChangeKey === '红果扫码登录') {
      DialogManager.CloseDialog();
    }
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
            this.ActionRow($r('sys.symbol.person_crop_circle_fill'), '#FF3B82F6', '从红果账号读取',
              this.loggedIn ? '已登录红果账号，点此重新读取云端收藏'
                : '扫码登录红果账号，读取云端收藏的短剧与漫剧', (): void => {
                  if (this.loggedIn) {
                    this.runFetch(this.cookie);
                  } else {
                    this.openQrLogin();
                  }
                })
            this.RowDivider()
            this.ActionRow($r('sys.symbol.doc_plaintext'), '#FF10B981', '从历史文件导入',
              '选择本页导出的红果收藏 JSON 文件', (): void => {
                this.runFileImport();
              })
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
              Text('点「从红果账号读取」，在弹窗中扫码登录红果账号，' +
                '登录成功后会自动读取云端收藏的短剧与漫剧；\n\n' +
                '也可点「从历史文件导入」，选择本页「导出收藏文件」生成的 JSON 文件，' +
                '把收藏传到其他设备导入。\n\n' +
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

  /** 打开扫码登录弹窗（自包含取码/轮询，确认后回传 cookie 并自动读取收藏）。 */
  private openQrLogin(): void {
    if (this.busy.length > 0) {
      return;
    }
    this.message = '';
    this.messageIsError = false;
    DialogManager.ShowHongguoQrLogin((cookie: string): void => {
      this.cookie = cookie;
      this.loggedIn = true;
      this.persistSession();
      this.runFetch(cookie);
    });
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

  /** 文件导入：系统选择器 → 读取 → 解析 → 预览。 */
  private async runFileImport(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = '请选择导入文件…';
    this.message = '';
    this.messageIsError = false;
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['json'],
      });
      if (uris.length === 0) {
        this.message = '已取消选择';
        return;
      }
      this.busy = '正在读取文件…';
      const text: string = this.readImportFile(uris[0]);
      const favorites: FqHongguoFavorite[] = FqHongguoImportService.parseFavoritesFileText(text);
      this.favorites = favorites;
      if (this.cookie.length > 0) {
        this.persistSession();
      }
      this.messageIsError = false;
      this.message = `已从文件读取 ${favorites.length} 部收藏，确认后点「合并到本机书架」。`;
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '读取文件失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 导出前弹窗确认。 */
  private confirmExportFavorites(): void {
    const favorites: FqHongguoFavorite[] | null = this.favorites;
    if (this.busy.length > 0 || favorites === null || favorites.length === 0) {
      return;
    }
    DialogManager.ShowConfirm('导出收藏文件',
      `当前收藏列表将导出为 JSON 文件（不含登录凭证），保存到 Download/${fqExportDirName()} 目录；` +
        '传到其他设备后，可在本页通过「从历史文件导入」解析合并。',
      '导出', (): void => {
        this.runExportFavorites();
      });
  }

  /** 导出收藏列表 JSON 到下载目录（与番茄导入页导出采集文件同款）。 */
  private async runExportFavorites(): Promise<void> {
    const favorites: FqHongguoFavorite[] | null = this.favorites;
    if (favorites === null || favorites.length === 0 || this.busy.length > 0) {
      return;
    }
    this.busy = '正在导出收藏文件…';
    try {
      const name: string = `hongguo-favorites-${fqHongguoImportFileStamp(new Date())}.json`;
      await fqExportTextFile(getContext(this), name,
        FqHongguoImportService.encodeFavoritesFile(favorites));
      this.messageIsError = false;
      this.message = `收藏文件已保存到 Download/${fqExportDirName()}/${name}`;
    } catch (error) {
      const err = error as BusinessError;
      this.messageIsError = true;
      this.message = err.message.length > 0 ? err.message : '导出失败，请重试';
    } finally {
      this.busy = '';
    }
  }

  /** 读取导入文件（≤16MB），UTF-8 解码为文本。 */
  private readImportFile(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size <= 0 || stat.size > FQ_HONGGUO_IMPORT_MAX_BYTES) {
        throw new Error('导入文件超过 16 MB 或不可读');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false });
      return decoder.decodeWithStream(new Uint8Array(buffer), { stream: false });
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        // 关闭失败忽略
      }
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
        this.service.cancel();
        FqHongguoSessionStore.clear(getContext(this));
        this.cookie = '';
        this.loggedIn = false;
        this.favorites = null;
        this.messageIsError = false;
        this.message = '已退出红果账号，下次导入需重新登录。';
      });
  }

  /** 返回拦截：可取消的 busy 先取消。 */
  private handleBack(): boolean {
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

  /** 操作行间分割线（与番茄导入页一致）。 */
  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: 60, right: 12 })
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

  /** 导入预览卡内容：统计 + 前 6 部 + 说明 + 合并/导出按钮。 */
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

      Button('导出收藏文件')
        .fontSize(14)
        .fontColor(appState.accentColor)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: FqColorUtils.withOpacity(appState.accentColor, 0.5) })
        .height(38)
        .borderRadius(12)
        .width('100%')
        .enabled(this.busy.length === 0)
        .onClick((): void => {
          this.confirmExportFavorites();
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

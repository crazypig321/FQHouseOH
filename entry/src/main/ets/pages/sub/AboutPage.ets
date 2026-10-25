/**
 * 关于页（我的-关于我们入口）：
 * - 开发者：作者；
 * - 项目地址：仓库（占位）+ 原项目仓库（浏览器打开）；
 * - 软件版本：更新日志（sheet）/ 检查更新 / 代理下载新版本（开关：仅用于下载更新软件包）；
 * - 开源与条款：GPL3.0 协议、免责声明（sheet）；
 * - 三方库：三方库列表（sheet）；
 * - 其他：支持作者（sheet + 爱发电）。
 * 内容用 List + ForEach 分组卡片渲染（SectionHeader + 卡片，对齐设置页样式）。
 */

import { CommonNav } from '../../view/CommonNav';
import { CommonSheet, FqSheetOptions } from '../../view/CommonSheet';
import { FQ_ACCENT } from '../../view/CommonCom';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqAppSettingsStore } from '../../core/FqAppSettingsStore';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';

const FQ_ABOUT_TAG: string = 'FqAboutPage';
const FQ_ABOUT_TOP_INSET: number = 56;
/** 滚动内容末尾偏移：悬浮底栏 56 + 底部悬浮边距 28。 */
const FQ_ABOUT_BOTTOM_INSET: number = 84;
/** 行内分割线左右避让：左侧行 padding 14 + 图标块 34 + 间距 12，右侧对称一致。 */
const FQ_ROW_DIVIDER_INSET: number = 60;
const FQ_REPO_URL: string = 'https://github.com/crazypig321/FQHouseOH.git';
const FQ_ORIG_REPO_URL: string = 'https://github.com/ch6vip/fqapp';
const FQ_AUTHOR_URL: string = 'https://github.com/crazypig321';
const FQ_GPL_URL: string = 'https://www.gnu.org/licenses/gpl-3.0.html';

/** 关于页半模态种类（单 bindSheet 内切换内容，规避同节点多 bindSheet 互斥闪关）。 */
class FqAboutSheetKind {
  public static readonly none: string = '';
  public static readonly changelog: string = 'changelog';
  public static readonly license: string = 'license';
  public static readonly disclaimer: string = 'disclaimer';
  public static readonly libraries: string = 'libraries';
  public static readonly support: string = 'support';
}

/** 三方库条目（名称 + 许可证徽标 + 用途说明）。 */
class FqLibraryEntry {
  public readonly name: string;
  public readonly license: string;
  public readonly desc: string;

  constructor(name: string, license: string, desc: string) {
    this.name = name;
    this.license = license;
    this.desc = desc;
  }
}

/** 更新日志条目：version/date 用于分组标题展示，lines 为该版本日志正文行。 */
class FqChangelogEntry {
  public readonly version: string;
  public readonly date: string;
  public readonly lines: string[];

  constructor(version: string, date: string, lines: string[]) {
    this.version = version;
    this.date = date;
    this.lines = lines;
  }
}

const FQ_LIBRARIES: FqLibraryEntry[] = [
  new FqLibraryEntry('mpv-arkts', 'GPL-2.0+', 'HarmonyOS libmpv 绑定，视频与听书播放内核'),
  new FqLibraryEntry('libmpv / FFmpeg', 'GPL 兼容', '媒体解码与渲染，随 mpv-arkts 引入'),
  new FqLibraryEntry('fqapi', 'GPL-3.0', '本项目自带的 Rust 后端核心'),
];

/** 关于页通用行：彩色图标块 + 标题/副标题 + 右侧文案与箭头，onTap 可空（纯展示行）。 */
class FqAboutItem {
  public readonly icon: Resource;
  public readonly tint: string;
  public readonly title: string;
  public readonly subtitle: string;
  public readonly rightText: string;
  public readonly showChevron: boolean;
  public readonly onTap: (() => void) | null;
  /** 可选图片图标（作者头像等）：非空时替代 symbol 图标圆形展示。 */
  public imageIcon: Resource | null = null;
  /** 右侧开关（代替 chevron/trailing）：开启=代理，关闭=直连。 */
  public showSwitch: boolean = false;

  constructor(icon: Resource, tint: string, title: string, subtitle: string,
    rightText: string, showChevron: boolean, onTap: (() => void) | null) {
    this.icon = icon;
    this.tint = tint;
    this.title = title;
    this.subtitle = subtitle;
    this.rightText = rightText;
    this.showChevron = showChevron;
    this.onTap = onTap;
  }

  public performTap(): void {
    const tap: (() => void) | null = this.onTap;
    if (tap !== null) {
      tap();
    }
  }
}

/** 关于页分组：小标题 + 行集合（ForEach 数据源）。 */
class FqAboutSection {
  public readonly title: string;
  public readonly items: FqAboutItem[];

  constructor(title: string, items: FqAboutItem[]) {
    this.title = title;
    this.items = items;
  }
}

@Builder
function fqAboutEmptyContent() {
}

/** 关于页分组卡片壳（对齐设置页 FqSettingsCard：comp_background_list_card + 深色描边）。 */
@ComponentV2
struct FqAboutCard {
  @BuilderParam content: () => void = fqAboutEmptyContent;

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
export struct AboutPage {
  private scroller: Scroller = new Scroller();
  /** bindSheet 显隐（独立于 activeSheet：关闭时内容保留至关闭动画结束）。 */
  @Local sheetVisible: boolean = false;
  /** 当前半模态内容种类。 */
  @Local activeSheet: string = FqAboutSheetKind.none;
  private sheetCloseToken: number = 0;
  @Local versionName: string = '1.0.0';
  /** 更新包代理下载开关（仅用于下载更新软件包：开=代理，关=直连）。 */
  @Local proxyDownload: boolean = false;
  private sections: FqAboutSection[] = [];
  /** 更新日志数据（按版本分组）。 */
  private changelogs: FqChangelogEntry[] = [];
  /** 当前展开的日志版本（空 = 全部收起，手风琴同时只展开一个）。 */
  @Local expandedVersion: string = '';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.versionName = info.versionName;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, FQ_ABOUT_TAG, `read versionName failed: ${JSON.stringify(err)}`);
    }
    this.buildChangelogs();
    this.expandedVersion = this.versionName;
    this.proxyDownload = FqAppSettingsStore.isUpdateProxyDownload();
    this.buildSections();
  }

  /** 更新日志数据（首个版本随包版本号）。 */
  private buildChangelogs(): void {
    const entries: FqChangelogEntry[] = [];
    entries.push(new FqChangelogEntry(this.versionName, '2026-10-25', [
      '全新 HarmonyOS 原生版本（ArkTS）',
      '小说 / 短剧 / 漫剧 / 漫画 / 听书聚合',
      '本地 Rust 后端内核，签名与解密在本地完成',
      'mpv 播放内核：视频、听书与倍速播放',
      '深色模式、后台播放与播控中心支持',
    ]));
    this.changelogs = entries;
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('关于', false),
      scroller: this.scroller,
    }) {
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
          this.AboutHeader()
        }

        ForEach(this.sections, (section: FqAboutSection) => {
          ListItem() {
            Column({ space: 12 }) {
              this.SectionHeader(section.title)
              FqAboutCard() {
                ForEach(section.items, (item: FqAboutItem, index: number) => {
                  if (index > 0) {
                    this.RowDivider()
                  }
                  this.AboutRow(item)
                }, (item: FqAboutItem) => item.title)
              }
            }
          }
        }, (section: FqAboutSection) => section.title)

        ListItem() {
          Text('仅限个人学习研究使用\n请遵守相关法律法规')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .textAlign(TextAlign.Center)
            .lineHeight(19)
            .width('100%')
            .padding({ top: 6, bottom: 10 })
        }
      }
      .padding({ left: 16, right: 16 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_ABOUT_TOP_INSET)
      .contentEndOffset(appState.bottomRect + FQ_ABOUT_BOTTOM_INSET)
      .bindSheet(this.sheetVisible, this.ActiveSheetBuilder(),
        FqSheetOptions((): void => {
          this.closeSheet();
        }, this.sheetHeight()))
    }
  }

  // ---------------------------------------------------------------------------
  // 分组数据（ForEach 数据源）
  // ---------------------------------------------------------------------------

  private buildSections(): void {
    const sections: FqAboutSection[] = [];
    const authorItem: FqAboutItem =
      new FqAboutItem($r('sys.symbol.person_fill'), '#FF8B5CF6', '作者', '', 'crazypig321', true,
        (): void => {
          this.openExternal(FQ_AUTHOR_URL);
        });
    authorItem.imageIcon = $r('app.media.crazypig321');
    sections.push(new FqAboutSection('开发者', [authorItem]));
    sections.push(new FqAboutSection('项目地址', [
      new FqAboutItem($r('sys.symbol.bookshelf'), '#FF3B82F6', '仓库', FQ_REPO_URL, '', true,
        (): void => {
          this.openExternal(FQ_REPO_URL);
        }),
      new FqAboutItem($r('sys.symbol.arrow_up_right'), '#FF0EA5E9', '原项目仓库', FQ_ORIG_REPO_URL, '', true,
        (): void => {
          this.openExternal(FQ_ORIG_REPO_URL);
        }),
    ]));
    const proxyItem: FqAboutItem =
      new FqAboutItem($r('sys.symbol.download'), '#FFEF5038', '代理下载新版本',
        '仅用于下载更新软件包，开启后经代理下载，关闭则直连', '', false, null);
    proxyItem.showSwitch = true;
    sections.push(new FqAboutSection('软件版本', [
      new FqAboutItem($r('sys.symbol.clock'), '#FF3B82F6', '更新日志', `当前版本 v${this.versionName}`, '', true,
        (): void => {
          this.openSheet(FqAboutSheetKind.changelog);
        }),
      new FqAboutItem($r('sys.symbol.arrow_clockwise'), '#FF10B981', '检查更新', '检查是否有新版本', '', true,
        (): void => {
          this.checkUpdate();
        }),
      proxyItem,
    ]));
    sections.push(new FqAboutSection('开源与条款', [
      new FqAboutItem($r('sys.symbol.textformat'), '#FF8B5CF6', '开源许可', 'GPL3.0 协议', '', true,
        (): void => {
          this.openSheet(FqAboutSheetKind.license);
        }),
      new FqAboutItem($r('sys.symbol.book_pages'), '#FFF43F5E', '免责声明', '使用前请仔细阅读', '', true,
        (): void => {
          this.openSheet(FqAboutSheetKind.disclaimer);
        }),
    ]));
    sections.push(new FqAboutSection('三方库', [
      new FqAboutItem($r('sys.symbol.store'), '#FF0EA5E9', '三方库列表', '本项目所使用到的三方库列表', '', true,
        (): void => {
          this.openSheet(FqAboutSheetKind.libraries);
        }),
    ]));
    sections.push(new FqAboutSection('其他', [
      new FqAboutItem($r('sys.symbol.hand_thumbsup'), '#FFF43F5E', '支持作者', '用爱发电，感谢每一份支持', '', true,
        (): void => {
          this.openSheet(FqAboutSheetKind.support);
        }),
    ]));
    this.sections = sections;
  }

  // ---------------------------------------------------------------------------
  // 主内容
  // ---------------------------------------------------------------------------

  /** 头部：应用图标 + 名称 + 版本 + 标语（fqapp About 页样式）。 */
  @Builder
  private AboutHeader() {
    Column({ space: 10 }) {
      Image($r('app.media.foreground'))
        .width(84)
        .height(84)
        .borderRadius(22)
        .objectFit(ImageFit.Cover)
      Text('FQHouseOH')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(`v${this.versionName}`)
        .fontSize(12.5)
        .fontColor($r('sys.color.font_secondary'))
      Text('小说 / 短剧 / 漫剧 / 漫画 / 听书聚合客户端')
        .fontSize(12.5)
        .fontColor($r('sys.color.font_tertiary'))
      Text('移植自 ch6vip 的开源项目 fqapp')
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .padding({ top: 4, bottom: 6 })
  }

  @Builder
  private SectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(3.5)
        .height(15)
        .borderRadius(2)
        .backgroundColor(FQ_ACCENT)
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
      .margin({ left: FQ_ROW_DIVIDER_INSET, right: 12 })
  }

  @Builder
  private AboutRow(item: FqAboutItem) {
    Row({ space: 12 }) {
      if (item.imageIcon !== null) {
        Image(item.imageIcon)
          .width(34)
          .height(34)
          .borderRadius(17)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else {
        Stack() {
          SymbolGlyph(item.icon)
            .fontSize(17)
            .fontColor([item.tint])
        }
        .width(34)
        .height(34)
        .borderRadius(10)
        .backgroundColor(FqColorUtils.withOpacity(item.tint, 0.12))
      }

      Column({ space: 3 }) {
        Text(item.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (item.subtitle.length > 0) {
          Text(item.subtitle)
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (item.rightText.length > 0) {
        Text(item.rightText)
          .fontSize(12.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      if (item.showSwitch) {
        Toggle({ type: ToggleType.Switch, isOn: this.proxyDownload })
          .selectedColor(FQ_ACCENT)
          .onChange((isOn: boolean): void => {
            this.proxyDownload = isOn;
            FqAppSettingsStore.setUpdateProxyDownload(isOn);
          })
      }
      if (item.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      item.performTap();
    })
  }

  // ---------------------------------------------------------------------------
  // 半模态
  // ---------------------------------------------------------------------------

  /** 单 bindSheet：按 activeSheet 切换半模态内容。 */
  @Builder
  private ActiveSheetBuilder() {
    if (this.activeSheet === FqAboutSheetKind.changelog) {
      this.ChangelogSheetBuilder()
    } else if (this.activeSheet === FqAboutSheetKind.license) {
      this.LicenseSheetBuilder()
    } else if (this.activeSheet === FqAboutSheetKind.disclaimer) {
      this.DisclaimerSheetBuilder()
    } else if (this.activeSheet === FqAboutSheetKind.libraries) {
      this.LibrariesSheetBuilder()
    } else if (this.activeSheet === FqAboutSheetKind.support) {
      this.SupportSheetBuilder()
    }
  }

  /** 更新日志分组头：版本号 + 日期 + 展开箭头，点击切换展开/收起。 */
  @Builder
  private ChangelogGroupHeader(entry: FqChangelogEntry) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(`v${entry.version}`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(entry.date)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
        .rotate({ angle: this.expandedVersion === entry.version ? 90 : 0 })
        .animation({ duration: 200, curve: Curve.Smooth })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick((): void => {
      this.toggleChangelog(entry.version);
    })
  }

  /** 更新日志 sheet：List + ListItemGroup 手风琴，一次只展开一个版本。 */
  @Builder
  private ChangelogSheetBuilder() {
    CommonSheet({
      sheetTitle: '更新日志',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List({ space: 10 }) {
        ForEach(this.changelogs, (entry: FqChangelogEntry) => {
          ListItemGroup({ header: this.ChangelogGroupHeader(entry) }) {
            if (this.expandedVersion === entry.version) {
              ListItem() {
                Column({ space: 8 }) {
                  ForEach(entry.lines, (line: string) => {
                    Text(`· ${line}`)
                      .fontSize(13.5)
                      .fontColor($r('sys.color.font_secondary'))
                      .lineHeight(21)
                  }, (line: string) => line)
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ top: 4, bottom: 12 })
              }
              .padding({ left: 16, right: 16 })
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          }
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(14)
        }, (entry: FqChangelogEntry) => entry.version)
      }
      .padding({ left: 20, right: 20, bottom: 24 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  private LicenseSheetBuilder() {
    CommonSheet({
      sheetTitle: '开源许可',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List({ space: 12 }) {
        ForEach([
          '本应用基于 GNU General Public License v3.0（GPL-3.0）协议开源。',
          '你可以自由地使用、复制、修改和分发本软件，但分发时必须提供完整源代码，且衍生作品必须同样以 GPL-3.0 协议发布。',
          '本软件按「现状」提供，不提供任何明示或暗示的担保。在适用法律允许的最大范围内，作者不对任何损失承担责任。',
          '完整协议文本请参阅：',
        ], (paragraph: string) => {
          ListItem() {
            Text(paragraph)
              .fontSize(13.5)
              .fontColor($r('sys.color.font_secondary'))
              .lineHeight(22)
          }
        }, (paragraph: string) => paragraph)
        ListItem() {
          Text(FQ_GPL_URL)
            .fontSize(13)
            .fontColor(FQ_ACCENT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => {
              this.openExternal(FQ_GPL_URL);
            })
        }
      }
      .padding({ left: 20, right: 20, bottom: 24 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  private DisclaimerSheetBuilder() {
    CommonSheet({
      sheetTitle: '免责声明',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List({ space: 12 }) {
        ForEach([
          '1. 本应用仅供个人学习、研究和技术交流使用，严禁用于任何商业用途或违法用途。',
          '2. 应用内的书籍、短剧、漫剧、漫画、听书等内容均来自第三方网络接口聚合，本应用不存储、不制作、不修改、不传播任何内容。',
          '3. 用户使用本应用所产生的一切行为及其后果，均由用户自行承担，与开发者无关。',
          '4. 若本应用侵犯了任何第三方权益，请通过原项目仓库 Issue 联系处理，收到反馈后将及时移除相关内容。',
          '5. 使用本应用即表示你已阅读并同意以上条款；请遵守你所在地区的相关法律法规。',
        ], (paragraph: string) => {
          ListItem() {
            Text(paragraph)
              .fontSize(13.5)
              .fontColor($r('sys.color.font_secondary'))
              .lineHeight(22)
          }
        }, (paragraph: string) => paragraph)
      }
      .padding({ left: 20, right: 20, bottom: 24 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  private LibrariesSheetBuilder() {
    CommonSheet({
      sheetTitle: '三方库列表',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List() {
        ForEach(FQ_LIBRARIES, (entry: FqLibraryEntry, index: number) => {
          ListItem() {
            Column() {
              if (index > 0) {
                Divider()
                  .strokeWidth(0.6)
                  .color($r('sys.color.comp_divider'))
              }
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Row({ space: 8 }) {
                    Text(entry.name)
                      .fontSize(14.5)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('sys.color.font_primary'))
                    Text(entry.license)
                      .fontSize(10.5)
                      .fontColor(FQ_ACCENT)
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(8)
                      .backgroundColor(FqColorUtils.withOpacity(FQ_ACCENT, 0.12))
                  }
                  Text(entry.desc)
                    .fontSize(11.5)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .padding({ top: 12, bottom: 12 })
              .width('100%')
            }
            .width('100%')
          }
        }, (entry: FqLibraryEntry) => entry.name)
      }
      .padding({ left: 20, right: 20, bottom: 24 })
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 支持作者：二维码卡片（musicfreeOH PaySupport 样式）。 */
  @Builder
  private SupportSheetBuilder() {
    CommonSheet({
      sheetTitle: '支持作者',
      showClose: true,
      closeClick: (): void => {
        this.closeSheet();
      },
    }) {
      List() {
        ListItem() {
          Column({ space: 16 }) {
            Text('如果你也喜欢 FQHouseOH 项目，欢迎打赏作者')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
            Column({ space: 5 }) {
              Image($r('app.media.erweima'))
                .width(140)
                .height(140)
                .borderRadius(10)
                .objectFit(ImageFit.Cover)
                .draggable(false)
              Text('微信 / 支付宝')
                .textAlign(TextAlign.Center)
                .fontSize(14)
                .fontColor($r('sys.color.font_tertiary'))
            }
            .borderRadius(12)
            .padding(12)
            .backgroundColor($r('sys.color.comp_background_list_card'))
          }
          .alignItems(HorizontalAlign.Center)
          .width('100%')
          .padding({ top: 10, bottom: 24 })
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 各半模态高度。 */
  private sheetHeight(): SheetSize | Length {
    switch (this.activeSheet) {
      case FqAboutSheetKind.changelog:
        return 440;
      case FqAboutSheetKind.license:
        return 500;
      case FqAboutSheetKind.disclaimer:
        return 480;
      case FqAboutSheetKind.libraries:
        return 460;
      case FqAboutSheetKind.support:
        return 420;
      default:
        return 600;
    }
  }

  // ---------------------------------------------------------------------------
  // 行为
  // ---------------------------------------------------------------------------

  /** 打开半模态：切换内容并置 isShow。 */
  private openSheet(kind: string): void {
    this.sheetCloseToken += 1;
    this.activeSheet = kind;
    this.sheetVisible = true;
  }

  /**
   * 关闭半模态：仅切 isShow，内容保留到下次 openSheet 再切换。
   * 标题栏（HDS menu）事件回调内同步改 isShow 会因重入渲染被丢弃，故延迟一拍。
   */
  private closeSheet(): void {
    const token: number = ++this.sheetCloseToken;
    setTimeout((): void => {
      if (token === this.sheetCloseToken) {
        this.sheetVisible = false;
      }
    }, 0);
  }

  /** 切换展开版本（手风琴，animateTo 驱动高度过渡）。 */
  private toggleChangelog(version: string): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.Linear }, (): void => {
      this.expandedVersion = this.expandedVersion === version ? '' : version;
    });
  }

  /** 检查更新（占位：当前无更新渠道，提示已是最新）。 */
  private checkUpdate(): void {
    this.getUIContext().getPromptAction().showToast({ message: '当前已是最新版本', duration: 1500 });
  }

  /** 用系统浏览器打开外部链接。 */
  private openExternal(url: string): void {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      return;
    }
    context.openLink(url, { appLinkingOnly: false }).catch((_error: BusinessError): void => {
      this.getUIContext().getPromptAction().showToast({ message: '打开链接失败', duration: 1500 });
    });
  }
}

/**
 * 更新日志半模态内容（供关于页与 Index 共用）：
 * - FqChangelogEntry / FQ_CHANGELOGS：更新日志数据（每次发版在此追加条目，新版本在前）；
 * - FqChangelogSheet：List + ListItemGroup 手风琴（一次只展开一个版本），
 *   CommonSheet 壳（标题「更新日志」+ 关闭按钮），经 bindSheet 展示；
 *   Index 在版本升级 / 首次启动时自动弹出（FqAppSettingsStore.changelogShownVersion 判定）。
 */

import { CommonSheet } from './CommonSheet';

/** 更新日志条目：version/date 用于分组标题展示，lines 为该版本日志正文行。 */
export class FqChangelogEntry {
  public readonly version: string;
  public readonly date: string;
  public readonly lines: string[];

  constructor(version: string, date: string, lines: string[]) {
    this.version = version;
    this.date = date;
    this.lines = lines;
  }
}

/** 全部版本更新日志（新版本在前）。 */
const FQ_CHANGELOGS: FqChangelogEntry[] = [
  new FqChangelogEntry('1.0.5', '2026-10-30', [
    '新增离线朗读：正文由小艺语音引擎本地合成，无网络也能听书，离线音色后台播放同样有实况窗胶囊与播控中心控制',
    '新增「离线朗读」设置页：朗读音色自由切换（未安装可下载，点选即时生效），朗读语速 0.75 ~ 2 档',
    '自定义主题字色新增色板：取色器新增的字色自动保存进字色列表直接选用（新色在前），「添加」卡片固定第一位不随滚动',
    '「上一章」直接切换上一章，不再先回到本章开头（应用内与播控中心一致）',
  ]),
  new FqChangelogEntry('1.0.4', '2026-10-29', [
    '新增 PC 与大屏适配：标题栏与窗口合一（拖拽移动窗口）、左侧可折叠导航栏常驻，二级页内容区切换；视频全屏观看进入系统沉浸全屏（隐藏标题栏 / Dock / 侧边栏），退出还原窗口；手机端不变',
    'PC 布局路由页进入 / 退出统一渐隐转场，不再横滑',
    '首页 / 书架网格宽屏自动加列铺满（3 → 6 列），书架列表 PC 宽屏一排两列，窄窗口 / 手机保持原列数',
    '新增书架进度标识：整书阅读百分比角标，短剧 / 漫剧已看进度同步显示，随备份导出恢复',
    '新增「点击直达阅读」开关：点小说 / 漫画跳过详情页，从上次进度直接开读',
    '新增音量键翻页开关：阅读设置 / 漫画设置内开启，音量键上 / 下键控制翻页',
    '自定义阅读主题（含背景图）加入备份与恢复',
    '新增更新提醒：静默检查新版本，设置页「关于」条目与关于页「检查更新」显示红点与新版本号',
    '上下滚动阅读支持左右屏幕分别控制滚动',
    '修复漫画翻页偶发闪烁、图片加载失败的问题',
    '修复上下翻页切换章节时的切段异常问题',
    '修复番茄账号导入登录页被屏幕遮挡的问题（右上角增加中置按钮），导入后书架正常显示进度标识',
    '完善弹窗与 sheet 的前景模糊，二级弹层互不影响；番茄采集信息支持导出',
  ]),
  new FqChangelogEntry('1.0.3', '2026-10-28', [
    '新增备份与恢复：导出收藏、浏览、收听、阅读进度、已看剧集与外观、阅读设置，换机合并恢复不覆盖本机',
    '新增 WebDAV 云备份：一键云端备份 / 恢复，独立备份文件自动清理超限旧备份，支持退出时自动备份',
    '新增导入番茄书架：网页登录番茄账号采集书架、文件夹与阅读进度合并到本机，支持导入采集 JSON 文件',
    '新增阅读自定义主题：多张背景图横滑选择，长按编辑名称 / 字色 / 字号 / 字体 / 行距，参数随备份导出恢复',
    '设置页四类缓存入口合并为「缓存与管理」页，书架页「离线缓存」菜单同步改跳该页',
    '阅读设置新增「段评」开关：关闭后不显示段评气泡与评论数，保位重排不错位',
    '主题色自定义颜色改为弹窗内 HSB 取色器选择',
    '修复上下滚动模式调整字号 / 行距后正文不实时刷新的问题',
    '修复仿真 / 覆盖翻页正文右侧缺一角的问题：满行行尾逐行补齐，两端对齐',
    '修复仿真 / 覆盖翻页部分页面底部缺段落、留大片空白的问题',
    '修复调整字号 / 行距后页底文字被裁切的问题',
    '仿真 / 覆盖翻页排版引擎重做：逐行断行渲染 + 行尾字距补齐，保位重排不错位',
  ]),
  new FqChangelogEntry('1.0.2', '2026-10-27', [
    '新增日志中心：应用 / 核心双源日志查看、筛选、搜索、复制、导出',
    '新增主题色：跟随系统 + 8 种预设色，深浅模式自动适配，即时生效',
    '修复漫画多章节显示同一套图片的问题（自动更换失效设备并重试）',
    '修复评论区总数显示偏小的问题',
    '修复切换阅读主题时背景图与主题底色叠加渲染的问题',
    '听书「边听边读」从当前段落起播并显示封面，后台播放接入长时任务',
    '视频播放支持横滑快进 / 快退，横屏选集菜单分段展示',
    '视频评论区接入剧评接口，菜单选中态统一系统对勾图标',
  ]),
  new FqChangelogEntry('1.0.1', '2026-10-26', [
    '本地书封面自动匹配、「本地书籍」角标，重复导入同一本书保留阅读进度',
    '修复短剧 / 听视频后台播放偶发中断、播控中心会话异常的问题',
    '修复全本导出 TXT 再导入章节丢失、本地书目录缺章的问题',
    '修复清除所有数据未清空搜索历史、排行榜切换分类偶发白屏的问题',
    '修复评论「作者」标识错乱：书评正确显示本书作者标识，段评 / 章评不再误标其他书作者',
    '启动 / 加载提速、接口并发优化、段评分页懒加载',
  ]),
  new FqChangelogEntry('1.0.0', '2026-10-26', [
    '全新 HarmonyOS 原生版本（ArkTS），UI 大框架对齐 musicfreeOH',
    '小说 / 漫画阅读器：上下翻页、段评气泡、章评、真实阅读进度与统计',
    '短剧 / 漫剧：mpv 内核视频播放、弹幕、倍速、后台播放、听视频模式',
    '听书：多音色 TTS、倍速、播控中心 / 实况窗、播控球、边听边读高亮',
    '缓存管理：章节 / 剧集（可导出）/ 听书 / 漫画离线缓存，清除所有数据',
    '书架收藏、聚合搜索、榜单、作者主页、我的页面',
    '本地 Rust 后端内核，签名与解密在本地完成',
    '深色模式三档切换、沉浸光感材质',
    '设置中心：更新日志、检查更新（代理下载更新包）、开源许可',
  ]),
];

@ComponentV2
export struct FqChangelogSheet {
  /** 打开时自动展开的版本（空 = 全部收起）。 */
  @Param focusVersion: string = '';
  /** 关闭按钮回调（由使用方绑定自身 sheet 关闭逻辑）。 */
  @Event closeClick: () => void = (): void => {
  };
  /** 当前展开的日志版本（空 = 全部收起，手风琴同时只展开一个）。 */
  @Local expandedVersion: string = '';

  aboutToAppear(): void {
    this.expandedVersion = this.focusVersion;
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

  build() {
    CommonSheet({
      sheetTitle: '更新日志',
      showClose: true,
      closeClick: (): void => {
        this.closeClick();
      },
    }) {
      List({ space: 10 }) {
        ForEach(FQ_CHANGELOGS, (entry: FqChangelogEntry) => {
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

  /** 切换展开版本（手风琴，animateTo 驱动高度过渡）。 */
  private toggleChangelog(version: string): void {
    this.getUIContext().animateTo({ duration: 250, curve: Curve.Linear }, (): void => {
      this.expandedVersion = this.expandedVersion === version ? '' : version;
    });
  }
}

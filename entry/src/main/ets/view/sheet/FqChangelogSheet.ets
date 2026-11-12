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
  new FqChangelogEntry('1.1.5', '2026-11-13', [
    '新增视频默认高清播放：默认清晰度升级为最高可用档（1080P 封顶），手动选择的清晰度跨集记忆并随备份同步',
    '新增首页排行榜卡片：左右滑动切换、点击直达详情；设置 → 外观「首页样式」可选今日焦点 / 排行榜 / 共存，随备份同步',
    '新增书架筛选与自定义分组：筛选支持类目（小说/短剧/漫剧/漫画/听书）、状态、来源任意组合；分组标签行点击过滤、长按重命名/删除；多选底栏「分组」批量归组；分组管理支持新建与排序（上移/下移/跳转）；随备份同步',
    '修复听书与视频先后切换后后台无播控中心/胶囊的问题',
    '修复退出播放页后偶发后台无胶囊/播控中心的问题',
    '修复视频后台胶囊与播控中心封面缺失的问题',
    '修复自定义字体下仿真/横滑翻页个别行行尾吞字的问题',
    '修复书架批量操作底栏「移出书架」按钮文字显示不全的问题',
    '修复画中画小窗黑边的问题：小窗比例改为实时跟随片源比例',
    '优化离线缓存清晰度：边看边缓存与手动缓存跟随当前播放清晰度档下载（默认最高高清档，手动选过 720P 等低档则按低档缓存）；已缓存集播放时清晰度按钮显示缓存文件的实际档名（如 1080P），不再只显示「默认」（本地缓存文件无法切换清晰度，与原版离线回放单档语义一致）',
  ]),
  new FqChangelogEntry('1.1.4', '2026-11-11', [
    '新增红果弹幕源：短剧播放页弹幕接入红果弹幕池，未匹配时自动回退番茄弹幕源',
    '新增启动默认展示页：设置 → 外观可选首页 / 书架 / 我的 / 设置，随备份同步',
    '本地后端版本参数外置到随包 config.json，对齐原版 fqapp',
    '修复红果弹幕部分表情显示为文字的问题',
    '修复短剧/漫剧偶发「视频下载失败」的问题',
  ]),
  new FqChangelogEntry('1.1.3', '2026-11-10', [
    '新增书架排序：名称 / 进度 / 最近观看 / 加入时间各正倒序（共 8 种）',
    '书架视图方式收进「视图方式」二级菜单',
    '弹幕正文官方表情渲染',
    'WebDAV 页新增服务器连通性状态点',
    '首页今日焦点封面改为顶部锚定裁切并升级 1080px 高清源',
    '修复分享缩略图模糊的问题',
    '修复非全屏播放页弹幕稀疏的问题',
    '修复片尾弹幕被截断的问题',
    '修复暂停播放后弹幕消失、恢复播放不回的问题',
    '修复开启段评后阅读页页底大片空白的问题',
    '修复段评数超过 99 时不显示气泡图标的问题',
  ]),
  new FqChangelogEntry('1.1.2', '2026-11-09', [
    '新增应用流转（应用接续）：阅读 / 听书 / 漫画 / 视频 / 听视频五场景可流转，进度精确保留',
    '新增分享直达链接：五场景分享链接直达对应页面，可同步分享方进度',
    '新增书架分享：多选「分享」与「分享书架」生成书单链接，接收方一键导入书架',
    '新增碰一碰与隔空手势分享',
    '分享预览缩略图改为内容封面',
    '新增本地书文件分享与打开导入（.txt / .epub）',
    '标题栏分享 / 流转按钮标签中文化',
    '短剧 / 漫剧详情页接入剧评，剧评回复支持展开',
  ]),
  new FqChangelogEntry('1.1.1', '2026-11-08', [
    '新增播放页上下滑切集（非全屏播放区 / 全屏中段区域）',
    '新增阅读页与播放页隔空手势翻页 / 切集',
    '播放设置「解码方式」改为菜单点选',
    '新增评论区回复展开（书评 / 章评 / 漫评 / 段评）',
    '评论 / 回复配图点击全屏放大',
    '章评 / 段评 / 回复正文官方表情渲染',
    '播放设置（弹幕样式 / 解码方式 / 边看边缓存 / 画中画 / 朗读音色语速）加入备份与恢复',
    '修复偶发点击章评 / 段评显示空白的问题',
    '修复配图查看器双指缩放图片乱飞、关闭后页面无法操作的问题',
    '修复部分短剧（VVC / H.266 编码）无法播放的问题',
  ]),
  new FqChangelogEntry('1.1.0', '2026-11-08', [
    '新增听书进度同步阅读：听书位置自动同步到阅读进度，续读无缝衔接',
    '修复部分章节在线听书出现电流杂音的问题',
    '修复离线朗读播完一章后不自动切换下一章的问题',
    '修复书旗小说备份与恢复失败的问题',
    '书旗下搜索无结果不再报错，正常展示空结果',
  ]),
  new FqChangelogEntry('1.0.9', '2026-11-06', [
    '新增弹幕样式设置（不透明度 / 速度 / 显示区域 / 字号 / 背景透明）',
    'PC 大窗口播放页新增右侧详情侧边栏（可收起）',
    '搜索页新增完结状态与评分筛选（高分排序 / 8 分以上 / 9 分以上）',
    '高分排序自动翻页拉完全部结果再全局降序',
    '书旗小说升级为完整本地化：可添加书架、记录进度、自动缓存',
    '横屏选集 / PC 目录侧边栏新增「定位」按钮',
    '离线缓存支持从播放设置进入；横屏侧边栏新增下载按钮',
    '选集 / 缓存集数网格改虚拟滚动，上千集不卡顿',
    '阅读进度变化实时刷新书架进度角标',
    '修复双击标题栏回顶手势判定不生效的问题',
  ]),
  new FqChangelogEntry('1.0.8', '2026-11-05', [
    '首页右上角新增「分类」按钮（类目 + 一级 tab + 二级栏 + 三级词）',
    '首页推荐流 / 排行榜卡片显示评分与运营角标',
    '短剧 / 漫剧选集面板新增「同系列」入口',
    '搜索页新增热搜榜与书旗小说源（右上角切换来源）',
    '书旗书籍详情页对齐番茄详情页样式',
    '新增播放预热下一集，自动连播切集不再等待取流',
    '新增剧集边看边缓存与「仅 Wi-Fi 自动缓存」开关',
    '剧集缓存页剧卡左滑「导出」；缓存条目操作统一左滑呼出',
    '设置 → 服务新增「本地接口」页',
    '修复排行榜「漫剧」标签下内容显示为小说的问题',
    '本地后端与原版 fqapp 完成同步',
  ]),
  new FqChangelogEntry('1.0.7', '2026-11-02', [
    '新增画中画：视频播放页退后台自动小窗续播',
    '章节自动缓存新增大小上限（默认 80MB，LRU 自动淘汰）',
    '章节缓存页新增「自动缓存上限」设置',
    '缓存与管理页实时显示四类离线缓存占用，新增「清空全部离线缓存」',
    '智感握姿左手握持时播控球展开态镜像布局，球体新增点光效果',
    '日志中心单条展开新增「复制本条」',
    '修复搜索漫剧偶发无结果的问题',
    '修复关键资产首次查询误报错误日志的问题',
  ]),
  new FqChangelogEntry('1.0.6', '2026-11-01', [
    '新增阅读自定义字体（导入 ttf / otf / ttc，长按删除）',
    '阅读主题新增「青绿」护眼预设',
    '自定义主题新增背景色（浅色 / 深色独立设置）',
    '自定义主题编辑弹窗支持选用自定义字体',
    '新增智感握姿：自动切换播控球停靠侧',
    '自定义主题字色板长按可删除自定义字色',
    '修复离线朗读音色列表偶发加载失败的问题',
    '阅读设置主题 / 字体 / 字色列表自动滚动到当前选中项',
  ]),
  new FqChangelogEntry('1.0.5', '2026-10-30', [
    '新增离线朗读：小艺语音引擎本地合成，无网络也能听书',
    '新增「离线朗读」设置页（音色切换 / 朗读语速）',
    '自定义主题字色新增色板',
    '「上一章」直接切换上一章，不再回到本章开头',
  ]),
  new FqChangelogEntry('1.0.4', '2026-10-29', [
    '新增 PC 与大屏适配：标题栏窗口合一、可折叠导航栏、视频全屏沉浸',
    'PC 布局路由页统一渐隐转场',
    '首页 / 书架网格宽屏自动加列铺满',
    '新增书架进度角标（阅读百分比 / 已看进度），随备份同步',
    '新增「点击直达阅读」开关',
    '新增音量键翻页开关',
    '自定义阅读主题（含背景图）加入备份与恢复',
    '新增更新提醒（设置页红点 + 新版本号）',
    '上下滚动阅读支持左右屏幕分别控制滚动',
    '修复漫画翻页偶发闪烁、图片加载失败的问题',
    '修复上下翻页切换章节时的切段异常问题',
    '修复番茄账号导入登录页被屏幕遮挡的问题',
    '完善弹窗与 sheet 的前景模糊；番茄采集信息支持导出',
  ]),
  new FqChangelogEntry('1.0.3', '2026-10-28', [
    '新增备份与恢复（本机导出 + 合并恢复不覆盖本机）',
    '新增 WebDAV 云备份（自动清理超限旧备份、退出时自动备份）',
    '新增导入番茄书架（账号采集 / JSON 文件导入）',
    '新增阅读自定义主题（背景图 / 字色 / 字号 / 字体 / 行距）',
    '设置页四类缓存入口合并为「缓存与管理」页',
    '阅读设置新增「段评」开关',
    '主题色自定义改为 HSB 取色器',
    '仿真 / 覆盖翻页排版引擎重做（逐行断行 + 行尾补齐）',
    '修复上下滚动模式调整字号 / 行距后正文不实时刷新的问题',
    '修复仿真 / 覆盖翻页正文右侧缺一角的问题',
    '修复仿真 / 覆盖翻页部分页面底部缺段落、留大片空白的问题',
    '修复调整字号 / 行距后页底文字被裁切的问题',
  ]),
  new FqChangelogEntry('1.0.2', '2026-10-27', [
    '新增日志中心：应用 / 核心双源日志查看、筛选、搜索、复制、导出',
    '新增主题色：跟随系统 + 8 种预设色，深浅模式自动适配，即时生效',
    '修复漫画多章节显示同一套图片的问题',
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
    '修复评论「作者」标识错乱的问题',
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

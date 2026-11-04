/**
 * 本地接口页（设置-服务-本地接口，对齐 fqapp ApiServicePage，条目用设置行样式）：
 * - 状态：/health 探测「运行中 · N 个设备 / 已停止」+ 自测按钮（显示探测结果）；
 * - 地址：本机地址行（点击复制）+ 局域网共享开关（开启需确认弹窗，经
 *   restartForListenMode 整体重启监听；开启后按同款行样式列出局域网地址与提示）；
 * - 接口：只读 v1 端点参考（默认收起，点击整条复制完整 URL）；
 * - 内置 Web UI 已随 fqapp 上游移除（9132732），此页是本地接口的唯一说明处。
 */

import { CommonNav } from '../../view/CommonNav';
import { FqTitleBarOptions } from '../../model/FqNavModels';
import { CommonLoading } from '../../view/CommonCom';
import { FqAppSettingsStore } from '../../core/FqAppSettingsStore';
import { FqBackend, FqRequestError } from '../../core/FqBackend';
import { DialogManager } from '../../utils/DialogUtils';
import { FqColorUtils } from '../../utils/FqColorUtils';
import { appState } from '../../entryability/AppState';
import { connection } from '@kit.NetworkKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/** 标题栏下方内容起始偏移。 */
const FQ_API_TOP_INSET: number = 56;
/** 行内分割线左避让：左侧行 padding 14 + 图标块 34 + 间距 12（与设置页一致）。 */
const FQ_ROW_DIVIDER_INSET: number = 60;
/** 静默状态刷新超时（ms）。 */
const FQ_API_REFRESH_TIMEOUT_MS: number = 3000;
/** 自测超时（ms）。 */
const FQ_API_PROBE_TIMEOUT_MS: number = 5000;

/** 接口参考条目（名称 / 相对路径 / 一行用途）。 */
class FqApiEndpoint {
  public readonly name: string;
  public readonly path: string;
  public readonly hint: string;

  constructor(name: string, path: string, hint: string) {
    this.name = name;
    this.path = path;
    this.hint = hint;
  }
}

/** /health 探测结果。 */
class FqHealthResult {
  public readonly ok: boolean;
  /** 设备池大小；-1 表示未知。 */
  public readonly devices: number;
  /** 失败时的结果文案（自测展示用）。 */
  public readonly message: string;

  constructor(ok: boolean, devices: number, message: string) {
    this.ok = ok;
    this.devices = devices;
    this.message = message;
  }
}

/** 只读 v1 端点参考（对齐 fqapp ApiServicePage，相对路径拼在根地址后）。 */
const FQ_API_ENDPOINTS: FqApiEndpoint[] = [
  new FqApiEndpoint('搜索', '/api/v1/search/fanqie?query=', '替换为关键词'),
  new FqApiEndpoint('详情', '/api/v1/books/{book_id}', '书名、作者、简介、封面'),
  new FqApiEndpoint('目录', '/api/v1/books/{book_id}/directory', '章节列表'),
  new FqApiEndpoint('正文', '/api/v1/chapters/{item_id}', '章节正文与插图'),
];

@Builder
function fqApiEmptyContent() {
}

/** 接口页卡片壳（与设置页 FqSettingsCard 同体系）。 */
@ComponentV2
struct FqApiCard {
  @BuilderParam content: () => void = fqApiEmptyContent;

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
export struct ApiServicePage {
  private scroller: Scroller = new Scroller();
  /** 服务是否运行（/health 应答 200）。 */
  @Local statusRunning: boolean = false;
  /** 设备池大小（-1 未知）。 */
  @Local devicesCount: number = -1;
  /** 状态行/自测的探测进行中。 */
  @Local probing: boolean = false;
  /** 本机根地址（等待服务启动时为空）。 */
  @Local apiUrl: string = '';
  /** 局域网共享开关。 */
  @Local lanShare: boolean = false;
  /** 监听模式切换进行中。 */
  @Local switching: boolean = false;
  /** 本机局域网地址（共享关闭或未检测到时为空）。 */
  @Local lanAddresses: string[] = [];
  /** 自测结果（空 = 尚未自测）。 */
  @Local probeResult: string = '';
  @Local probeOk: boolean = false;
  /** 接口参考是否展开。 */
  @Local showEndpoints: boolean = false;

  aboutToAppear(): void {
    this.lanShare = FqAppSettingsStore.isLanShareEnabled();
    this.apiUrl = FqBackend.get().baseUrl;
    if (this.lanShare) {
      this.detectLanAddresses().then((ips: string[]): void => {
        this.lanAddresses = ips;
      });
    }
    this.pullUpAndRefresh();
  }

  /** 未启动时幂等拉起（对齐旧设置页刷新按钮行为），随后刷新状态。 */
  private pullUpAndRefresh(): void {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    const backend: FqBackend = FqBackend.get();
    if (context !== null && backend.baseUrl.length === 0) {
      backend.start(context)
        .then((): void => {
          this.refresh();
        })
        .catch((_error: Object): void => {
          // 拉起失败：状态行如实显示已停止
        });
    }
    this.refresh();
  }

  /** 静默刷新状态行（/health，不动设备池轮换预算）。 */
  private async refresh(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    const result: FqHealthResult = await this.fetchHealth(FQ_API_REFRESH_TIMEOUT_MS);
    this.statusRunning = result.ok;
    this.devicesCount = result.devices;
    this.apiUrl = FqBackend.get().baseUrl;
    this.probing = false;
  }

  /** 自测：明确动作，把客户端实际拿到的结果说出来。 */
  private async selfTest(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    const result: FqHealthResult = await this.fetchHealth(FQ_API_PROBE_TIMEOUT_MS);
    if (result.ok) {
      this.probeResult = result.devices >= 0
        ? `通了 · HTTP 200 · ${result.devices} 个设备`
        : '通了 · HTTP 200';
    } else {
      this.probeResult = result.message.length > 0 ? result.message : '不通';
    }
    this.probeOk = result.ok;
    this.statusRunning = result.ok;
    this.devicesCount = result.devices;
    this.apiUrl = FqBackend.get().baseUrl;
    this.probing = false;
  }

  /** 读一次 /health，保留结论与设备数（拿不到 JSON 也算监听器应答了）。 */
  private async fetchHealth(timeoutMs: number): Promise<FqHealthResult> {
    const backend: FqBackend = FqBackend.get();
    if (backend.baseUrl.length === 0) {
      return new FqHealthResult(false, -1, '本地后端未启动');
    }
    try {
      const payload: Record<string, Object> = await backend.getJson('/health', '', timeoutMs);
      const devicesRaw: Object | undefined = payload['devices'];
      let devices: number = -1;
      if (typeof devicesRaw === 'number') {
        devices = devicesRaw;
      }
      return new FqHealthResult(true, devices, '');
    } catch (error) {
      if (error instanceof FqRequestError) {
        return new FqHealthResult(false, -1, `返回 HTTP ${error.statusCode}`);
      }
      const reason: string = error instanceof Error ? error.message : String(error);
      return new FqHealthResult(false, -1, `不通 · ${reason}`);
    }
  }

  /** 局域网共享行点击（开启需确认，关闭直接切换）。 */
  private onLanShareRowTap(): void {
    this.requestLanShare(!this.lanShare);
  }

  private requestLanShare(target: boolean): void {
    if (this.switching || target === this.lanShare) {
      return;
    }
    if (target) {
      DialogManager.ShowConfirm('开启局域网共享',
        '同一网络下的其他设备将能访问这些接口，无需密码。\n\n开启后本地服务会重启，正在进行的请求会中断一次。',
        '开启', (): void => {
          this.applyLanShare(true);
        });
    } else {
      this.applyLanShare(false);
    }
  }

  /** 持久化开关并重启监听（核心在 init 时绑定监听地址，必须整体停启）。 */
  private async applyLanShare(target: boolean): Promise<void> {
    const context: common.UIAbilityContext | null = appState.abilityContext;
    if (context === null) {
      this.toast('操作失败，请稍后重试');
      return;
    }
    this.switching = true;
    FqAppSettingsStore.setLanShare(target);
    try {
      await FqBackend.get().restartForListenMode(context);
    } catch (error) {
      // 重启结果由状态行随刷新如实反映
    }
    this.lanShare = target;
    this.apiUrl = FqBackend.get().baseUrl;
    this.lanAddresses = target ? await this.detectLanAddresses() : [];
    this.switching = false;
    this.refresh();
  }

  /** 默认网络的 IPv4 链路地址（192.168 优先，回环/链路本地剔除）。 */
  private async detectLanAddresses(): Promise<string[]> {
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      const props: connection.ConnectionProperties =
        await connection.getConnectionProperties(netHandle);
      const found: string[] = [];
      for (const link of props.linkAddresses) {
        const ip: string = link.address.address;
        if (this.isUsableLanIp(ip)) {
          found.push(ip);
        }
      }
      found.sort((a: string, b: string): number => this.lanIpRank(a) - this.lanIpRank(b));
      return found;
    } catch (error) {
      return [];
    }
  }

  private isUsableLanIp(ip: string): boolean {
    if (ip.length === 0 || ip.includes(':')) {
      return false;
    }
    if (ip.startsWith('127.') || ip.startsWith('169.254.') || ip.startsWith('0.')) {
      return false;
    }
    return true;
  }

  private lanIpRank(ip: string): number {
    if (ip.startsWith('192.168.')) {
      return 0;
    }
    if (ip.startsWith('10.')) {
      return 1;
    }
    if (ip.startsWith('172.')) {
      return 2;
    }
    return 3;
  }

  /** 核心监听端口（从根地址解析，与回环行不会各说各话）。 */
  private listenPort(): string {
    const base: string = this.apiUrl;
    const schemeEnd: number = base.indexOf('://');
    const authority: string = schemeEnd >= 0 ? base.substring(schemeEnd + 3) : base;
    const colon: number = authority.lastIndexOf(':');
    return colon >= 0 ? authority.substring(colon + 1) : '';
  }

  private statusText(): string {
    if (this.statusRunning) {
      return this.devicesCount >= 0 ? `运行中 · ${this.devicesCount} 个设备` : '运行中';
    }
    return '已停止';
  }

  /** 状态图标块用色：运行绿色 / 停止红色（与设置页开关行色板一致）。 */
  private statusTint(): string {
    return this.statusRunning ? '#FF10B981' : '#FFF43F5E';
  }

  private endpointsToggleLabel(): string {
    return this.showEndpoints ? '隐藏接口' : '查看可用接口';
  }

  /** 地址行展示值（服务未启动时的占位文案）。 */
  private addressDisplay(url: string): string {
    return url.length > 0 ? url : '等待服务启动';
  }

  private copyText(label: string, text: string): void {
    if (text.length === 0) {
      return;
    }
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data)
      .then((): void => {
        this.toast(`已复制${label}`);
      })
      .catch((_error: BusinessError): void => {
        this.toast('复制失败');
      });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
  }

  build() {
    CommonNav({
      titleBarOp: FqTitleBarOptions('本地接口', false),
      scroller: this.scroller,
    }) {
      List({ space: 12 }) {
        ListItem() {
          FqApiCard() {
            this.StatusCardContent()
          }
        }
        ListItem() {
          FqApiCard() {
            this.AddressCardContent()
          }
        }
        ListItem() {
          this.EndpointsToggleRow()
        }
        if (this.showEndpoints) {
          ListItem() {
            FqApiCard() {
              this.EndpointsCardContent()
            }
          }
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 40 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(appState.topRect + FQ_API_TOP_INSET)
      .contentEndOffset(appState.bottomRect + 24)
    }
  }

  @Builder
  private RowDivider() {
    Divider()
      .strokeWidth(0.6)
      .color($r('sys.color.comp_divider'))
      .margin({ left: FQ_ROW_DIVIDER_INSET, right: 12 })
  }

  /** 状态卡：服务状态行（绿/红图标块 + 状态副文本）+ 自测按钮 + 自测结果。 */
  @Builder
  private StatusCardContent() {
    Column() {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(17)
            .fontColor([this.statusTint()])
        }
        .width(34)
        .height(34)
        .borderRadius(10)
        .backgroundColor(FqColorUtils.withOpacity(this.statusTint(), 0.12))

        Column({ space: 3 }) {
          Text('服务状态')
            .fontSize(14.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text(this.statusText())
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 5 }) {
          if (this.probing) {
            CommonLoading({ sizeValue: 14, loadColor: $r('sys.color.font_secondary') })
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(13)
              .fontColor([$r('sys.color.font_secondary')])
          }
          Text('自测')
            .fontSize(12.5)
            .fontColor($r('sys.color.font_secondary'))
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onClick((): void => {
          this.selfTest();
        })
      }
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .width('100%')

      if (this.probeResult.length > 0) {
        Text(this.probeResult)
          .fontSize(11.5)
          .fontColor(this.probeOk ? appState.accentColor : $r('sys.color.font_primary'))
          .padding({ left: FQ_ROW_DIVIDER_INSET, right: 14, top: 2, bottom: 12 })
          .width('100%')
      }
    }
    .width('100%')
  }

  /** 地址卡：本机地址行 + 局域网共享开关行 + 局域网地址行（与本机行同款样式）。 */
  @Builder
  private AddressCardContent() {
    Column() {
      this.AddressEntryRow('本机地址', this.apiUrl)
      this.RowDivider()

      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_up_right'))
            .fontSize(17)
            .fontColor(['#FFF59E0B'])
        }
        .width(34)
        .height(34)
        .borderRadius(10)
        .backgroundColor(FqColorUtils.withOpacity('#FFF59E0B', 0.12))

        Column({ space: 3 }) {
          Text('局域网共享')
            .fontSize(14.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text('同一网络下的设备可访问本机接口')
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.switching) {
          CommonLoading({ sizeValue: 15, loadColor: $r('sys.color.font_secondary') })
        } else {
          Toggle({ type: ToggleType.Switch, isOn: this.lanShare })
            .selectedColor(appState.accentColor)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .width('100%')
      .onClick((): void => {
        this.onLanShareRowTap();
      })

      if (this.lanShare) {
        this.RowDivider()
        if (this.lanAddresses.length === 0) {
          Text('未检测到局域网地址，请确认已连接 WiFi。')
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: FQ_ROW_DIVIDER_INSET, right: 14, top: 11, bottom: 12 })
            .width('100%')
        } else {
          ForEach(this.lanAddresses, (ip: string, index: number) => {
            if (index > 0) {
              this.RowDivider()
            }
            this.AddressEntryRow('局域网地址', `http://${ip}:${this.listenPort()}`)
          }, (ip: string) => `lan_${ip}`)
          Text('无密码，同一网络下任何设备都能读取；公共 WiFi 建议关闭。')
            .fontSize(11.5)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: FQ_ROW_DIVIDER_INSET, right: 14, top: 2, bottom: 12 })
            .width('100%')
        }
      }
    }
    .width('100%')
  }

  /** 地址条目行（设置行样式：图标块 + 标题/地址副文本 + 复制标识），本机与局域网同款。 */
  @Builder
  private AddressEntryRow(title: string, url: string) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.scope'))
          .fontSize(17)
          .fontColor(['#FF0EA5E9'])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(FqColorUtils.withOpacity('#FF0EA5E9', 0.12))

      Column({ space: 3 }) {
        Text(title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.addressDisplay(url))
          .fontSize(11.5)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .width('100%')
    .onClick((): void => {
      this.copyText('地址', url);
    })
  }

  /** 接口参考展开/收起入口。 */
  @Builder
  private EndpointsToggleRow() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('sys.color.font_secondary')])
        .rotate({ angle: this.showEndpoints ? 90 : 0 })
      Text(this.endpointsToggleLabel())
        .fontSize(12.5)
        .fontColor($r('sys.color.font_secondary'))
    }
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .width('100%')
    .onClick((): void => {
      this.showEndpoints = !this.showEndpoints;
    })
  }

  /** 接口参考卡片：端点名 + GET 徽标 + 路径 + 一行用途，点击复制完整 URL。 */
  @Builder
  private EndpointsCardContent() {
    Column() {
      ForEach(FQ_API_ENDPOINTS, (endpoint: FqApiEndpoint, index: number) => {
        if (index > 0) {
          Divider()
            .strokeWidth(0.6)
            .color($r('sys.color.comp_divider'))
            .margin({ left: 14, right: 14 })
        }
        this.EndpointRow(endpoint)
      }, (endpoint: FqApiEndpoint) => `ep_${endpoint.name}`)
      Text('路径拼在上面的地址后面；{ } 内是变量，需替换成实际 ID。')
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
        .padding({ left: 14, right: 14, top: 6, bottom: 12 })
        .width('100%')
    }
    .width('100%')
  }

  @Builder
  private EndpointRow(endpoint: FqApiEndpoint) {
    Column() {
      Row({ space: 8 }) {
        Text(endpoint.name)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text('GET')
          .fontSize(9)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(4)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
      }
      .padding({ left: 14, right: 14, top: 11, bottom: 2 })
      .width('100%')
      Text(endpoint.path)
        .fontSize(11.5)
        .fontColor($r('sys.color.font_secondary'))
        .fontFamily('monospace')
        .padding({ left: 14, right: 14 })
        .width('100%')
      Text(endpoint.hint)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
        .padding({ left: 14, right: 14, top: 2, bottom: 11 })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.copyText(endpoint.name, `${this.apiUrl}${endpoint.path}`);
    })
  }
}

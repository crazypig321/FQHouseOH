/**
 * 更新检查工具：拉取 GitHub 最新 release 并与本地版本比较；
 * 代理开关（FqAppSettingsStore）决定直连/国内代理候选顺序，检查与下载共用、失败自动回退。
 */

import http from '@ohos.net.http';
import { fileIo as fs } from '@kit.CoreFileKit';
import { bundleManager } from '@kit.AbilityKit';
import { appState } from '../entryability/AppState';
import { FqAppSettingsStore } from './FqAppSettingsStore';

/** GitHub 最新 release 接口 */
const FQ_RELEASE_API_URL: string = 'https://api.github.com/repos/crazypig321/FQHouseOH/releases/latest';
/** 国内加速前缀型代理（拼接在目标 URL 前），检查更新与下载均依次回退尝试 */
const FQ_GH_PROXY_PREFIXES: string[] = ['https://gh-proxy.com/', 'https://ghfast.top/'];
/** 静默检查节流间隔（毫秒）：会话内最多每 10 分钟请求一次接口 */
const FQ_SILENT_CHECK_THROTTLE_MS: number = 10 * 60 * 1000;

/** GitHub latest release 接口返回体（仅声明所需字段） */
export interface FqReleaseRaw {
  tag_name?: string;
  assets?: FqReleaseAssetRaw[];
}

/** release 资产原始字段 */
export interface FqReleaseAssetRaw {
  name?: string;
  browser_download_url?: string;
}

/** 归一化后的 release 软件包资产 */
export class FqReleaseAsset {
  public name: string = '';
  public url: string = '';
}

export class FqUpdateChecker {
  /** 上次静默检查时间戳（0 = 本次会话尚未检查） */
  private static lastSilentCheckAt: number = 0;

  /** 读取本地版本号（bundleManager 同步读取；失败返回空串）。 */
  public static currentVersionName(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      return '';
    }
  }

  /** 静默检查更新（会话内 10 分钟节流，设置页/关于页进入时共用）：
   *  最新版本高于本地时记录到 appState.latestVersion，否则清空（红点/标签随状态刷新）；
   *  请求失败不改动现有状态。 */
  public static async checkLatestSilently(): Promise<void> {
    const now: number = Date.now();
    if (now - FqUpdateChecker.lastSilentCheckAt < FQ_SILENT_CHECK_THROTTLE_MS) {
      return;
    }
    FqUpdateChecker.lastSilentCheckAt = now;
    const current: string = FqUpdateChecker.currentVersionName();
    if (current.length === 0) {
      return;
    }
    const raw: FqReleaseRaw | null = await FqUpdateChecker.fetchLatestRelease(
      FqAppSettingsStore.isUpdateProxyDownload());
    if (raw === null) {
      return;
    }
    const tag = raw.tag_name;
    if (tag !== undefined && FqUpdateChecker.isNewerVersion(tag, current)) {
      appState.latestVersion = tag;
    } else {
      appState.latestVersion = '';
    }
  }

  /** 从 release 资产中选取软件包：优先 .hap，其次第一个有效资产；无资产返回 null */
  public static pickReleaseAsset(release: FqReleaseRaw): FqReleaseAsset | null {
    const assets = release.assets;
    if (assets === undefined) {
      return null;
    }
    let fallback: FqReleaseAsset | null = null;
    for (const raw of assets) {
      const name = raw.name;
      const url = raw.browser_download_url;
      if (typeof name !== 'string' || name.length === 0 || typeof url !== 'string' || url.length === 0) {
        continue;
      }
      const asset: FqReleaseAsset = new FqReleaseAsset();
      asset.name = name;
      asset.url = url;
      if (fallback === null) {
        fallback = asset;
      }
      if (name.toLowerCase().endsWith('.hap')) {
        return asset;
      }
    }
    return fallback;
  }

  /** 比较语义化版本号（忽略 v 前缀与非数字字符，逐段比较）：a 是否大于 b */
  public static isNewerVersion(a: string, b: string): boolean {
    const parse = (v: string): number[] => {
      const parts: number[] = [];
      const segs: string[] = v.replace(/^[vV]/, '').split('.');
      for (const seg of segs) {
        const digits: string = seg.replace(/[^0-9]/g, '');
        const n: number = digits.length > 0 ? Number(digits) : 0;
        parts.push(Number.isFinite(n) ? n : 0);
      }
      return parts;
    };
    const pa: number[] = parse(a);
    const pb: number[] = parse(b);
    const len: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const x: number = i < pa.length ? pa[i] : 0;
      const y: number = i < pb.length ? pb[i] : 0;
      if (x !== y) {
        return x > y;
      }
    }
    return false;
  }

  /** 按代理开关排序候选地址（检查与下载共用）：
   *  开启 = 国内代理在前、直连兜底；关闭 = 直连在前、代理回退；均含全部来源，失败自动切换 */
  public static orderedUrls(targetUrl: string, proxyFirst: boolean): string[] {
    const urls: string[] = [];
    if (!proxyFirst) {
      urls.push(targetUrl);
    }
    for (const prefix of FQ_GH_PROXY_PREFIXES) {
      urls.push(prefix + targetUrl);
    }
    if (proxyFirst) {
      urls.push(targetUrl);
    }
    return urls;
  }

  /** 拉取 GitHub 最新 release 信息：直连不通时依次走国内代理；全部失败返回 null */
  public static async fetchLatestRelease(proxyFirst: boolean): Promise<FqReleaseRaw | null> {
    const headers: Record<string, string> = {
      'User-Agent': 'FQHouseOH',
      'Accept': 'application/vnd.github+json'
    };
    const urls: string[] = FqUpdateChecker.orderedUrls(FQ_RELEASE_API_URL, proxyFirst);
    for (const url of urls) {
      const client: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await client.request(url, {
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 6000,
          readTimeout: 10000,
          header: headers,
        });
        if (response.responseCode !== 200 || typeof response.result !== 'string') {
          continue;
        }
        const raw: FqReleaseRaw = JSON.parse(response.result) as FqReleaseRaw;
        const tag = raw.tag_name;
        if (typeof tag === 'string' && tag.length > 0) {
          return raw;
        }
      } catch (error) {
        // 当前源失败，尝试下一个
      } finally {
        client.destroy();
      }
    }
    return null;
  }

  /** 流式下载软件包到文件：返回是否成功；onProgress 回调已接收/总字节数（total 为 0 表示未知） */
  public static downloadToFile(url: string, destPath: string,
    onProgress: (downloaded: number, total: number) => void): Promise<boolean> {
    return new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      const client: http.HttpRequest = http.createHttp();
      let file: fs.File | null = null;
      let failed: boolean = false;
      client.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (failed || file === null) {
          failed = true;
          return;
        }
        try {
          fs.writeSync(file.fd, chunk);
        } catch (error) {
          failed = true;
        }
      });
      client.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo): void => {
        onProgress(info.receiveSize, info.totalSize);
      });
      client.requestInStream(url, {
        header: { 'User-Agent': 'FQHouseOH' },
        connectTimeout: 15000,
        readTimeout: 300000,
      }).then((code: number): void => {
        FqUpdateChecker.finishDownload(client, file, resolve, !failed && code >= 200 && code < 300);
      }).catch((): void => {
        FqUpdateChecker.finishDownload(client, file, resolve, false);
      });
      try {
        file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      } catch (error) {
        failed = true;
      }
    });
  }

  /** 收尾：注销事件、销毁请求、关闭中转文件并结算结果。 */
  private static finishDownload(client: http.HttpRequest, file: fs.File | null,
    resolve: (ok: boolean) => void, ok: boolean): void {
    client.off('dataReceive');
    client.off('dataReceiveProgress');
    client.destroy();
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (error) {
        // 中转文件句柄关闭失败不影响结果
      }
    }
    resolve(ok);
  }
}

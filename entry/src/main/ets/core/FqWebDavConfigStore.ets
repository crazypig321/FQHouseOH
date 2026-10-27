/**
 * WebDAV 配置持久化（WebDAV 备份与恢复页）：
 * preferences 独立存储（fq_webdav）：
 * - url：服务器地址（如 https://dav.example.com/dav/）；
 * - path：备份路径（可选，如 /backups）；
 * - username / password：Basic Auth 凭据（可留空）；
 * - maxBackupCount：备份保留数量（1-50，默认 10，超出时自动删除最老备份）；
 * - autoBackupOnExit：退出应用前自动备份开关（EntryAbility onDestroy 触发，静默执行）。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const FQ_WEBDAV_STORE_NAME: string = 'fq_webdav';
const FQ_WEBDAV_KEY_URL: string = 'url';
const FQ_WEBDAV_KEY_PATH: string = 'path';
const FQ_WEBDAV_KEY_USERNAME: string = 'username';
const FQ_WEBDAV_KEY_PASSWORD: string = 'password';
const FQ_WEBDAV_KEY_MAX_COUNT: string = 'maxBackupCount';
const FQ_WEBDAV_KEY_AUTO_EXIT: string = 'autoBackupOnExit';

export class FqWebDavConfigStore {
  private static pref: preferences.Preferences | null = null;
  private static url: string = '';
  private static path: string = '';
  private static username: string = '';
  private static password: string = '';
  private static maxBackupCount: number = 10;
  private static autoBackupOnExit: boolean = false;

  public static init(context: common.Context): void {
    if (FqWebDavConfigStore.pref !== null) {
      return;
    }
    try {
      FqWebDavConfigStore.pref =
        preferences.getPreferencesSync(context, { name: FQ_WEBDAV_STORE_NAME });
    } catch (error) {
      FqWebDavConfigStore.pref = null;
      return;
    }
    const pref: preferences.Preferences = FqWebDavConfigStore.pref;
    try {
      const rawUrl: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_URL, '');
      if (typeof rawUrl === 'string') {
        FqWebDavConfigStore.url = rawUrl;
      }
      const rawPath: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_PATH, '');
      if (typeof rawPath === 'string') {
        FqWebDavConfigStore.path = rawPath;
      }
      const rawUser: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_USERNAME, '');
      if (typeof rawUser === 'string') {
        FqWebDavConfigStore.username = rawUser;
      }
      const rawPass: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_PASSWORD, '');
      if (typeof rawPass === 'string') {
        FqWebDavConfigStore.password = rawPass;
      }
      const rawCount: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_MAX_COUNT, 10);
      if (typeof rawCount === 'number' && rawCount >= 1 && rawCount <= 50) {
        FqWebDavConfigStore.maxBackupCount = Math.trunc(rawCount);
      }
      const rawAuto: preferences.ValueType = pref.getSync(FQ_WEBDAV_KEY_AUTO_EXIT, false);
      if (typeof rawAuto === 'boolean') {
        FqWebDavConfigStore.autoBackupOnExit = rawAuto;
      }
    } catch (error) {
      // 损坏数据按默认值处理
    }
  }

  /** 单键持久化（putSync + 异步 flush）。 */
  private static persist(key: string, value: preferences.ValueType): void {
    const pref: preferences.Preferences | null = FqWebDavConfigStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.putSync(key, value);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  public static getUrl(): string {
    return FqWebDavConfigStore.url;
  }

  public static setUrl(value: string): void {
    FqWebDavConfigStore.url = value;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_URL, value);
  }

  public static getPath(): string {
    return FqWebDavConfigStore.path;
  }

  public static setPath(value: string): void {
    FqWebDavConfigStore.path = value;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_PATH, value);
  }

  public static getUsername(): string {
    return FqWebDavConfigStore.username;
  }

  public static setUsername(value: string): void {
    FqWebDavConfigStore.username = value;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_USERNAME, value);
  }

  public static getPassword(): string {
    return FqWebDavConfigStore.password;
  }

  public static setPassword(value: string): void {
    FqWebDavConfigStore.password = value;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_PASSWORD, value);
  }

  public static getMaxBackupCount(): number {
    return FqWebDavConfigStore.maxBackupCount;
  }

  public static setMaxBackupCount(value: number): void {
    const count: number = Math.min(50, Math.max(1, Math.trunc(value)));
    FqWebDavConfigStore.maxBackupCount = count;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_MAX_COUNT, count);
  }

  public static isAutoBackupOnExit(): boolean {
    return FqWebDavConfigStore.autoBackupOnExit;
  }

  public static setAutoBackupOnExit(enabled: boolean): void {
    FqWebDavConfigStore.autoBackupOnExit = enabled;
    FqWebDavConfigStore.persist(FQ_WEBDAV_KEY_AUTO_EXIT, enabled);
  }
}

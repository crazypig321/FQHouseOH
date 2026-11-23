/**
 * 分组加锁的应用内密码存储（设备无任何系统锁屏凭据时的兜底验证）：
 * - 4~8 位数字密码，随机盐 + SHA-256 哈希后存 preferences（明文不落盘）；
 * - 密码为设备本地数据：不进备份/恢复链路，清除所有数据时随 KV 一并清空。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const FQ_GROUP_LOCK_STORE_NAME: string = 'fq_group_lock';
const FQ_GROUP_LOCK_KEY_SALT: string = 'salt_v1';
const FQ_GROUP_LOCK_KEY_HASH: string = 'hash_v1';
/** 盐长度（字节）。 */
const FQ_GROUP_LOCK_SALT_LEN: number = 32;
/** 密码规则：4~8 位数字。 */
const FQ_GROUP_LOCK_PATTERN: RegExp = /^\d{4,8}$/;

export class FqGroupLockStore {
  private static pref: preferences.Preferences | null = null;
  private static saltHex: string = '';
  private static hashHex: string = '';

  public static init(context: common.Context): void {
    if (FqGroupLockStore.pref !== null) {
      return;
    }
    try {
      FqGroupLockStore.pref = preferences.getPreferencesSync(context, { name: FQ_GROUP_LOCK_STORE_NAME });
    } catch (error) {
      FqGroupLockStore.pref = null;
      return;
    }
    try {
      const rawSalt: preferences.ValueType = FqGroupLockStore.pref.getSync(FQ_GROUP_LOCK_KEY_SALT, '');
      if (typeof rawSalt === 'string') {
        FqGroupLockStore.saltHex = rawSalt;
      }
      const rawHash: preferences.ValueType = FqGroupLockStore.pref.getSync(FQ_GROUP_LOCK_KEY_HASH, '');
      if (typeof rawHash === 'string') {
        FqGroupLockStore.hashHex = rawHash;
      }
    } catch (error) {
      // 读取失败按无密码处理
    }
  }

  /** 是否已设置应用内密码。 */
  public static hasPassword(): boolean {
    return FqGroupLockStore.saltHex.length > 0 && FqGroupLockStore.hashHex.length > 0;
  }

  /** 密码格式是否合法（4~8 位数字）。 */
  public static isValidPassword(pwd: string): boolean {
    return FQ_GROUP_LOCK_PATTERN.test(pwd);
  }

  /** 设置（或覆盖）应用内密码；格式非法返回 false。 */
  public static async setPassword(pwd: string): Promise<boolean> {
    if (!FqGroupLockStore.isValidPassword(pwd)) {
      return false;
    }
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    const salt: Uint8Array = rand.generateRandomSync(FQ_GROUP_LOCK_SALT_LEN).data;
    const hash: string = await FqGroupLockStore.hashPassword(pwd, salt);
    FqGroupLockStore.saltHex = FqGroupLockStore.toHex(salt);
    FqGroupLockStore.hashHex = hash;
    return FqGroupLockStore.persist();
  }

  /** 校验密码（无密码或格式非法直接 false）。 */
  public static async verifyPassword(pwd: string): Promise<boolean> {
    if (!FqGroupLockStore.hasPassword() || !FqGroupLockStore.isValidPassword(pwd)) {
      return false;
    }
    const salt: Uint8Array | null = FqGroupLockStore.fromHex(FqGroupLockStore.saltHex);
    if (salt === null) {
      return false;
    }
    const hash: string = await FqGroupLockStore.hashPassword(pwd, salt);
    return hash === FqGroupLockStore.hashHex;
  }

  /** 清除应用内密码（清除所有数据场景随 KV 清空，通常无需单独调用）。 */
  public static clearPassword(): void {
    FqGroupLockStore.saltHex = '';
    FqGroupLockStore.hashHex = '';
    const pref: preferences.Preferences | null = FqGroupLockStore.pref;
    if (pref === null) {
      return;
    }
    try {
      pref.deleteSync(FQ_GROUP_LOCK_KEY_SALT);
      pref.deleteSync(FQ_GROUP_LOCK_KEY_HASH);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** salt + 密码字节 SHA-256 → 64 位 hex。 */
  private static async hashPassword(pwd: string, salt: Uint8Array): Promise<string> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const pwdBytes: Uint8Array = encoder.encodeInto(pwd);
    const data: Uint8Array = new Uint8Array(salt.length + pwdBytes.length);
    data.set(salt, 0);
    data.set(pwdBytes, salt.length);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const input: cryptoFramework.DataBlob = { data: data };
    await md.update(input);
    const digest: cryptoFramework.DataBlob = await md.digest();
    return FqGroupLockStore.toHex(digest.data);
  }

  private static toHex(bytes: Uint8Array): string {
    let text: string = '';
    for (let index: number = 0; index < bytes.length; index++) {
      const value: number = bytes[index];
      text += value < 16 ? `0${value.toString(16)}` : value.toString(16);
    }
    return text;
  }

  /** hex 还原字节（长度非偶数或含非法字符返回 null）。 */
  private static fromHex(text: string): Uint8Array | null {
    if (text.length === 0 || text.length % 2 !== 0) {
      return null;
    }
    const bytes: Uint8Array = new Uint8Array(text.length / 2);
    for (let index: number = 0; index < bytes.length; index++) {
      const high: number = parseInt(text.substring(index * 2, index * 2 + 1), 16);
      const low: number = parseInt(text.substring(index * 2 + 1, index * 2 + 2), 16);
      if (Number.isNaN(high) || Number.isNaN(low)) {
        return null;
      }
      bytes[index] = high * 16 + low;
    }
    return bytes;
  }

  private static persist(): boolean {
    const pref: preferences.Preferences | null = FqGroupLockStore.pref;
    if (pref === null) {
      return false;
    }
    try {
      pref.putSync(FQ_GROUP_LOCK_KEY_SALT, FqGroupLockStore.saltHex);
      pref.putSync(FQ_GROUP_LOCK_KEY_HASH, FqGroupLockStore.hashHex);
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
      return true;
    } catch (error) {
      return false;
    }
  }
}

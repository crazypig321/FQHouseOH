/**
 * 设备池加密密钥管理（Asset Store Kit）。
 *
 * 对齐 fqapp SecureKeyProvider（P1-2）：32 字节随机密钥，首启生成并持久化；
 * 安全存储不可用时返回 null，调用方降级为明文池（不阻塞启动）。
 */

import asset from '@ohos.security.asset';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const DEVICE_POOL_KEY_ALIAS: string = 'fqoh_device_pool_key_v1';

export class FqKeyStore {
  private static readonly instance: FqKeyStore = new FqKeyStore();

  private cached: Uint8Array | null = null;

  private constructor() {
  }

  public static get(): FqKeyStore {
    return FqKeyStore.instance;
  }

  public async devicePoolKey(): Promise<Uint8Array | null> {
    if (this.cached !== null) {
      return this.cached;
    }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      query.set(asset.Tag.ALIAS, FqKeyStore.aliasBytes());
      const rows: Array<asset.AssetMap> = await asset.query(query);
      if (rows.length > 0) {
        const secret: boolean | number | Uint8Array | undefined = rows[0].get(asset.Tag.SECRET);
        if (secret instanceof Uint8Array && secret.length === 32) {
          this.cached = secret;
          return secret;
        }
      }
      const fresh: Uint8Array = FqKeyStore.randomBytes();
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.SECRET, fresh);
      attrs.set(asset.Tag.ALIAS, FqKeyStore.aliasBytes());
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      await asset.add(attrs);
      this.cached = fresh;
      return fresh;
    } catch (error) {
      return null;
    }
  }

  private static aliasBytes(): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(DEVICE_POOL_KEY_ALIAS);
  }

  private static randomBytes(): Uint8Array {
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = rand.generateRandomSync(32);
    return blob.data;
  }
}

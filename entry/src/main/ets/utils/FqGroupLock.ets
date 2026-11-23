/**
 * 分组加锁验证编排：
 * - 系统凭据（人脸/指纹/锁屏密码，userAuth ATL2）优先；
 * - 设备无任何锁屏凭据时，应用内密码（FqGroupLockStore）兜底；
 * - 两者均不可用时直接放行（备份恢复/解锁边界，避免永久锁死）。
 * 验证失败不 toast，由调用方提示。
 */

import { userAuth } from '@kit.UserAuthenticationKit';
import { FqGroupLockStore } from '../core/FqGroupLockStore';
import { DialogManager } from './DialogUtils';

/** userAuth 认证成功结果码。 */
const FQ_AUTH_RESULT_SUCCESS: number = 12500000;

export class FqGroupLock {
  /** 系统凭据（人脸/指纹/锁屏密码任一）是否可用于验证。 */
  public static systemAuthAvailable(): boolean {
    const types: userAuth.UserAuthType[] = [userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.PIN];
    for (const type of types) {
      try {
        userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL2);
        return true;
      } catch (error) {
        // 该凭据不可用，探测下一种
      }
    }
    return false;
  }

  /** 分组访问验证门：系统凭据优先，无系统凭据时应用内密码兜底；
   *  onSuccess 验证通过回调；onFail 验证未通过回调（用户取消/失败/密码错误）。 */
  public static verifyGroupAccess(onSuccess: () => void, onFail: () => void): void {
    if (FqGroupLock.systemAuthAvailable()) {
      FqGroupLock.authenticate('验证身份', onSuccess, onFail);
      return;
    }
    if (FqGroupLockStore.hasPassword()) {
      DialogManager.ShowGroupPassword('输入分组密码', (pwd: string): void => {
        FqGroupLockStore.verifyPassword(pwd).then((ok: boolean): void => {
          if (ok) {
            onSuccess();
          } else {
            onFail();
          }
        });
      });
      return;
    }
    // 无任何验证手段：放行（否则无法访问/解锁，备份恢复死锁）
    onSuccess();
  }

  /** 唤起系统验证（人脸/指纹/锁屏密码，取设备可用的类型集合）。 */
  public static authenticate(title: string, onSuccess: () => void, onFail: () => void): void {
    const authTypes: userAuth.UserAuthType[] = [];
    const allTypes: userAuth.UserAuthType[] = [userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.PIN];
    for (const type of allTypes) {
      try {
        userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL2);
        authTypes.push(type);
      } catch (error) {
        // 该凭据不可用
      }
    }
    if (authTypes.length === 0) {
      onFail();
      return;
    }
    const authParam: userAuth.AuthParam = {
      challenge: new Uint8Array(32),
      authType: authTypes,
      authTrustLevel: userAuth.AuthTrustLevel.ATL2
    };
    const widgetParam: userAuth.WidgetParam = {
      title: title
    };
    try {
      const instance: userAuth.UserAuthInstance = userAuth.getUserAuthInstance(authParam, widgetParam);
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult): void => {
          if (result.result === FQ_AUTH_RESULT_SUCCESS) {
            onSuccess();
          } else {
            onFail();
          }
        }
      };
      instance.on('result', callback);
      instance.start();
    } catch (error) {
      onFail();
    }
  }
}

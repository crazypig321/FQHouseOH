/**
 * 公共 UI 工具：沉浸式材质版本兼容适配器。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';

/** 设备系统 API 是否 >= 26.0.0（Search.systemMaterial 最低版本）。 */
export function isApiVersion26(): boolean {
  return deviceInfo.distributionOSApiVersion >= 260000;
}

/** Search 沉浸式材质（ULTRA_THIN + colorInvert）版本兼容适配器：仅在 API >= 26 时调用 systemMaterial。 */
export class SearchImmersiveModifier implements AttributeModifier<SearchAttribute> {
  applyNormalAttribute(instance: SearchAttribute): void {
    if (isApiVersion26()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true,
      }));
    }
  }
}

/** 共享的无状态 Search 材质适配器实例。 */
export const searchImmersiveModifier: SearchImmersiveModifier = new SearchImmersiveModifier();

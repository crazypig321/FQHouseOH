import { uiMaterial } from "@kit.ArkUI";
import { deviceInfo } from "@kit.BasicServicesKit";

/** 设备系统 API 是否 >= 26.0.0（沉浸式材质 systemMaterial / ImmersiveMaterial 最低版本） */
export function IsApiVersion_26(): boolean {
  return deviceInfo.distributionOSApiVersion >= 260000;
}

/** Row 沉浸式材质（ULTRA_THIN + colorInvert）版本兼容适配器：仅在 API >= 26 时生效 */
export class RowImmersiveModifier implements AttributeModifier<RowAttribute> {
  applyNormalAttribute(instance: RowAttribute): void {
    if (IsApiVersion_26()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true
      }));
    }
  }
}

/** 共享的无状态 Row 材质适配器实例 */
export const rowImmersiveModifier: RowImmersiveModifier = new RowImmersiveModifier();

/** Text 沉浸式材质（ULTRA_THIN + colorInvert）版本兼容适配器：仅在 API >= 26 时生效 */
export class TextImmersiveModifier implements AttributeModifier<TextAttribute> {
  applyNormalAttribute(instance: TextAttribute): void {
    if (IsApiVersion_26()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true
      }));
    }
  }
}

/** 共享的无状态 Text 材质适配器实例 */
export const textImmersiveModifier: TextImmersiveModifier = new TextImmersiveModifier();

/** Stack 沉浸式材质（ULTRA_THIN + colorInvert）版本兼容适配器：仅在 API >= 26 时生效 */
export class StackImmersiveModifier implements AttributeModifier<StackAttribute> {
  applyNormalAttribute(instance: StackAttribute): void {
    if (IsApiVersion_26()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true
      }));
    }
  }
}

/** 共享的无状态 Stack 材质适配器实例 */
export const stackImmersiveModifier: StackImmersiveModifier = new StackImmersiveModifier();


/** Search 沉浸式材质（ULTRA_THIN + colorInvert）版本兼容适配器：仅在 API >= 26 时调用 systemMaterial。 */
export class SearchImmersiveModifier implements AttributeModifier<SearchAttribute> {
  applyNormalAttribute(instance: SearchAttribute): void {
    if (IsApiVersion_26()) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true,
      }));
    }
  }
}

/** 共享的无状态 Search 材质适配器实例。 */
export const searchImmersiveModifier: SearchImmersiveModifier = new SearchImmersiveModifier();
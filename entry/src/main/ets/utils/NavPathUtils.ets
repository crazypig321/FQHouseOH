import { appState } from '../entryability/AppState';

/** 路由操作工具（对齐 musicfreeOH NavPathUtils 模式）。 */
export class NavPathUtils {
  static push(key: string): void {
    appState.pageInfos.pushPathByName(key, false);
  }

  static pop(): void {
    appState.pageInfos.pop(false);
  }

  static clear(): void {
    appState.pageInfos.clear(false);
  }
}

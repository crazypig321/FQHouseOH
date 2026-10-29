import { appState } from '../entryability/AppState';
import { useSidebarLayout } from './BreakpointUtils';

/** 路由操作工具（对齐 musicfreeOH NavPathUtils 模式）。 */
export class NavPathUtils {
  static push(key: string): void {
    // PC 侧边栏布局：页面在内容区 Navigation 内替换栈顶（栈不增长，返回恒回主内容）
    if (useSidebarLayout(appState.WidthBp, appState.windowWidthVp, appState.displayWidthVp)) {
      appState.pageInfos.replacePath({ name: key });
      return;
    }
    appState.pageInfos.pushPathByName(key, false);
  }

  static pop(): void {
    appState.pageInfos.pop(false);
  }

  static clear(): void {
    appState.pageInfos.clear(false);
  }
}

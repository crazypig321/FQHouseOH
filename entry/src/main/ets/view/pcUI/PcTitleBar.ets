import { window } from '@kit.ArkUI';
import { appState } from '../../entryability/AppState';

/**
 * PC 顶部标题栏（与窗口标题栏合一，对齐 musicfreeOH PcTitleBar）：
 * - 自由窗口模式下系统标题栏已隐藏（setWindowDecorVisible(false)），本栏即为窗口标题栏
 * - 左侧品牌区：应用图标 + 应用名；中部空白区可按下拖拽移动窗口
 * - 右上角系统三键（最小化/最大化/关闭，下沉到页面内）避让区
 * - 底部分隔线与侧边栏/内容区分隔保持一致
 */
@ComponentV2
export struct PcTitleBar {
  /** 窗口拖拽按下标记：Down 后 Move 才触发移动，避免点击误拖 */
  private dragPressed: boolean = false;

  /** 标题栏空白/品牌区按下拖拽移动窗口（仅自由窗口生效，其余形态静默失败） */
  private onDragZoneTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.dragPressed = true;
    } else if (event.type === TouchType.Move && this.dragPressed) {
      this.dragPressed = false;
      const context = appState.abilityContext;
      if (context === null) {
        return;
      }
      window.getLastWindow(context).then((win: window.Window): void => {
        win.startMoving().catch((): void => {
        });
      }).catch((): void => {
        // 非自由窗口形态不支持拖动窗口，忽略
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.dragPressed = false;
    }
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        // 品牌区：应用图标 + 应用名（空白可拖拽移动窗口）
        Row({ space: 10 }) {
          Image($r('app.media.startIcon'))
            .width(26)
            .height(26)
            .borderRadius(8)
            .draggable(false)

          Text($r('app.string.EntryAbility_label'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)
        .onTouch((event: TouchEvent): void => {
          this.onDragZoneTouch(event);
        })

        // 中部空白拖拽区
        Blank()
          .onTouch((event: TouchEvent): void => {
            this.onDragZoneTouch(event);
          })

        // 右上角系统三键（最小化/最大化/关闭）避让区：标题栏隐藏后三键下沉到页面内
        if (appState.decorButtonWidth > 0) {
          Row()
            .width(appState.decorButtonWidth)
            .height(44)
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: appState.decorButtonWidth > 0 ? 8 : 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: appState.topRect })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .border({ width: { bottom: 1 }, color: $r('sys.color.comp_divider') })
  }
}

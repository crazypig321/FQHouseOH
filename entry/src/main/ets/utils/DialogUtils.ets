/**
 * 公共弹窗管理（参考 musicfreeOH DialogManager，适配本项目）：
 * 宿主页（持有 CustomDialogController）aboutToAppear 时经 Register 注册
 * 打开/轻提示/关闭动作，aboutToDisappear 时经 Unregister 注销；
 * 各处经 OpenDialog(key) 打开弹窗，宿主内容构建按 dialogChangeKey 分发内容组件；
 * 弹窗消失时宿主 onWillDisappear 调 DisappearDialog 清理状态并触发一次性关闭回调。
 */

import { ButtonOptions } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { appState } from '../entryability/AppState';
import { FqWebDavBackupEntry } from '../core/FqWebDav';
import { FqCustomReaderTheme } from '../core/FqReaderStore';

/** 公共弹窗管理器：弹窗标识/宿主动作/生命周期回调的静态集散地。 */
export class DialogManager {
  /** 当前弹窗标识（如「通用确认」；空串表示当前无弹窗）。 */
  public static dialogChangeKey: string = '';

  /** 弹窗关闭回调（一次性，触发后自动清空）。 */
  public static onDialogClosed: (() => void) | null = null;

  // ===== 通用确认弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 通用确认弹窗标题。 */
  public static confirmTitle: string = '';
  /** 通用确认弹窗正文。 */
  public static confirmMessage: string = '';
  /** 通用确认弹窗确认按钮文案（移出/删除/清空等）。 */
  public static confirmLabel: string = '确定';
  /** 通用确认弹窗确认回调（点击确认后执行；取消/关闭弹窗不触发）。 */
  public static confirmCallback: (() => void) | null = null;

  // ===== 自定义颜色弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 自定义颜色弹窗：取色器起始色。 */
  public static customColorInitial: string = '#FF7A3D';
  /** 自定义颜色弹窗：当前拖选色（确认后回传，取消丢弃）。 */
  public static customColorPicked: string = '#FF7A3D';
  /** 自定义颜色弹窗确认回调（确认后执行并回传所选色；取消/关闭不触发）。 */
  private static customColorConfirmCallback: ((hex: string) => void) | null = null;

  // ===== WebDAV 备份选择弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 远端备份条目列表。 */
  public static webdavBackupEntries: FqWebDavBackupEntry[] = [];
  /** 当前选中条目下标。 */
  public static webdavBackupIndex: number = 0;
  /** 选中确认回调（回传备份文件名；取消/关闭不触发）。 */
  private static webdavBackupPick: ((fileName: string) => void) | null = null;

  // ===== WebDAV 备份保留数量弹窗参数（打开前由调用方赋值，弹窗关闭后自动清空） =====
  /** 保留数量输入文本。 */
  public static webdavCountValue: string = '';
  /** 保留数量确认回调（回传 1-50 整数；取消/关闭不触发）。 */
  private static webdavCountConfirm: ((count: number) => void) | null = null;

  // ===== 自定义阅读主题编辑弹窗参数（独立宿主弹窗，打开前由调用方赋值，关闭后自动清空） =====
  /** 编辑中主题名称（输入框双向值）。 */
  public static readerThemeName: string = '';
  /** 编辑中浅色模式背景图路径。 */
  public static readerThemeLightBg: string = '';
  /** 编辑中浅色模式正文字色（空 = 默认墨黑）。 */
  public static readerThemeLightFontColor: string = '';
  /** 编辑中浅色模式字号（0 = 跟随全局）。 */
  public static readerThemeLightFontSize: number = 0;
  /** 编辑中浅色模式字体档位（-1 = 跟随全局）。 */
  public static readerThemeLightFontIndex: number = -1;
  /** 编辑中浅色模式行距（0 = 跟随全局）。 */
  public static readerThemeLightLineHeight: number = 0;
  /** 编辑中深色模式背景图路径。 */
  public static readerThemeDarkBg: string = '';
  /** 编辑中深色模式正文字色（空 = 默认夜间灰）。 */
  public static readerThemeDarkFontColor: string = '';
  /** 编辑中深色模式字号（0 = 跟随全局）。 */
  public static readerThemeDarkFontSize: number = 0;
  /** 编辑中深色模式字体档位（-1 = 跟随全局）。 */
  public static readerThemeDarkFontIndex: number = -1;
  /** 编辑中深色模式行距（0 = 跟随全局）。 */
  public static readerThemeDarkLineHeight: number = 0;
  /** 保存回调（保存按钮触发，回传双模式草稿；取消/关闭不触发）。 */
  private static readerThemeSaveCallback: ((draft: FqCustomReaderTheme) => void) | null = null;
  /** 删除回调（弹窗内「删除该主题」触发；取消/关闭不触发）。 */
  private static readerThemeDeleteCallback: ((id: string) => void) | null = null;
  /** 名称实时回调（输入框逐字触发，设置弹窗主题行标签即时跟随；仅编辑模式）。 */
  private static readerThemeNameLiveCallback: ((id: string, name: string) => void) | null = null;
  /** 编辑中的主题 id（空串 = 新建模式）。 */
  private static readerThemeEditId: string = '';
  /** 本次编辑会话新导入、尚未随保存落账的背景图文件（取消/关闭时删除清理）。 */
  private static readerThemeImportedFiles: string[] = [];

  // ===== 宿主注册动作（由持有 CustomDialogController 的页面注入） =====
  private static opener: (() => void) | null = null;
  private static toaster: ((message: string) => void) | null = null;
  private static closer: (() => void) | null = null;

  /** 注册弹窗宿主：opener 打开弹窗、toaster 轻提示、closer 关闭弹窗。 */
  public static Register(opener: () => void, toaster: (message: string) => void,
    closer: () => void): void {
    DialogManager.opener = opener;
    DialogManager.toaster = toaster;
    DialogManager.closer = closer;
  }

  /** 注销弹窗宿主（页面 aboutToDisappear 调用，防悬空回调与残留标识）。 */
  public static Unregister(): void {
    DialogManager.opener = null;
    DialogManager.toaster = null;
    DialogManager.closer = null;
    DialogManager.onDialogClosed = null;
    DialogManager.dialogChangeKey = '';
  }

  /** 打开弹窗：key 写入 dialogChangeKey 后交宿主打开，内容按 key 分发。 */
  public static OpenDialog(key: string): void {
    DialogManager.dialogChangeKey = key;
    if (DialogManager.opener !== null) {
      DialogManager.opener();
    }
  }

  /** 关闭弹窗（由弹窗内自定义动作完成后调用）。 */
  public static CloseDialog(): void {
    if (DialogManager.closer !== null) {
      DialogManager.closer();
    }
  }

  /** 弹窗内轻提示。 */
  public static Toast(message: string): void {
    if (DialogManager.toaster !== null) {
      DialogManager.toaster(message);
    }
  }

  /** 通用确认弹窗（移出书架/删除记录/清空书架/清空浏览历史等共用）：
   *  title 标题、message 正文、confirmLabel 确认按钮文案，onConfirm 点确认后执行（取消/关闭不触发）。 */
  public static ShowConfirm(title: string, message: string, confirmLabel: string, onConfirm: () => void): void {
    DialogManager.confirmTitle = title;
    DialogManager.confirmMessage = message;
    DialogManager.confirmLabel = confirmLabel;
    DialogManager.confirmCallback = onConfirm;
    DialogManager.OpenDialog('通用确认');
  }

  /** 自定义颜色弹窗（HSB 取色器 + 确认/取消）：initial 取色器起始色，onConfirm 确认后回传所选色（取消/关闭不触发）。 */
  public static ShowCustomColorPicker(initial: string, onConfirm: (hex: string) => void): void {
    DialogManager.customColorInitial = initial;
    DialogManager.customColorPicked = initial;
    DialogManager.customColorConfirmCallback = onConfirm;
    DialogManager.OpenDialog('自定义颜色');
  }

  /** WebDAV 远端备份选择弹窗：entries 远端备份列表（新在前），onPick 选中确认后回传备份文件名。 */
  public static SelectWebDavBackup(entries: FqWebDavBackupEntry[], onPick: (fileName: string) => void): void {
    DialogManager.webdavBackupEntries = entries;
    DialogManager.webdavBackupIndex = 0;
    DialogManager.webdavBackupPick = onPick;
    DialogManager.OpenDialog('选择WebDAV备份');
  }

  /** WebDAV 备份保留数量弹窗：current 当前值，onConfirm 确认后回传 1-50 整数。 */
  public static InputWebDavBackupCount(current: number, onConfirm: (count: number) => void): void {
    DialogManager.webdavCountValue = current.toString();
    DialogManager.webdavCountConfirm = onConfirm;
    DialogManager.OpenDialog('备份保留数量');
  }

  /** 自定义阅读主题编辑弹窗：initial 为待编辑主题（null = 新建模式，无删除行），
   *  onSave 保存回调（回传双模式草稿，id 为空 = 新建），onDelete 删除回调（仅编辑模式），
   *  onNameLive 名称实时回调（仅编辑模式，输入即写回主题行标签）。 */
  public static ShowReaderThemeEditor(initial: FqCustomReaderTheme | null,
    onSave: (draft: FqCustomReaderTheme) => void,
    onDelete: (id: string) => void,
    onNameLive: (id: string, name: string) => void): void {
    DialogManager.readerThemeEditId = initial === null ? '' : initial.id;
    DialogManager.readerThemeName = initial === null ? '' : initial.name;
    DialogManager.readerThemeLightBg = initial === null ? '' : initial.lightBgPath;
    DialogManager.readerThemeLightFontColor = initial === null ? '' : initial.lightFontColor;
    DialogManager.readerThemeLightFontSize = initial === null ? 0 : initial.lightFontSize;
    DialogManager.readerThemeLightFontIndex = initial === null ? -1 : initial.lightFontIndex;
    DialogManager.readerThemeLightLineHeight = initial === null ? 0 : initial.lightLineHeight;
    DialogManager.readerThemeDarkBg = initial === null ? '' : initial.darkBgPath;
    DialogManager.readerThemeDarkFontColor = initial === null ? '' : initial.darkFontColor;
    DialogManager.readerThemeDarkFontSize = initial === null ? 0 : initial.darkFontSize;
    DialogManager.readerThemeDarkFontIndex = initial === null ? -1 : initial.darkFontIndex;
    DialogManager.readerThemeDarkLineHeight = initial === null ? 0 : initial.darkLineHeight;
    DialogManager.readerThemeImportedFiles = [];
    DialogManager.readerThemeSaveCallback = onSave;
    DialogManager.readerThemeDeleteCallback = onDelete;
    DialogManager.readerThemeNameLiveCallback = onNameLive;
    DialogManager.OpenDialog('自定义主题编辑');
  }

  /** 编辑弹窗标题（新建/编辑）。 */
  public static ReaderThemeEditorTitle(): string {
    return DialogManager.readerThemeEditId.length === 0 ? '新建自定义主题' : '编辑自定义主题';
  }

  /** 编辑弹窗是否为编辑模式（非新建）。 */
  public static IsReaderThemeEditorEdit(): boolean {
    return DialogManager.readerThemeEditId.length > 0;
  }

  /** 编辑弹窗名称实时写回（输入框 onChange 逐字触发；新建模式忽略）。 */
  public static LiveReaderThemeName(name: string): void {
    const id: string = DialogManager.readerThemeEditId;
    const cb: ((id: string, name: string) => void) | null = DialogManager.readerThemeNameLiveCallback;
    if (cb !== null && id.length > 0) {
      cb(id, name);
    }
  }

  /** 编辑弹窗选图导入记账：新图 path 落入未保存清单；
   *  previous 为被顶替的旧图（若也是本次未保存导入则立即删除，防止孤儿文件）。 */
  public static TrackReaderThemeBgImport(previous: string, path: string): void {
    const list: string[] = DialogManager.readerThemeImportedFiles;
    const index: number = list.indexOf(previous);
    if (index >= 0) {
      list.splice(index, 1);
      try {
        fileIo.unlinkSync(previous);
      } catch (unlinkError) {
        // 文件可能已被清理
      }
    }
    if (path.length > 0) {
      list.push(path);
    }
  }

  /** 编辑弹窗保存成功：导入图片落账（保留文件，清空未保存清单）。 */
  public static SettleReaderThemeBgImports(): void {
    DialogManager.readerThemeImportedFiles = [];
  }

  /** 编辑弹窗保存（保存按钮 action 调用；弹窗自动关闭）：
   *  由双模式静态值组装草稿回调；新建模式双模式图均空时提示不保存。 */
  public static ConfirmReaderThemeEditor(): void {
    const id: string = DialogManager.readerThemeEditId;
    const cb: ((draft: FqCustomReaderTheme) => void) | null = DialogManager.readerThemeSaveCallback;
    if (cb === null) {
      return;
    }
    const draft: FqCustomReaderTheme = new FqCustomReaderTheme();
    draft.id = id;
    draft.name = DialogManager.readerThemeName;
    draft.lightBgPath = DialogManager.readerThemeLightBg;
    draft.lightFontColor = DialogManager.readerThemeLightFontColor;
    draft.lightFontSize = DialogManager.readerThemeLightFontSize;
    draft.lightFontIndex = DialogManager.readerThemeLightFontIndex;
    draft.lightLineHeight = DialogManager.readerThemeLightLineHeight;
    draft.darkBgPath = DialogManager.readerThemeDarkBg;
    draft.darkFontColor = DialogManager.readerThemeDarkFontColor;
    draft.darkFontSize = DialogManager.readerThemeDarkFontSize;
    draft.darkFontIndex = DialogManager.readerThemeDarkFontIndex;
    draft.darkLineHeight = DialogManager.readerThemeDarkLineHeight;
    if (draft.lightBgPath.length === 0 && draft.darkBgPath.length === 0) {
      DialogManager.Toast('请至少选择一张背景图');
      return;
    }
    cb(draft);
  }

  /** 编辑弹窗删除：先关弹窗再触发回调（回调内可再开确认弹窗，避免弹窗键冲突）。 */
  public static RequestReaderThemeEditorDelete(): void {
    const id: string = DialogManager.readerThemeEditId;
    const cb: ((id: string) => void) | null = DialogManager.readerThemeDeleteCallback;
    DialogManager.CloseDialog();
    if (cb !== null && id.length > 0) {
      cb(id);
    }
  }

  /** 编辑弹窗消失清理（编辑弹窗宿主 onWillDisappear 调用）：
   *  未保存的新导入图片删除回收，一次性参数回收。 */
  public static ClearReaderThemeEditor(): void {
    for (const path of DialogManager.readerThemeImportedFiles) {
      try {
        fileIo.unlinkSync(path);
      } catch (unlinkError) {
        // 文件可能已被清理
      }
    }
    DialogManager.readerThemeImportedFiles = [];
    DialogManager.readerThemeEditId = '';
    DialogManager.readerThemeName = '';
    DialogManager.readerThemeLightBg = '';
    DialogManager.readerThemeLightFontColor = '';
    DialogManager.readerThemeLightFontSize = 0;
    DialogManager.readerThemeLightFontIndex = -1;
    DialogManager.readerThemeLightLineHeight = 0;
    DialogManager.readerThemeDarkBg = '';
    DialogManager.readerThemeDarkFontColor = '';
    DialogManager.readerThemeDarkFontSize = 0;
    DialogManager.readerThemeDarkFontIndex = -1;
    DialogManager.readerThemeDarkLineHeight = 0;
    DialogManager.readerThemeSaveCallback = null;
    DialogManager.readerThemeDeleteCallback = null;
    DialogManager.readerThemeNameLiveCallback = null;
  }

  /** 弹窗标题（宿主渲染时读取）。 */
  public static DialogTitle(key: string): ResourceStr {
    if (key === '通用确认') {
      return DialogManager.confirmTitle;
    }
    if (key === '自定义颜色') {
      return '自定义颜色';
    }
    if (key === '选择WebDAV备份') {
      return '选择备份文件';
    }
    if (key === '备份保留数量') {
      return '备份保留数量';
    }
    return '';
  }

  /** 弹窗底部按钮（宿主渲染时读取；CustomContentDialog 点击按钮后自动关闭）。 */
  public static DialogButtons(key: string): Array<ButtonOptions> {
    if (key === '通用确认' || key === '自定义颜色' ||
      key === '选择WebDAV备份' || key === '备份保留数量' || key === '自定义主题编辑') {
      const cancel: ButtonOptions = {
        value: '取消',
        fontColor: appState.accentColor,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => {
        }
      };
      let confirmLabel: string = '确认';
      if (key === '通用确认') {
        confirmLabel = DialogManager.confirmLabel;
      } else if (key === '选择WebDAV备份') {
        confirmLabel = '恢复';
      } else if (key === '备份保留数量') {
        confirmLabel = '确定';
      } else if (key === '自定义主题编辑') {
        confirmLabel = '保存';
      }
      const confirm: ButtonOptions = {
        value: confirmLabel,
        fontColor: Color.White,
        background: appState.accentColor,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        action: (): void => {
          DialogManager.ConfirmButtonDialog(key);
        }
      };
      return [cancel, confirm];
    }
    return [];
  }

  /** 弹窗确认键回调（宿主按钮 action 调用）。 */
  public static ConfirmButtonDialog(key: string): void {
    if (key === '通用确认') {
      const cb: (() => void) | null = DialogManager.confirmCallback;
      if (cb !== null) {
        cb();
      }
    }
    if (key === '自定义颜色') {
      const cb: ((hex: string) => void) | null = DialogManager.customColorConfirmCallback;
      if (cb !== null) {
        cb(DialogManager.customColorPicked);
      }
    }
    if (key === '自定义主题编辑') {
      DialogManager.ConfirmReaderThemeEditor();
    }
    if (key === '选择WebDAV备份') {
      const index: number = DialogManager.webdavBackupIndex;
      const entries: FqWebDavBackupEntry[] = DialogManager.webdavBackupEntries;
      const pick: ((fileName: string) => void) | null = DialogManager.webdavBackupPick;
      if (index >= 0 && index < entries.length && pick !== null) {
        pick(entries[index].fileName);
      }
    }
    if (key === '备份保留数量') {
      const count: number = parseInt(DialogManager.webdavCountValue, 10);
      if (Number.isNaN(count) || count < 1 || count > 50) {
        DialogManager.Toast('请输入 1-50 之间的整数');
        return;
      }
      const cb: ((value: number) => void) | null = DialogManager.webdavCountConfirm;
      if (cb !== null) {
        cb(count);
      }
    }
  }

  /** 弹窗消失清理（宿主 onWillDisappear 调用）：清标识、触发一次性关闭回调。 */
  public static DisappearDialog(key: string): void {
    if (key !== DialogManager.dialogChangeKey) {
      return;
    }
    DialogManager.dialogChangeKey = '';
    // 通用确认弹窗参数一次性，关闭后清理（取消/关闭不触发确认回调）
    if (key === '通用确认') {
      DialogManager.confirmTitle = '';
      DialogManager.confirmMessage = '';
      DialogManager.confirmLabel = '确定';
      DialogManager.confirmCallback = null;
    }
    // 自定义颜色弹窗参数一次性，关闭后清理（取消丢弃拖选色）
    if (key === '自定义颜色') {
      DialogManager.customColorInitial = '#FF7A3D';
      DialogManager.customColorPicked = '#FF7A3D';
      DialogManager.customColorConfirmCallback = null;
    }
    // WebDAV 备份选择弹窗参数一次性，关闭后清理
    if (key === '选择WebDAV备份') {
      DialogManager.webdavBackupEntries = [];
      DialogManager.webdavBackupIndex = 0;
      DialogManager.webdavBackupPick = null;
    }
    // WebDAV 备份保留数量弹窗参数一次性，关闭后清理
    if (key === '备份保留数量') {
      DialogManager.webdavCountValue = '';
      DialogManager.webdavCountConfirm = null;
    }
    const cb: (() => void) | null = DialogManager.onDialogClosed;
    DialogManager.onDialogClosed = null;
    if (cb !== null) {
      cb();
    }
  }
}

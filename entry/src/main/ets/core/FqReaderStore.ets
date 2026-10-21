/**
 * 阅读进度与阅读设置持久化（preferences，参考 musicfreeOH KVStore 用法）：
 * - 进度：每本书 { chapterIndex, domPos }（Reader Kit pageShow 的 startDomPos）。
 * - 设置：字号/行距/主题/翻页方式，全局共享，内存单例 + 落盘。
 */

import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fqAsRecord } from './FqJson';

const FQ_READER_STORE_NAME: string = 'fq_reader';
const FQ_READER_KEY_SETTINGS: string = 'settings';
const FQ_READER_KEY_PROGRESS: string = 'progress_';

/** 单书阅读进度。 */
export class FqReaderProgress {
  readonly chapterIndex: number;
  readonly domPos: string;

  constructor(chapterIndex: number, domPos: string) {
    this.chapterIndex = chapterIndex;
    this.domPos = domPos;
  }
}

/** 阅读设置（构造即默认值）。 */
export class FqReaderSettings {
  fontSize: number = 19;
  lineHeight: number = 1.9;
  /** -1 跟随系统深浅色 / 0 纸白 / 1 米黄 / 2 夜间。 */
  themeIndex: number = -1;
  /** 0 仿真翻页 / 1 横滑翻页。 */
  flipIndex: number = 0;
  /** 字体档位（FQ_FONT_OPTIONS 下标）：0 书宋 / 1 黑体。 */
  fontIndex: number = 0;
}

function fqClampFontSize(value: number): number {
  return Math.min(32, Math.max(12, Math.round(value)));
}

function fqClampLineHeight(value: number): number {
  return Math.min(2.6, Math.max(1.2, Math.round(value * 10) / 10));
}

export class FqReaderStore {
  private static pref: preferences.Preferences | null = null;
  private static settings: FqReaderSettings = new FqReaderSettings();

  public static init(context: common.Context): void {
    if (FqReaderStore.pref !== null) {
      return;
    }
    try {
      FqReaderStore.pref = preferences.getPreferencesSync(context, { name: FQ_READER_STORE_NAME });
    } catch (error) {
      FqReaderStore.pref = null;
      return;
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = FqReaderStore.pref.getSync(FQ_READER_KEY_SETTINGS, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = parsed === null ? null : fqAsRecord(parsed);
      if (rec === null) {
        return;
      }
      const fontSize: Object | undefined = rec['fontSize'];
      if (typeof fontSize === 'number') {
        FqReaderStore.settings.fontSize = fqClampFontSize(fontSize);
      }
      const lineHeight: Object | undefined = rec['lineHeight'];
      if (typeof lineHeight === 'number') {
        FqReaderStore.settings.lineHeight = fqClampLineHeight(lineHeight);
      }
      const themeIndex: Object | undefined = rec['themeIndex'];
      if (typeof themeIndex === 'number') {
        FqReaderStore.settings.themeIndex = Math.min(2, Math.max(-1, Math.trunc(themeIndex)));
      }
      // 旧版本数据（无版本号）迁移：主题重置为跟随系统（旧版无跟随档，存值语义已变化）
      const version: Object | undefined = rec['v'];
      if (typeof version !== 'number' || Math.trunc(version) < 2) {
        FqReaderStore.settings.themeIndex = -1;
      }
      const flipIndex: Object | undefined = rec['flipIndex'];
      if (typeof flipIndex === 'number') {
        FqReaderStore.settings.flipIndex = Math.min(1, Math.max(0, Math.trunc(flipIndex)));
      }
      const fontIndex: Object | undefined = rec['fontIndex'];
      if (typeof fontIndex === 'number') {
        FqReaderStore.settings.fontIndex = Math.max(0, Math.trunc(fontIndex));
      }
    } catch (error) {
      // 损坏配置按默认处理
    }
  }

  public static getSettings(): FqReaderSettings {
    return FqReaderStore.settings;
  }

  public static saveSettings(fontSize: number, lineHeight: number,
    themeIndex: number, flipIndex: number, fontIndex: number): void {
    FqReaderStore.settings.fontSize = fqClampFontSize(fontSize);
    FqReaderStore.settings.lineHeight = fqClampLineHeight(lineHeight);
    FqReaderStore.settings.themeIndex = Math.min(2, Math.max(-1, Math.trunc(themeIndex)));
    FqReaderStore.settings.flipIndex = Math.min(1, Math.max(0, Math.trunc(flipIndex)));
    FqReaderStore.settings.fontIndex = Math.max(0, Math.trunc(fontIndex));
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null) {
      return;
    }
    const rec: Record<string, Object> = {};
    rec['v'] = 2;
    rec['fontSize'] = FqReaderStore.settings.fontSize;
    rec['lineHeight'] = FqReaderStore.settings.lineHeight;
    rec['themeIndex'] = FqReaderStore.settings.themeIndex;
    rec['flipIndex'] = FqReaderStore.settings.flipIndex;
    rec['fontIndex'] = FqReaderStore.settings.fontIndex;
    try {
      pref.putSync(FQ_READER_KEY_SETTINGS, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }

  /** 读取单书进度；无记录时 chapterIndex 为 -1。 */
  public static getProgress(bookId: string): FqReaderProgress {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return new FqReaderProgress(-1, '');
    }
    let text: string = '';
    try {
      const raw: preferences.ValueType = pref.getSync(`${FQ_READER_KEY_PROGRESS}${bookId}`, '');
      if (typeof raw === 'string') {
        text = raw;
      }
    } catch (error) {
      return new FqReaderProgress(-1, '');
    }
    if (text.length === 0) {
      return new FqReaderProgress(-1, '');
    }
    try {
      const parsed: Object | null = JSON.parse(text);
      const rec: Record<string, Object> | null = parsed === null ? null : fqAsRecord(parsed);
      if (rec === null) {
        return new FqReaderProgress(-1, '');
      }
      const chapterIndex: Object | undefined = rec['chapterIndex'];
      const domPos: Object | undefined = rec['domPos'];
      if (typeof chapterIndex !== 'number' || typeof domPos !== 'string') {
        return new FqReaderProgress(-1, '');
      }
      return new FqReaderProgress(Math.trunc(chapterIndex), domPos);
    } catch (error) {
      return new FqReaderProgress(-1, '');
    }
  }

  public static saveProgress(bookId: string, chapterIndex: number, domPos: string): void {
    const pref: preferences.Preferences | null = FqReaderStore.pref;
    if (pref === null || bookId.length === 0) {
      return;
    }
    const rec: Record<string, Object> = {};
    rec['chapterIndex'] = chapterIndex;
    rec['domPos'] = domPos;
    try {
      pref.putSync(`${FQ_READER_KEY_PROGRESS}${bookId}`, JSON.stringify(rec));
      pref.flush().catch((_error: BusinessError): void => {
        // 落盘失败不阻断
      });
    } catch (error) {
      // 忽略写入失败
    }
  }
}

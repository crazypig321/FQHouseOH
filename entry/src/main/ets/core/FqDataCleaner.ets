/**
 * 清除所有数据（设置页「清除所有数据」）。
 *
 * 一次清空：
 * - 全部 preferences KV：浏览 / 搜索 / 收听 / 观看记录、阅读统计、书架收藏、阅读进度与阅读设置、
 *   应用设置（深色模式 / 后台播放 / 代理下载）、首页缓存、剧集 / 听书 / 漫画缓存索引、本地书籍索引；
 * - filesDir 下各数据目录：chapter_cache（章节缓存）、detail_cache（详情缓存）、home_feed_cache（首页流缓存）、
 *   offline_video（剧集离线）、offline_audio（听书离线）、offline_comic（漫画离线）、local_books（本地书籍文件）、
 *   fq_reader_bg（自定义阅读背景图）；
 * - 沙箱 cacheDir 临时缓存（更新包中转等）。
 *
 * 保留（白名单式删除，未列入一律不动）：
 * - 公共导出目录 Download/<包名>/（沙箱外，用户可见的导出文件，任何情况不做清除）；
 * - 沙箱导出回退目录 filesDir/export（resolveDownloadRoot 失败时的导出落点，同样保留）；
 * - 后端运行时（backend）、阅读器字体、设备池密钥（Asset Store Kit，非应用数据）。
 *
 * 清除完成后由调用方 restartApp 重启应用：各 store 内存态随进程销毁，
 * 无需逐 store 刷新（store 均以 EntryAbility context 初始化，getPreferencesSync 命中同一实例，
 * clearSync 后即使有在途 flush 也只会写出已清空状态）；DOWNLOAD 模式授予的
 * Download/<包名> 持久化目录权限由系统管理，不随 KV 清除丢失，重启后可直接继续导出。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { hilog } from '@kit.PerformanceAnalysisKit';

const FQ_DATA_CLEAN_TAG: string = 'FqDataCleaner';

/** 全部 preferences 存储名（新增 KV store 时需同步维护）。 */
const FQ_PREF_NAMES: string[] = [
  'fq_browse_history',
  'fq_search_history',
  'fq_listen_history',
  'fq_watched',
  'fq_read_stats',
  'fq_shelf',
  'fq_reader',
  'fq_app_settings',
  'fq_home_cache',
  'fq_audio_cache',
  'fq_drama_cache',
  'fq_comic_cache',
  'fq_local_books',
];

/** filesDir 下需删除的数据目录名（新增数据目录时需同步维护）。 */
const FQ_DATA_DIR_NAMES: string[] = [
  'chapter_cache',
  'detail_cache',
  'home_feed_cache',
  'offline_video',
  'offline_audio',
  'offline_comic',
  'local_books',
  'fq_reader_bg',
];

export class FqDataCleaner {
  /** 清空全部 KV 与数据目录、沙箱缓存；返回是否全部成功（部分失败仅记日志，不阻断整体清除）。 */
  public static async clearAll(context: common.Context): Promise<boolean> {
    let ok: boolean = true;
    for (const name of FQ_PREF_NAMES) {
      try {
        const pref: preferences.Preferences = preferences.getPreferencesSync(context, { name: name });
        pref.clearSync();
        await pref.flush();
      } catch (error) {
        ok = false;
        hilog.error(0x0000, FQ_DATA_CLEAN_TAG, `clear pref ${name} failed: ${JSON.stringify(error)}`);
      }
    }
    for (const dirName of FQ_DATA_DIR_NAMES) {
      if (!FqDataCleaner.removeDir(`${context.filesDir}/${dirName}`)) {
        ok = false;
      }
    }
    if (!FqDataCleaner.clearDirContents(context.cacheDir)) {
      ok = false;
    }
    return ok;
  }

  /** 删除整个目录（含全部内容；不存在视为成功）。 */
  private static removeDir(path: string): boolean {
    try {
      if (fs.accessSync(path)) {
        fs.rmdirSync(path);
      }
      return true;
    } catch (error) {
      hilog.error(0x0000, FQ_DATA_CLEAN_TAG, `remove dir ${path} failed: ${JSON.stringify(error)}`);
      return false;
    }
  }

  /** 清空目录内容但保留目录本身（cacheDir 沙箱缓存）。 */
  private static clearDirContents(dir: string): boolean {
    let ok: boolean = true;
    try {
      if (!fs.accessSync(dir)) {
        return true;
      }
      const names: string[] = fs.listFileSync(dir);
      for (const name of names) {
        if (!FqDataCleaner.removeDir(`${dir}/${name}`)) {
          ok = false;
        }
      }
    } catch (error) {
      ok = false;
      hilog.error(0x0000, FQ_DATA_CLEAN_TAG, `clear dir ${dir} failed: ${JSON.stringify(error)}`);
    }
    return ok;
  }
}

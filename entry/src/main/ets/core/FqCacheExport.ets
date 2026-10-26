/**
 * 缓存导出（章节缓存 → 合并 txt / 剧集缓存 → mp4 副本）。
 *
 * 对齐 musicfreeOH PathConst 的公共下载目录方案：
 * - 导出目录固定为公共 Download/<bundleName>/（fileUri 同步构造，无沙箱回落）；
 * - 目录不可用时通过 DOWNLOAD 模式 save（免弹窗）让系统自动重建
 *   Download/包名/ 并授予持久化权限，随后清理预置的占位空文件；
 * - 授权后直接 fs 写入（应用仅可访问自己包名子树，FAQ 67 语义）。
 */

import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqCachedEpisode, FqDramaCacheStore } from './FqDramaCacheStore';
import { FqChapterCacheStore } from './FqChapterCacheStore';

const TAG: string = 'FqCacheExport';

let downloadRoot: string = '';

/** 文件名清洗：去非法字符与首尾空白，超长截断，空结果回退 fallback。 */
function fqSanitizeName(raw: string, fallback: string): string {
  let name: string = raw.replace(/[\\/:*?"<>|]/g, ' ').trim();
  if (name.length > 80) {
    name = name.substring(0, 80).trim();
  }
  return name.length > 0 ? name : fallback;
}

/** 导出目录名（= 应用包名，Download/ 下的固定子目录；弹窗提示文案用）。 */
export function fqExportDirName(): string {
  try {
    const bundleInfo: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    if (bundleInfo.name.length > 0) {
      return bundleInfo.name;
    }
  } catch (error) {
    // 回退默认名
  }
  return 'FQHouseOH';
}

/** 同步构造公共下载目录 Download/<bundleName>/ 路径；失败回退沙箱 export 目录。 */
function resolveDownloadRoot(context: common.Context): string {
  try {
    const bundleInfo: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const dirPath: string =
      new fileUri.FileUri('file://docs/storage/Users/currentUser/Download/' + bundleInfo.name).path;
    if (dirPath.length > 0) {
      return dirPath;
    }
  } catch (error) {
    hilog.warn(0x0001, TAG, 'resolve download root failed');
  }
  return `${context.filesDir}/export`;
}

/** 探测目录可写性：不存在则尝试直接 mkdir（公共 Download 下通常被拒绝）。 */
function probeWritable(dir: string): boolean {
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return true;
  } catch (error) {
    return false;
  }
}

/** DOWNLOAD 模式保存（免弹窗）：系统自动重建 Download/包名/ 并授予持久化权限。 */
async function rebuildViaDownloadMode(context: common.Context): Promise<void> {
  try {
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const uris: string[] = await docPicker.save(saveOptions);
    for (const u of uris) {
      try {
        const placeholder: string = new fileUri.FileUri(u).path;
        // 防御：仅清理 0 字节占位空文件，任何有内容的文件（含历史导出）一律不动
        if (fs.accessSync(placeholder) && fs.statSync(placeholder).size === 0) {
          fs.unlinkSync(placeholder);
        }
      } catch (error) {
        // 占位文件清理失败不影响目录可用性
      }
    }
  } catch (error) {
    // 重建失败由外层探测兜底
  }
}

/** 确保导出根目录就绪（懒解析 + 按需 DOWNLOAD 模式重建）；不可用抛错。 */
async function ensureExportRoot(context: common.Context): Promise<string> {
  if (downloadRoot.length === 0) {
    downloadRoot = resolveDownloadRoot(context);
  }
  if (probeWritable(downloadRoot)) {
    return downloadRoot;
  }
  hilog.info(0x0001, TAG, `download root missing, rebuild via download mode: ${downloadRoot}`);
  await rebuildViaDownloadMode(context);
  if (probeWritable(downloadRoot)) {
    hilog.info(0x0001, TAG, `download root rebuilt: ${downloadRoot}`);
    return downloadRoot;
  }
  throw new Error('导出目录不可用，请重试');
}

/**
 * 导出一本缓存书：按 catalog 章节顺序合并已缓存正文，
 * 直接写入 Download/<包名>/书名.txt；返回导出文件路径。
 * 无目录或全部章节未缓存时抛错。
 */
export async function fqExportCachedBook(context: common.Context, bookId: string): Promise<string> {
  const catalog = FqChapterCacheStore.catalog(bookId);
  if (catalog === null) {
    throw new Error('未找到缓存目录数据');
  }
  const parts: string[] = [];
  let exported: number = 0;
  for (const chapter of catalog.chapters) {
    const text: string = FqChapterCacheStore.read(bookId, chapter.itemId);
    if (text.trim().length === 0) {
      continue;
    }
    exported++;
    parts.push(chapter.title.length > 0 ? chapter.title : '');
    parts.push('');
    parts.push(text.trim());
    parts.push('');
    parts.push('');
  }
  if (exported === 0) {
    throw new Error('暂无已缓存章节可导出');
  }
  const root: string = await ensureExportRoot(context);
  const path: string = `${root}/${fqSanitizeName(catalog.title, bookId)}.txt`;
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, parts.join('\n'));
    fs.closeSync(file);
    hilog.info(0x0001, TAG, `export book ok: ${path} chapters=${exported}`);
    return path;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(0x0001, TAG, `export book failed: ${path} code=${err.code} msg=${err.message}`);
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeError) {
        // 忽略
      }
    }
    throw new Error('导出失败，请重试');
  }
}

/**
 * 导出一集缓存剧集：在 Download/<包名>/<剧名>/ 下创建
 * 第N集 标题.mp4 后拷入缓存正文；返回导出文件路径。
 * 源文件缺失时抛错。
 */
export async function fqExportCachedEpisode(context: common.Context,
  episode: FqCachedEpisode): Promise<string> {
  const srcPath: string = FqDramaCacheStore.filePath(episode.itemId);
  let exists: boolean = false;
  try {
    exists = fs.accessSync(srcPath);
  } catch (error) {
    exists = false;
  }
  if (!exists) {
    throw new Error('缓存文件缺失，请重新下载');
  }
  const root: string = await ensureExportRoot(context);
  const seriesDir: string = `${root}/${fqSanitizeName(episode.seriesTitle, episode.seriesId)}`;
  if (!probeWritable(seriesDir)) {
    throw new Error('创建剧集目录失败，请重试');
  }
  const path: string = `${seriesDir}/${
    fqSanitizeName(`第${episode.index}集 ${episode.title}`, episode.itemId)}.mp4`;
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.copyFileSync(srcPath, file.fd);
    fs.closeSync(file);
    hilog.info(0x0001, TAG, `export episode ok: ${path}`);
    return path;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(0x0001, TAG, `export episode failed: ${path} code=${err.code} msg=${err.message}`);
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeError) {
        // 忽略
      }
    }
    throw new Error('导出失败，请重试');
  }
}

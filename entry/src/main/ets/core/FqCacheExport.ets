/**
 * 缓存导出（章节缓存 → 合并 txt / 剧集缓存 → mp4 副本）。
 *
 * 默认导出到公共下载目录 Download/<bundleName>/（fileUri 构造，用户可见可读写）；
 * 构造失败回落应用沙箱 files/export/（实际不会发生）。
 * 文件名做非法字符清洗；目标重名直接覆盖。
 */

import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqCachedEpisode, FqDramaCacheStore } from './FqDramaCacheStore';
import { FqChapterCacheStore } from './FqChapterCacheStore';

const TAG: string = 'FqCacheExport';

/** 同步构造公共下载目录 Download/<bundleName>/ 路径（仅构造失败才回落沙箱，实际不会发生）。 */
export function fqResolvePublicDownloadPath(context: common.Context): string {
  try {
    const bundleInfo: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const uri: string = 'file://docs/storage/Users/currentUser/Download/' + bundleInfo.name;
    const dirPath: string = new fileUri.FileUri(uri).path;
    if (dirPath.length > 0) {
      return dirPath;
    }
  } catch (error) {
    const detail = error as BusinessError;
    hilog.error(0x0001, TAG, `构造公共下载目录失败: ${detail.code} ${detail.message}`);
  }
  return `${context.filesDir}/export/`;
}

/** 文件/目录名清洗：去非法字符与首尾空白，超长截断，空结果回退 fallback。 */
function fqSanitizeName(raw: string, fallback: string): string {
  let name: string = raw.replace(/[\\/:*?"<>|]/g, ' ').trim();
  if (name.length > 80) {
    name = name.substring(0, 80).trim();
  }
  return name.length > 0 ? name : fallback;
}

/** 目录确保存在：mkdir 递归模式对已存在目录抛 13900015，存在即成功。 */
function fqEnsureDir(dir: string): boolean {
  try {
    fs.mkdirSync(dir, true);
    return true;
  } catch (error) {
    try {
      return fs.accessSync(dir);
    } catch (accessError) {
      return false;
    }
  }
}

/**
 * 导出一本缓存书：按 catalog 章节顺序合并已缓存正文为单个 txt。
 * 返回导出文件路径；无目录或全部章节未缓存时抛错。
 * （章节正文为 KB 级小文件，同步读取耗时可控。）
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
  const root: string = fqResolvePublicDownloadPath(context);
  if (!fqEnsureDir(root)) {
    throw new Error('创建导出目录失败');
  }
  const fileName: string = `${fqSanitizeName(catalog.title, bookId)}.txt`;
  const path: string = `${root}/${fileName}`;
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
 * 导出一集缓存剧集：复制 mp4 到 Download/<bundleName>/<剧名>/第N集 标题.mp4。
 * mp4 体积大，用异步 copyFile 避免阻塞 UI 线程；源文件缺失时抛错。
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
  const root: string = fqResolvePublicDownloadPath(context);
  const seriesDir: string = `${root}/${fqSanitizeName(episode.seriesTitle, episode.seriesId)}`;
  if (!fqEnsureDir(root) || !fqEnsureDir(seriesDir)) {
    throw new Error('创建导出目录失败');
  }
  const fileName: string = `${fqSanitizeName(`第${episode.index}集 ${episode.title}`, episode.itemId)}.mp4`;
  const destPath: string = `${seriesDir}/${fileName}`;
  try {
    await fs.copyFile(srcPath, destPath);
    hilog.info(0x0001, TAG, `export episode ok: ${destPath}`);
    return destPath;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(0x0001, TAG, `export episode failed: ${destPath} code=${err.code} msg=${err.message}`);
    throw new Error('导出失败，请重试');
  }
}

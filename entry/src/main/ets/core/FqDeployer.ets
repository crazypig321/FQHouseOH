/**
 * 运行时资源部署器。
 *
 * 对齐 fqapp BackendService._deploy：把随包 rawfile/backend/** 复制到
 * filesDir/backend/**（config + filters + web + plugins），设备池文件首启从
 * example 种子化。构建期资源清单硬编码于此，规避 rawfile 目录枚举 API 的
 * 行为差异。
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const RAWFILE_ROOT: string = 'backend/';

const CONFIG_MANIFEST: string[] = [
  'config/config.json',
  'config/device_pool.example.json',
  'config/filter.json',
];

const RUNTIME_MANIFEST: string[] = [
  'filters/article.js',
  'filters/audio.js',
  'filters/author.js',
  'filters/book.js',
  'filters/chapter.js',
  'filters/comment.js',
  'filters/forum_id.js',
  'filters/item.js',
  'filters/manga.js',
  'filters/novel.js',
  'filters/rank.js',
  'filters/recommend.js',
  'filters/search.js',
  'filters/video.js',
  'filters/viewer.js',
  'plugins/manga_reader.html',
  'plugins/player.html',
  'web/assets/css/all.min.css',
  'web/assets/storage.js',
  'web/assets/webfonts/fa-solid-900.woff2',
  'web/comic.html',
  'web/detail.html',
  'web/favicon.png',
  'web/index.html',
  'web/listen.html',
  'web/read.html',
  'web/video.html',
];

export class FqDeployer {
  /**
   * 部署全部运行时文件。幂等：已存在且内容一致时跳过写入。
   */
  public async deploy(context: common.Context): Promise<void> {
    const root: string = `${context.filesDir}/backend`;
    for (const rel of CONFIG_MANIFEST) {
      await this.copyRawFile(context, rel, `${root}/${rel}`);
    }
    const poolPath: string = `${root}/config/device_pool.json`;
    if (!fileIo.accessSync(poolPath)) {
      await this.copyRawFile(context, 'config/device_pool.example.json', poolPath);
    }
    for (const rel of RUNTIME_MANIFEST) {
      await this.copyRawFile(context, rel, `${root}/${rel}`);
    }
  }

  private async copyRawFile(context: common.Context, rel: string, destPath: string): Promise<void> {
    const content: Uint8Array = await context.resourceManager.getRawFileContent(`${RAWFILE_ROOT}${rel}`);
    if (fileIo.accessSync(destPath)) {
      const stat: fileIo.Stat = fileIo.statSync(destPath);
      if (stat.size === content.length) {
        const existing: Uint8Array = new Uint8Array(content.length);
        const readFd: fileIo.File = fileIo.openSync(destPath, fileIo.OpenMode.READ_ONLY);
        try {
          fileIo.readSync(readFd.fd, existing.buffer);
        } finally {
          fileIo.closeSync(readFd);
        }
        if (FqDeployer.bytesEqual(existing, content)) {
          return;
        }
      }
    }
    const dirEnd: number = destPath.lastIndexOf('/');
    if (dirEnd > 0) {
      const dirPath: string = destPath.substring(0, dirEnd);
      // OHOS mkdirSync 递归模式对已存在目录仍抛 13900015（File exists），先探测再创建。
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath, true);
      }
    }
    const writeFd: fileIo.File = fileIo.openSync(
      destPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
    );
    try {
      fileIo.writeSync(writeFd.fd, content.buffer);
    } finally {
      fileIo.closeSync(writeFd);
    }
  }

  private static bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }
}

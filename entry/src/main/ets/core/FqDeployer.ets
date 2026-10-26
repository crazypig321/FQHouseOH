/**
 * 运行时资源部署器。
 *
 * 对齐 fqapp BackendService._deploy：把随包 rawfile/backend/** 复制到
 * filesDir/backend/**（config + filters + web + plugins），设备池文件首启从
 * example 种子化。构建期资源清单硬编码于此，规避 rawfile 目录枚举 API 的
 * 行为差异。
 *
 * 性能：部署戳（app 版本 + 各 rawfile 尺寸指纹）命中时整体跳过复制；
 * 未命中时先建目录再并行复制。戳在全部文件写完后才落盘，中途被杀
 * （或数据清理删了半个 backend）下次自动全量重部署。
 */

import { fileIo } from '@kit.CoreFileKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import type resourceManager from '@ohos.resourceManager';

const RAWFILE_ROOT: string = 'backend/';
const STAMP_FILE: string = '.deploy-stamp';

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
   * 部署全部运行时文件。幂等：部署戳一致时跳过复制；变化时并行覆盖。
   */
  public async deploy(context: common.Context): Promise<void> {
    const root: string = `${context.filesDir}/backend`;
    const stampPath: string = `${root}/${STAMP_FILE}`;
    const stamp: string = await FqDeployer.buildStamp(context);
    if (stamp.length > 0 && FqDeployer.readStamp(stampPath) === stamp) {
      await this.ensureDevicePool(context, root);
      return;
    }
    const rels: string[] = CONFIG_MANIFEST.concat(RUNTIME_MANIFEST);
    this.ensureDirs(root, rels);
    const jobs: Promise<void>[] = [];
    for (const rel of rels) {
      jobs.push(this.copyRawFile(context, rel, `${root}/${rel}`));
    }
    await Promise.all(jobs);
    await this.ensureDevicePool(context, root);
    if (stamp.length > 0) {
      FqDeployer.writeStamp(stampPath, stamp);
    }
  }

  /**
   * 部署指纹：app 版本 + 各 rawfile 尺寸。任一获取失败返回 ''（退化为
   * 每次全量部署），保证 rawfile 内容变化即使未升版本号（尺寸变化）
   * 也能被感知。
   */
  private static async buildStamp(context: common.Context): Promise<string> {
    try {
      const info: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const rels: string[] = CONFIG_MANIFEST.concat(RUNTIME_MANIFEST);
      const sizes: number[] = [];
      for (const rel of rels) {
        const rawPath: string = `${RAWFILE_ROOT}${rel}`;
        try {
          const descriptor: resourceManager.RawFileDescriptor =
            await context.resourceManager.getRawFileDescriptor(rawPath);
          sizes.push(descriptor.length);
          context.resourceManager.closeRawFileDescriptor(rawPath);
        } catch (error) {
          return '';
        }
      }
      return `v=${info.versionCode}.${info.versionName};s=${sizes.join(',')}`;
    } catch (error) {
      return '';
    }
  }

  private static readStamp(stampPath: string): string {
    try {
      if (!fileIo.accessSync(stampPath)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(stampPath);
      if (stat.size <= 0 || stat.size > 4096) {
        return '';
      }
      const fd: fileIo.File = fileIo.openSync(stampPath, fileIo.OpenMode.READ_ONLY);
      try {
        const buf: Uint8Array = new Uint8Array(stat.size);
        const readLen: number = fileIo.readSync(fd.fd, buf.buffer);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        return decoder.decodeWithStream(buf.subarray(0, readLen));
      } finally {
        fileIo.closeSync(fd);
      }
    } catch (error) {
      return '';
    }
  }

  private static writeStamp(stampPath: string, stamp: string): void {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(stamp);
      const fd: fileIo.File = fileIo.openSync(
        stampPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
      try {
        fileIo.writeSync(fd.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(fd);
      }
    } catch (error) {
      // 戳写失败不影响本次部署，下次全量再来。
    }
  }

  /** 设备池文件缺失时从 example 种子化（部署戳跳过路径下仍需保证）。 */
  private async ensureDevicePool(context: common.Context, root: string): Promise<void> {
    const poolPath: string = `${root}/config/device_pool.json`;
    if (!fileIo.accessSync(poolPath)) {
      await this.copyRawFile(context, 'config/device_pool.example.json', poolPath);
    }
  }

  /** 串行建目录（并行复制前），规避并发 mkdirSync 的 File exists 竞争。 */
  private ensureDirs(root: string, rels: string[]): void {
    const dirs: Set<string> = new Set<string>();
    for (const rel of rels) {
      const destPath: string = `${root}/${rel}`;
      const dirEnd: number = destPath.lastIndexOf('/');
      if (dirEnd > 0) {
        dirs.add(destPath.substring(0, dirEnd));
      }
    }
    for (const dirPath of dirs) {
      // OHOS mkdirSync 递归模式对已存在目录仍抛 13900015（File exists），先探测再创建。
      if (!fileIo.accessSync(dirPath)) {
        try {
          fileIo.mkdirSync(dirPath, true);
        } catch (error) {
          if (!fileIo.accessSync(dirPath)) {
            throw new Error(`mkdir failed: ${dirPath}`);
          }
        }
      }
    }
  }

  private async copyRawFile(context: common.Context, rel: string, destPath: string): Promise<void> {
    const content: Uint8Array = await context.resourceManager.getRawFileContent(`${RAWFILE_ROOT}${rel}`);
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
}

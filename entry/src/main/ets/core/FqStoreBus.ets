/**
 * store 数据版本总线：store 数据变更后版本号自增，
 * 页面（@ComponentV2）持单例为状态变量后用 @Monitor 监听版本路径，
 * 实现跨页实时刷新（替代 aboutToAppear 一次性加载）。
 */
@ObservedV2
export class FqStoreBus {
  /** 书架数据版本（FqShelfStore 每次变更 +1）。 */
  @Trace shelfVersion: number = 0;
  /** 浏览历史数据版本（FqBrowseStore 每次变更 +1）。 */
  @Trace browseVersion: number = 0;
  /** 章节缓存数据版本（FqChapterCacheStore 每次变更 +1）。 */
  @Trace chapterCacheVersion: number = 0;
  /** 剧集缓存数据版本（FqDramaCacheStore 每次变更 +1）。 */
  @Trace dramaCacheVersion: number = 0;
  /** 听书音频缓存数据版本（FqAudioCacheStore 每次变更 +1）。 */
  @Trace audioCacheVersion: number = 0;
  /** 漫画缓存数据版本（FqComicCacheStore 每次变更 +1）。 */
  @Trace comicCacheVersion: number = 0;
}

export const fqStoreBus: FqStoreBus = new FqStoreBus();

/**
 * 官方分类词表（/api/v1/category ← /reading/bookapi/new_category/front/v）。
 *
 * 实证（probe_category，194 词）：down_category 为推荐序平铺，tile.dim 标注
 * 维度（'1048576' 主题 / '2097152' 情节 / '3145728' 角色），词名全局唯一；
 * category_tab 切频道对设备身份不生效（固定回男频词表），故只拉一份。
 * 组结构：热门标签（推荐序前 N）/主题/角色/情节；女频官方无数据，
 * 由调用方（HomePage）以人工词表一级补齐。
 * 磁盘缓存（files/category_cache.json）二次启动秒显，启动后台静默拉新
 * 覆盖；失败回退 HomePage FQ_CHANNELS 静态词表。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FqBackend } from './FqBackend';
import { fqAsArray, fqAsRecord, fqNum, fqParseObject, fqStr } from './FqJson';

const FQ_CATEGORY_CACHE_FILE: string = 'category_cache.json';
/** 磁盘缓存结构版本：组名/顺序调整时递增，旧缓存自动失效。 */
const FQ_CATEGORY_CACHE_VERSION: number = 2;
/** 热门组词数：官方推荐序前 N 词。 */
const FQ_HOT_GROUP_SIZE: number = 20;
/** 官方维度 dim 值（实证 tile.dim 为字符串）。 */
const FQ_DIM_THEME: string = '1048576';
const FQ_DIM_PLOT: string = '2097152';
const FQ_DIM_ROLE: string = '3145728';
/** 拉取固定 tab=1（切频道无效，设备身份决定返回内容）。 */
const FQ_CATEGORY_TAB: number = 1;
const TAG: string = 'FqCategoryStore';

/** 频道大分类（分类条 Select 项）：一组细分词表。 */
export class FqCategoryGroup {
  readonly label: string;
  readonly categories: string[];

  constructor(label: string, categories: string[]) {
    this.label = label;
    this.categories = categories;
  }
}

export class FqCategoryStore {
  private static filesDir: string = '';
  /** 内存缓存：官方组（不含女频人工组）。 */
  private static cached: FqCategoryGroup[] | null = null;
  /** 并发合并：启动拉新与手动刷新同帧触发时只发一次请求。 */
  private static inFlight: Promise<FqCategoryGroup[] | null> | null = null;

  /** 初始化（进程内一次）。 */
  public static init(context: common.Context): void {
    if (FqCategoryStore.filesDir.length === 0) {
      FqCategoryStore.filesDir = context.filesDir;
    }
  }

  /** 官方组（内存 → 磁盘）；无缓存返回 null（调用方回退静态词表）。 */
  public static officialGroups(): FqCategoryGroup[] | null {
    if (FqCategoryStore.cached !== null) {
      return FqCategoryStore.cached;
    }
    const disk: FqCategoryGroup[] | null = FqCategoryStore.readDisk();
    if (disk !== null) {
      FqCategoryStore.cached = disk;
    }
    return disk;
  }

  /** 网络拉取官方组（并发合并；成功写内存 + 磁盘，失败返回 null，不抛错）。 */
  public static fetchOfficial(context: common.Context): Promise<FqCategoryGroup[] | null> {
    if (FqCategoryStore.inFlight !== null) {
      return FqCategoryStore.inFlight;
    }
    const task: Promise<FqCategoryGroup[] | null> = FqCategoryStore.doFetch(context);
    FqCategoryStore.inFlight = task;
    task.then(
      (): void => {
        FqCategoryStore.inFlight = null;
      },
      (): void => {
        FqCategoryStore.inFlight = null;
      },
    );
    return task;
  }

  private static async doFetch(context: common.Context): Promise<FqCategoryGroup[] | null> {
    try {
      await FqBackend.get().start(context);
      const payload: Record<string, Object> =
        await FqBackend.get().categoryFront(FQ_CATEGORY_TAB);
      const groups: FqCategoryGroup[] | null = FqCategoryStore.parseGroups(payload);
      if (groups === null) {
        return null;
      }
      FqCategoryStore.cached = groups;
      FqCategoryStore.writeDisk(groups);
      return groups;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `fetchOfficial failed: code=${err.code}`);
      return null;
    }
  }

  /** 解析官方载荷：data.down_category[]（推荐序）→ 热门/主题/情节/角色。 */
  private static parseGroups(payload: Record<string, Object>): FqCategoryGroup[] | null {
    const data: Record<string, Object> | null = fqAsRecord(payload['data']);
    if (data === null) {
      return null;
    }
    const rawTiles: Object[] | null = fqAsArray(data['down_category']);
    if (rawTiles === null || rawTiles.length === 0) {
      return null;
    }
    const hotCats: string[] = [];
    const themeCats: string[] = [];
    const plotCats: string[] = [];
    const roleCats: string[] = [];
    for (const raw of rawTiles) {
      const tile: Record<string, Object> | null = fqAsRecord(raw);
      if (tile === null) {
        continue;
      }
      const name: string = fqStr(tile, 'name');
      if (name.length === 0) {
        continue;
      }
      if (hotCats.length < FQ_HOT_GROUP_SIZE) {
        hotCats.push(name);
      }
      const dim: string = fqStr(tile, 'dim');
      if (dim === FQ_DIM_THEME) {
        themeCats.push(name);
      } else if (dim === FQ_DIM_PLOT) {
        plotCats.push(name);
      } else if (dim === FQ_DIM_ROLE) {
        roleCats.push(name);
      }
    }
    // 热门/主题是主维度（54 主题词），缺失视为载荷异常，回退静态词表。
    if (hotCats.length === 0 || themeCats.length === 0) {
      return null;
    }
    // 组序对齐官方分类页：热门标签（推荐序前 N）/主题/角色/情节。
    const groups: FqCategoryGroup[] = [new FqCategoryGroup('热门标签', hotCats)];
    groups.push(new FqCategoryGroup('主题', themeCats));
    if (roleCats.length > 0) {
      groups.push(new FqCategoryGroup('角色', roleCats));
    }
    if (plotCats.length > 0) {
      groups.push(new FqCategoryGroup('情节', plotCats));
    }
    return groups;
  }

  private static cachePath(): string {
    return `${FqCategoryStore.filesDir}/${FQ_CATEGORY_CACHE_FILE}`;
  }

  private static writeDisk(groups: FqCategoryGroup[]): void {
    if (FqCategoryStore.filesDir.length === 0) {
      return;
    }
    const groupRecs: Object[] = [];
    for (const group of groups) {
      const catList: Object[] = [];
      for (const cat of group.categories) {
        catList.push(cat);
      }
      const rec: Record<string, Object> = {
        'label': group.label,
        'categories': catList,
      };
      groupRecs.push(rec);
    }
    const payload: Record<string, Object> = {
      'version': FQ_CATEGORY_CACHE_VERSION,
      'groups': groupRecs,
    };
    let file: fs.File | null = null;
    try {
      file = fs.openSync(FqCategoryStore.cachePath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(payload));
      fs.closeSync(file);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `writeDisk failed: code=${err.code}`);
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 忽略
        }
      }
    }
  }

  private static readDisk(): FqCategoryGroup[] | null {
    if (FqCategoryStore.filesDir.length === 0) {
      return null;
    }
    let text: string = '';
    try {
      text = fs.readTextSync(FqCategoryStore.cachePath());
    } catch (error) {
      return null;
    }
    const payload: Record<string, Object> | null = fqParseObject(text);
    if (payload === null) {
      return null;
    }
    if (fqNum(payload, 'version') !== FQ_CATEGORY_CACHE_VERSION) {
      return null;
    }
    const rawGroups: Object[] | null = fqAsArray(payload['groups']);
    if (rawGroups === null) {
      return null;
    }
    const groups: FqCategoryGroup[] = [];
    for (const raw of rawGroups) {
      const rec: Record<string, Object> | null = fqAsRecord(raw);
      if (rec === null) {
        continue;
      }
      const label: string = fqStr(rec, 'label');
      const rawCats: Object[] | null = fqAsArray(rec['categories']);
      if (label.length === 0 || rawCats === null) {
        continue;
      }
      const cats: string[] = [];
      for (const rawCat of rawCats) {
        if (typeof rawCat === 'string' && rawCat.length > 0) {
          cats.push(rawCat);
        }
      }
      if (cats.length > 0) {
        groups.push(new FqCategoryGroup(label, cats));
      }
    }
    return groups.length > 0 ? groups : null;
  }
}

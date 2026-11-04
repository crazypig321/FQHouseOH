/**
 * 官方番茄小说分类词表（静态，转写自官方 .label/*.txt）。
 *
 * 结构对齐官方分类页：一级（弹窗顶部横向 tab）→ 二级组（左侧栏）→
 * 三级词（右侧网格）。各频道树见 FQ_CHANNEL_TREES（索引对齐 HomePage
 * FQ_CHANNELS：推荐/小说/短剧/漫剧/漫画/听书）：
 * - 推荐/小说：男生/女生/出版（.label 同名 txt；点击结果是否限类目由
 *   HomePage 分类源映射决定，树本身不携带搜索信息）；
 * - 短剧/漫剧：男生/女生，二级组用 短剧分类.txt（情节/主题/背景/角色）；
 * - 漫画：男生/女生，二级组保持现有人工组（热门/男频/女频）；
 * - 听书：男生/女生，二级组用 听书分类.txt（其他）。
 * 出版词表每组首个「全部」与弹窗自带「全部」chip 语义重复，转写时剔除。
 */

/** 分类二级组（弹窗左侧栏项）：label 组名 + categories 三级词。 */
export class FqCategoryGroup {
  readonly label: string;
  readonly categories: string[];

  constructor(label: string, categories: string[]) {
    this.label = label;
    this.categories = categories;
  }
}

/** 分类一级（弹窗顶部横向 tab）：label 一级名 + groups 二级组。 */
export class FqCategoryLevel1 {
  readonly label: string;
  readonly groups: FqCategoryGroup[];

  constructor(label: string, groups: FqCategoryGroup[]) {
    this.label = label;
    this.groups = groups;
  }
}

/** '组名:词1 词2 …' 行 → 二级组（格式非法返回 null）。 */
function fqParseGroup(line: string): FqCategoryGroup | null {
  const sep: number = line.indexOf(':');
  if (sep <= 0 || sep >= line.length - 1) {
    return null;
  }
  const label: string = line.substring(0, sep);
  const words: string[] = [];
  for (const word of line.substring(sep + 1).split(' ')) {
    if (word.length > 0) {
      words.push(word);
    }
  }
  return words.length > 0 ? new FqCategoryGroup(label, words) : null;
}

function fqParseGroups(lines: string[]): FqCategoryGroup[] {
  const groups: FqCategoryGroup[] = [];
  for (const line of lines) {
    const group: FqCategoryGroup | null = fqParseGroup(line);
    if (group !== null) {
      groups.push(group);
    }
  }
  return groups;
}

function fqLevel1(label: string, lines: string[]): FqCategoryLevel1 {
  return new FqCategoryLevel1(label, fqParseGroups(lines));
}

/** 男生一级（.label/男生分类.txt）。 */
const FQ_MALE_LINES: string[] = [
  '热门标签:悬疑 玄幻 都市 历史 衍生 种田 科幻末世 同人 奇幻仙侠 游戏体育 灾难 悬疑灵异 腹黑 1v1 无脑爽 搞笑轻松 无限流 悬疑推理 无女主 惊悚游戏 悬疑脑洞 规则怪谈 多女主',
  '主题:古代 末日求生 都市脑洞 宝可梦 历史古代 游戏动漫 男频衍生 轻小说 综漫 体育 玄幻脑洞 都市日常 西方奇幻 架空 异世大陆 都市生活 都市异能 东方玄幻 都市高武 克苏鲁 东方仙侠 历史脑洞 高武世界 第四天灾 仕途 异能 影视小说 抗战谍战 都市种田 国运 灵气复苏 综影视 武侠 天灾 开局 第一人称 断层 赛博朋克 谍战 武将 清朝 宋朝',
  '角色:单女主 扮猪吃虎 大小姐 特种兵 反派 大佬 校花 女帝 学霸 群像 游戏主播 特工 贵族 赘婿 奶爸 皇帝 神探 天才 战神赘婿 全能 神医',
  '情节:修仙 推理 灵异 重生 打脸 系统 风水秘术 穿越 末世 穿书 破案 电竞 双重生 捉鬼 星际 二次元 娱乐圈 迪化 黑化 无后宫 盗墓 求生 火影 神奇宝贝 动漫衍生 洪荒 美食 升级流 民国 宠物 网游 副本 乡村 仙侠 魂穿 诸天万界 海贼王 奇幻 发家致富 奥特同人 无敌 三国 斩神 基建 四合院 山海经 黑道 十日衍生 直播 职场 囤物资 钓鱼 双系统 海贼 九叔 鉴宝 都市修真 传统玄幻 外卖 灵魂互换 剑修 废土 神豪 都市江湖 海岛 空间 绝地逃生 聊天群 家庭 黑科技 卡牌 封神 争霸 科举 红楼衍生 西游衍生 高手下山 斩神衍生 剑道 龙珠 甄嬛衍生 漫威 公版衍生 大唐 大秦 如懿衍生 明朝',
];

/** 女生一级（.label/女生分类.txt）。 */
const FQ_FEMALE_LINES: string[] = [
  '热门标签:现代言情 悬疑 古代言情 纯爱 衍生 影视原著 追妻火葬场 病娇 虐恋情深 双男主 虐文 惊悚游戏 搞笑轻松 追妻 悬疑脑洞 悬疑推理 腹黑 无限流 玄幻言情 快穿 1v1 女扮男装 虐渣 无脑爽 甜宠 强强',
  '主题:幻想言情 科幻末世 异世穿越 女频悬疑 现言脑洞 古代 悬疑恋爱 游戏动漫 综漫 现言甜宠 宫斗宅斗 女频衍生 民国言情 青春甜宠 古言脑洞 豪门世家 天灾 武侠 现代 古言权谋 影视小说 日久生情 综影视 都市生活 仕途 独宠 古风世情 谍战 第一人称 职场商战',
  '角色:女强 豪门总裁 大女主 双病娇 无CP 白切黑 替身 扮猪吃虎 总裁 大小姐 忠犬 反派 萌宝 冰山 明星 大佬 作精 群像 宠妻 皇叔 游戏主播 学霸 团宠 王妃 公主 位尊权重 贵族 神探 双面 将军 医生 全能 戏精 古灵精怪 皇后 天才 精灵 天作之合 双学霸 厨娘 律师 嫡女 可盐可甜 毒医',
  '情节:灵异 末世 穿越 重生 男二上位 攻略反派 年代 带球跑 推理 破镜重圆 双洁 追夫 穿书 校园 风水秘术 系统 双女主 同人 星际 捉鬼 电竞 种田 打脸 年下 娱乐圈 破案 兽世 双重生 先婚后爱 暗恋 二次元 HE 青梅竹马 相爱相杀 真假千金 动漫衍生 契约婚姻 美食 黑化 剑修 民国 盗墓 游戏体育 养崽 囤物资 一见钟情 白月光 替嫁 今穿古 相互救赎 养成 年龄差 久别重逢 山海经 乡村 发家致富 直播 代嫁代娶 隐婚 魂穿 空间 基建 无敌 胎穿 宠夫 十日衍生 四合院 灵魂互换 古穿今 双系统 星光璀璨 封神 前世今生 情有独钟 清穿 斩神衍生 互宠 钓鱼 双向奔赴 职场 逃婚 群穿 家长里短 西游衍生 闪婚 婚恋 职场婚恋 逃荒 红楼衍生 古色古香 科举 甄嬛衍生 家庭 公版衍生 如懿衍生 医术 护短',
];

/** 出版一级（.label/出版分类.txt；各组首个「全部」与弹窗「全部」chip 重复，剔除）。 */
const FQ_PUBLISH_LINES: string[] = [
  '历史:中国历史 世界历史 历史小说 历史文化',
  '文学经典:中国名著 世界名著 外国文学 中国文学 当代文学 古代文学 诗歌散文 文学理论 古籍 国学',
  '影视小说:国内影视 国外影视',
  '精品小说:悬疑推理 科幻小说 武侠小说 玄幻小说 都市生活 现实小说 情感小说 青春文学 战争军旅',
  '社会文化:社会人文 社会科学 法律 传统文化 文化理论',
  '心理:心理学 少儿心理 心理疗愈',
  '个人成长:励志提升 思维智商 情商口才 职场经验',
  '经济管理:经济 财政 管理 理财 商业',
  '艺术:艺术文化 音乐舞蹈 绘画 摄影 鉴赏理论',
  '生活百科:运动健身 时尚美妆 美食休闲 家居旅游 风水占卜 百科常识 生活情感',
  '养生健康:医学 养生 两性',
  '家庭育儿:母婴孕产 亲子教育 童书童话 胎教早教',
  '科学技术:技术 科学 工业 农林牧渔 计算机 建筑园林',
  '教育学习:基础教育 高等教育 技能专业 语言学习 工具拓展',
  '人物传记:历史人物 科技人物 财经人物 政治人物 文艺名人',
  '哲学宗教:哲学 宗教',
  '政治军事:政治理论 党政图书 军事理论',
];

/** 短剧/漫剧二级组（.label/短剧分类.txt）。 */
const FQ_DRAMA_LINES: string[] = [
  '情节:都市爱情 女性成长 都市日常 都市脑洞 家庭伦理 奇幻脑洞 奇幻爱情 剧情 都市玄幻 古风爱情 战神归来 宫斗宅斗 玄幻仙侠 古风权谋 种田经营 年代爱情 赘婿逆袭 青春 历史古代 无敌神医 悬疑推理 志怪 民国爱情 悬疑情感 婚姻生活 悬疑灵异 乡村爱情 现言甜宠 犯罪 仙侠爱情 现言虐恋 法律正义 搞笑轻松 刑侦破案 抗战谍战 江湖武侠 民国传奇 动作 体育竞技 末世求生 友情岁月 医疗 科幻 荒野求生 冒险 恐怖惊悚',
  '主题:打脸虐渣 逆袭 马甲 日久生情 重生 穿越 系统 亲情 反转 先婚后爱 家长里短 闪婚 暗恋成真 穿书 破镜重圆 追妻 极品亲戚 强者回归 豪门恩怨 异能 传承觉醒 虐恋 欢喜冤家 奇幻 喜剧 甜宠 读心术 天下无敌 青梅竹马 玄学 追妻火葬场 一见钟情 灰姑娘 替嫁 直播 双向奔赴 前世今生 双向救赎 年龄差 商业联姻 黄昏恋 灵魂互换 锦鲤 家国情怀 女扮男装 权臣篡位 分家争产 强取豪夺 暴富 交换人生 黑道 仙凡恋 绝地逃生 逼婚 父子情 逃婚 家族诅咒 生存游戏 快穿 擂台比武 帮派纷争 网恋奔现 江湖侠义 网络暴力 仙魔大战 寻宝探险 相濡以沫 嫡庶之争 AI觉醒 争霸',
  '背景:现代 都市 乡村 古代 年代 架空 职场 豪门 民国 校园 宫廷 娱乐圈 异界 方言 军阀 末世 朝堂 史诗奇幻 幻想空间 荒岛 海岛',
  '角色:总裁 大男主 大女主 女强 萌宝 群像 小人物 神豪 真假千金 医生 古灵精怪 强强联合 王爷 皇帝 神医 姐弟恋 大小姐 婆媳 王妃 业界精英 天才 福宝 高冷禁欲 太子 捞偏门 女帝 律师 公主 龙王 反派主角 战神 皇后 萌宠 替身 落魄千金 乖乖女 世子 甜妹 少帅 皇子 大叔 仙门弟子 病娇 校花 帝王 仙尊 嫔妃 厨娘 主播 刺客杀手 家庭主妇 后妈 痞少 腹黑 特工 嘴硬心软 戏精 影后 毒舌 校草 武林高手 美强惨 御姐 书生 黑客 作精 拳击手 丧尸 热血硬汉 特种兵 太后 神童 校霸 法医',
];

/** 听书二级组（.label/听书分类.txt）。 */
const FQ_AUDIO_LINES: string[] = [
  '其他:女性 搞笑段子 情感故事 中国史 科普 心理 娱乐 名著解读 二次元 相声 夜话 儿童文学 儿童英语 近现代 美文 心理健康 法律 小品 世界史 国学历史 婚姻 自然科学 纪录 沟通表达 名人传 郭德纲 励志成功 散文戏剧 新闻 国学 经管商业 美食烹饪 戏曲 魏晋南北朝 战争史 职业职场 唐宋 佛学 评书 投资理财 艺术 社科 孕期保健 文化 健康养生 产后护理 旅游 明清 胎教早教 亲子健康 田连元 秦汉 刘兰芳 单田芳 袁阔成',
];

/** 漫画二级组（仅热门，保持现有人工词表）。 */
const FQ_MANGA_LINES: string[] = [
  '热门:恋爱 搞笑 热血 玄幻 都市 古风 科幻 冒险 悬疑 治愈',
];

/** 文字类树（推荐/小说共用：男生/女生/出版）。 */
const FQ_TREE_TEXT: FqCategoryLevel1[] = [
  fqLevel1('男生', FQ_MALE_LINES),
  fqLevel1('女生', FQ_FEMALE_LINES),
  fqLevel1('出版', FQ_PUBLISH_LINES),
];

/** 短剧/漫剧共用树（男生/女生，组词用短剧分类.txt）。 */
const FQ_TREE_DRAMA: FqCategoryLevel1[] = [
  fqLevel1('男生', FQ_DRAMA_LINES),
  fqLevel1('女生', FQ_DRAMA_LINES),
];

/** 漫画树（男生/女生，组词仅热门）。 */
const FQ_TREE_MANGA: FqCategoryLevel1[] = [
  fqLevel1('男生', FQ_MANGA_LINES),
  fqLevel1('女生', FQ_MANGA_LINES),
];

/** 听书树（一级仅「默认」，组词用听书分类.txt）。 */
const FQ_TREE_AUDIO: FqCategoryLevel1[] = [
  fqLevel1('默认', FQ_AUDIO_LINES),
];

/** 各频道分类树（索引对齐 HomePage FQ_CHANNELS：推荐/小说/短剧/漫剧/漫画/听书）。 */
export const FQ_CHANNEL_TREES: FqCategoryLevel1[][] = [
  FQ_TREE_TEXT, FQ_TREE_TEXT, FQ_TREE_DRAMA, FQ_TREE_DRAMA, FQ_TREE_MANGA, FQ_TREE_AUDIO,
];

/**
 * 「分类」弹窗内容（首页右上角「分类」按钮 → DialogManager.ShowHomeCategory 打开，
 * 由宿主页 Index 的 CustomContentDialog 装配）：
 * 顶部类目 Select（推荐/小说/短剧/漫剧/漫画/听书，与首页频道条一致）+
 * 一级横向 tab + 左侧二级竖版列表 + 右侧三级词三列网格；
 * 布局对齐 fqapp 官方分类页（category_page.dart：顶部频道 tab + 左维度栏 + 右词网格），
 * 收进弹窗。点词即选：经 DialogManager.PickHomeCategory 回调首页并关弹窗
 * （类目 Select 切换 = 换频道树并重置一级/组；回调携带类目下标，首页频道条同步切换）。
 */

import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqCategoryGroup, FqCategoryLevel1, FQ_CHANNEL_LABELS, FQ_CHANNEL_TREES }
  from '../../core/FqCategoryStore';
import { selectImmersiveModifier } from '../../utils/ModifierUtils';

/** 左侧二级栏宽度（fqapp 官方 88dp 维度栏）。 */
const FQ_RAIL_WIDTH: number = 75;
/** 两栏区固定高度（左右各自独立滚动）。 */
const FQ_PANE_HEIGHT: number = 380;

@ComponentV2
export struct HomeCategoryDialogContent {
  /** 当前类目（频道）下标。 */
  @Local channelIndex: number = 0;
  /** 当前一级 tab 下标。 */
  @Local l1Index: number = 0;
  /** 当前二级组下标。 */
  @Local groupIndex: number = 0;

  aboutToAppear(): void {
    let channel: number = DialogManager.homeCategoryChannel;
    if (channel < 0 || channel >= FQ_CHANNEL_TREES.length) {
      channel = 0;
    }
    this.channelIndex = channel;
    const tree: FqCategoryLevel1[] = this.channelTree();
    let l1: number = DialogManager.homeCategoryL1;
    if (l1 < 0 || l1 >= tree.length) {
      l1 = 0;
    }
    this.l1Index = l1;
    const groups: FqCategoryGroup[] = tree.length > 0 ? tree[l1].groups : [];
    let group: number = DialogManager.homeCategoryGroup;
    if (group < 0 || group >= groups.length) {
      group = 0;
    }
    this.groupIndex = group;
  }

  build() {
    Column() {
      Row({space: 10}) {
        this.ChannelPicker()
        this.LevelTabs()
      } .width('100%')

      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ top: 8, bottom: 14 })

      Row({space: 10}) {
        this.GroupRail()
        this.WordPane()
      }
      .width('100%')
      .height(FQ_PANE_HEIGHT)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  /** 顶部类目 Select（与首页频道条同源：FQ_CHANNEL_LABELS/FQ_CHANNEL_TREES 同序）。 */
  @Builder
  private ChannelPicker() {
    Select(this.channelOptions())
      .value(FQ_CHANNEL_LABELS[this.channelIndex])
      .selected(this.channelIndex)
      .font({ size: 15, weight: FontWeight.Medium })
      .fontColor($r('sys.color.font_primary'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Medium })
      .selectedOptionFontColor(appState.accentColor)
      .optionFont({ size: 15 })
      .optionFontColor($r('sys.color.font_primary'))
      .backgroundColor(Color.Transparent)
      .height(36)
      .padding({ left: 0, right: 0 })
      .onSelect((index: number, text: string) => {
        this.selectChannel(index);
      })
      .attributeModifier(selectImmersiveModifier)
  }

  /** 一级横向 tab（fqapp：选中黑加粗、未选灰，选中下挂主题色小横条）。 */
  @Builder
  private LevelTabs() {
    List({ space: 22 }) {
      ForEach(this.channelTree(), (level1: FqCategoryLevel1, index: number) => {
        ListItem() {
          Column({ space: 4 }) {
            Text(level1.label)
              .fontSize(15)
              .fontWeight(this.l1Index === index ? 700 : 400)
              .fontColor(this.l1Index === index
                ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
            Column()
              .width(16)
              .height(3)
              .borderRadius(2)
              .backgroundColor(this.l1Index === index ? appState.accentColor : Color.Transparent)
          }
          .alignItems(HorizontalAlign.Center)
          .onClick((): void => {
            this.selectL1(index);
          })
        }
      }, (level1: FqCategoryLevel1): string => level1.label)
    }
    .listDirection(Axis.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .height(38)
    .alignListItem(ListItemAlign.Center)
    .fadingEdge(true)
    .padding({ left: 4, right: 4 })
  }

  /** 左侧二级竖版列表（fqapp 维度栏：选中主题色）。 */
  @Builder
  private GroupRail() {
    List() {
      ForEach(this.currentLevel1().groups, (group: FqCategoryGroup, index: number) => {
        ListItem() {
          Text(group.label)
            .fontSize(13)
            .fontWeight(this.groupIndex === index ? 600 : 400)
            .fontColor(this.groupIndex === index
              ? Color.White : $r('sys.color.font_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(44)
        .borderRadius(10)
        .backgroundColor(this.groupIndex === index
          ? appState.accentColor : Color.Transparent)
        .onClick((): void => {
          this.groupIndex = index;
        })
      }, (group: FqCategoryGroup): string => group.label)
    }
    .width(FQ_RAIL_WIDTH)
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
  }

  /** 右侧三级词三列网格（点词即选并关弹窗）。 */
  @Builder
  private WordPane() {
    Grid() {
      ForEach(this.currentGroup().categories, (word: string, index: number) => {
        GridItem() {
          this.WordChip(word, this.wordSelected(index), index)
        }
      }, (word: string): string => word)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .layoutWeight(1)
    .height('100%')
    .columnsGap(10)
    .rowsGap(10)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
  }

  /** 三级词 chip（wordIndex -1 = 「全部」清分类格）。 */
  @Builder
  private WordChip(label: string, selected: boolean, wordIndex: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(selected ? 600 : 400)
      .fontColor(selected ? Color.White : $r('sys.color.font_primary'))
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .width('100%')
      .constraintSize({ minHeight: 34 })
      .padding({ left: 4, right: 4, top: 8, bottom: 8 })
      .borderRadius(10)
      .backgroundColor(selected
        ? appState.accentColor : $r('sys.color.comp_background_tertiary'))
      .onClick((): void => {
        DialogManager.PickHomeCategory(this.channelIndex, this.l1Index, this.groupIndex, wordIndex + 1);
      })
  }

  /** 类目 Select 选项（频道名表）。 */
  private channelOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const label of FQ_CHANNEL_LABELS) {
      const option: SelectOption = { value: label };
      options.push(option);
    }
    return options;
  }

  /** 类目切换：换频道树，一级/组回零。 */
  private selectChannel(index: number): void {
    if (this.channelIndex === index) {
      return;
    }
    this.channelIndex = index;
    this.l1Index = 0;
    this.groupIndex = 0;
  }

  /** 一级 tab 切换：二级组回首组。 */
  private selectL1(index: number): void {
    if (this.l1Index === index) {
      return;
    }
    this.l1Index = index;
    this.groupIndex = 0;
  }

  /** 当前类目的分类树（越界回退首类目）。 */
  private channelTree(): FqCategoryLevel1[] {
    if (this.channelIndex > 0 && this.channelIndex < FQ_CHANNEL_TREES.length) {
      return FQ_CHANNEL_TREES[this.channelIndex];
    }
    return FQ_CHANNEL_TREES[0];
  }

  /** 当前一级（越界回退首项；树空回退空定义）。 */
  private currentLevel1(): FqCategoryLevel1 {
    const tree: FqCategoryLevel1[] = this.channelTree();
    if (this.l1Index >= 0 && this.l1Index < tree.length) {
      return tree[this.l1Index];
    }
    return tree.length > 0 ? tree[0] : new FqCategoryLevel1('', []);
  }

  /** 当前二级组（越界回退首组）。 */
  private currentGroup(): FqCategoryGroup {
    const groups: FqCategoryGroup[] = this.currentLevel1().groups;
    if (this.groupIndex >= 0 && this.groupIndex < groups.length) {
      return groups[this.groupIndex];
    }
    return groups.length > 0 ? groups[0] : new FqCategoryGroup('', []);
  }

  /** 三级词选中态：类目/一级/二级组/词均与打开时选中一致才高亮。 */
  private wordSelected(index: number): boolean {
    return DialogManager.homeCategoryWord === index + 1
      && DialogManager.homeCategoryChannel === this.channelIndex
      && DialogManager.homeCategoryL1 === this.l1Index
      && DialogManager.homeCategoryGroup === this.groupIndex;
  }
}

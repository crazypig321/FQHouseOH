/**
 * 「分类」弹窗内容（首页右上角「分类」按钮 → DialogManager.ShowHomeCategory 打开，
 * 由宿主页 Index 的 CustomContentDialog 装配）：
 * 一级横向 tab（男生/女生/有声书/出版/短剧/漫画）+ 左侧二级竖版列表 +
 * 右侧三级词三列网格（首格「全部」= 清分类回频道默认推荐流）；
 * 布局对齐 fqapp 官方分类页（category_page.dart：顶部频道 tab + 左维度栏 + 右词网格），
 * 收进弹窗。点词即选：经 DialogManager.PickHomeCategory 回调首页并关弹窗。
 */

import { DialogManager } from '../../utils/DialogUtils';
import { appState } from '../../entryability/AppState';
import { FqCategoryGroup, FqCategoryLevel1 } from '../../core/FqCategoryStore';

/** 左侧二级栏宽度（fqapp 官方 88dp 维度栏）。 */
const FQ_RAIL_WIDTH: number = 75;
/** 两栏区固定高度（左右各自独立滚动）。 */
const FQ_PANE_HEIGHT: number = 380;

@ComponentV2
export struct HomeCategoryDialogContent {
  /** 当前一级 tab 下标。 */
  @Local l1Index: number = 0;
  /** 当前二级组下标。 */
  @Local groupIndex: number = 0;

  aboutToAppear(): void {
    const tree: FqCategoryLevel1[] = DialogManager.homeCategoryTree;
    let l1: number = DialogManager.homeCategoryL1;
    if (tree.length === 0 || l1 < 0 || l1 >= tree.length) {
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
      this.LevelTabs()
      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ top: 8, bottom: 14 })
      Row() {
        this.GroupRail()
        this.WordPane()
      }
      .width('100%')
      .height(FQ_PANE_HEIGHT)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
  }

  /** 一级横向 tab（fqapp：选中黑加粗、未选灰，选中下挂主题色小横条）。 */
  @Builder
  private LevelTabs() {
    List({ space: 22 }) {
      ForEach(DialogManager.homeCategoryTree, (level1: FqCategoryLevel1, index: number) => {
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
              ? appState.accentColor : $r('sys.color.font_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(44)
        .borderRadius(10)
        .backgroundColor(this.groupIndex === index
          ? $r('sys.color.comp_background_tertiary') : Color.Transparent)
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

  /** 右侧三级词三列网格（首格「全部」= 清分类；点词即选并关弹窗）。 */
  @Builder
  private WordPane() {
    Grid() {
     // GridItem() {
      //  this.WordChip('全部', DialogManager.homeCategoryWord === 0, -1)
      //}
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
        DialogManager.PickHomeCategory(this.l1Index, this.groupIndex, wordIndex + 1);
      })
  }

  /** 一级 tab 切换：二级组回首组。 */
  private selectL1(index: number): void {
    if (this.l1Index === index) {
      return;
    }
    this.l1Index = index;
    this.groupIndex = 0;
  }

  /** 当前一级（越界回退首项；树空回退空定义）。 */
  private currentLevel1(): FqCategoryLevel1 {
    const tree: FqCategoryLevel1[] = DialogManager.homeCategoryTree;
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

  /** 三级词选中态：一级/二级组/词均与打开时选中一致才高亮。 */
  private wordSelected(index: number): boolean {
    return DialogManager.homeCategoryWord === index + 1
      && DialogManager.homeCategoryL1 === this.l1Index
      && DialogManager.homeCategoryGroup === this.groupIndex;
  }
}

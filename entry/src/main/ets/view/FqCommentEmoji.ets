/**
 * 评论正文官方括号表情（对齐 fqapp lib/widgets/comment_emoji.dart）：
 * 上游章评/段评/回复正文把表情编码为 `[微笑]`-style 括号 token
 * （官方客户端 `\[[A-Z一-龥]+\]` 匹配，emoji_config.json 共 53 个 token，
 * 图片为官方 drawable-xxhdpi webp，已随包拷入 resources/base/media/）。
 * 另含红果短剧弹幕面板独有 4 token（爽/鼓掌/没看够/送花，emoji_hg_50..53.webp）。
 * - fqCommentEmojiSegments：正文切段（普通文本段 + 表情图段，未知 token 保持原文）；
 * - FqCommentEmojiText：富文本渲染组件（无 token 时退化为纯 Text，排版不变）；
 * 表情尺寸随字号 1.4 倍（官方 sp(16)*1.4 比例）。
 */

/** 官方括号表情 token（仅 53 个官方词命中；未知括号词保持原文本）。 */
const FQ_COMMENT_EMOJI_PATTERN: RegExp = /\[[A-Z一-龥]+\]/;

/** token → 随包表情图（emoji_01..53.webp，编号与官方 emoji_config.json 一致）。 */
const FQ_COMMENT_EMOJI_ASSETS: Record<string, Resource> = {
  '[微笑]': $r('app.media.emoji_01'),
  '[偷笑]': $r('app.media.emoji_02'),
  '[笑]': $r('app.media.emoji_03'),
  '[什么]': $r('app.media.emoji_04'),
  '[害羞]': $r('app.media.emoji_05'),
  '[爱慕]': $r('app.media.emoji_06'),
  '[飞吻]': $r('app.media.emoji_07'),
  '[奸笑]': $r('app.media.emoji_08'),
  '[尬笑]': $r('app.media.emoji_09'),
  '[思考]': $r('app.media.emoji_10'),
  '[撇嘴]': $r('app.media.emoji_11'),
  '[做鬼脸]': $r('app.media.emoji_12'),
  '[酷]': $r('app.media.emoji_13'),
  '[翻白眼]': $r('app.media.emoji_14'),
  '[惊呆]': $r('app.media.emoji_15'),
  '[震惊]': $r('app.media.emoji_16'),
  '[送心]': $r('app.media.emoji_17'),
  '[委屈]': $r('app.media.emoji_18'),
  '[快哭了]': $r('app.media.emoji_19'),
  '[笑哭]': $r('app.media.emoji_20'),
  '[哭]': $r('app.media.emoji_21'),
  '[大笑]': $r('app.media.emoji_22'),
  '[舔屏]': $r('app.media.emoji_23'),
  '[怒]': $r('app.media.emoji_24'),
  '[捂脸]': $r('app.media.emoji_25'),
  '[吐]': $r('app.media.emoji_26'),
  '[恐惧]': $r('app.media.emoji_27'),
  '[抓狂]': $r('app.media.emoji_28'),
  '[敬礼]': $r('app.media.emoji_29'),
  '[石化]': $r('app.media.emoji_30'),
  '[OK]': $r('app.media.emoji_31'),
  '[赞]': $r('app.media.emoji_32'),
  '[爱心]': $r('app.media.emoji_33'),
  '[伤心]': $r('app.media.emoji_34'),
  '[KISS]': $r('app.media.emoji_35'),
  '[懂了]': $r('app.media.emoji_36'),
  '[探究]': $r('app.media.emoji_37'),
  '[重拳出击]': $r('app.media.emoji_38'),
  '[吃瓜]': $r('app.media.emoji_39'),
  '[盯]': $r('app.media.emoji_40'),
  '[你细品]': $r('app.media.emoji_41'),
  '[赶稿中]': $r('app.media.emoji_42'),
  '[注意]': $r('app.media.emoji_43'),
  '[饱了]': $r('app.media.emoji_44'),
  '[码住]': $r('app.media.emoji_45'),
  '[学会了]': $r('app.media.emoji_46'),
  '[顶帖]': $r('app.media.emoji_47'),
  '[求爆更]': $r('app.media.emoji_48'),
  '[求关注]': $r('app.media.emoji_49'),
  '[我也强推]': $r('app.media.emoji_50'),
  '[雀食神作]': $r('app.media.emoji_51'),
  '[已种草]': $r('app.media.emoji_52'),
  '[书架加一]': $r('app.media.emoji_53'),
  // 红果短剧弹幕独有 token（官方 dr 表情集 50-53 槽，CDN png 已转 webp 随包）。
  '[爽]': $r('app.media.emoji_hg_50'),
  '[鼓掌]': $r('app.media.emoji_hg_51'),
  '[没看够]': $r('app.media.emoji_hg_52'),
  '[送花]': $r('app.media.emoji_hg_53'),
};

/** 正文切段：普通文本段（emoji 为 null）与官方表情段（plain 为 token 原文）。 */
export class FqEmojiSegment {
  readonly plain: string;
  readonly emoji: Resource | null;

  constructor(plain: string, emoji: Resource | null) {
    this.plain = plain;
    this.emoji = emoji;
  }
}

/** 是否包含官方括号表情 token（无 token 时调用方保持纯 Text 排版）。 */
export function fqHasCommentEmoji(text: string): boolean {
  return FQ_COMMENT_EMOJI_PATTERN.test(text);
}

/** 正文按官方表情 token 切段；未知括号词保持原文本不替换。 */
export function fqCommentEmojiSegments(text: string): FqEmojiSegment[] {
  const segments: FqEmojiSegment[] = [];
  const pattern: RegExp = new RegExp(FQ_COMMENT_EMOJI_PATTERN.source, 'g');
  let cursor: number = 0;
  let match: RegExpExecArray | null = pattern.exec(text);
  while (match !== null) {
    const token: string = match[0];
    const emoji: Resource | undefined = FQ_COMMENT_EMOJI_ASSETS[token];
    if (emoji !== undefined) {
      const before: string = text.substring(cursor, match.index);
      if (before.length > 0) {
        segments.push(new FqEmojiSegment(before, null));
      }
      segments.push(new FqEmojiSegment(token, emoji));
      cursor = match.index + token.length;
    }
    match = pattern.exec(text);
  }
  const tail: string = text.substring(cursor);
  if (tail.length > 0) {
    segments.push(new FqEmojiSegment(tail, null));
  }
  return segments;
}

/** 评论正文富文本：官方括号表情渲染为随包内联图（1.4 倍字号），其余原样。 */
@ComponentV2
export struct FqCommentEmojiText {
  @Param text: string = '';
  @Param fontSize: number = 13.5;
  @Param fontColor: ResourceColor = $r('sys.color.font_primary');
  @Param lineHeight: number = 22;
  /** 最大行数（0 不限，详情页预览传 4）。 */
  @Param maxLines: number = 0;

  build() {
    if (fqHasCommentEmoji(this.text)) {
      Text() {
        ForEach(fqCommentEmojiSegments(this.text), (segment: FqEmojiSegment, index: number) => {
          if (segment.emoji !== null) {
            ImageSpan(segment.emoji)
              .width(this.fontSize * 1.4)
              .height(this.fontSize * 1.4)
              .verticalAlign(ImageSpanAlignment.CENTER)
          } else {
            Span(segment.plain)
          }
        }, (segment: FqEmojiSegment, index: number): string => `${index}_${segment.plain.length}`)
      }
      .fontSize(this.fontSize)
      .fontColor(this.fontColor)
      .lineHeight(this.lineHeight)
      .maxLines(this.maxLines > 0 ? this.maxLines : 9999)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    } else {
      Text(this.text)
        .fontSize(this.fontSize)
        .fontColor(this.fontColor)
        .lineHeight(this.lineHeight)
        .maxLines(this.maxLines > 0 ? this.maxLines : 9999)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
  }
}

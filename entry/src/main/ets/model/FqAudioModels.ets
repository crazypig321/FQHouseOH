/**
 * 听书数据模型（对齐 fqapp models/audio_extra.dart + chapter_media.dart）：
 * - FqAudioTone/FqAudioToneSet：音色表（智能朗读 tts / 真人讲书 narrator）；
 * - FqAudioSource：可播放章节流（URL + toneId + 时长）；
 * - FqRelatedWork：相关作品（原著小说 / 改编短剧）；
 * - FqSubtitleCue/FqSubtitleTrack：边听边读字幕（[3025,0]<3025,0,0>文本）。
 */

/** 一个可选音色（/api/v1/books/{id}/tones 或真人讲书条目）。 */
export class FqAudioTone {
  readonly id: string;
  readonly title: string;
  /** 短描述（自然流畅 / 超自然等）。 */
  readonly description: string;
  /** 角标（升级等）。 */
  readonly badge: string;
  readonly iconUrl: string;
  /** 多角色对话音色。 */
  readonly isMultiTone: boolean;

  constructor(id: string, title: string, description: string, badge: string,
    iconUrl: string, isMultiTone: boolean) {
    this.id = id;
    this.title = title;
    this.description = description;
    this.badge = badge;
    this.iconUrl = iconUrl;
    this.isMultiTone = isMultiTone;
  }

  get isEmpty(): boolean {
    return this.id.length === 0 && this.title.length === 0;
  }
}

/** 一本书的全部音色（fqapp AudioToneSet）。 */
export class FqAudioToneSet {
  readonly ttsTones: FqAudioTone[];
  /** 离线朗读音色（playinfo 拒绝其 id，仅用于候选过滤）。 */
  readonly offlineTones: FqAudioTone[];
  /** 真人讲书（title 已是「主播：…」；id 是 abook_id，需跨书切换）。 */
  readonly narratorTones: FqAudioTone[];
  /** req_book_genre_type：1 = 有声书固定录音（playinfo 忽略 tone_id）。 */
  readonly genreType: number;
  /** 关联小说（固定录音的 TTS 音色需换到该书）。 */
  readonly relatedNovel: FqRelatedWork | null;

  constructor(ttsTones: FqAudioTone[], offlineTones: FqAudioTone[],
    narratorTones: FqAudioTone[], genreType: number, relatedNovel: FqRelatedWork | null) {
    this.ttsTones = ttsTones;
    this.offlineTones = offlineTones;
    this.narratorTones = narratorTones;
    this.genreType = genreType;
    this.relatedNovel = relatedNovel;
  }

  /** 有声书/有声剧：playinfo 恒返回同一录音。 */
  get hasFixedTone(): boolean {
    return this.genreType === 1;
  }

  get isEmpty(): boolean {
    return this.ttsTones.length === 0 && this.offlineTones.length === 0
      && this.narratorTones.length === 0;
  }

  /** 官方预选：优先多角色，其次首个 tts，再退真人讲书。 */
  get recommended(): FqAudioTone | null {
    for (const tone of this.ttsTones) {
      if (tone.isMultiTone) {
        return tone;
      }
    }
    if (this.ttsTones.length > 0) {
      return this.ttsTones[0];
    }
    if (this.narratorTones.length > 0) {
      return this.narratorTones[0];
    }
    return null;
  }
}

export function fqEmptyToneSet(): FqAudioToneSet {
  return new FqAudioToneSet([], [], [], 0, null);
}

/** detail CSV 音色（fqapp AudioVoice：id + 占位标签，'0' = 默认音色）。 */
export class FqAudioVoice {
  readonly id: string;
  readonly label: string;

  constructor(id: string, label: string) {
    this.id = id;
    this.label = label;
  }
}

export function fqDefaultVoices(): FqAudioVoice[] {
  return [new FqAudioVoice('0', '默认音色')];
}

/** 可播放章节流。 */
export class FqAudioSource {
  readonly itemId: string;
  /** 播放地址（mode=download 后多为后端 /src/ 相对路径，需 resourceUrl 锚定）。 */
  readonly url: string;
  readonly toneId: string;
  /** 章节时长（秒；0 未知）。 */
  readonly durationSec: number;

  constructor(itemId: string, url: string, toneId: string, durationSec: number) {
    this.itemId = itemId;
    this.url = url;
    this.toneId = toneId;
    this.durationSec = durationSec;
  }
}

/** 相关作品（/api/v1/books/{id}/related）。 */
export class FqRelatedWork {
  /** 'book' 原著小说 / 'video' 改编短剧。 */
  readonly kind: string;
  readonly id: string;
  readonly title: string;
  readonly cover: string;
  /** 标签文案（原著小说 / 改编短剧）。 */
  readonly label: string;

  constructor(kind: string, id: string, title: string, cover: string, label: string) {
    this.kind = kind;
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.label = label;
  }

  get isEmpty(): boolean {
    return this.id.length === 0 && this.title.length === 0;
  }
}

/** 一条字幕（起始毫秒 + 文本）。 */
export class FqSubtitleCue {
  readonly startMs: number;
  readonly text: string;

  constructor(startMs: number, text: string) {
    this.startMs = startMs;
    this.text = text;
  }
}

/** 边听边读字幕轨（data.speech_text 逐行解析）。 */
export class FqSubtitleTrack {
  readonly cues: FqSubtitleCue[];

  constructor(cues: FqSubtitleCue[]) {
    this.cues = cues;
  }

  get isEmpty(): boolean {
    return this.cues.length === 0;
  }

  /** positionMs 处应高亮的行下标（二分；-1 表示之前）。 */
  indexAt(positionMs: number): number {
    if (this.cues.length === 0) {
      return -1;
    }
    if (positionMs < this.cues[0].startMs) {
      return -1;
    }
    let low: number = 0;
    let high: number = this.cues.length - 1;
    let found: number = -1;
    while (low <= high) {
      const mid: number = (low + high) >> 1;
      if (this.cues[mid].startMs <= positionMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }
}

export function fqEmptySubtitleTrack(): FqSubtitleTrack {
  return new FqSubtitleTrack([]);
}

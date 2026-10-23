/**
 * 听书解析层（对齐 fqapp chapter_media.dart + audio_extra.dart）：
 * - fqParseAudioSource：playinfo（data[].video_model）优先，回退 legacy
 *   （video_info.video_model_datas）——mode=download 后地址是后端 /src/ 相对
 *   路径，由 FqBackend.resourceUrl 锚定；
 * - fqParseAudioToneSet：/tones（小写 key；真人讲书 int64 四舍五入恢复）；
 * - fqParseRelatedWorks：/related（cell_data.book_data / video_data）；
 * - fqParseSubtitleTrack：timeline data.speech_text（[3025,0]<3025,0,0>文本）。
 */

import {
  fqAsArray,
  fqAsInt,
  fqAsRecord,
  fqBool,
  fqFirstString,
  fqNum,
  fqStr,
  fqTruthy,
} from './FqJson';
import {
  FqAudioSource,
  FqAudioTone,
  FqAudioToneSet,
  FqAudioVoice,
  fqEmptyToneSet,
  FqRelatedWork,
  FqSubtitleCue,
  FqSubtitleTrack,
  fqEmptySubtitleTrack,
} from '../model/FqAudioModels';

/** 校验 envelope：任一层 code 非 0/200 或 success=false 抛业务错误。 */
class FqEnvelope {
  /** 沿 data 链下钻收集各层 Record；错误抛出。 */
  static objectsOf(payload: Record<string, Object>): Record<string, Object>[] {
    const objects: Record<string, Object>[] = [];
    let current: Record<string, Object> = payload;
    for (let depth: number = 0; depth < 8; depth++) {
      const code: Object | undefined = current['code'];
      const badCode: boolean = (typeof code === 'number' && code !== 0 && code !== 200)
        || (typeof code === 'string' && code !== '0' && code !== '200');
      if (badCode || current['success'] === false) {
        const message: string = fqFirstString(current, ['message', 'error']);
        throw new Error(message.length > 0 ? message : '媒体请求失败');
      }
      objects.push(current);
      const next: Record<string, Object> | null = fqAsRecord(current['data']);
      if (next === null) {
        return objects;
      }
      current = next;
    }
    throw new Error('媒体响应嵌套过深');
  }

  /** fqapp _resolveData：data ?? 自身；data.data 存在再下钻一层。 */
  static dataOf(payload: Record<string, Object>): Record<string, Object> | null {
    let data: Record<string, Object> | null = fqAsRecord(payload['data']);
    if (data === null) {
      return fqAsRecord(payload);
    }
    const inner: Record<string, Object> | null = fqAsRecord(data['data']);
    if (inner !== null) {
      data = inner;
    }
    return data;
  }
}

/**
 * 解析章节播放流。playinfo 形状（外层 data[] + 嵌套 video_model JSON 串）优先；
 * FormatException 语义（「未获取到音频地址」）时由调用方回退 legacy 形状。
 */
export function fqParsePlayinfoSource(payload: Record<string, Object>, itemId: string,
  toneId: string): FqAudioSource {
  const objects: Record<string, Object>[] = FqEnvelope.objectsOf(payload);
  const last: Record<string, Object> = objects[objects.length - 1];
  const streams: Object[] | null = fqAsArray(last['data']);
  if (streams === null) {
    throw new Error('未获取到音频地址');
  }
  for (const raw of streams) {
    const stream: Record<string, Object> | null = fqAsRecord(raw);
    if (stream === null) {
      continue;
    }
    const streamItemId: string = fqStr(stream, 'item_id');
    if (streamItemId.length > 0 && streamItemId !== itemId) {
      continue;
    }
    // 行内业务错误优先于可用的媒体行
    const code: Object | undefined = stream['code'];
    const badCode: boolean = (typeof code === 'number' && code !== 0 && code !== 200)
      || (typeof code === 'string' && code !== '0' && code !== '200');
    if (badCode || stream['success'] === false) {
      const message: string = fqStr(stream, 'message');
      throw new Error(message.length > 0 ? message : '音频资源暂不可用');
    }
    const rawModel: string = fqStr(stream, 'video_model');
    if (rawModel.length === 0) {
      // 旧直出形状：无 model 但必须可解
      const url: string = fqMediaUrlOf(stream);
      if (url.length === 0) {
        continue;
      }
      return new FqAudioSource(itemId, url, toneId, 0);
    }
    const model: Record<string, Object> | null = fqDecodeModel(rawModel);
    if (model === null) {
      continue;
    }
    const mediaType: string = fqStr(model, 'media_type');
    if (mediaType.length > 0 && mediaType !== 'audio') {
      continue;
    }
    const status: Object | undefined = model['status'];
    if (typeof status === 'number' && status !== 10) {
      const message: string = fqStr(model, 'message');
      throw new Error(message.length > 0 ? message : '音频资源暂不可用');
    }
    const durationSec: number = fqNum(model, 'video_duration');
    const url: string = fqModelAudioUrl(model, stream);
    if (url.length === 0) {
      continue;
    }
    return new FqAudioSource(itemId, url, toneId, durationSec > 0 ? durationSec : 0);
  }
  throw new Error('未获取到音频地址');
}

/** legacy mget 形状：video_info.video_model_datas[].video_model。 */
export function fqParseLegacyAudioSource(payload: Record<string, Object>, itemId: string,
  toneId: string): FqAudioSource {
  const objects: Record<string, Object>[] = FqEnvelope.objectsOf(payload);
  const playback: Record<string, Object> | null = fqAsRecord(payload['video_info']);
  if (playback !== null) {
    const inner: Record<string, Object>[] = FqEnvelope.objectsOf(playback);
    for (const object of inner) {
      const rows: Object[] | null = fqAsArray(object['video_model_datas']);
      if (rows === null) {
        continue;
      }
      for (const rawRow of rows) {
        const row: Record<string, Object> | null = fqAsRecord(rawRow);
        if (row === null || fqStr(row, 'item_id') !== itemId) {
          continue;
        }
        const itemStatus: Object | undefined = row['item_status'];
        if (typeof itemStatus === 'number' && itemStatus !== 0) {
          throw new Error('该章节暂时无法播放');
        }
        const model: Record<string, Object> | null = fqDecodeModel(fqStr(row, 'video_model'));
        if (model === null) {
          continue;
        }
        if (fqStr(model, 'media_type') !== 'audio') {
          continue;
        }
        const status: Object | undefined = model['status'];
        if (typeof status === 'number' && status !== 10) {
          const message: string = fqStr(model, 'message');
          throw new Error(message.length > 0 ? message : '音频资源暂不可用');
        }
        const url: string = fqModelAudioUrl(model, row);
        if (url.length === 0) {
          continue;
        }
        const durationSec: number = fqNum(model, 'video_duration');
        return new FqAudioSource(itemId, url, toneId, durationSec > 0 ? durationSec : 0);
      }
    }
  }
  for (const object of objects) {
    const url: string = fqMediaUrlOf(object);
    if (url.length > 0) {
      return new FqAudioSource(itemId, url, toneId, 0);
    }
  }
  throw new Error('未获取到音频地址');
}

/** video_model JSON 串解码。 */
function fqDecodeModel(raw: string): Record<string, Object> | null {
  if (raw.trim().length === 0) {
    return null;
  }
  try {
    const parsed: Object | null = JSON.parse(raw);
    return fqAsRecord(parsed);
  } catch (error) {
    return null;
  }
}

/** 取 model.video_list 首条可用流地址（外层行地址优先精确匹配）。 */
function fqModelAudioUrl(model: Record<string, Object>, row: Record<string, Object>): string {
  const streams: Object[] | null = fqAsArray(model['video_list']);
  if (streams === null) {
    return '';
  }
  const candidates: string[] = [];
  for (const rawStream of streams) {
    const stream: Record<string, Object> | null = fqAsRecord(rawStream);
    if (stream === null) {
      continue;
    }
    const url: string = fqMediaUrlOf(stream);
    if (url.length > 0) {
      candidates.push(url);
    }
  }
  if (candidates.length === 0) {
    return '';
  }
  const preferred: string = fqMediaUrlOf(row);
  if (preferred.length > 0) {
    for (const candidate of candidates) {
      if (candidate === preferred) {
        return candidate;
      }
    }
  }
  return candidates[0];
}

/** main_url / backup_url 取首个非空。 */
function fqMediaUrlOf(rec: Record<string, Object>): string {
  const main: string = fqStr(rec, 'main_url').trim();
  if (main.length > 0) {
    return main;
  }
  return fqStr(rec, 'backup_url').trim();
}

// ---------------------------------------------------------------------------
// /tones 音色表
// ---------------------------------------------------------------------------

/** 精确 book_id 候选（book_infos 反查 int64 四舍五入损失）。 */
class FqExactBook {
  readonly id: string;
  readonly author: string;
  readonly isAudioBook: boolean;

  constructor(id: string, author: string, isAudioBook: boolean) {
    this.id = id;
    this.author = author;
    this.isAudioBook = isAudioBook;
  }
}

export function fqParseAudioToneSet(payload: Record<string, Object>): FqAudioToneSet {
  const data: Record<string, Object> | null = FqEnvelope.dataOf(payload);
  if (data === null) {
    return fqEmptyToneSet();
  }
  return new FqAudioToneSet(
    fqToneList(fqAsArray(data['tts_tones'])),
    fqToneList(fqAsArray(data['offline_tts_tones'])),
    fqNarratorTones(data),
    fqAsInt(data['req_book_genre_type'], 0),
    fqRelatedNovelOf(data),
  );
}

function fqToneFromRaw(raw: Object | null | undefined): FqAudioTone | null {
  const rec: Record<string, Object> | null = fqAsRecord(raw);
  if (rec === null) {
    return null;
  }
  const id: string = fqStr(rec, 'id').trim();
  const title: string = fqStr(rec, 'title').trim();
  if (id.length === 0 && title.length === 0) {
    return null;
  }
  return new FqAudioTone(id, title, fqStr(rec, 'description').trim(), fqStr(rec, 'badge').trim(),
    fqStr(rec, 'icon_url').trim(), fqBool(rec, 'is_multi_tone'));
}

function fqToneList(raw: Object[] | null): FqAudioTone[] {
  const tones: FqAudioTone[] = [];
  if (raw === null) {
    return tones;
  }
  for (const entry of raw) {
    const tone: FqAudioTone | null = fqToneFromRaw(entry);
    if (tone !== null) {
      tones.push(tone);
    }
  }
  return tones;
}

/** 真人讲书（audio_tones；id 是 abook_id，int64 经 JSON 数字会舍入）。 */
function fqNarratorTones(data: Record<string, Object>): FqAudioTone[] {
  const raw: Object[] | null = fqAsArray(data['audio_tones']);
  if (raw === null) {
    return [];
  }
  const exact: FqExactBook[] = fqExactBooks(fqAsArray(data['book_infos']));
  const tones: FqAudioTone[] = [];
  for (const entry of raw) {
    const rec: Record<string, Object> | null = fqAsRecord(entry);
    if (rec === null) {
      continue;
    }
    const id: string = fqNarratorId(rec, exact);
    if (id.length === 0) {
      continue;
    }
    const patched: Record<string, Object> = {};
    const keys: string[] = Object.keys(rec);
    for (const key of keys) {
      patched[key] = rec[key];
    }
    patched['id'] = id;
    const tone: FqAudioTone | null = fqToneFromRaw(patched);
    if (tone !== null) {
      tones.push(tone);
    }
  }
  return tones;
}

function fqNarratorId(rec: Record<string, Object>, exact: FqExactBook[]): string {
  const fromKeys: string = fqFirstString(rec, ['abook_id_str', 'book_id']);
  if (fromKeys.length > 0) {
    return fromKeys;
  }
  const abook: Object | undefined = rec['abook_id'];
  if (typeof abook !== 'number' || !Number.isFinite(abook)) {
    return '';
  }
  if (Math.abs(abook) <= 9007199254740992) {
    return Math.trunc(abook).toString();
  }
  return fqMatchExactBookId(abook, fqStr(rec, 'title'), exact);
}

/** 只有能无歧义还原的才用；宁可丢弃也不能发错 tone id。 */
function fqMatchExactBookId(rounded: number, title: string, exact: FqExactBook[]): string {
  const bucket: FqExactBook[] = [];
  for (const book of exact) {
    const parsed: number = Number(book.id);
    if (Number.isFinite(parsed) && parsed === rounded) {
      bucket.push(book);
    }
  }
  if (bucket.length === 0) {
    return '';
  }
  const wanted: string = fqNormalizeNarratorName(title);
  if (wanted.length === 0) {
    return '';
  }
  let matches: FqExactBook[] = [];
  for (const book of bucket) {
    if (fqNormalizeNarratorName(book.author) === wanted) {
      matches.push(book);
    }
  }
  if (matches.length > 1) {
    const audio: FqExactBook[] = [];
    for (const book of matches) {
      if (book.isAudioBook) {
        audio.push(book);
      }
    }
    if (audio.length > 0) {
      matches = audio;
    }
  }
  const ids: Set<string> = new Set<string>();
  for (const book of matches) {
    ids.add(book.id);
  }
  return ids.size === 1 ? (ids.values().next().value ?? '') : '';
}

function fqExactBooks(raw: Object[] | null): FqExactBook[] {
  const books: FqExactBook[] = [];
  if (raw === null) {
    return books;
  }
  const seen: Set<string> = new Set<string>();
  for (const entry of raw) {
    const rec: Record<string, Object> | null = fqAsRecord(entry);
    if (rec === null) {
      continue;
    }
    const id: string = fqStr(rec, 'book_id');
    if (id.length === 0 || seen.has(id)) {
      continue;
    }
    seen.add(id);
    const typeRaw: Object | undefined = rec['book_type'];
    const isAudioBook: boolean = typeRaw === 1 || typeRaw === '1';
    books.push(new FqExactBook(id, fqStr(rec, 'author'), isAudioBook));
  }
  return books;
}

function fqNormalizeNarratorName(value: string): string {
  return value.replace(/^主播[:：]\s*/, '').replace(/\s+/g, '').trim();
}

// ---------------------------------------------------------------------------
// detail CSV voices（fqapp parseAudioVoices / _mergeToneVoices）
// ---------------------------------------------------------------------------

/**
 * 小说 detail 的 tones CSV（"0,201,…"）拆音色 id：
 * '0' 恒在（默认音色），其余逐个生成「音色 {id}」占位标签。
 * 业务错误沿 envelope 校验抛出，由调用方兜底默认。
 */
export function fqParseAudioVoices(payload: Record<string, Object>): FqAudioVoice[] {
  const objects: Record<string, Object>[] = FqEnvelope.objectsOf(payload);
  const ids: string[] = ['0'];
  for (const object of objects) {
    const tones: Object | undefined = object['tones'];
    if (typeof tones !== 'string') {
      continue;
    }
    const parts: string[] = tones.split(',');
    for (const part of parts) {
      const id: string = part.trim();
      if (id.length > 0 && !ids.includes(id)) {
        ids.push(id);
      }
    }
    break;
  }
  const voices: FqAudioVoice[] = [];
  for (const id of ids) {
    voices.push(new FqAudioVoice(id, id === '0' ? '默认音色' : `音色 ${id}`));
  }
  return voices;
}

/** fqapp _uniqueTones：按 id+title 去重，保序。 */
export function fqUniqueTones(tones: FqAudioTone[]): FqAudioTone[] {
  const seen: Set<string> = new Set<string>();
  const out: FqAudioTone[] = [];
  for (const tone of tones) {
    const key: string = `${tone.id}\u0000${tone.title}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(tone);
  }
  return out;
}

/**
 * fqapp _mergeToneVoices：/tones 真实音色名覆盖 CSV 占位标签；
 * 标签撞车时加「title（id）」后缀。返回 id 有序去重的合并 voices。
 */
export function fqMergeToneVoices(toneSet: FqAudioToneSet, rawVoices: FqAudioVoice[]): FqAudioVoice[] {
  const byId: Map<string, FqAudioVoice> = new Map<string, FqAudioVoice>();
  for (const voice of rawVoices) {
    byId.set(voice.id, voice);
  }
  const labels: Map<string, string> = new Map<string, string>();
  byId.forEach((voice: FqAudioVoice): void => {
    labels.set(voice.label, voice.id);
  });
  const merged: FqAudioTone[] = fqUniqueTones(toneSet.ttsTones.concat(toneSet.narratorTones));
  for (const tone of merged) {
    const id: string = tone.id.trim();
    const title: string = tone.title.trim();
    if (id.length === 0 || title.length === 0) {
      continue;
    }
    let label: string = title;
    const owner: string | undefined = labels.get(label);
    if (owner !== undefined && owner !== id) {
      label = `${title}（${id}）`;
      let bump: number = 2;
      let taken: string | undefined = labels.get(label);
      while (taken !== undefined && taken !== id) {
        label = `${title}（${id}·${bump}）`;
        bump += 1;
        taken = labels.get(label);
      }
    }
    labels.set(label, id);
    byId.set(id, new FqAudioVoice(id, label));
  }
  const out: FqAudioVoice[] = [];
  byId.forEach((voice: FqAudioVoice): void => {
    out.push(voice);
  });
  return out;
}

/** relate_novel_bookid（str 优先；数字四舍五入经 book_infos 无歧义恢复）。 */
function fqRelatedNovelOf(data: Record<string, Object>): FqRelatedWork | null {
  const entries: Object[] | null = fqAsArray(data['book_infos']);
  const raw: Object | undefined = data['relate_novel_bookid'];
  let id: string = fqDecimalBookId(fqStr(data, 'relate_novel_bookid_str'));
  if (id.length === 0) {
    id = fqDecimalBookId(fqStr(data, 'relate_novel_bookid'));
  }
  if (id.length === 0 && typeof raw === 'number' && Number.isFinite(raw) && raw > 0) {
    const candidates: Set<string> = new Set<string>();
    if (entries !== null) {
      for (const entry of entries) {
        const rec: Record<string, Object> | null = fqAsRecord(entry);
        if (rec === null) {
          continue;
        }
        const candidate: string = fqDecimalBookId(fqStr(rec, 'book_id'));
        if (fqStr(rec, 'is_ebook') === '1' && candidate.length > 0
          && Number(candidate) === raw) {
          candidates.add(candidate);
        }
      }
    }
    if (candidates.size === 1) {
      id = candidates.values().next().value ?? '';
    } else if (candidates.size === 0 && raw <= 9007199254740992
      && raw === Math.trunc(raw)) {
      id = Math.trunc(raw).toString();
    }
  }
  if (id.length === 0) {
    return null;
  }
  if (entries !== null) {
    for (const entry of entries) {
      const rec: Record<string, Object> | null = fqAsRecord(entry);
      if (rec !== null && fqStr(rec, 'book_id') === id) {
        return fqRelatedWorkFromRaw(rec, 'book', '原著小说');
      }
    }
  }
  return new FqRelatedWork('book', id, '', '', '原著小说');
}

function fqDecimalBookId(raw: string): string {
  const value: string = raw.trim();
  return /^[1-9][0-9]*$/.test(value) ? value : '';
}

// ---------------------------------------------------------------------------
// /related 相关作品
// ---------------------------------------------------------------------------

export function fqParseRelatedWorks(payload: Record<string, Object>): FqRelatedWork[] {
  const data: Record<string, Object> | null = FqEnvelope.dataOf(payload);
  if (data === null) {
    return [];
  }
  const cells: Object[] | null = fqAsArray(data['cell_data']);
  if (cells === null) {
    return [];
  }
  const works: FqRelatedWork[] = [];
  for (const rawCell of cells) {
    const cell: Record<string, Object> | null = fqAsRecord(rawCell);
    if (cell === null) {
      continue;
    }
    const books: Object[] | null = fqAsArray(cell['book_data']);
    if (books !== null) {
      for (const entry of books) {
        const rec: Record<string, Object> | null = fqAsRecord(entry);
        if (rec !== null) {
          const work: FqRelatedWork | null = fqRelatedWorkFromRaw(rec, 'book', '原著小说');
          if (work !== null) {
            works.push(work);
          }
        }
      }
    }
    const videos: Object[] | null = fqAsArray(cell['video_data']);
    if (videos !== null) {
      for (const entry of videos) {
        const rec: Record<string, Object> | null = fqAsRecord(entry);
        if (rec !== null) {
          const work: FqRelatedWork | null = fqRelatedWorkFromRaw(rec, 'video', '改编短剧');
          if (work !== null) {
            works.push(work);
          }
        }
      }
    }
    if (works.length > 0) {
      break;
    }
  }
  return works;
}

function fqRelatedWorkFromRaw(rec: Record<string, Object>, kind: string,
  label: string): FqRelatedWork | null {
  const title: string = fqFirstString(rec, ['book_name', 'title']);
  const id: string = fqFirstString(rec, ['book_id', 'series_id']);
  if (id.length === 0 && title.length === 0) {
    return null;
  }
  const cover: string = fqFirstString(rec, ['thumb_url', 'cover', 'cover_url', 'poster_url']);
  return new FqRelatedWork(kind, id, title, cover, label);
}

// ---------------------------------------------------------------------------
// timeline 字幕
// ---------------------------------------------------------------------------

const FQ_CUE_RE: RegExp = /^\[(\d+),\d+\]<\d+,\d+,\d+>(.*)$/;

export function fqParseSubtitleTrack(payload: Record<string, Object>): FqSubtitleTrack {
  const data: Record<string, Object> | null = FqEnvelope.dataOf(payload);
  if (data === null) {
    return fqEmptySubtitleTrack();
  }
  const raw: string = fqStr(data, 'speech_text');
  if (raw.trim().length === 0) {
    return fqEmptySubtitleTrack();
  }
  const cues: FqSubtitleCue[] = [];
  const lines: string[] = raw.split('\n');
  for (const line of lines) {
    const match: RegExpMatchArray | null = line.trim().match(FQ_CUE_RE);
    if (match === null) {
      continue;
    }
    const startMs: number = Number.parseInt(match[1] ?? '', 10);
    const text: string = (match[2] ?? '').trim();
    if (Number.isNaN(startMs) || text.length === 0) {
      continue;
    }
    cues.push(new FqSubtitleCue(startMs, text));
  }
  if (cues.length === 0) {
    return fqEmptySubtitleTrack();
  }
  cues.sort((a: FqSubtitleCue, b: FqSubtitleCue): number => a.startMs - b.startMs);
  return new FqSubtitleTrack(cues);
}

/** 上游业务错误码（1301008 等）→ 空字幕。 */
export function fqSubtitleUnavailable(payload: Record<string, Object>): boolean {
  const code: Object | undefined = payload['code'];
  if (typeof code === 'number' && code !== 0 && code !== 200) {
    return true;
  }
  if (typeof code === 'string' && code !== '0' && code !== '200') {
    return true;
  }
  return !fqTruthy(payload['data']) && !fqTruthy(payload['speech_text']);
}

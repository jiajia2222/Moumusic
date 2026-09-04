import { dateFormat } from './common'
import he from 'he'

export { tranditionalize as langS2T } from '@/utils/simplify-chinese-main'

export * from './common'

const qualityAliases: Record<string, LX.Quality> = {
  flac32bit: 'flac24bit',
}

const supportedQualities = new Set<LX.Quality>(['128k', '192k', '320k', 'flac', 'flac24bit', 'ape', 'wav'])

/**
 * A quality flag is useful only when the source supplied a real, positive
 * file size. Some platform endpoints omit fields or return "0" as a string;
 * checking with `!== 0` turns those missing values into false Hi-Res badges.
 */
export const hasQualityFileSize = (value: unknown): boolean => {
  if (typeof value == 'number') return Number.isFinite(value) && value > 0
  if (typeof value != 'string') return false
  const normalized = value.trim().toLowerCase()
  if (!normalized) return false
  const number = Number.parseFloat(normalized)
  return Number.isFinite(number) && number > 0
}

const normalizeQualityType = (value: unknown): LX.Quality | null => {
  const type = typeof value == 'string' ? (qualityAliases[value] ?? value) : ''
  return supportedQualities.has(type as LX.Quality) ? type as LX.Quality : null
}

/**
 * Keep only quality entries backed by the song's own metadata. This is
 * intentionally stricter than a source-level capability list: a source may
 * support FLAC in general while this particular song only has 320k.
 */
export const normalizeMusicQuality = (types: unknown, qualityMap: unknown): {
  types: LX.Music.MusicQualityType[]
  qualityMap: LX.Music._MusicQualityType
} => {
  const rawTypes = Array.isArray(types) ? types : []
  const rawMap = qualityMap && typeof qualityMap == 'object' ? qualityMap as Record<string, any> : {}
  const candidates = new Map<LX.Quality, any>()

  rawTypes.forEach((entry: any) => {
    const type = normalizeQualityType(entry?.type)
    if (!type) return
    candidates.set(type, { ...(candidates.get(type) || {}), ...(entry || {}), type })
  })
  Object.entries(rawMap).forEach(([rawType, entry]) => {
    const type = normalizeQualityType(rawType)
    if (!type) return
    candidates.set(type, { ...(candidates.get(type) || {}), ...(entry || {}), type })
  })

  const normalizedTypes: LX.Music.MusicQualityType[] = []
  const normalizedMap: LX.Music._MusicQualityType = {}
  for (const [type, entry] of candidates) {
    const size = entry?.size
    if (!hasQualityFileSize(size)) continue
    const normalizedEntry: LX.Music.MusicQualityType = { ...entry, size, type }
    normalizedTypes.push(normalizedEntry)
    normalizedMap[type] = { ...entry, size }
  }

  return { types: normalizedTypes, qualityMap: normalizedMap }
}

export const isQualityAvailable = (musicInfo: LX.Music.MusicInfoOnline, quality: LX.Quality): boolean => {
  return hasQualityFileSize(musicInfo.meta._qualitys?.[quality]?.size)
}

// https://stackoverflow.com/a/53387532
export function compareVer(currentVer: string, targetVer: string): -1 | 0 | 1 {
  // treat non-numerical characters as lower version
  // replacing them with a negative number based on charcode of each character
  const fix = (s: string) => `.${s.toLowerCase().charCodeAt(0) - 2147483647}.`

  const currentVerArr: Array<string | number> = ('' + currentVer).replace(/[^0-9.]/g, fix).split('.')
  const targetVerArr: Array<string | number> = ('' + targetVer).replace(/[^0-9.]/g, fix).split('.')
  let c = Math.max(currentVerArr.length, targetVerArr.length)
  for (let i = 0; i < c; i++) {
    // convert to integer the most efficient way
    currentVerArr[i] = ~~currentVerArr[i]
    targetVerArr[i] = ~~targetVerArr[i]
    if (currentVerArr[i] > targetVerArr[i]) return 1
    else if (currentVerArr[i] < targetVerArr[i]) return -1
  }
  return 0
}


export const toNewMusicInfo = (oldMusicInfo: any): LX.Music.MusicInfo => {
  const meta: Record<string, any> = {
    songId: oldMusicInfo.songmid, // 歌曲ID，local为文件路径
    albumName: oldMusicInfo.albumName, // 歌曲专辑名称
    picUrl: oldMusicInfo.img, // 歌曲图片链接
  }
  const newInfo = {
    id: `${oldMusicInfo.source as string}_${oldMusicInfo.songmid as string}`,
    name: oldMusicInfo.name,
    singer: oldMusicInfo.singer,
    source: oldMusicInfo.source,
    interval: oldMusicInfo.interval,
    meta: meta as LX.Music.MusicInfoOnline['meta'],
  }

  if (oldMusicInfo.source == 'local') {
    meta.filePath = oldMusicInfo.filePath ?? oldMusicInfo.songmid ?? ''
    meta.ext = oldMusicInfo.ext ?? /\.(\w+)$/.exec(meta.filePath as string)?.[1] ?? ''
  } else {
    const qualityInfo = normalizeMusicQuality(oldMusicInfo.types, oldMusicInfo._types)
    meta.qualitys = qualityInfo.types
    meta._qualitys = qualityInfo.qualityMap
    meta.albumId = oldMusicInfo.albumId

    switch (oldMusicInfo.source) {
      case 'kg':
        meta.hash = oldMusicInfo.hash
        newInfo.id = oldMusicInfo.songmid + '_' + oldMusicInfo.hash
        break
      case 'tx':
        meta.strMediaMid = oldMusicInfo.strMediaMid
        meta.albumMid = oldMusicInfo.albumMid
        meta.id = oldMusicInfo.songId
        break
      case 'mg':
        meta.copyrightId = oldMusicInfo.copyrightId
        meta.lrcUrl = oldMusicInfo.lrcUrl
        meta.mrcUrl = oldMusicInfo.mrcUrl
        meta.trcUrl = oldMusicInfo.trcUrl
        break
    }
  }

  return newInfo
}

export const toOldMusicInfo = (minfo: LX.Music.MusicInfo): any => {
  const oInfo: Record<string, any> = {
    name: minfo.name,
    singer: minfo.singer,
    source: minfo.source,
    songmid: minfo.meta.songId,
    interval: minfo.interval,
    albumName: minfo.meta.albumName,
    img: minfo.meta.picUrl ?? '',
    typeUrl: {},
  }
  if (minfo.source == 'local') {
    oInfo.filePath = minfo.meta.filePath
    oInfo.ext = minfo.meta.ext
    oInfo.albumId = ''
    oInfo.types = []
    oInfo._types = {}
  } else {
    oInfo.albumId = minfo.meta.albumId
    const qualityInfo = normalizeMusicQuality(minfo.meta.qualitys, minfo.meta._qualitys)
    oInfo.types = qualityInfo.types
    oInfo._types = qualityInfo.qualityMap

    switch (minfo.source) {
      case 'kg':
        oInfo.hash = minfo.meta.hash
        break
      case 'tx':
        oInfo.strMediaMid = minfo.meta.strMediaMid
        oInfo.albumMid = minfo.meta.albumMid
        oInfo.songId = minfo.meta.id
        break
      case 'mg':
        oInfo.copyrightId = minfo.meta.copyrightId
        oInfo.lrcUrl = minfo.meta.lrcUrl
        oInfo.mrcUrl = minfo.meta.mrcUrl
        oInfo.trcUrl = minfo.meta.trcUrl
        break
    }
  }

  return oInfo
}

/**
 * 修复2.0.0-dev.8之前的新列表数据音质
 * @param musicInfo
 */
export const fixNewMusicInfoQuality = (musicInfo: LX.Music.MusicInfo) => {
  if (musicInfo.source == 'local') return musicInfo

  const qualityInfo = normalizeMusicQuality(musicInfo.meta.qualitys, musicInfo.meta._qualitys)
  musicInfo.meta.qualitys = qualityInfo.types
  musicInfo.meta._qualitys = qualityInfo.qualityMap

  return musicInfo
}


export const filterMusicList = <T extends LX.Music.MusicInfo>(list: T[]): T[] => {
  const ids = new Set<string>()
  return list.filter(s => {
    if (!s.id || ids.has(s.id) || !s.name) return false
    if (s.singer == null) s.singer = ''
    ids.add(s.id)
    return true
  })
}


export const deduplicationList = <T extends LX.Music.MusicInfo>(list: T[]): T[] => {
  const ids = new Set<string>()
  return list.filter(s => {
    if (ids.has(s.id)) return false
    ids.add(s.id)
    return true
  })
}


/**
 * 时间格式化
 */
export const dateFormat2 = (time: number): string => {
  let differ = Math.trunc((Date.now() - time) / 1000)
  if (differ < 60) {
    return global.i18n.t('date_format_second', { num: differ })
  } else if (differ < 3600) {
    return global.i18n.t('date_format_minute', { num: Math.trunc(differ / 60) })
  } else if (differ < 86400) {
    return global.i18n.t('date_format_hour', { num: Math.trunc(differ / 3600) })
  } else {
    return dateFormat(time)
  }
}

/**
 * 格式化播放数量
 * @param {*} num 数字
 */
export const formatPlayCount = (num: number): string => {
  if (num > 100000000) return `${Math.trunc(num / 10000000) / 10}亿`
  if (num > 10000) return `${Math.trunc(num / 1000) / 10}万`
  return String(num)
}

export const decodeName = (str: string | null = '') => {
  if (!str) return ''
  return he.decode(str)
}

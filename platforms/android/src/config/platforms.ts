export interface MoumusicPlatform {
  id: LX.OnlineSource
  name: string
  description: string
  color: string
}

/**
 * Moumusic separates two concerns, matching the useful part of LX's model:
 * a platform provides search/catalog data, while a user source provides the
 * playable URL, lyrics, cover and quality negotiation.
 */
export const MUSIC_PLATFORMS: readonly MoumusicPlatform[] = [
  { id: 'kw', name: '酷我', description: '搜索与歌单', color: '#45c486' },
  { id: 'kg', name: '酷狗', description: '搜索与歌词', color: '#3c86ff' },
  { id: 'tx', name: 'QQ 音乐', description: '搜索与排行榜', color: '#20c997' },
  { id: 'wy', name: '网易云', description: '搜索与评论', color: '#ef5361' },
  { id: 'mg', name: '咪咕', description: '搜索与歌单', color: '#f59e0b' },
]

export const getPlatform = (id: LX.OnlineSource) => MUSIC_PLATFORMS.find(platform => platform.id == id)

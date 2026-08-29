import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ActivityIndicator, ScrollView, TouchableOpacity, View } from 'react-native'
import Input from '@/components/common/Input'
import Text from '@/components/common/Text'
import { Icon } from '@/components/common/Icon'
import { useTheme } from '@/store/theme/hook'
import { createStyle } from '@/utils/tools'
import OnlineList, { type OnlineListType } from '@/components/OnlineList'
import SonglistSearch, { type MusicListType as SonglistSearchType } from '../Views/Search/SonglistList'
import { search as searchMusic } from '@/core/search/music'
import { addHistoryWord, setSearchType as setSearchTypeCore } from '@/core/search/search'
import searchMusicState, { type Source as MusicSource } from '@/store/search/music/state'
import searchSonglistState from '@/store/search/songlist/state'
import { getSearchSetting, saveSearchSetting } from '@/utils/data'
import { useSourceListI18n } from '@/components/SourceSelector'
import type { SearchType } from '@/store/search/state'

interface Props {
  onOpenSettings: () => void
}

const EmptySearch = ({ searched, loading, error, onOpenSettings }: { searched: boolean, loading: boolean, error: boolean, onOpenSettings: () => void }) => {
  const theme = useTheme()
  if (searched && loading) {
    return <View style={styles.empty}><ActivityIndicator color={theme['c-primary']} /><Text style={styles.emptyTitle}>正在聚合搜索…</Text></View>
  }
  if (searched && error) {
    return <View style={styles.empty}><Icon name="available_updates" size={32} color={theme['c-font-label']} /><Text style={styles.emptyTitle}>搜索失败，请检查网络或音源</Text><Text size={13} color={theme['c-font-label']}>可以到设置重新选择 LX 音源</Text></View>
  }
  if (searched) {
    return <View style={styles.empty}><Icon name="search-2" size={32} color={theme['c-font-label']} /><Text style={styles.emptyTitle}>没有找到相关歌曲</Text><Text size={13} color={theme['c-font-label']}>换个关键词，或切换搜索平台再试</Text></View>
  }
  return (
    <View style={styles.empty}>
      <View style={{ ...styles.emptyIcon, backgroundColor: theme['c-primary-background-active'] }}><Icon name="logo" size={34} color={theme['c-primary-font-active']} /></View>
      <Text size={22} style={styles.emptyTitle}>搜索你的音乐</Text>
      <Text size={14} color={theme['c-font-label']} style={styles.emptyCopy}>综合搜索会并发查询已启用的平台，播放地址和歌词由你导入的 LX 音源提供。</Text>
      <TouchableOpacity onPress={onOpenSettings} style={{ ...styles.action, backgroundColor: theme['c-primary-background-active'] }}><Text color={theme['c-primary-font-active']} size={14}>管理 LX 音源</Text></TouchableOpacity>
    </View>
  )
}

export default ({ onOpenSettings }: Props) => {
  const theme = useTheme()
  const listRef = useRef<OnlineListType>(null)
  const songlistRef = useRef<SonglistSearchType>(null)
  const requestIdRef = useRef(0)
  const loadingRef = useRef(false)
  const [query, setQuery] = useState('')
  const [source, setSource] = useState<MusicSource>('all')
  const [searchType, setSearchType] = useState<SearchType>('music')
  const [searched, setSearched] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(false)
  const [resultCount, setResultCount] = useState(0)

  const sources = useMemo(() => {
    const ids = searchType == 'music' ? searchMusicState.sources : searchSonglistState.sources
    return ids
  }, [searchType])
  const sourceLabels = useSourceListI18n(sources)

  useEffect(() => {
    if (sources.includes(source)) return
    const fallback = sources.includes('all') ? 'all' : sources[0]
    if (fallback) setSource(fallback)
  }, [source, sources])

  useEffect(() => {
    let mounted = true
    void getSearchSetting().then(info => {
      if (!mounted) return
      setSource(info.source as MusicSource)
      setSearchType(info.type)
    }).catch(() => {})
    return () => { mounted = false }
  }, [])

  const runSearch = useCallback(async(text: string, nextSource: MusicSource, nextType: SearchType) => {
    const trimmed = text.trim()
    const requestId = ++requestIdRef.current
    setQuery(text)
    setError(false)
    if (!trimmed) {
      setSearched(false)
      setLoading(false)
      loadingRef.current = false
      setResultCount(0)
      listRef.current?.setList([], false, false)
      listRef.current?.setStatus('idle')
      return
    }
    setSearched(true)
    setLoading(true)
    loadingRef.current = true
    setResultCount(0)
    listRef.current?.setList([], false, nextSource == 'all')
    listRef.current?.setStatus('loading')
    try {
      if (nextType == 'music') {
        const list = await searchMusic(trimmed, 1, nextSource)
        if (requestId != requestIdRef.current) return
        setResultCount(list.length)
        listRef.current?.setList(list, false, nextSource == 'all')
        const info = searchMusicState.listInfos[nextSource]
        listRef.current?.setStatus(info && info.maxPage > info.page ? 'idle' : 'end')
      } else {
        await Promise.resolve(songlistRef.current?.loadList(trimmed, nextSource))
        if (requestId != requestIdRef.current) return
        setResultCount(searchSonglistState.listInfos[nextSource]?.list.length ?? 0)
      }
    } catch {
      if (requestId != requestIdRef.current) return
      setError(true)
      listRef.current?.setStatus('error')
    } finally {
      if (requestId == requestIdRef.current) {
        loadingRef.current = false
        setLoading(false)
      }
    }
  }, [])

  const loadMore = useCallback(async() => {
    if (searchType != 'music' || loadingRef.current || !query.trim()) return
    const info = searchMusicState.listInfos[source]
    if (!info || info.maxPage <= info.page) {
      listRef.current?.setStatus('end')
      return
    }
    const requestId = requestIdRef.current
    const nextPage = info.page + 1
    loadingRef.current = true
    listRef.current?.setStatus('loading')
    try {
      const list = await searchMusic(query.trim(), nextPage, source)
      if (requestId != requestIdRef.current) return
      setResultCount(list.length)
      listRef.current?.setList(list, false, source == 'all')
      const nextInfo = searchMusicState.listInfos[source]
      listRef.current?.setStatus(nextInfo && nextInfo.maxPage > nextInfo.page ? 'idle' : 'end')
    } catch {
      if (requestId == requestIdRef.current) {
        setError(true)
        listRef.current?.setStatus('error')
      }
    } finally {
      if (requestId == requestIdRef.current) loadingRef.current = false
    }
  }, [query, searchType, source])

  const submit = useCallback(() => {
    void saveSearchSetting({ source, type: searchType })
    void addHistoryWord(query.trim())
    void runSearch(query, source, searchType)
  }, [query, runSearch, searchType, source])

  const changeSource = (nextSource: MusicSource) => {
    setSource(nextSource)
    void saveSearchSetting({ source: nextSource })
    if (query.trim()) void runSearch(query, nextSource, searchType)
  }

  const changeType = (nextType: SearchType) => {
    setSearchType(nextType)
    setSearchTypeCore(nextType)
    void saveSearchSetting({ type: nextType })
    if (query.trim()) void runSearch(query, source, nextType)
  }

  const refresh = useCallback(() => {
    if (query.trim()) void runSearch(query, source, searchType)
  }, [query, runSearch, searchType, source])

  const resultList = (
    <>
      <View style={searchType == 'music' ? styles.activeResult : styles.inactiveResult}>
        <OnlineList ref={listRef} onRefresh={refresh} onLoadMore={() => { void loadMore() }} checkHomePagerIdle />
      </View>
      <View style={searchType == 'songlist' ? styles.activeResult : styles.inactiveResult}>
        <SonglistSearch ref={songlistRef} />
      </View>
    </>
  )

  return (
    <View style={styles.container}>
      <View style={{ ...styles.searchCard, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.84)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
        <View style={{ ...styles.inputWrap, backgroundColor: theme.isDark ? 'rgba(0,0,0,0.18)' : 'rgba(245,247,251,0.9)' }}>
          <Icon name="search-2" size={17} color={theme['c-font-label']} />
          <Input
            clearBtn
            onChangeText={setQuery}
            onSubmitEditing={submit}
            placeholder="搜索歌曲、歌手或歌单"
            returnKeyType="search"
            size={15}
            style={styles.input}
            value={query}
          />
        </View>
        <TouchableOpacity onPress={submit} style={{ ...styles.searchButton, backgroundColor: theme['c-primary-background-active'] }}><Text size={14} color={theme['c-primary-font-active']}>搜索</Text></TouchableOpacity>
      </View>

      <View style={styles.sectionHeader}>
        <Text size={13} color={theme['c-font-label']}>搜索平台</Text>
        <Text size={12} color={theme['c-font-label']}>{source == 'all' ? '聚合' : '单平台'}</Text>
      </View>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.chipList} keyboardShouldPersistTaps="always">
        {sourceLabels.map(item => {
          const active = source == item.action
          return <TouchableOpacity key={item.action} onPress={() => { changeSource(item.action) }} style={{ ...styles.chip, borderColor: active ? theme['c-primary'] : theme['c-border-background'], backgroundColor: active ? theme['c-primary-background-active'] : 'transparent' }}><Text size={12} color={active ? theme['c-primary-font-active'] : theme['c-font']}>{item.label}</Text></TouchableOpacity>
        })}
      </ScrollView>

      <View style={styles.modeBar}>
        {([{ id: 'music', label: '歌曲' }, { id: 'songlist', label: '歌单' }] as const).map(item => {
          const active = searchType == item.id
          return <TouchableOpacity key={item.id} onPress={() => { changeType(item.id) }} style={{ ...styles.mode, borderBottomColor: active ? theme['c-primary'] : 'transparent' }}><Text size={14} color={active ? theme['c-primary-font-active'] : theme['c-font-label']}>{item.label}</Text></TouchableOpacity>
        })}
        {searched && !loading ? <Text size={12} color={theme['c-font-label']} style={styles.count}>{resultCount} 条结果</Text> : null}
      </View>

      <View style={styles.results}>
        {resultList}
        {!searched || (searched && resultCount == 0 && !loading)
          ? <View style={styles.emptyOverlay}><EmptySearch searched={searched} loading={loading} error={error} onOpenSettings={onOpenSettings} /></View>
          : null}
        {searched && loading && resultCount > 0 ? <View pointerEvents="none" style={styles.loadingOverlay}><ActivityIndicator color={theme['c-primary']} /></View> : null}
      </View>
    </View>
  )
}

const styles = createStyle({
  container: { flex: 1 },
  searchCard: { margin: 12, padding: 8, borderRadius: 20, borderWidth: 1, flexDirection: 'row', alignItems: 'center' },
  inputWrap: { flex: 1, height: 42, paddingHorizontal: 11, borderRadius: 13, flexDirection: 'row', alignItems: 'center' },
  input: { flex: 1, height: 42, paddingHorizontal: 8 },
  searchButton: { height: 42, minWidth: 56, marginLeft: 8, borderRadius: 13, alignItems: 'center', justifyContent: 'center' },
  sectionHeader: { paddingHorizontal: 16, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  chipList: { paddingHorizontal: 12, paddingTop: 8, paddingBottom: 2 },
  chip: { paddingHorizontal: 11, paddingVertical: 7, marginHorizontal: 3, borderRadius: 99, borderWidth: 1 },
  modeBar: { minHeight: 42, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', borderBottomWidth: 1 },
  mode: { paddingHorizontal: 13, paddingVertical: 8, marginRight: 5, borderBottomWidth: 2 },
  count: { marginLeft: 'auto' },
  results: { flex: 1, overflow: 'hidden' },
  activeResult: { flex: 1 },
  inactiveResult: { display: 'none' },
  emptyOverlay: { position: 'absolute', left: 0, right: 0, top: 0, bottom: 0 },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 32 },
  emptyIcon: { width: 72, height: 72, borderRadius: 22, alignItems: 'center', justifyContent: 'center', marginBottom: 16 },
  emptyTitle: { marginTop: 10, textAlign: 'center' },
  emptyCopy: { maxWidth: 330, marginTop: 8, textAlign: 'center', lineHeight: 21 },
  action: { paddingHorizontal: 16, paddingVertical: 10, borderRadius: 12, marginTop: 18 },
  loadingOverlay: { ...({ position: 'absolute', left: 0, right: 0, top: 0, bottom: 0 } as const), alignItems: 'center', justifyContent: 'center' },
})

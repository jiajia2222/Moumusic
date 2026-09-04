import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react'

import { search } from '@/core/search/songlist'
import Songlist, { type SonglistProps, type SonglistType } from '@/screens/Home/Views/SongList/components/Songlist'
import searchSonglistState, { type Source } from '@/store/search/songlist/state'
import type { SearchFinishedStatus } from './SearchStatusOverlay'

// export type MusicListProps = Pick<OnlineListProps,
// 'onLoadMore'
// | 'onPlayList'
// | 'onRefresh'
// >

export interface MusicListType {
  loadList: (text: string, source: Source) => void
}

interface SonglistListProps {
  onSearchFinished: (status: SearchFinishedStatus) => void
}

export default forwardRef<MusicListType, SonglistListProps>(({ onSearchFinished }, ref) => {
  const listRef = useRef<SonglistType>(null)
  const searchInfoRef = useRef<{ text: string, source: Source }>({ text: '', source: 'kw' })
  const isUnmountedRef = useRef(false)
  useImperativeHandle(ref, () => ({
    async loadList(text, source) {
      // const listDetailInfo = searchSonglistState.listDetailInfo
      listRef.current?.setList([], source == 'all')
      if (searchSonglistState.searchText == text && searchSonglistState.source == source && searchSonglistState.listInfos[searchSonglistState.source]!.list.length) {
        requestAnimationFrame(() => {
          listRef.current?.setList(searchSonglistState.listInfos[searchSonglistState.source]!.list, source == 'all')
          onSearchFinished('success')
        })
      } else {
        listRef.current?.setStatus('loading')
        const page = 1
        searchInfoRef.current.text = text
        searchInfoRef.current.source = source
        return search(text, page, source).then((list) => {
          // const result = setListInfo(listDetail, id, page)
          if (isUnmountedRef.current) return
          requestAnimationFrame(() => {
            listRef.current?.setList(list, source == 'all')
            listRef.current?.setStatus(searchSonglistState.maxPages[searchSonglistState.source] == page ? 'end' : 'idle')
            onSearchFinished('success')
          })
        }).catch(() => {
          listRef.current?.setStatus('error')
          onSearchFinished('error')
        })
      }
    },
  }), [onSearchFinished])

  useEffect(() => {
    isUnmountedRef.current = false
    return () => {
      isUnmountedRef.current = true
    }
  }, [])


  const handleRefresh: SonglistProps['onRefresh'] = () => {
    const page = 1
    listRef.current?.setStatus('refreshing')
    search(searchInfoRef.current.text, page, searchInfoRef.current.source).then((list) => {
      // const result = setListInfo(listDetail, searchSonglistState.listDetailInfo.id, page)
      if (isUnmountedRef.current) return
      listRef.current?.setList(list, searchInfoRef.current.source == 'all')
      listRef.current?.setStatus(searchSonglistState.maxPages[searchSonglistState.source] == page ? 'end' : 'idle')
      onSearchFinished('success')
    }).catch(() => {
      listRef.current?.setStatus('error')
      onSearchFinished('error')
    })
  }
  const handleLoadMore: SonglistProps['onLoadMore'] = () => {
    listRef.current?.setStatus('loading')
    const info = searchSonglistState.listInfos[searchInfoRef.current.source]!
    const page = info.list.length ? info.page + 1 : 1
    search(searchInfoRef.current.text, page, searchInfoRef.current.source).then((list) => {
      // const result = setListInfo(listDetail, searchSonglistState.listDetailInfo.id, page)
      if (isUnmountedRef.current) return
      listRef.current?.setList(list, searchInfoRef.current.source == 'all')
      listRef.current?.setStatus(searchSonglistState.maxPages[searchSonglistState.source] == page ? 'end' : 'idle')
      onSearchFinished('success')
    }).catch(() => {
      listRef.current?.setStatus('error')
      onSearchFinished('error')
    })
  }

  return <Songlist
    ref={listRef}
    onRefresh={handleRefresh}
    onLoadMore={handleLoadMore}
  />
})

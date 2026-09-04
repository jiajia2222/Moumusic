import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react'
import OnlineList, { type OnlineListType, type OnlineListProps } from '@/components/OnlineList'
import { search } from '@/core/search/music'
import searchMusicState, { type SearchMode, type Source } from '@/store/search/music/state'
import type { SearchFinishedStatus } from './SearchStatusOverlay'

// export type MusicListProps = Pick<OnlineListProps,
// 'onLoadMore'
// | 'onPlayList'
// | 'onRefresh'
// >

export interface MusicListType {
  loadList: (text: string, source: Source, mode?: SearchMode) => void
}

interface MusicListProps {
  onSearchFinished: (status: SearchFinishedStatus) => void
}

export default forwardRef<MusicListType, MusicListProps>(({ onSearchFinished }, ref) => {
  const listRef = useRef<OnlineListType>(null)
  const searchInfoRef = useRef<{ text: string, source: Source, mode: SearchMode }>({ text: '', source: 'kw', mode: 'music' })
  const isUnmountedRef = useRef(false)
  useImperativeHandle(ref, () => ({
    async loadList(text, source, mode = 'music') {
      // const listDetailInfo = searchMusicState.listDetailInfo
      listRef.current?.setList([], false, source == 'all')
      if (searchMusicState.searchText == text && searchMusicState.searchMode == mode && searchMusicState.source == source && searchMusicState.listInfos[searchMusicState.source]!.list.length) {
        requestAnimationFrame(() => {
          listRef.current?.setList(searchMusicState.listInfos[searchMusicState.source]!.list, false, source == 'all')
          onSearchFinished('success')
        })
      } else {
        listRef.current?.setStatus('loading')
        const page = 1
        searchInfoRef.current.text = text
        searchInfoRef.current.source = source
        searchInfoRef.current.mode = mode
        return search(text, page, source, mode).then((list) => {
          // const result = setListInfo(listDetail, id, page)
          if (isUnmountedRef.current) return
          requestAnimationFrame(() => {
            listRef.current?.setList(list, false, source == 'all')
            listRef.current?.setStatus(searchMusicState.listInfos[searchMusicState.source]!.maxPage <= page ? 'end' : 'idle')
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


  const handleRefresh: OnlineListProps['onRefresh'] = () => {
    const page = 1
    listRef.current?.setStatus('refreshing')
    search(searchInfoRef.current.text, page, searchInfoRef.current.source, searchInfoRef.current.mode).then((list) => {
      // const result = setListInfo(listDetail, searchMusicState.listDetailInfo.id, page)
      if (isUnmountedRef.current) return
      listRef.current?.setList(list, false, searchInfoRef.current.source == 'all')
      listRef.current?.setStatus(searchMusicState.listInfos[searchInfoRef.current.source]!.maxPage <= page ? 'end' : 'idle')
      onSearchFinished('success')
    }).catch(() => {
      listRef.current?.setStatus('error')
      onSearchFinished('error')
    })
  }
  const handleLoadMore: OnlineListProps['onLoadMore'] = () => {
    listRef.current?.setStatus('loading')
    const info = searchMusicState.listInfos[searchInfoRef.current.source]!
    const page = info?.page ? info.page + 1 : 1
    search(searchInfoRef.current.text, page, searchInfoRef.current.source, searchInfoRef.current.mode).then((list) => {
      // const result = setListInfo(listDetail, searchMusicState.listDetailInfo.id, page)
      if (isUnmountedRef.current) return
      listRef.current?.setList(list, true, searchInfoRef.current.source == 'all')
      listRef.current?.setStatus(info.maxPage <= page ? 'end' : 'idle')
      onSearchFinished('success')
    }).catch(() => {
      listRef.current?.setStatus('error')
      onSearchFinished('error')
    })
  }

  return <OnlineList
    ref={listRef}
    onRefresh={handleRefresh}
    onLoadMore={handleLoadMore}
    checkHomePagerIdle
  />
})

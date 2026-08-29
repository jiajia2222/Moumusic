import { useCallback, useState } from 'react'
import { ScrollView, TouchableOpacity, View } from 'react-native'
import StatusBar from '@/components/common/StatusBar'
import Text from '@/components/common/Text'
import { Icon } from '@/components/common/Icon'
import { createStyle } from '@/utils/tools'
import { useTheme } from '@/store/theme/hook'
import { useStatusbarHeight } from '@/store/common/hook'
import { usePlayMusicInfo } from '@/store/player/hook'
import { setNavActiveId } from '@/core/common'
import Leaderboard from '../Views/Leaderboard'
import Mylist from '../Views/Mylist'
import PlayerBar from '@/components/player/PlayerBar'
import TabBar, { type KumoneTab } from './TabBar'
import Search from './Search'
import Settings from './Settings'

const navIds: Partial<Record<KumoneTab, Parameters<typeof setNavActiveId>[0]>> = {
  search: 'nav_search',
  explore: 'nav_top',
  library: 'nav_love',
  settings: 'nav_setting',
}

const HomeLanding = ({ onSearch }: { onSearch: () => void }) => {
  const theme = useTheme()
  return (
    <ScrollView contentContainerStyle={styles.landing}>
      <View style={{ ...styles.hero, backgroundColor: theme.isDark ? 'rgba(22,23,30,0.88)' : 'rgba(255,255,255,0.88)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
        <View style={{ ...styles.heroIcon, backgroundColor: theme['c-primary-background-active'] }}><Text size={34} color={theme['c-primary-font-active']} style={styles.heroMark}>M</Text></View>
        <Text size={27} style={styles.heroTitle}>你的音乐空间</Text>
        <Text size={14} color={theme['c-font-label']} style={styles.heroCopy}>Kumone 风格界面，LX 核心驱动。添加自己的音源，跨平台搜索并播放。</Text>
        <TouchableOpacity onPress={onSearch} style={{ ...styles.primaryAction, backgroundColor: theme['c-primary-background-active'] }}><Icon name="search-2" size={16} color={theme['c-primary-font-active']} /><Text size={14} color={theme['c-primary-font-active']} style={styles.actionText}>开始聚合搜索</Text></TouchableOpacity>
      </View>
      <View style={styles.featureRow}>
        <View style={{ ...styles.featureCard, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.8)' }}><Icon name="leaderboard" size={22} color={theme['c-primary']} /><Text size={15} style={styles.featureTitle}>平台聚合</Text><Text size={12} color={theme['c-font-label']}>一次搜索多个目录</Text></View>
        <View style={{ ...styles.featureCard, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.8)' }}><Icon name="lyric-on" size={22} color={theme['c-primary']} /><Text size={15} style={styles.featureTitle}>歌词与播放</Text><Text size={12} color={theme['c-font-label']}>使用你的 LX 音源</Text></View>
      </View>
    </ScrollView>
  )
}

export default () => {
  const theme = useTheme()
  const statusBarHeight = useStatusbarHeight()
  const [activeTab, setActiveTab] = useState<KumoneTab>('home')
  const playInfo = usePlayMusicInfo()

  const changeTab = useCallback((tab: KumoneTab) => {
    setActiveTab(tab)
    const navId = navIds[tab]
    if (navId) setNavActiveId(navId)
  }, [])

  const openSearch = () => { changeTab('search') }

  return (
    <View style={{ ...styles.container, backgroundColor: theme['c-main-background'] }}>
      <StatusBar />
      <View style={{ ...styles.header, paddingTop: statusBarHeight }}>
        <View style={styles.brandMark}><Text size={18} color={theme['c-primary-font-active']} style={styles.brandText}>M</Text></View>
        <View style={styles.brandCopy}><Text size={17} style={styles.brandTitle}>Moumusic</Text><Text size={11} color={theme['c-font-label']}>Kumone UI · LX Core</Text></View>
        <TouchableOpacity onPress={() => { changeTab('settings') }} style={styles.headerButton}><Icon name="setting" size={19} color={theme['c-font-label']} /></TouchableOpacity>
      </View>
      <View style={styles.body}>
        {activeTab == 'home' ? <HomeLanding onSearch={openSearch} /> : null}
        {activeTab == 'explore' ? <Leaderboard /> : null}
        {activeTab == 'search' ? <Search onOpenSettings={() => { changeTab('settings') }} /> : null}
        {activeTab == 'library' ? <Mylist /> : null}
        {activeTab == 'settings' ? <Settings /> : null}
      </View>
      {playInfo.musicInfo ? <PlayerBar isHome /> : null}
      <TabBar activeTab={activeTab} onChange={changeTab} />
    </View>
  )
}

const styles = createStyle({
  container: { flex: 1, overflow: 'hidden' },
  header: { minHeight: 58, paddingHorizontal: 14, paddingBottom: 8, flexDirection: 'row', alignItems: 'center' },
  brandMark: { width: 35, height: 35, borderRadius: 11, alignItems: 'center', justifyContent: 'center', backgroundColor: '#ef5350' },
  brandText: { fontWeight: '800' },
  brandCopy: { marginLeft: 10, flex: 1 },
  brandTitle: { fontWeight: '700', letterSpacing: 0.2 },
  headerButton: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center', borderRadius: 20 },
  body: { flex: 1, overflow: 'hidden' },
  landing: { padding: 14, paddingTop: 8 },
  hero: { minHeight: 300, padding: 25, borderRadius: 28, borderWidth: 1, alignItems: 'center', justifyContent: 'center' },
  heroIcon: { width: 72, height: 72, borderRadius: 22, alignItems: 'center', justifyContent: 'center', marginBottom: 18 },
  heroMark: { fontWeight: '800' },
  heroTitle: { fontWeight: '700', textAlign: 'center' },
  heroCopy: { maxWidth: 320, marginTop: 9, lineHeight: 21, textAlign: 'center' },
  primaryAction: { paddingHorizontal: 16, paddingVertical: 11, borderRadius: 13, marginTop: 21, flexDirection: 'row', alignItems: 'center' },
  actionText: { marginLeft: 7 },
  featureRow: { flexDirection: 'row', gap: 10, marginTop: 12 },
  featureCard: { flex: 1, minHeight: 115, borderRadius: 20, padding: 14 },
  featureTitle: { fontWeight: '600', marginTop: 10, marginBottom: 4 },
})

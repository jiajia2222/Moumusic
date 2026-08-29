import { useMemo, useRef } from 'react'
import { ScrollView, TouchableOpacity, View } from 'react-native'
import Text from '@/components/common/Text'
import { Icon } from '@/components/common/Icon'
import Button from '@/components/common/Button'
import UserApiEditModal, { type UserApiEditModalType } from '@/screens/Home/Views/Setting/settings/Basic/UserApiEditModal'
import { useTheme } from '@/store/theme/hook'
import { useI18n } from '@/lang'
import { createStyle } from '@/utils/tools'
import { useSettingValue } from '@/store/setting/hook'
import { useStatus, useUserApiList } from '@/store/userApi'
import { setApiSource } from '@/core/apiSource'
import searchMusicState from '@/store/search/music/state'
import { useSourceListI18n } from '@/components/SourceSelector'

const formatVersion = (version: string) => /^\d/.test(version) ? `v${version}` : version

export default () => {
  const theme = useTheme()
  const t = useI18n()
  const activeSource = useSettingValue('common.apiSource')
  const status = useStatus()
  const userApis = useUserApiList()
  const modalRef = useRef<UserApiEditModalType>(null)
  const platformIds = useMemo(() => searchMusicState.sources.filter((id): id is LX.OnlineSource => id != 'all'), [])
  const platformLabels = useSourceListI18n(platformIds)

  return (
    <View style={styles.container}>
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.content} keyboardShouldPersistTaps="always">
        <View style={styles.titleRow}>
          <View style={{ ...styles.titleIcon, backgroundColor: theme['c-primary-background-active'] }}><Icon name="setting" size={21} color={theme['c-primary-font-active']} /></View>
          <View><Text size={22} style={styles.title}>设置</Text><Text size={12} color={theme['c-font-label']}>Kumone 界面 · LX 核心</Text></View>
        </View>

        <View style={{ ...styles.card, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.86)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
          <Text size={18} style={styles.cardTitle}>播放音源</Text>
          <Text size={13} color={theme['c-font-label']} style={styles.description}>音源不会内置在 Moumusic 中。请导入你自己的 LX User API，它负责歌曲地址、歌词、封面和可用音质。</Text>
          {userApis.length
            ? userApis.map(api => {
              const active = activeSource == api.id
              return <TouchableOpacity key={api.id} onPress={() => { setApiSource(api.id) }} style={{ ...styles.apiRow, backgroundColor: active ? theme['c-primary-background-active'] : 'transparent' }}><View style={styles.apiInfo}><Text size={15}>{api.name}</Text><Text size={12} color={theme['c-font-label']}>{[api.version ? formatVersion(api.version) : '', api.author].filter(Boolean).join(' · ') || 'LX User API'}</Text>{api.description ? <Text size={12} color={theme['c-font-label']}>{api.description}</Text> : null}</View><View style={{ ...styles.statusDot, backgroundColor: active && status.status ? theme['c-primary'] : active ? theme['c-font-label'] : theme['c-border-background'] }} /></TouchableOpacity>
            })
            : <Text size={14} color={theme['c-font-label']} style={styles.emptyApi}>{t('user_api_empty')}</Text>}
          <Button onPress={() => { modalRef.current?.show() }} style={styles.addButton}><Text size={14} color={theme['c-button-font']}>添加 / 管理 LX 音源</Text></Button>
        </View>

        <View style={{ ...styles.card, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.86)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
          <Text size={18} style={styles.cardTitle}>搜索平台</Text>
          <Text size={13} color={theme['c-font-label']} style={styles.description}>搜索页可以选择单个平台，也可以选择“全部”进行聚合搜索。平台只负责目录结果，播放仍由上面的 LX 音源提供。</Text>
          <View style={styles.platforms}>{platformLabels.map(platform => <View key={platform.action} style={{ ...styles.platformChip, borderColor: theme['c-border-background'] }}><View style={{ ...styles.platformDot, backgroundColor: theme['c-primary'] }} /><Text size={13}>{platform.label}</Text></View>)}</View>
        </View>

        <View style={{ ...styles.card, backgroundColor: theme.isDark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.86)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
          <Text size={18} style={styles.cardTitle}>说明</Text>
          <Text size={13} color={theme['c-font-label']} style={styles.description}>Moumusic 使用 LX 的搜索、播放队列、歌词和缓存能力，界面按 Kumone 的卡片、沉浸播放和液态玻璃导航思路重做。</Text>
        </View>
      </ScrollView>
      <UserApiEditModal ref={modalRef} />
    </View>
  )
}

const styles = createStyle({
  container: { flex: 1 },
  content: { paddingHorizontal: 14, paddingTop: 18, paddingBottom: 18 },
  titleRow: { flexDirection: 'row', alignItems: 'center', marginBottom: 14 },
  titleIcon: { width: 46, height: 46, borderRadius: 15, alignItems: 'center', justifyContent: 'center', marginRight: 11 },
  title: { fontWeight: '700' },
  card: { padding: 16, marginBottom: 12, borderRadius: 22, borderWidth: 1 },
  cardTitle: { fontWeight: '700', marginBottom: 5 },
  description: { lineHeight: 20, marginBottom: 10 },
  apiRow: { minHeight: 58, borderRadius: 14, paddingHorizontal: 11, paddingVertical: 8, flexDirection: 'row', alignItems: 'center' },
  apiInfo: { flex: 1, gap: 2 },
  statusDot: { width: 9, height: 9, borderRadius: 5, marginLeft: 8 },
  emptyApi: { paddingVertical: 12 },
  addButton: { alignSelf: 'flex-start', paddingHorizontal: 14, paddingVertical: 10, marginTop: 10, borderRadius: 12 },
  platforms: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  platformChip: { borderWidth: 1, borderRadius: 99, paddingHorizontal: 10, paddingVertical: 7, flexDirection: 'row', alignItems: 'center' },
  platformDot: { width: 6, height: 6, borderRadius: 3, marginRight: 6 },
})

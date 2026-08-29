import { TouchableOpacity, View } from 'react-native'
import { createStyle } from '@/utils/tools'
import { Icon } from '@/components/common/Icon'
import Text from '@/components/common/Text'
import { useTheme } from '@/store/theme/hook'

export type KumoneTab = 'home' | 'explore' | 'search' | 'library' | 'settings'

interface TabItem {
  id: KumoneTab
  title: string
  icon: string
}

const tabs: readonly TabItem[] = [
  { id: 'home', title: '推荐', icon: 'home' },
  { id: 'explore', title: '发现', icon: 'leaderboard' },
  { id: 'search', title: '搜索', icon: 'search-2' },
  { id: 'library', title: '我的', icon: 'love' },
  { id: 'settings', title: '设置', icon: 'setting' },
]

interface Props {
  activeTab: KumoneTab
  onChange: (tab: KumoneTab) => void
}

export default ({ activeTab, onChange }: Props) => {
  const theme = useTheme()

  return (
    <View style={{ ...styles.bar, backgroundColor: theme.isDark ? 'rgba(22, 23, 30, 0.88)' : 'rgba(255, 255, 255, 0.88)', borderColor: theme.isDark ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.95)' }}>
      {tabs.map(tab => {
        const active = activeTab == tab.id
        return (
          <TouchableOpacity
            accessibilityRole="tab"
            accessibilityState={{ selected: active }}
            key={tab.id}
            onPress={() => { onChange(tab.id) }}
            style={{ ...styles.item, backgroundColor: active ? (theme.isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.07)') : 'transparent' }}
          >
            <Icon name={tab.icon} size={20} color={active ? theme['c-primary-font-active'] : theme['c-font-label']} />
            <Text size={10} color={active ? theme['c-primary-font-active'] : theme['c-font-label']} style={styles.label}>{tab.title}</Text>
          </TouchableOpacity>
        )
      })}
    </View>
  )
}

const styles = createStyle({
  bar: {
    minHeight: 58,
    marginHorizontal: 12,
    marginBottom: 8,
    padding: 4,
    borderRadius: 24,
    borderWidth: 1,
    flexDirection: 'row',
    elevation: 8,
    shadowColor: '#000',
    shadowOpacity: 0.12,
    shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 },
  },
  item: {
    flex: 1,
    minHeight: 50,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
  },
  label: {
    marginTop: 2,
    fontWeight: '600',
  },
})

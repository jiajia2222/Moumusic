import { View } from 'react-native'
import Text from '@/components/common/Text'
import { createStyle } from '@/utils/tools'
import { useTheme } from '@/store/theme/hook'
import { MUSIC_PLATFORMS } from '@/config/platforms'
import { useUserApiList } from '@/store/userApi'
import MoumusicBrand from './MoumusicBrand'

export default () => {
  const theme = useTheme()
  const sources = useUserApiList()

  return (
    <View style={{ ...styles.hero, backgroundColor: theme['c-content-background'] }}>
      <MoumusicBrand />
      <Text style={styles.headline} size={22}>把平台和音源交给你选择</Text>
      <Text style={styles.description} color={theme['c-font-label']} size={14}>
        搜索平台负责找到歌曲，用户音源负责返回播放地址、歌词和音质。两者可以独立切换。
      </Text>
      <View style={styles.stats}>
        <View style={styles.stat}>
          <Text size={20} style={styles.statValue}>{MUSIC_PLATFORMS.length}</Text>
          <Text color={theme['c-font-label']} size={12}>搜索平台</Text>
        </View>
        <View style={styles.stat}>
          <Text size={20} style={styles.statValue}>{sources.length}</Text>
          <Text color={theme['c-font-label']} size={12}>已导入音源</Text>
        </View>
      </View>
      <View style={styles.platforms}>
        {MUSIC_PLATFORMS.map(platform => (
          <View key={platform.id} style={{ ...styles.chip, borderColor: platform.color }}>
            <View style={{ ...styles.dot, backgroundColor: platform.color }} />
            <Text size={12}>{platform.name}</Text>
          </View>
        ))}
      </View>
    </View>
  )
}

const styles = createStyle({
  hero: {
    margin: 15,
    padding: 20,
    borderRadius: 22,
    borderWidth: 1,
    borderColor: 'rgba(127, 127, 127, 0.16)',
  },
  headline: {
    marginTop: 24,
    fontWeight: '700',
  },
  description: {
    lineHeight: 22,
    marginTop: 8,
  },
  stats: {
    flexDirection: 'row',
    marginTop: 18,
  },
  stat: {
    marginRight: 32,
  },
  statValue: {
    fontWeight: '700',
  },
  platforms: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    marginTop: 16,
  },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderRadius: 99,
    paddingHorizontal: 9,
    paddingVertical: 6,
    marginRight: 7,
    marginBottom: 7,
  },
  dot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    marginRight: 5,
  },
})

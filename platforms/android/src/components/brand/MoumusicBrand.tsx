import { View } from 'react-native'
import Text from '@/components/common/Text'
import { createStyle } from '@/utils/tools'
import { useTheme } from '@/store/theme/hook'

export default ({ compact = false }: { compact?: boolean }) => {
  const theme = useTheme()

  return (
    <View style={styles.row}>
      <View style={{ ...styles.mark, width: compact ? 30 : 38, height: compact ? 30 : 38, borderRadius: compact ? 10 : 13, backgroundColor: theme['c-primary-background-active'] }}>
        <Text size={compact ? 18 : 23} color={theme['c-primary-font-active']} style={styles.markText}>M</Text>
      </View>
      <View style={styles.copy}>
        <Text size={compact ? 17 : 24} style={styles.title}>Moumusic</Text>
        {compact ? null : <Text size={12} color={theme['c-font-label']}>你的音乐空间</Text>}
      </View>
    </View>
  )
}

const styles = createStyle({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  mark: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  markText: {
    fontWeight: '800',
  },
  copy: {
    marginLeft: 12,
  },
  title: {
    fontWeight: '700',
    letterSpacing: 0.2,
  },
})

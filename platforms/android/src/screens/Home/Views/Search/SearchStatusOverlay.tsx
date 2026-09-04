import { TouchableOpacity, View } from 'react-native'

import Loading from '@/components/common/Loading'
import Text from '@/components/common/Text'
import { useI18n } from '@/lang'
import { useTheme } from '@/store/theme/hook'
import { createStyle } from '@/utils/tools'

export type SearchStatus = 'loading' | 'error'
export type SearchFinishedStatus = 'success' | 'error'

interface SearchStatusOverlayProps {
  status: SearchStatus
  query: string
  onRetry: () => void
}

export default ({ status, query, onRetry }: SearchStatusOverlayProps) => {
  const theme = useTheme()
  const t = useI18n()
  const isLoading = status == 'loading'

  return (
    <View style={styles.overlay} pointerEvents={isLoading ? 'none' : 'box-none'}>
      <View style={{ ...styles.card, backgroundColor: theme['c-content-background'], borderColor: theme['c-border-background'] }}>
        <View style={{ ...styles.icon, backgroundColor: theme['c-primary-background-active'] }}>
          {isLoading
            ? <Loading size={22} />
            : <Text color={theme['c-primary-font-active']} size={22}>!</Text>
          }
        </View>
        <Text style={styles.title} size={15}>{isLoading ? t('search_status_searching') : t('search_status_failed')}</Text>
        <Text style={styles.query} color={theme['c-font-label']} size={12} numberOfLines={1}>{query}</Text>
        {!isLoading
          ? <TouchableOpacity style={{ ...styles.retryButton, backgroundColor: theme['c-primary-background-active'] }} onPress={onRetry}>
              <Text color={theme['c-primary-font-active']} size={13}>{t('search_status_retry')}</Text>
            </TouchableOpacity>
          : null
        }
      </View>
    </View>
  )
}

const styles = createStyle({
  overlay: {
    position: 'absolute',
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    zIndex: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  card: {
    minWidth: 180,
    maxWidth: '82%',
    paddingTop: 18,
    paddingBottom: 18,
    paddingLeft: 22,
    paddingRight: 22,
    borderRadius: 22,
    borderWidth: 1,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.16,
    shadowRadius: 14,
    elevation: 8,
  },
  icon: {
    width: 42,
    height: 42,
    borderRadius: 21,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 10,
  },
  title: {
    textAlign: 'center',
  },
  query: {
    maxWidth: 220,
    marginTop: 5,
    textAlign: 'center',
  },
  retryButton: {
    minWidth: 96,
    marginTop: 13,
    paddingTop: 8,
    paddingBottom: 8,
    paddingLeft: 16,
    paddingRight: 16,
    borderRadius: 18,
    alignItems: 'center',
  },
})

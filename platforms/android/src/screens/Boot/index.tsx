import { ActivityIndicator, StatusBar, StyleSheet, Text, View } from 'react-native'

export default () => (
  <View style={styles.container}>
    <StatusBar barStyle="dark-content" backgroundColor="#f5f7fb" />
    <View style={styles.glow} />
    <View style={styles.card}>
      <View style={styles.logo}><Text style={styles.logoText}>M</Text></View>
      <Text style={styles.title}>Moumusic</Text>
      <Text style={styles.subtitle}>LX 功能 · Kumone 风格</Text>
      <ActivityIndicator color="#ef5350" size="small" style={styles.spinner} />
      <Text style={styles.status}>正在启动音源与播放器…</Text>
    </View>
  </View>
)

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    backgroundColor: '#f5f7fb',
    flex: 1,
    justifyContent: 'center',
    overflow: 'hidden',
  },
  glow: {
    backgroundColor: '#ffd8d6',
    borderRadius: 240,
    height: 480,
    opacity: 0.5,
    position: 'absolute',
    right: -170,
    top: -150,
    width: 480,
  },
  card: {
    alignItems: 'center',
    backgroundColor: 'rgba(255, 255, 255, 0.86)',
    borderColor: 'rgba(255, 255, 255, 0.95)',
    borderRadius: 28,
    borderWidth: StyleSheet.hairlineWidth,
    elevation: 8,
    minWidth: 240,
    paddingHorizontal: 32,
    paddingVertical: 30,
    shadowColor: '#9aa4b2',
    shadowOffset: { height: 12, width: 0 },
    shadowOpacity: 0.16,
    shadowRadius: 24,
  },
  logo: {
    alignItems: 'center',
    backgroundColor: '#ef5350',
    borderRadius: 18,
    height: 64,
    justifyContent: 'center',
    shadowColor: '#ef5350',
    shadowOffset: { height: 8, width: 0 },
    shadowOpacity: 0.25,
    shadowRadius: 12,
    width: 64,
  },
  logoText: {
    color: '#fff',
    fontSize: 34,
    fontWeight: '800',
  },
  title: {
    color: '#20242b',
    fontSize: 24,
    fontWeight: '700',
    marginTop: 16,
  },
  subtitle: {
    color: '#68707d',
    fontSize: 14,
    marginTop: 6,
  },
  spinner: {
    marginTop: 26,
  },
  status: {
    color: '#68707d',
    fontSize: 13,
    marginTop: 10,
  },
})

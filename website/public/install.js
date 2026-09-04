const configElement = document.getElementById('site-config')
let config = {}
try {
  config = JSON.parse(configElement?.textContent || '{}')
} catch {
  config = {}
}

const links = {
  'ios-download': config.iosDownloadUrl,
  'android-download': config.androidDownloadUrl,
  'install-support': config.afdianUrl || 'https://www.ifdian.net/a/moumou2026',
  'install-support-hero': config.afdianUrl || 'https://www.ifdian.net/a/moumou2026',
}

for (const [id, href] of Object.entries(links)) {
  const link = document.getElementById(id)
  if (link && href) link.href = href
}

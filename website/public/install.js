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
  'install-support': config.afdianUrl,
}

for (const [id, href] of Object.entries(links)) {
  const link = document.getElementById(id)
  if (link && href) link.href = href
}

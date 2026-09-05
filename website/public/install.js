const configElement = document.getElementById('site-config')
let config = {}
try {
  config = JSON.parse(configElement?.textContent || '{}')
} catch {
  config = {}
}

const i18n = window.MoumusicI18n || { language: () => 'zh', t: key => key }
const links = {
  'ios-download': config.iosDownloadUrl,
  'android-download': config.androidDownloadUrl,
  'install-support': config.afdianPlanUrl || config.afdianUrl || 'https://ifdian.net/a/moumou2026/plan',
  'install-support-hero': config.afdianPlanUrl || config.afdianUrl || 'https://ifdian.net/a/moumou2026/plan',
}

for (const [id, href] of Object.entries(links)) {
  const link = document.getElementById(id)
  if (link && href) link.href = href
}

function setReleaseVersion(id, version) {
  const element = document.getElementById(id)
  if (!element) return
  element.classList.remove('skeleton')
  element.textContent = version
    ? i18n.t('install.latestVersion', { version })
    : i18n.t('install.versionUnavailable')
}

function renderReleaseVersions(release) {
  const version = release?.version && release.version !== 'latest' ? release.version : ''
  setReleaseVersion('latest-release-version', version)
  setReleaseVersion('ios-release-version', release?.ios?.version && release.ios.version !== 'latest' ? release.ios.version : version)
  setReleaseVersion('android-release-version', release?.android?.version && release.android.version !== 'latest' ? release.android.version : version)
}

async function loadLatestRelease() {
  try {
    const response = await fetch(`/api/releases/latest?ts=${Date.now()}`, { cache: 'no-store' })
    if (!response.ok) throw new Error(`Release lookup failed: ${response.status}`)
    const payload = await response.json()
    if (!payload.success || !payload.release) throw new Error('Release metadata unavailable')
    window.latestMoumusicRelease = payload.release
    renderReleaseVersions(payload.release)
  } catch {
    window.latestMoumusicRelease = null
    renderReleaseVersions(null)
  }
}

window.latestMoumusicRelease = null
document.addEventListener('moumusic:languagechange', () => renderReleaseVersions(window.latestMoumusicRelease))
loadLatestRelease()

const configElement = document.getElementById('site-config')
let siteConfig = {}
try {
  siteConfig = JSON.parse(configElement?.textContent || '{}')
} catch {
  siteConfig = {}
}

const $ = id => document.getElementById(id)
const i18n = window.MoumusicI18n || { language: () => 'zh', t: key => key }
const supportLink = siteConfig.afdianPlanUrl || siteConfig.afdianUrl || 'https://ifdian.net/a/moumou2026/plan'
const showAmount = Boolean(siteConfig.showAmount)

let supporters = []
let stats = {}
let query = ''

function locale() {
  return i18n.language() === 'en' ? 'en-US' : 'zh-CN'
}

function formatDate(timestamp) {
  if (!timestamp) return ''
  return new Intl.DateTimeFormat(locale(), { year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(timestamp * 1000))
}

function formatMoney(amount) {
  return `¥${Number(amount).toFixed(2).replace(/\.00$/, '')}`
}

function avatarFor(sponsor) {
  const avatar = document.createElement('span')
  avatar.className = 'avatar'
  avatar.setAttribute('aria-hidden', 'true')
  avatar.textContent = (String(sponsor.name || 'M').trim().slice(0, 1) || 'M').toUpperCase()
  if (sponsor.avatar) {
    const image = document.createElement('img')
    image.src = sponsor.avatar
    image.alt = ''
    image.loading = 'lazy'
    image.decoding = 'async'
    image.referrerPolicy = 'no-referrer'
    image.addEventListener('error', () => image.remove(), { once: true })
    avatar.append(image)
  }
  return avatar
}

async function fetchJson(path) {
  const response = await fetch(path, { headers: { accept: 'application/json' }, cache: 'no-store' })
  const data = await response.json().catch(() => null)
  if (!response.ok || !data?.success) throw new Error('unavailable')
  return data
}

function sortedSupporters() {
  return [...supporters].sort((a, b) => (b.lastSupportTime || 0) - (a.lastSupportTime || 0))
}

/* ---- Home: recent supporters ---- */
function renderRecent() {
  const list = $('recent-list')
  if (!list) return
  list.replaceChildren()
  const recent = sortedSupporters().slice(0, 5)
  $('recent-empty').hidden = recent.length > 0
  for (const sponsor of recent) {
    const item = document.createElement('li')
    const name = document.createElement('span')
    name.className = 'name'
    name.textContent = sponsor.name
    const when = document.createElement('time')
    when.textContent = formatDate(sponsor.lastSupportTime)
    item.append(avatarFor(sponsor), name, when)
    list.append(item)
  }
}

/* ---- Credits page: every supporter, grouped by year ---- */
function yearOf(sponsor) {
  return sponsor.lastSupportTime ? new Date(sponsor.lastSupportTime * 1000).getFullYear() : 0
}

function setState(text, retry = false) {
  const box = $('state-box')
  box.hidden = !text
  $('state-text').textContent = text || ''
  $('retry-button').hidden = !retry
}

function renderCredits() {
  const container = $('credits')
  if (!container) return
  container.replaceChildren()
  const needle = query.trim().toLowerCase()
  const matches = sortedSupporters().filter(item => !needle || String(item.name).toLowerCase().includes(needle))

  if (!supporters.length) {
    setState(i18n.t('c.empty'))
    return
  }
  if (!matches.length) {
    setState(i18n.t('c.noMatch', { q: query.trim() }))
    return
  }
  setState('')

  const groups = new Map()
  for (const sponsor of matches) {
    const year = yearOf(sponsor)
    if (!groups.has(year)) groups.set(year, [])
    groups.get(year).push(sponsor)
  }
  for (const [year, items] of groups) {
    const section = document.createElement('section')
    section.className = 'year'
    const heading = document.createElement('h2')
    heading.textContent = year ? i18n.t('c.year', { year }) : '—'
    const list = document.createElement('ul')
    for (const sponsor of items) {
      const row = document.createElement('li')
      const who = document.createElement('div')
      who.className = 'who'
      const name = document.createElement('strong')
      name.textContent = sponsor.name
      const plan = document.createElement('span')
      plan.textContent = sponsor.plan || ''
      who.append(name, plan)
      const when = document.createElement('div')
      when.className = 'when'
      if (showAmount && sponsor.amount !== undefined) {
        const amount = document.createElement('b')
        amount.textContent = formatMoney(sponsor.amount)
        when.append(amount)
      }
      when.append(formatDate(sponsor.lastSupportTime))
      row.append(avatarFor(sponsor), who, when)
      list.append(row)
    }
    section.append(heading, list)
    container.append(section)
  }
}

function renderStats() {
  if (!$('stat-count')) return
  $('stat-count').textContent = i18n.t('c.count', { count: stats.supporterCount ?? supporters.length })
  $('stat-latest').textContent = stats.recentSupportAt ? i18n.t('c.latest', { date: formatDate(stats.recentSupportAt) }) : ''
  $('stat-total').textContent = showAmount && stats.totalAmount !== undefined ? i18n.t('c.total', { amount: formatMoney(stats.totalAmount) }) : ''
}

async function loadSponsors() {
  try {
    const [sponsorData, statsData] = await Promise.all([
      fetchJson('/api/aifadian/sponsors'),
      fetchJson('/api/aifadian/stats'),
    ])
    supporters = Array.isArray(sponsorData.supporters) ? sponsorData.supporters : []
    stats = statsData.stats || {}
    renderRecent()
    renderCredits()
    renderStats()
  } catch {
    if ($('credits')) {
      $('credits').replaceChildren()
      setState(i18n.t('c.error'), true)
    }
    if ($('recent-empty')) {
      $('recent-empty').hidden = false
    }
  }
}

/* ---- Release version for the hero ---- */
async function loadVersion() {
  const element = $('hero-version')
  if (!element) return
  try {
    const data = await fetchJson(`/api/releases/latest?ts=${Date.now()}`)
    const version = data.release?.version
    element.textContent = version && version !== 'latest'
      ? i18n.t('h.version', { version })
      : i18n.t('h.versionUnavailable')
  } catch {
    element.textContent = i18n.t('h.versionUnavailable')
  }
}

/* ---- Wire up ---- */
for (const id of ['support-link', 'footer-support-link']) {
  const link = $(id)
  if (link) link.href = supportLink
}
for (const [id, href] of [['ios-download', siteConfig.iosDownloadUrl], ['ios15-download', siteConfig.ios15DownloadUrl]]) {
  const link = $(id)
  if (link && href) link.href = href
}
$('search')?.addEventListener('input', event => {
  query = event.target.value
  renderCredits()
})
$('retry-button')?.addEventListener('click', () => {
  setState('')
  loadSponsors()
})
document.addEventListener('moumusic:languagechange', () => {
  renderRecent()
  renderCredits()
  renderStats()
  loadVersion()
})
loadSponsors()
loadVersion()

const configElement = document.getElementById('site-config')
let siteConfig = {}
try {
  siteConfig = JSON.parse(configElement?.textContent || '{}')
} catch {
  siteConfig = {}
}

const $ = id => document.getElementById(id)
const supportLink = siteConfig.afdianUrl || '#support'
const showAmount = Boolean(siteConfig.showAmount)
let supporters = []

function fallbackInitial(name) {
  return String(name || 'M').trim().slice(0, 1).toUpperCase() || 'M'
}

function makeAvatar(name, source, className = 'avatar--small') {
  const avatar = document.createElement('span')
  avatar.className = `avatar ${className}`
  avatar.setAttribute('aria-hidden', 'true')
  const fallback = document.createElement('span')
  fallback.className = 'avatar-fallback'
  fallback.textContent = fallbackInitial(name)
  avatar.append(fallback)
  if (source) {
    const image = document.createElement('img')
    image.className = 'avatar-image'
    image.src = source
    image.alt = ''
    image.loading = 'lazy'
    image.decoding = 'async'
    image.addEventListener('error', () => image.remove(), { once: true })
    avatar.prepend(image)
  }
  return avatar
}

function setProfileAvatar(element, name, source) {
  element.replaceChildren(makeAvatar(name, source, 'avatar--hero').firstElementChild)
  if (!source) return
  const image = document.createElement('img')
  image.className = 'avatar-image'
  image.src = source
  image.alt = `${name} 的头像`
  image.loading = 'eager'
  image.decoding = 'async'
  image.addEventListener('error', () => image.remove(), { once: true })
  element.prepend(image)
}

function formatDate(timestamp) {
  if (!timestamp) return '暂无记录'
  return new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(timestamp * 1000))
}

function formatRelative(timestamp) {
  if (!timestamp) return '暂无记录'
  const seconds = Math.max(0, Math.floor(Date.now() / 1000) - timestamp)
  if (seconds < 60) return '刚刚'
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`
  if (seconds < 604800) return `${Math.floor(seconds / 86400)} 天前`
  return formatDate(timestamp)
}

function formatMoney(amount) {
  return `¥${Number(amount).toFixed(2).replace(/\.00$/, '')}`
}

function setText(id, value) {
  const element = $(id)
  if (!element) return
  element.classList.remove('skeleton')
  element.textContent = value
}

function renderProfile() {
  const name = siteConfig.name || 'MouMou'
  setText('site-name', name)
  setText('site-tagline', siteConfig.tagline || '感谢你的支持，每一份心意都会变成继续维护和创造的动力。')
  setText('site-thanks', siteConfig.thanks || '感谢每一位支持者，让 Moumusic 可以持续更新。')
  setProfileAvatar($('profile-avatar'), name, siteConfig.avatar)
  for (const id of ['support-link', 'footer-support-link']) {
    const link = $(id)
    if (link) link.href = supportLink
  }
}

function createSponsorCard(sponsor) {
  const card = document.createElement('button')
  card.type = 'button'
  card.className = 'sponsor-card'
  card.addEventListener('click', () => openSponsor(sponsor))

  const top = document.createElement('div')
  top.className = 'sponsor-card__top'
  top.append(makeAvatar(sponsor.name, sponsor.avatar))
  const identity = document.createElement('div')
  identity.innerHTML = `<p class="sponsor-card__name"></p><p class="sponsor-card__plan"></p>`
  identity.querySelector('.sponsor-card__name').textContent = sponsor.name
  identity.querySelector('.sponsor-card__plan').textContent = sponsor.plan
  top.append(identity)

  const meta = document.createElement('div')
  meta.className = 'sponsor-card__meta'
  const date = document.createElement('span')
  date.textContent = `支持于 ${formatDate(sponsor.lastSupportTime)}`
  meta.append(date)
  if (showAmount && sponsor.amount !== undefined) {
    const amount = document.createElement('span')
    amount.className = 'sponsor-card__amount'
    amount.textContent = formatMoney(sponsor.amount)
    meta.append(amount)
  }
  card.append(top, meta)
  return card
}

function renderSponsorList() {
  const all = $('sponsor-list')
  const recent = $('recent-list')
  all.replaceChildren()
  recent.replaceChildren()
  if (!supporters.length) {
    $('empty-state').hidden = false
    return
  }
  $('empty-state').hidden = true
  supporters.forEach(sponsor => all.append(createSponsorCard(sponsor)))
  supporters.slice(0, 6).forEach(sponsor => recent.append(createSponsorCard(sponsor)))
}

function renderStats(stats) {
  setText('supporter-count', String(stats.supporterCount ?? supporters.length))
  setText('recent-support', formatRelative(stats.recentSupportAt))
  if (showAmount && stats.totalAmount !== undefined) setText('total-support', formatMoney(stats.totalAmount))
  else setText('total-support', '持续支持中')
}

function openSponsor(sponsor) {
  const dialog = $('sponsor-dialog')
  const avatar = $('dialog-avatar')
  avatar.replaceChildren(makeAvatar(sponsor.name, sponsor.avatar, '').firstElementChild)
  if (sponsor.avatar) {
    const image = document.createElement('img')
    image.className = 'avatar-image'
    image.src = sponsor.avatar
    image.alt = `${sponsor.name} 的头像`
    image.loading = 'lazy'
    image.addEventListener('error', () => image.remove(), { once: true })
    avatar.prepend(image)
  }
  $('dialog-name').textContent = sponsor.name
  $('dialog-plan').textContent = sponsor.plan
  $('dialog-time').textContent = formatDate(sponsor.lastSupportTime)
  const amountRow = $('dialog-amount-row')
  amountRow.hidden = !(showAmount && sponsor.amount !== undefined)
  if (!amountRow.hidden) $('dialog-amount').textContent = formatMoney(sponsor.amount)
  if (typeof dialog.showModal === 'function') dialog.showModal()
  else dialog.setAttribute('open', '')
}

function closeSponsor() {
  const dialog = $('sponsor-dialog')
  if (dialog.open && typeof dialog.close === 'function') dialog.close()
  else dialog.removeAttribute('open')
}

function showError() {
  $('error-card').hidden = false
  $('sponsor-list').hidden = true
  $('recent-list').hidden = true
  $('empty-state').hidden = true
  setText('supporter-count', '—')
  setText('recent-support', '暂不可用')
  setText('total-support', '持续支持中')
}

function clearError() {
  $('error-card').hidden = true
  $('sponsor-list').hidden = false
  $('recent-list').hidden = false
}

async function fetchJson(path) {
  const response = await fetch(path, { headers: { accept: 'application/json' }, cache: 'no-store' })
  const data = await response.json().catch(() => null)
  if (!response.ok || !data?.success) throw new Error('sponsor-data-unavailable')
  return data
}

async function loadSponsors() {
  const refresh = $('refresh-button')
  refresh.classList.add('is-loading')
  clearError()
  try {
    const [sponsorData, statsData] = await Promise.all([
      fetchJson('/api/aifadian/sponsors'),
      fetchJson('/api/aifadian/stats'),
    ])
    supporters = Array.isArray(sponsorData.supporters) ? sponsorData.supporters : []
    renderSponsorList()
    renderStats(statsData.stats || {})
  } catch {
    showError()
  } finally {
    refresh.classList.remove('is-loading')
  }
}

renderProfile()
$('refresh-button').addEventListener('click', loadSponsors)
$('retry-button').addEventListener('click', loadSponsors)
$('dialog-close').addEventListener('click', closeSponsor)
$('sponsor-dialog').addEventListener('click', event => {
  if (event.target === $('sponsor-dialog')) closeSponsor()
})
document.querySelectorAll('[data-reveal]').forEach((element, index) => {
  window.setTimeout(() => element.classList.add('is-visible'), 70 + index * 55)
})
loadSponsors()

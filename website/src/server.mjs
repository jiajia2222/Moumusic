import { createHash, createHmac, randomUUID } from 'node:crypto'
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { dirname, extname, join, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const websiteRoot = resolve(__dirname, '..')
const publicRoot = join(websiteRoot, 'public')
const port = Number.parseInt(process.env.PORT || '8787', 10) || 8787
const cacheTtlMs = 10 * 60 * 1000
const afdianApiBases = [
  'https://afdian.com/api/open',
  'https://ifdian.net/api/open',
  'https://afdian.net/api/open',
]
const githubReleasesUrl = 'https://api.github.com/repos/jiajia2222/Moumusic/releases?per_page=20'
const githubReleasesPage = 'https://github.com/jiajia2222/Moumusic/releases'
const githubReleaseDownloadBase = 'https://github.com/jiajia2222/Moumusic/releases/latest/download'
const releaseAssetNames = {
  ios: ['Moumusic-unsigned.ipa'],
  android: ['Moumusic-android-unsigned.apk', 'moumusic-mobile-v1.0.2-universal.apk'],
}
const defaultAfdianUrl = 'https://www.ifdian.net/a/moumou2026'
const cache = new Map()
const latestReleaseCache = new Map()
const rateBuckets = new Map()

export class AfdianError extends Error {
  constructor(code, message, status = 502) {
    super(message)
    this.name = 'AfdianError'
    this.code = code
    this.status = status
  }
}

export function makeAfdianSignature({ token, userId, timestamp, params }) {
  const paramsString = typeof params === 'string' ? params : JSON.stringify(params)
  const canonical = `params${paramsString}ts${timestamp}user_id${userId}`
  return createHash('md5').update(`${token}${canonical}`).digest('hex')
}

function envBoolean(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value || '').trim().toLowerCase())
}

function getConfig() {
  return {
    userId: String(process.env.AFDIAN_USER_ID || '').trim(),
    token: String(process.env.AFDIAN_TOKEN || '').trim(),
    showAmount: envBoolean(process.env.SHOW_SPONSOR_AMOUNT),
  }
}

function getPublicConfig(baseUrl = `http://localhost:${port}`) {
  const siteOrigin = new URL(baseUrl).origin
  return {
    name: process.env.SITE_NAME || 'MouMou',
    avatar: safeHttpUrl(process.env.SITE_AVATAR) || '',
    tagline: process.env.SITE_TAGLINE || '感谢你的支持，每一份心意都会变成继续维护和创造的动力。',
    taglineEn: process.env.SITE_TAGLINE_EN || 'Download the app, add a source you are allowed to use, and start playing.',
    thanks: process.env.SITE_THANKS || '感谢每一位支持者，让 Moumusic 可以持续更新。',
    thanksEn: process.env.SITE_THANKS_EN || 'Thank you to every supporter for helping Moumusic keep moving.',
    afdianUrl: safeHttpUrl(process.env.AFDIAN_URL) || defaultAfdianUrl,
    showAmount: envBoolean(process.env.SHOW_SPONSOR_AMOUNT),
    iosDownloadUrl: safeHttpUrl(process.env.IOS_DOWNLOAD_URL) || `${siteOrigin}/download/ios`,
    androidDownloadUrl: safeHttpUrl(process.env.ANDROID_DOWNLOAD_URL) || `${siteOrigin}/download/android`,
  }
}

async function getDirectReleaseAsset(platform) {
  for (const name of releaseAssetNames[platform] || []) {
    const url = `${githubReleaseDownloadBase}/${encodeURIComponent(name)}`
    try {
      const response = await fetch(url, { redirect: 'manual' })
      if (response.ok || [301, 302, 303, 307, 308].includes(response.status)) return { url, version: 'latest' }
    } catch {
      // Try the next compatible filename before falling back to the GitHub API.
    }
  }
  return null
}

async function getLatestTaggedAsset(platform) {
  try {
    const releasePage = await fetch(`${githubReleasesPage}?_=${Math.floor(Date.now() / 300_000)}`)
    const html = await releasePage.text()
    const tagMatch = html.match(/\/releases\/tag\/([^"?#<]+)/)
    if (!releasePage.ok || !tagMatch) return null
    const tag = decodeURIComponent(tagMatch[1])
    for (const name of releaseAssetNames[platform] || []) {
      const url = `https://github.com/jiajia2222/Moumusic/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`
      const response = await fetch(url, { redirect: 'manual' })
      if (response.ok || [301, 302, 303, 307, 308].includes(response.status)) return { url, version: tag }
    }
  } catch {
    // Continue to the API and direct URL fallbacks.
  }
  return null
}

async function getLatestReleaseAsset(platform) {
  const cached = latestReleaseCache.get(platform)
  if (cached && cached.expiresAt > Date.now()) return cached.value

  let response
  try {
    response = await fetch(`${githubReleasesUrl}&_=${Math.floor(Date.now() / 300_000)}`, {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'Moumusic-website' },
      cache: 'no-store',
    })
  } catch {
    response = null
  }
  if (response?.ok) {
    try {
      const releases = await response.json()
      const release = Array.isArray(releases)
        ? releases.find(item => item?.draft !== true && item?.prerelease !== true && Array.isArray(item?.assets) && (
          platform === 'ios'
            ? item.assets.some(asset => asset?.name === 'Moumusic-unsigned.ipa' || /\.ipa$/i.test(asset?.name || ''))
            : item.assets.some(asset => /universal\.apk$/i.test(asset?.name || '') || /\.apk$/i.test(asset?.name || ''))
        ))
        : null
      const assets = Array.isArray(release?.assets) ? release.assets : []
      const asset = platform === 'ios'
        ? assets.find(item => item?.name === 'Moumusic-unsigned.ipa') || assets.find(item => /\.ipa$/i.test(item?.name || ''))
        : assets.find(item => /universal\.apk$/i.test(item?.name || '')) || assets.find(item => /\.apk$/i.test(item?.name || ''))
      const url = safeHttpUrl(asset?.browser_download_url)
      if (url) {
        const value = { url, version: String(release.tag_name || '') }
        latestReleaseCache.set(platform, { value, expiresAt: Date.now() + cacheTtlMs })
        return value
      }
    } catch {
      // Continue with the public releases page fallback.
    }
  }

  const taggedAsset = await getLatestTaggedAsset(platform)
  if (taggedAsset) {
    latestReleaseCache.set(platform, { value: taggedAsset, expiresAt: Date.now() + cacheTtlMs })
    return taggedAsset
  }
  const directAsset = await getDirectReleaseAsset(platform)
  if (directAsset) {
    latestReleaseCache.set(platform, { value: directAsset, expiresAt: Date.now() + cacheTtlMs })
    return directAsset
  }
  throw new AfdianError('RELEASE_ASSET_MISSING', `No ${platform} asset found in recent releases.`, 503)
}

function assertAfdianConfig(config) {
  if (!config.userId || !config.token) {
    throw new AfdianError('CONFIG_MISSING', 'Afdian API is not configured.', 503)
  }
}

function parseJsonBody(response, endpoint) {
  return response.json().catch(() => {
    throw new AfdianError('UPSTREAM_INVALID_JSON', `Afdian returned invalid JSON for ${endpoint}.`)
  })
}

async function requestAfdian(endpoint, params) {
  const config = getConfig()
  assertAfdianConfig(config)

  const timestamp = Math.floor(Date.now() / 1000)
  const paramsString = JSON.stringify(params)
  const payload = {
    user_id: config.userId,
    params: paramsString,
    ts: timestamp,
    sign: makeAfdianSignature({
      token: config.token,
      userId: config.userId,
      timestamp,
      params: paramsString,
    }),
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 12_000)
  try {
    let lastHttpStatus = null
    for (const apiBase of afdianApiBases) {
      const response = await fetch(`${apiBase}/${endpoint}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify(payload),
        signal: controller.signal,
      })
      if (!response.ok) {
        lastHttpStatus = response.status
        continue
      }
      const body = await parseJsonBody(response, endpoint)
      if (body?.ec !== 200) {
        throw new AfdianError('UPSTREAM_API', 'Afdian rejected the API request.')
      }
      return body.data || {}
    }
    throw new AfdianError('UPSTREAM_HTTP', `Afdian returned HTTP ${lastHttpStatus || 502}.`)
  } catch (error) {
    if (error instanceof AfdianError) throw error
    if (error?.name === 'AbortError') {
      throw new AfdianError('UPSTREAM_TIMEOUT', 'Afdian request timed out.')
    }
    throw new AfdianError('UPSTREAM_UNAVAILABLE', 'Afdian is temporarily unavailable.')
  } finally {
    clearTimeout(timeout)
  }
}

async function fetchAllPages(endpoint, pageSizeLimit = 100) {
  const records = []
  let page = 1
  let totalPages = 1
  while (page <= totalPages && page <= pageSizeLimit) {
    const data = await requestAfdian(endpoint, { page })
    if (Array.isArray(data.list)) records.push(...data.list)
    totalPages = Math.max(1, Number.parseInt(data.total_page, 10) || 1)
    page += 1
  }
  return records
}

function cleanText(value, fallback, maxLength = 120) {
  const text = String(value || '').replace(/\s+/g, ' ').trim().slice(0, maxLength)
  return text || fallback
}

function safeHttpUrl(value) {
  try {
    const url = new URL(String(value || ''))
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : undefined
  } catch {
    return undefined
  }
}

function unixTime(value) {
  const number = Number(value)
  return Number.isFinite(number) && number > 0 ? Math.floor(number) : undefined
}

function money(value) {
  const number = Number.parseFloat(String(value ?? ''))
  return Number.isFinite(number) && number >= 0 ? Math.round(number * 100) / 100 : undefined
}

function publicId(config, value) {
  const source = String(value || 'anonymous')
  return createHmac('sha256', config.token || 'moumusic-public-id').update(source).digest('hex').slice(0, 20)
}

export function mapSponsor(raw, { showAmount = false, token = '' } = {}) {
  const config = { token }
  const user = raw?.user || {}
  const lastSupportTime = unixTime(raw?.last_pay_time) || unixTime(raw?.create_time)
  const currentPlan = cleanText(raw?.current_plan?.name, '')
  const plan = currentPlan || '持续支持中'
  const result = {
    id: publicId(config, raw?.user_private_id || user.user_id || `${user.name}-${lastSupportTime || ''}`),
    name: cleanText(user.name, '匿名支持者'),
    plan,
    lastSupportTime: lastSupportTime || null,
  }
  const avatar = safeHttpUrl(user.avatar)
  if (avatar) result.avatar = avatar
  if (showAmount) {
    const amount = money(raw?.all_sum_amount)
    if (amount !== undefined) result.amount = amount
  }
  return result
}

function mapOrder(raw, { showAmount = false, token = '' } = {}) {
  const result = {
    id: publicId({ token }, raw?.out_trade_no),
    plan: cleanText(raw?.title, raw?.plan_id ? `支持方案 ${String(raw.plan_id).slice(0, 8)}` : '一次支持'),
    paidAt: unixTime(raw?.create_time) || unixTime(raw?.pay_time) || null,
  }
  if (showAmount) {
    const amount = money(raw?.show_amount ?? raw?.total_amount)
    if (amount !== undefined) result.amount = amount
  }
  return result
}

async function cached(key, loader) {
  const current = cache.get(key)
  if (current && current.expiresAt > Date.now()) return current.value
  const value = await loader()
  cache.set(key, { value, expiresAt: Date.now() + cacheTtlMs })
  return value
}

async function getSponsors() {
  return cached('sponsors', async () => {
    const config = getConfig()
    const records = await fetchAllPages('query-sponsor')
    return records
      .map(record => mapSponsor(record, { showAmount: config.showAmount, token: config.token }))
      .sort((a, b) => (b.lastSupportTime || 0) - (a.lastSupportTime || 0))
  })
}

async function getOrders() {
  return cached('orders', async () => {
    const config = getConfig()
    const records = await fetchAllPages('query-order')
    return records
      .filter(record => Number(record?.status) === 2 || record?.status === undefined)
      .map(record => mapOrder(record, { showAmount: config.showAmount, token: config.token }))
      .sort((a, b) => (b.paidAt || 0) - (a.paidAt || 0))
  })
}

export async function getStats() {
  const sponsors = await getSponsors()
  const config = getConfig()
  const totalAmount = config.showAmount
    ? sponsors.reduce((sum, sponsor) => sum + (sponsor.amount || 0), 0)
    : undefined
  return {
    supporterCount: sponsors.length,
    recentSupportAt: sponsors[0]?.lastSupportTime || null,
    showAmount: config.showAmount,
    ...(totalAmount !== undefined ? { totalAmount: Math.round(totalAmount * 100) / 100 } : {}),
  }
}

function safeJson(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026')
}

async function renderPage(filename, baseUrl) {
  const template = await readFile(join(publicRoot, filename), 'utf8')
  return template.replace('__SITE_CONFIG__', safeJson(getPublicConfig(baseUrl)))
}

function logEvent(event, fields = {}) {
  process.stdout.write(`${JSON.stringify({ level: 'info', event, at: new Date().toISOString(), ...fields })}\n`)
}

function setSecurityHeaders(response) {
  response.setHeader('X-Content-Type-Options', 'nosniff')
  response.setHeader('X-Frame-Options', 'DENY')
  response.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin')
  response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
  response.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' https: data:; style-src 'self'; script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
}

function sendJson(response, status, body) {
  response.statusCode = status
  response.setHeader('content-type', 'application/json; charset=utf-8')
  response.setHeader('cache-control', 'no-store')
  response.end(JSON.stringify(body))
}

async function sendLatestReleaseRedirect(response, platform) {
  try {
    const asset = await getLatestReleaseAsset(platform)
    response.statusCode = 302
    response.setHeader('location', asset.url)
    response.setHeader('cache-control', 'public, max-age=300, stale-while-revalidate=600')
    response.end()
  } catch (error) {
    sendJson(response, error instanceof AfdianError ? error.status : 503, {
      success: false,
      error: { code: 'RELEASE_UNAVAILABLE', message: '暂时无法获取最新安装包，请稍后再试。' },
    })
  }
}

function checkRateLimit(request) {
  const ip = request.headers['x-forwarded-for']?.split(',')[0]?.trim() || request.socket.remoteAddress || 'unknown'
  const now = Date.now()
  const bucket = rateBuckets.get(ip) || { count: 0, startedAt: now }
  if (now - bucket.startedAt > 60_000) {
    bucket.count = 0
    bucket.startedAt = now
  }
  bucket.count += 1
  rateBuckets.set(ip, bucket)
  return bucket.count <= 60
}

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
}

async function sendStatic(response, filename) {
  const target = resolve(publicRoot, filename)
  if (!target.startsWith(`${publicRoot}${sep}`)) {
    response.statusCode = 403
    response.end('Forbidden')
    return
  }
  try {
    const data = await readFile(target)
    response.statusCode = 200
    response.setHeader('content-type', contentTypes[extname(target)] || 'application/octet-stream')
    response.setHeader('cache-control', 'public, max-age=300')
    response.end(data)
  } catch {
    response.statusCode = 404
    response.end('Not found')
  }
}

async function handleRequest(request, response) {
  const requestId = randomUUID()
  response.setHeader('x-request-id', requestId)
  setSecurityHeaders(response)
  const url = new URL(request.url || '/', 'http://localhost')
  const pathname = url.pathname

  if (pathname.startsWith('/api/') && !checkRateLimit(request)) {
    sendJson(response, 429, { success: false, error: { code: 'RATE_LIMITED', message: '请求过于频繁，请稍后再试。' } })
    return
  }

  if (request.method !== 'GET') {
    response.setHeader('allow', 'GET')
    sendJson(response, 405, { success: false, error: { code: 'METHOD_NOT_ALLOWED', message: '仅支持 GET 请求。' } })
    return
  }

  if (pathname === '/' || pathname === '/aifadian') {
    const html = await renderPage('index.html', url)
    response.statusCode = 200
    response.setHeader('content-type', 'text/html; charset=utf-8')
    response.setHeader('cache-control', 'no-cache')
    response.end(html)
    return
  }
  if (pathname === '/install') {
    const html = await renderPage('install.html', url)
    response.statusCode = 200
    response.setHeader('content-type', 'text/html; charset=utf-8')
    response.setHeader('cache-control', 'no-cache')
    response.end(html)
    return
  }
  if (pathname === '/download/ios') {
    await sendLatestReleaseRedirect(response, 'ios')
    return
  }
  if (pathname === '/download/android') {
    await sendLatestReleaseRedirect(response, 'android')
    return
  }
  if (pathname === '/health') {
    sendJson(response, 200, { status: 'ok' })
    return
  }
  if (pathname === '/api/site-config') {
    sendJson(response, 200, { success: true, config: getPublicConfig(url) })
    return
  }

  const apiHandlers = {
    '/api/aifadian/sponsors': async () => ({ supporters: await getSponsors() }),
    '/api/aifadian/orders': async () => ({ orders: await getOrders() }),
    '/api/aifadian/stats': async () => ({ stats: await getStats() }),
  }
  if (apiHandlers[pathname]) {
    try {
      const data = await apiHandlers[pathname]()
      sendJson(response, 200, { success: true, ...data, cacheTtlSeconds: cacheTtlMs / 1000 })
    } catch (error) {
      const safeError = error instanceof AfdianError ? error : new AfdianError('INTERNAL_ERROR', 'Unable to load sponsor data.')
      logEvent('aifadian_api_error', { requestId, path: pathname, code: safeError.code })
      sendJson(response, safeError.status || 502, {
        success: false,
        error: { code: safeError.code, message: '暂时无法获取赞助名单，请稍后再试。' },
      })
    }
    return
  }

  const staticFile = pathname.replace(/^\/+/, '')
  await sendStatic(response, staticFile)
}

const server = createServer((request, response) => {
  handleRequest(request, response).catch(error => {
    logEvent('request_error', { code: error?.code || 'INTERNAL_ERROR' })
    if (!response.headersSent) sendJson(response, 500, { success: false, error: { code: 'INTERNAL_ERROR', message: '页面暂时无法打开，请稍后再试。' } })
    else response.end()
  })
})

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  server.listen(port, () => logEvent('server_started', { port }))
}

setInterval(() => {
  const now = Date.now()
  for (const [key, value] of cache) if (value.expiresAt <= now) cache.delete(key)
  for (const [key, value] of rateBuckets) if (now - value.startedAt > 60_000) rateBuckets.delete(key)
}, 60_000).unref()

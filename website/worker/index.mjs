import { createHash, createHmac } from 'node:crypto'

const AFDIAN_API_BASES = [
  'https://afdian.com/api/open',
  'https://ifdian.net/api/open',
  'https://afdian.net/api/open',
]
const GITHUB_LATEST_RELEASE_URL = 'https://api.github.com/repos/jiajia2222/Moumusic/releases/latest'
const CACHE_TTL_SECONDS = 10 * 60
const DEFAULT_AFDIAN_URL = 'https://www.ifdian.net/a/moumou2026'
const memoryCache = new Map()
const rateBuckets = new Map()

class AfdianError extends Error {
  constructor(code, message, status = 502) {
    super(message)
    this.name = 'AfdianError'
    this.code = code
    this.status = status
  }
}

function makeAfdianSignature({ token, userId, timestamp, params }) {
  const paramsString = typeof params === 'string' ? params : JSON.stringify(params)
  const canonical = `params${paramsString}ts${timestamp}user_id${userId}`
  return createHash('md5').update(`${token}${canonical}`).digest('hex')
}

function envBoolean(value) {
  return ['1', 'true', 'yes', 'on'].includes(String(value || '').trim().toLowerCase())
}

function safeHttpUrl(value, fallback = '') {
  try {
    const url = new URL(String(value || ''))
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.toString() : fallback
  } catch {
    return fallback
  }
}

function getConfig(env) {
  return {
    userId: String(env.AFDIAN_USER_ID || '').trim(),
    token: String(env.AFDIAN_TOKEN || '').trim(),
    showAmount: envBoolean(env.SHOW_SPONSOR_AMOUNT),
  }
}

function getPublicConfig(env, request) {
  const siteOrigin = request ? new URL(request.url).origin : 'https://music.nadev.xyz'
  return {
    name: String(env.SITE_NAME || 'MouMou').trim() || 'MouMou',
    avatar: safeHttpUrl(env.SITE_AVATAR),
    tagline: env.SITE_TAGLINE || '感谢你的支持，每一份心意都会变成继续维护和创造的动力。',
    thanks: env.SITE_THANKS || '感谢每一位支持者，让 Moumusic 可以持续更新。',
    afdianUrl: safeHttpUrl(env.AFDIAN_URL, DEFAULT_AFDIAN_URL),
    showAmount: envBoolean(env.SHOW_SPONSOR_AMOUNT),
    iosDownloadUrl: safeHttpUrl(env.IOS_DOWNLOAD_URL, `${siteOrigin}/download/ios`),
    androidDownloadUrl: safeHttpUrl(env.ANDROID_DOWNLOAD_URL, `${siteOrigin}/download/android`),
  }
}

async function getLatestReleaseAsset(request, ctx, platform) {
  const cacheKey = new Request(new URL(`/__cache/latest-release/${platform}`, request.url).toString())
  const memoryKey = `latest-release:${platform}`
  const cachedMemory = memoryCache.get(memoryKey)
  if (cachedMemory && cachedMemory.expiresAt > Date.now()) return cachedMemory.value

  const cached = await caches.default.match(cacheKey)
  if (cached) {
    try {
      const value = await cached.json()
      memoryCache.set(memoryKey, { value, expiresAt: Date.now() + CACHE_TTL_SECONDS * 1000 })
      return value
    } catch {
      // Ignore a stale or invalid cache entry and refresh it below.
    }
  }

  let response
  try {
    response = await fetch(GITHUB_LATEST_RELEASE_URL, {
      headers: {
        accept: 'application/vnd.github+json',
        'user-agent': 'Moumusic-website',
      },
    })
  } catch {
    throw new AfdianError('RELEASE_UNAVAILABLE', 'Latest GitHub release is unavailable.', 503)
  }
  if (!response.ok) throw new AfdianError('RELEASE_UNAVAILABLE', `GitHub returned HTTP ${response.status}.`, 503)

  let release
  try {
    release = await response.json()
  } catch {
    throw new AfdianError('RELEASE_UNAVAILABLE', 'GitHub returned invalid release data.', 503)
  }

  const assets = Array.isArray(release?.assets) ? release.assets : []
  const asset = platform === 'ios'
    ? assets.find(item => item?.name === 'Moumusic-unsigned.ipa') || assets.find(item => /\.ipa$/i.test(item?.name || ''))
    : assets.find(item => /universal\.apk$/i.test(item?.name || '')) || assets.find(item => /\.apk$/i.test(item?.name || ''))
  const url = safeHttpUrl(asset?.browser_download_url)
  if (!url) throw new AfdianError('RELEASE_ASSET_MISSING', `No ${platform} asset found in the latest release.`, 503)

  const value = { url, version: String(release.tag_name || '') }
  memoryCache.set(memoryKey, { value, expiresAt: Date.now() + CACHE_TTL_SECONDS * 1000 })
  ctx.waitUntil(caches.default.put(cacheKey, new Response(JSON.stringify(value), {
    headers: { 'content-type': 'application/json', 'cache-control': `public, max-age=${CACHE_TTL_SECONDS}` },
  })).catch(() => undefined))
  return value
}

async function redirectToLatestRelease(request, ctx, platform) {
  try {
    const asset = await getLatestReleaseAsset(request, ctx, platform)
    return new Response(null, {
      status: 302,
      headers: {
        location: asset.url,
        'cache-control': 'public, max-age=300, stale-while-revalidate=600',
      },
    })
  } catch (error) {
    return jsonResponse(error instanceof AfdianError ? error.status : 503, {
      success: false,
      error: { code: 'RELEASE_UNAVAILABLE', message: '暂时无法获取最新安装包，请稍后再试。' },
    })
  }
}

function assertAfdianConfig(config) {
  if (!config.userId || !config.token) {
    throw new AfdianError('CONFIG_MISSING', 'Afdian API is not configured.', 503)
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

function cleanText(value, fallback, maxLength = 120) {
  const text = String(value || '').replace(/\s+/g, ' ').trim().slice(0, maxLength)
  return text || fallback
}

function publicId(config, value) {
  const source = String(value || 'anonymous')
  return createHmac('sha256', config.token || 'moumusic-public-id').update(source).digest('hex').slice(0, 20)
}

function mapSponsor(raw, config) {
  const user = raw?.user || {}
  const lastSupportTime = unixTime(raw?.last_pay_time) || unixTime(raw?.create_time)
  const plan = cleanText(raw?.current_plan?.name, '持续支持中')
  const result = {
    id: publicId(config, raw?.user_private_id || user.user_id || `${user.name}-${lastSupportTime || ''}`),
    name: cleanText(user.name, '匿名支持者'),
    plan,
    lastSupportTime: lastSupportTime || null,
  }
  const avatar = safeHttpUrl(user.avatar)
  if (avatar) result.avatar = avatar
  if (config.showAmount) {
    const amount = money(raw?.all_sum_amount)
    if (amount !== undefined) result.amount = amount
  }
  return result
}

function mapOrder(raw, config) {
  const plan = raw?.plan_id
    ? `支持方案 ${String(raw.plan_id).slice(0, 8)}`
    : '一次支持'
  const result = {
    id: publicId(config, raw?.out_trade_no),
    plan: cleanText(raw?.title, plan),
    paidAt: unixTime(raw?.create_time) || unixTime(raw?.pay_time) || null,
  }
  if (config.showAmount) {
    const amount = money(raw?.show_amount ?? raw?.total_amount)
    if (amount !== undefined) result.amount = amount
  }
  return result
}

async function requestAfdian(env, endpoint, params) {
  const config = getConfig(env)
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
    for (const apiBase of AFDIAN_API_BASES) {
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
      let body
      try {
        body = await response.json()
      } catch {
        throw new AfdianError('UPSTREAM_INVALID_JSON', `Afdian returned invalid JSON for ${endpoint}.`)
      }
      if (body?.ec !== 200) throw new AfdianError('UPSTREAM_API', 'Afdian rejected the API request.')
      return body.data || {}
    }
    throw new AfdianError('UPSTREAM_HTTP', `Afdian returned HTTP ${lastHttpStatus || 502}.`)
  } catch (error) {
    if (error instanceof AfdianError) throw error
    if (error?.name === 'AbortError') throw new AfdianError('UPSTREAM_TIMEOUT', 'Afdian request timed out.')
    throw new AfdianError('UPSTREAM_UNAVAILABLE', 'Afdian is temporarily unavailable.')
  } finally {
    clearTimeout(timeout)
  }
}

async function fetchAllPages(env, endpoint) {
  const records = []
  let page = 1
  let totalPages = 1
  while (page <= totalPages && page <= 100) {
    const data = await requestAfdian(env, endpoint, { page })
    if (Array.isArray(data.list)) records.push(...data.list)
    totalPages = Math.max(1, Number.parseInt(data.total_page, 10) || 1)
    page += 1
  }
  return records
}

async function cached(key, loader, ctx) {
  const current = memoryCache.get(key)
  if (current && current.expiresAt > Date.now()) return current.value

  const cacheKey = new Request(`https://cache.moumusic.internal/${key}`)
  const cachedResponse = await caches.default.match(cacheKey)
  if (cachedResponse) {
    const value = await cachedResponse.json()
    memoryCache.set(key, { value, expiresAt: Date.now() + CACHE_TTL_SECONDS * 1000 })
    return value
  }

  const value = await loader()
  const response = new Response(JSON.stringify(value), {
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': `public, max-age=${CACHE_TTL_SECONDS}`,
    },
  })
  ctx.waitUntil(caches.default.put(cacheKey, response.clone()))
  memoryCache.set(key, { value, expiresAt: Date.now() + CACHE_TTL_SECONDS * 1000 })
  return value
}

async function getSponsors(env, ctx) {
  return cached('sponsors', async () => {
    const config = getConfig(env)
    const records = await fetchAllPages(env, 'query-sponsor')
    return records
      .map(record => mapSponsor(record, config))
      .sort((a, b) => (b.lastSupportTime || 0) - (a.lastSupportTime || 0))
  }, ctx)
}

async function getOrders(env, ctx) {
  return cached('orders', async () => {
    const config = getConfig(env)
    const records = await fetchAllPages(env, 'query-order')
    return records
      .filter(record => Number(record?.status) === 2 || record?.status === undefined)
      .map(record => mapOrder(record, config))
      .sort((a, b) => (b.paidAt || 0) - (a.paidAt || 0))
  }, ctx)
}

async function getStats(env, ctx) {
  const sponsors = await getSponsors(env, ctx)
  const config = getConfig(env)
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

async function renderPage(request, env, filename) {
  const assetUrl = new URL(request.url)
  assetUrl.pathname = `/${filename}`
  const assetRequest = new Request(assetUrl, { headers: request.headers })
  const asset = await env.ASSETS.fetch(assetRequest)
  if (!asset.ok) return new Response('Not found', { status: 404 })
  const html = (await asset.text()).replace('__SITE_CONFIG__', safeJson(getPublicConfig(env, request)))
  const headers = new Headers(asset.headers)
  headers.set('content-type', 'text/html; charset=utf-8')
  headers.set('cache-control', 'no-cache')
  return new Response(html, { status: 200, headers })
}

function securityHeaders(headers = new Headers()) {
  headers.set('X-Content-Type-Options', 'nosniff')
  headers.set('X-Frame-Options', 'DENY')
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin')
  headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
  headers.set('Content-Security-Policy', "default-src 'self'; img-src 'self' https: data:; style-src 'self'; script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
  return headers
}

function jsonResponse(status, body, cacheControl = 'no-store') {
  const headers = securityHeaders(new Headers({
    'content-type': 'application/json; charset=utf-8',
    'cache-control': cacheControl,
  }))
  return new Response(JSON.stringify(body), { status, headers })
}

function checkRateLimit(request) {
  const ip = request.headers.get('CF-Connecting-IP') || request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown'
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

function apiError(error, requestId) {
  const safeError = error instanceof AfdianError ? error : new AfdianError('INTERNAL_ERROR', 'Unable to load sponsor data.')
  console.error(JSON.stringify({ event: 'aifadian_api_error', requestId, code: safeError.code }))
  return jsonResponse(safeError.status, {
    success: false,
    error: { code: safeError.code, message: '暂时无法获取赞助名单，请稍后再试。' },
  })
}

async function handleRequest(request, env, ctx) {
  const requestId = crypto.randomUUID()
  const url = new URL(request.url)
  const pathname = url.pathname

  if (pathname.startsWith('/api/') && !checkRateLimit(request)) {
    return jsonResponse(429, { success: false, error: { code: 'RATE_LIMITED', message: '请求过于频繁，请稍后再试。' } })
  }
  if (request.method !== 'GET') {
    const response = jsonResponse(405, { success: false, error: { code: 'METHOD_NOT_ALLOWED', message: '仅支持 GET 请求。' } })
    response.headers.set('allow', 'GET')
    return response
  }

  if (pathname === '/' || pathname === '/aifadian') return renderPage(request, env, 'index.html')
  if (pathname === '/install') return renderPage(request, env, 'install.html')
  if (pathname === '/download/ios') return redirectToLatestRelease(request, ctx, 'ios')
  if (pathname === '/download/android') return redirectToLatestRelease(request, ctx, 'android')
  if (pathname === '/health') return jsonResponse(200, { status: 'ok' })
  if (pathname === '/api/site-config') return jsonResponse(200, { success: true, config: getPublicConfig(env, request) })

  try {
    if (pathname === '/api/aifadian/sponsors') {
      return jsonResponse(200, { success: true, supporters: await getSponsors(env, ctx), cacheTtlSeconds: CACHE_TTL_SECONDS }, 'public, max-age=60, stale-while-revalidate=600')
    }
    if (pathname === '/api/aifadian/orders') {
      return jsonResponse(200, { success: true, orders: await getOrders(env, ctx), cacheTtlSeconds: CACHE_TTL_SECONDS }, 'public, max-age=60, stale-while-revalidate=600')
    }
    if (pathname === '/api/aifadian/stats') {
      return jsonResponse(200, { success: true, stats: await getStats(env, ctx), cacheTtlSeconds: CACHE_TTL_SECONDS }, 'public, max-age=60, stale-while-revalidate=600')
    }
  } catch (error) {
    return apiError(error, requestId)
  }

  const asset = await env.ASSETS.fetch(request)
  const headers = securityHeaders(new Headers(asset.headers))
  return new Response(asset.body, { status: asset.status, statusText: asset.statusText, headers })
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await handleRequest(request, env, ctx)
    } catch (error) {
      const requestId = crypto.randomUUID()
      console.error(JSON.stringify({ event: 'request_error', requestId, code: error?.code || 'INTERNAL_ERROR' }))
      return jsonResponse(500, { success: false, error: { code: 'INTERNAL_ERROR', message: '页面暂时无法打开，请稍后再试。' } })
    }
  },
}

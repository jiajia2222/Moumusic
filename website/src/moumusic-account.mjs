import { createHash, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const schemaVersion = 2
const sessionLifetimeMs = 30 * 24 * 60 * 60 * 1000
const adminSessionLifetimeMs = 8 * 60 * 60 * 1000

export class MoumusicAccountError extends Error {
  constructor(code, message, status = 400) {
    super(message)
    this.name = 'MoumusicAccountError'
    this.code = code
    this.status = status
  }
}

function text(value, fallback = '', maxLength = 160) {
  const result = String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, '').trim()
  return (result || fallback).slice(0, maxLength)
}

function isValidDeviceID(value) {
  return /^[A-Za-z0-9._:-]{16,128}$/.test(String(value || ''))
}

// Public IDs are deliberately separate from the opaque internal user ID.
// They are safe to show in profile cards and URLs, while sessions continue
// to reference the internal ID only.
function normalizePublicID(value) {
  return String(value || '').trim().toLowerCase()
}

function isValidPublicID(value) {
  return /^[a-z0-9][a-z0-9._-]{2,31}$/.test(normalizePublicID(value))
}

function hashToken(value) {
  return createHash('sha256').update(value).digest('hex')
}

function makeID(prefix) {
  return `${prefix}_${randomBytes(7).toString('base64url')}`
}

function makePublicID() {
  return `mou_${randomBytes(8).toString('base64url').toLowerCase()}`
}

function parsePasswordHash(value) {
  const match = /^scrypt\$(\d+)\$([0-9a-f]+)\$([0-9a-f]+)$/.exec(String(value || ''))
  if (!match) return null
  return { cost: Number(match[1]), salt: Buffer.from(match[2], 'hex'), digest: Buffer.from(match[3], 'hex') }
}

export function makeAdminPasswordHash(password, salt = randomBytes(16)) {
  const cost = 16_384
  const digest = scryptSync(String(password), salt, 64, { N: cost, r: 8, p: 1 })
  return `scrypt$${cost}$${salt.toString('hex')}$${digest.toString('hex')}`
}

function verifyAdminPassword(password, encoded) {
  const parsed = parsePasswordHash(encoded)
  if (!parsed || !Number.isSafeInteger(parsed.cost) || parsed.cost < 1_024 || parsed.cost > 1_048_576) return false
  const digest = scryptSync(String(password), parsed.salt, parsed.digest.length, {
    N: parsed.cost,
    r: 8,
    p: 1,
  })
  return digest.length === parsed.digest.length && timingSafeEqual(digest, parsed.digest)
}

function defaultState(serverID) {
  return {
    schemaVersion,
    serverID,
    settings: { downloadsEnabled: true },
    users: [],
    sessions: [],
  }
}

export class MoumusicAccountService {
  constructor(options = {}) {
    this.dataDir = options.dataDir || process.env.MOUMUSIC_DATA_DIR || join(process.cwd(), 'data')
    this.filePath = join(this.dataDir, 'moumusic-accounts.json')
    this.adminUsername = options.adminUsername || process.env.MOUMUSIC_ADMIN_USERNAME || 'moumou'
    this.adminPasswordHash = options.adminPasswordHash || process.env.MOUMUSIC_ADMIN_PASSWORD_HASH || ''
    this.adminID = options.adminID || process.env.MOUMUSIC_ADMIN_ID || 'moumusic-admin'
    this.adminPublicID = normalizePublicID(options.adminPublicID || process.env.MOUMUSIC_ADMIN_PUBLIC_ID || this.adminID)
    this.serverID = options.serverID || process.env.MOUMUSIC_SERVER_ID || makeID('srv')
    this.serverVersion = text(options.serverVersion || process.env.MOUMUSIC_SERVER_VERSION, '1.0.0', 40)
    this.writeQueue = Promise.resolve()
    this.state = defaultState(this.serverID)
    this.ready = this.load()
  }

  async load() {
    await mkdir(this.dataDir, { recursive: true })
    try {
      const parsed = JSON.parse(await readFile(this.filePath, 'utf8'))
      if (!parsed || typeof parsed !== 'object') throw new Error('invalid state')
      this.state = {
        ...defaultState(this.serverID),
        ...parsed,
        serverID: text(parsed.serverID, this.serverID, 80),
        settings: { downloadsEnabled: parsed.settings?.downloadsEnabled !== false },
        users: this.migrateUsers(Array.isArray(parsed.users) ? parsed.users : []),
        sessions: Array.isArray(parsed.sessions) ? parsed.sessions : [],
      }
      this.serverID = this.state.serverID
      if (this.state.schemaVersion !== schemaVersion) {
        this.state.schemaVersion = schemaVersion
        await this.persist()
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw new MoumusicAccountError('STATE_UNREADABLE', 'Moumusic account storage is unreadable.', 500)
      }
      await this.persist()
    }
  }

  migrateUsers(users) {
    const used = new Set()
    return users.map(item => {
      const user = { ...item }
      let publicID = normalizePublicID(user.publicID || user.id)
      if (!isValidPublicID(publicID) || used.has(publicID)) {
        do publicID = makePublicID(); while (used.has(publicID))
      }
      used.add(publicID)
      user.publicID = publicID
      user.role = user.role === 'admin' ? 'admin' : 'user'
      user.nickname = text(user.nickname, user.role === 'admin' ? 'MouMou' : 'Moumusic User', 60)
      user.avatarURL = text(user.avatarURL, '', 500)
      user.signature = text(user.signature, '', 160)
      user.disabled = Boolean(user.disabled)
      return user
    })
  }

  async persist() {
    const snapshot = JSON.stringify(this.state, null, 2)
    this.writeQueue = this.writeQueue.then(async () => {
      const temporary = `${this.filePath}.${process.pid}.tmp`
      await writeFile(temporary, snapshot, { encoding: 'utf8', mode: 0o600 })
      await rename(temporary, this.filePath)
    })
    return this.writeQueue
  }

  async ensureReady() {
    await this.ready
    this.pruneExpiredSessions()
  }

  pruneExpiredSessions() {
    const now = Date.now()
    const active = this.state.sessions.filter(session => Number(session.expiresAt) > now)
    if (active.length !== this.state.sessions.length) {
      this.state.sessions = active
      void this.persist()
    }
  }

  publicConfig() {
    return {
      configured: Boolean(this.adminPasswordHash),
      serverID: this.serverID,
      version: this.serverVersion,
      downloadsEnabled: this.state.settings.downloadsEnabled !== false,
      serverInfo: {
        ipv4: text(process.env.MOUMUSIC_SERVER_IPV4, '', 64) || undefined,
        ipv6: text(process.env.MOUMUSIC_SERVER_IPV6, '', 128) || undefined,
        cpuCores: Number(process.env.MOUMUSIC_SERVER_CPU_CORES) || undefined,
        memoryMB: Number(process.env.MOUMUSIC_SERVER_MEMORY_MB) || undefined,
        storageGB: Number(process.env.MOUMUSIC_SERVER_STORAGE_GB) || undefined,
        networkPortMbps: Number(process.env.MOUMUSIC_SERVER_NETWORK_MBPS) || undefined,
      },
    }
  }

  async register({ deviceID, nickname } = {}) {
    await this.ensureReady()
    if (!isValidDeviceID(deviceID)) throw new MoumusicAccountError('INVALID_DEVICE_ID', 'A valid device ID is required.', 422)
    let user = this.state.users.find(item => item.deviceID === deviceID && item.role !== 'admin')
    if (!user) {
      const now = new Date().toISOString()
      user = {
        id: makeID('user'),
        publicID: this.nextPublicID(),
        deviceID: String(deviceID),
        role: 'user',
        nickname: text(nickname, 'Moumusic User', 60),
        avatarURL: '',
        signature: '',
        disabled: false,
        createdAt: now,
        updatedAt: now,
      }
      this.state.users.push(user)
      await this.persist()
    } else if (!isValidPublicID(user.publicID)) {
      user.publicID = this.nextPublicID()
      user.updatedAt = new Date().toISOString()
      await this.persist()
    }
    if (user.disabled) throw new MoumusicAccountError('ACCOUNT_DISABLED', 'This Moumusic account is disabled.', 403)
    return this.sessionResponse(user)
  }

  async adminLogin({ username, password } = {}) {
    await this.ensureReady()
    if (!this.adminPasswordHash || String(username || '') !== this.adminUsername || !verifyAdminPassword(password, this.adminPasswordHash)) {
      throw new MoumusicAccountError('ADMIN_LOGIN_FAILED', 'Administrator credentials are invalid.', 401)
    }
    let user = this.state.users.find(item => item.id === this.adminID)
    // A server operator can nominate an existing account by its public ID
    // through MOUMUSIC_ADMIN_PUBLIC_ID. The promotion happens only after the
    // server-side admin password has been verified; it is never client-driven.
    if (!user && isValidPublicID(this.adminPublicID)) {
      user = this.state.users.find(item => item.publicID === this.adminPublicID)
      if (user) {
        user.role = 'admin'
        user.deviceID = ''
        user.updatedAt = new Date().toISOString()
        await this.persist()
      }
    }
    if (!user) {
      const now = new Date().toISOString()
      user = {
        id: this.adminID,
        publicID: this.nextPublicID(this.adminPublicID),
        deviceID: '',
        role: 'admin',
        nickname: 'MouMou',
        avatarURL: '',
        signature: 'Moumusic administrator',
        disabled: false,
        createdAt: now,
        updatedAt: now,
      }
      this.state.users.push(user)
      await this.persist()
    } else if (user.role !== 'admin') {
      throw new MoumusicAccountError('ADMIN_ID_CONFLICT', 'The configured administrator ID belongs to a normal account.', 500)
    }
    return this.sessionResponse(user, adminSessionLifetimeMs)
  }

  async authenticate(request) {
    await this.ensureReady()
    const header = String(request.headers.authorization || '')
    const token = /^Bearer\s+(.+)$/i.exec(header)?.[1]?.trim()
    if (!token) throw new MoumusicAccountError('UNAUTHORIZED', 'Authentication is required.', 401)
    const session = this.state.sessions.find(item => item.tokenHash === hashToken(token) && item.expiresAt > Date.now())
    if (!session) throw new MoumusicAccountError('UNAUTHORIZED', 'The session has expired.', 401)
    const user = this.state.users.find(item => item.id === session.userID)
    if (!user || user.disabled) throw new MoumusicAccountError('ACCOUNT_DISABLED', 'This account is unavailable.', 403)
    return user
  }

  async logout(request) {
    await this.ensureReady()
    const header = String(request.headers.authorization || '')
    const token = /^Bearer\s+(.+)$/i.exec(header)?.[1]?.trim()
    if (token) {
      this.state.sessions = this.state.sessions.filter(item => item.tokenHash !== hashToken(token))
      await this.persist()
    }
  }

  async updateProfile(user, patch = {}) {
    await this.ensureReady()
    const target = this.state.users.find(item => item.id === user.id)
    if (!target) throw new MoumusicAccountError('NOT_FOUND', 'User profile not found.', 404)
    target.nickname = text(patch.nickname, target.nickname, 60)
    target.avatarURL = text(patch.avatarURL, target.avatarURL, 500)
    target.signature = text(patch.signature, target.signature, 160)
    if (patch.publicID !== undefined) {
      target.publicID = this.reservePublicID(patch.publicID, target)
    }
    target.updatedAt = new Date().toISOString()
    await this.persist()
    return this.publicUser(target)
  }

  async updateAdminSettings(user, patch = {}) {
    this.requireAdmin(user)
    await this.ensureReady()
    if (typeof patch.downloadsEnabled !== 'boolean') {
      throw new MoumusicAccountError('INVALID_SETTINGS', 'downloadsEnabled must be a boolean.', 422)
    }
    this.state.settings.downloadsEnabled = patch.downloadsEnabled
    await this.persist()
    return this.publicConfig()
  }

  async listUsers(user) {
    this.requireAdmin(user)
    await this.ensureReady()
    return this.state.users.map(item => this.publicUser(item, true))
  }

  async updateUser(user, userID, patch = {}) {
    this.requireAdmin(user)
    await this.ensureReady()
    const target = this.state.users.find(item => item.publicID === normalizePublicID(userID))
    if (!target || target.role === 'admin') throw new MoumusicAccountError('NOT_FOUND', 'User profile not found.', 404)
    if (typeof patch.disabled === 'boolean') target.disabled = patch.disabled
    if (typeof patch.nickname === 'string') target.nickname = text(patch.nickname, target.nickname, 60)
    if (typeof patch.avatarURL === 'string') target.avatarURL = text(patch.avatarURL, target.avatarURL, 500)
    if (typeof patch.signature === 'string') target.signature = text(patch.signature, target.signature, 160)
    if (patch.publicID !== undefined) target.publicID = this.reservePublicID(patch.publicID, target)
    target.updatedAt = new Date().toISOString()
    await this.persist()
    return this.publicUser(target, true)
  }

  async profile(userID) {
    await this.ensureReady()
    const normalized = normalizePublicID(userID)
    const user = this.state.users.find(item => item.publicID === normalized)
    if (!user || user.disabled) throw new MoumusicAccountError('NOT_FOUND', 'User profile not found.', 404)
    return this.publicUser(user)
  }

  requireAdmin(user) {
    if (!user || user.role !== 'admin' || (user.id !== this.adminID && user.publicID !== this.adminPublicID)) {
      throw new MoumusicAccountError('FORBIDDEN', 'Administrator access is required.', 403)
    }
  }

  publicUser(user, includeAdminFields = false) {
    const result = {
      id: user.publicID || user.id,
      role: user.role,
      nickname: user.nickname,
      avatarURL: user.avatarURL || null,
      signature: user.signature || null,
      createdAt: user.createdAt,
      updatedAt: user.updatedAt,
    }
    if (includeAdminFields) result.disabled = Boolean(user.disabled)
    return result
  }

  nextPublicID(preferred = '') {
    const candidate = normalizePublicID(preferred)
    if (isValidPublicID(candidate) && !this.state.users.some(item => item.publicID === candidate)) return candidate
    let generated = makePublicID()
    while (this.state.users.some(item => item.publicID === generated)) generated = makePublicID()
    return generated
  }

  reservePublicID(value, currentUser) {
    const publicID = normalizePublicID(value)
    if (!isValidPublicID(publicID)) {
      throw new MoumusicAccountError(
        'INVALID_PUBLIC_ID',
        'ID must be 3-32 characters using letters, numbers, dot, underscore, or hyphen.',
        422,
      )
    }
    const conflict = this.state.users.find(item => item.publicID === publicID && item.id !== currentUser.id)
    if (conflict) {
      throw new MoumusicAccountError('PUBLIC_ID_CONFLICT', 'This ID is already in use. Please choose another.', 409)
    }
    return publicID
  }

  sessionResponse(user, lifetime = sessionLifetimeMs) {
    const token = randomBytes(32).toString('base64url')
    this.state.sessions.push({
      tokenHash: hashToken(token),
      userID: user.id,
      expiresAt: Date.now() + lifetime,
    })
    return this.persist().then(() => ({
      accessToken: token,
      expiresAt: Date.now() + lifetime,
      profile: this.publicUser(user),
      server: this.publicConfig(),
    }))
  }

  get downloadsEnabled() {
    return this.state.settings.downloadsEnabled !== false
  }
}

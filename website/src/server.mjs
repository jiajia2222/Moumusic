// Moumusic server: device IDs, heartbeat, remote config, feedback, profile cards.
// Protocol is modelled on Beans 2.0.2 (DeviceReporter / RemoteControlStore). Zero dependencies, Node >= 22.5.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const PORT = Number(process.env.PORT || 8790);
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR = process.env.DATA_DIR || './data';
const BASE = (process.env.BASE_PATH || '/moumusic').replace(/\/$/, '');
const PUBLIC_URL = (process.env.PUBLIC_URL || '').replace(/\/$/, '');
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
const DEVELOPER_IDS = new Set((process.env.DEVELOPER_IDS || '').split(',').map(s => s.trim()).filter(Boolean));
const MAX_ATTACH = 50 * 1024 * 1024;
const MAX_ATTACH_COUNT = 4;
const FIRST_PUBLIC_ID = 100001;
const DEVICE_RE = /^[a-f0-9-]{16,80}$/;
const BADGES = new Set(['black_purple_gold', 'classic_gold']);

fs.mkdirSync(path.join(DATA_DIR, 'uploads'), { recursive: true });
const db = new DatabaseSync(path.join(DATA_DIR, 'moumusic.db'));
db.exec(`
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS devices (
  user_id TEXT PRIMARY KEY,
  public_user_id TEXT NOT NULL UNIQUE,
  exclusive_id TEXT,
  exclusive_badge_style TEXT NOT NULL DEFAULT 'black_purple_gold',
  device_model TEXT, device_name TEXT, system_name TEXT, system_version TEXT,
  app_version TEXT, app_build TEXT,
  listening_seconds INTEGER NOT NULL DEFAULT 0,
  listening_play_count INTEGER NOT NULL DEFAULT 0,
  blocked INTEGER NOT NULL DEFAULT 0,
  download_unlocked INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS feedback (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL, content TEXT NOT NULL, contact TEXT,
  attachments TEXT NOT NULL DEFAULT '[]', submitted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS feedback_replies (
  id INTEGER PRIMARY KEY AUTOINCREMENT, feedback_id TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS profiles (
  user_id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at TEXT NOT NULL
);
`);

const now = () => new Date().toISOString();
const getSetting = (k, d) => { const r = db.prepare('SELECT value FROM settings WHERE key=?').get(k); return r ? JSON.parse(r.value) : d; };
const setSetting = (k, v) => db.prepare('INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(k, JSON.stringify(v));

const DEFAULT_CONFIG = {
  enabled: true,
  announcement: '',
  announcement_enabled: false,
  announcement_image_url: '',
  announcement_media_url: '',
  announcement_media_type: 'image',
  announcement_text_color: '',
  platforms: { netease: true, qq: true, kugou: true },
  features: { third_party_sources: true, comments: true, homepage_remote_notice: true },
};
const getConfig = () => ({ ...DEFAULT_CONFIG, ...getSetting('config', {}), updated_at: getSetting('config_updated_at', now()) });
const saveConfig = patch => {
  const cur = { ...DEFAULT_CONFIG, ...getSetting('config', {}) };
  const next = { ...cur, ...patch };
  setSetting('config', next); setSetting('config_updated_at', now());
  return getConfig();
};

class ApiError extends Error {
  constructor(status, code, message) { super(message || code); this.status = status; this.code = code; }
}

function nextPublicId() {
  // Random six-digit ID, unique among public and exclusive IDs.
  for (let attempt = 0; attempt < 200; attempt++) {
    const candidate = String(crypto.randomInt(100000, 1000000));
    const taken = db.prepare('SELECT 1 FROM devices WHERE public_user_id=? OR exclusive_id=?').get(candidate, candidate);
    if (!taken) return candidate;
  }
  throw new ApiError(503, 'id_exhausted', 'No free public ID.');
}

// One-time migration: sequential IDs become random six-digit IDs.
if (!getSetting('public_id_random_v1', false)) {
  for (const row of db.prepare('SELECT user_id FROM devices').all()) {
    db.prepare('UPDATE devices SET public_user_id=? WHERE user_id=?').run(nextPublicId(), row.user_id);
  }
  setSetting('public_id_random_v1', true);
}
const deviceView = d => ({
  message: 'ok',
  is_developer: DEVELOPER_IDS.has(d.user_id),
  blocked: !!d.blocked,
  public_user_id: d.exclusive_id || d.public_user_id,
  original_public_user_id: d.public_user_id,
  exclusive_id: d.exclusive_id || '',
  exclusive_badge_style: d.exclusive_badge_style,
  download_unlocked: !!d.download_unlocked,
  download_global_enabled: !!getSetting('download_global', false),
  listening_seconds: d.listening_seconds,
  listening_play_count: d.listening_play_count,
});

function heartbeat(b) {
  const id = String(b.user_id || '').toLowerCase();
  if (!DEVICE_RE.test(id)) throw new ApiError(400, 'invalid_public_user_id', 'The device identifier is invalid.');
  const t = now();
  const s = v => (v == null ? null : String(v).slice(0, 120));
  const n = v => Math.max(0, Math.floor(Number(v) || 0));
  let d = db.prepare('SELECT * FROM devices WHERE user_id=?').get(id);
  if (!d) {
    db.prepare(`INSERT INTO devices(user_id,public_user_id,device_model,device_name,system_name,system_version,app_version,app_build,
      listening_seconds,listening_play_count,created_at,last_seen_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(id, nextPublicId(), s(b.device_model), s(b.device_name), s(b.system_name), s(b.system_version), s(b.app_version), s(b.app_build),
        n(b.listening_seconds), n(b.listening_play_count), t, t);
  } else {
    // Counters only move forward so a reinstall that reports 0 cannot wipe history.
    db.prepare(`UPDATE devices SET device_model=?,device_name=?,system_name=?,system_version=?,app_version=?,app_build=?,
      listening_seconds=MAX(listening_seconds,?),listening_play_count=MAX(listening_play_count,?),last_seen_at=? WHERE user_id=?`)
      .run(s(b.device_model), s(b.device_name), s(b.system_name), s(b.system_version), s(b.app_version), s(b.app_build),
        n(b.listening_seconds), n(b.listening_play_count), t, id);
  }
  return deviceView(db.prepare('SELECT * FROM devices WHERE user_id=?').get(id));
}

const recordView = d => ({ user_id: d.user_id, public_user_id: d.public_user_id, exclusive_id: d.exclusive_id || '', badge_style: d.exclusive_badge_style,
  device_model: d.device_model, device_name: d.device_name, system_name: d.system_name, system_version: d.system_version, app_version: d.app_version, app_build: d.app_build,
  last_seen_at: d.last_seen_at, enabled: true, changed_at: d.last_seen_at });
// Target may be the visible public ID, the exclusive ID, or the raw device code (user_id).
const findByPublic = pid => db.prepare('SELECT * FROM devices WHERE public_user_id=? OR exclusive_id=? OR user_id=?').get(pid, pid, String(pid).toLowerCase());
function requireDeveloper(req, b) {
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (ADMIN_TOKEN && bearer) {
    const a = crypto.createHash('sha256').update(bearer).digest();
    const z = crypto.createHash('sha256').update(ADMIN_TOKEN).digest();
    if (crypto.timingSafeEqual(a, z)) return;
  }
  const dev = String(b.developer_user_id || '').toLowerCase();
  if (dev && DEVELOPER_IDS.has(dev)) return;
  throw new ApiError(403, 'developer_unauthorized', 'This device does not have developer access.');
}
const mustTarget = b => {
  const pid = String(b.target_public_user_id || '').trim();
  if (!pid) throw new ApiError(400, 'missing_required_fields', 'Please complete all required fields.');
  const d = findByPublic(pid);
  if (!d) throw new ApiError(404, 'device_not_found', 'That device was not found. Ask the user to launch the app first.');
  return d;
};

// ---------- body parsing ----------
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', c => { size += c.length; if (size > limit) { reject(new ApiError(413, 'attachment_too_large', 'Request too large.')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}
const readJson = async req => {
  const buf = await readBody(req, 1024 * 1024);
  if (!buf.length) return {};
  try { return JSON.parse(buf.toString('utf8')); } catch { throw new ApiError(400, 'invalid_json', 'Invalid JSON.'); }
};
function parseMultipart(buf, boundary) {
  const fields = {}; const files = [];
  const delim = Buffer.from('--' + boundary);
  let pos = buf.indexOf(delim);
  while (pos !== -1) {
    const start = pos + delim.length;
    if (buf.slice(start, start + 2).toString() === '--') break;
    const next = buf.indexOf(delim, start);
    if (next === -1) break;
    const part = buf.slice(start + 2, next - 2); // strip CRLF both sides
    const sep = part.indexOf('\r\n\r\n');
    if (sep !== -1) {
      const head = part.slice(0, sep).toString('utf8');
      const body = part.slice(sep + 4);
      const name = /name="([^"]*)"/.exec(head)?.[1];
      const filename = /filename="([^"]*)"/.exec(head)?.[1];
      const type = /content-type:\s*([^\r\n]+)/i.exec(head)?.[1] || 'application/octet-stream';
      if (filename !== undefined) files.push({ name, filename, type, data: body }); else if (name) fields[name] = body.toString('utf8');
    }
    pos = next;
  }
  return { fields, files };
}
const ALLOWED_EXT = /\.(js|png|jpe?g|gif|webp|heic|mp4|mov|m4v|txt|log|json|zip|pdf)$/i;

async function submitFeedback(req) {
  const ct = req.headers['content-type'] || '';
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(ct);
  let fields, files = [];
  if (m) {
    const buf = await readBody(req, MAX_ATTACH * MAX_ATTACH_COUNT + 2 * 1024 * 1024);
    ({ fields, files } = parseMultipart(buf, m[1] || m[2]));
  } else fields = await readJson(req);
  const id = String(fields.user_id || '').toLowerCase();
  const content = String(fields.content || fields.message || '').trim();
  if (!DEVICE_RE.test(id) || !content) throw new ApiError(400, 'missing_required_fields', 'Please complete all required fields.');
  if (files.length > MAX_ATTACH_COUNT) throw new ApiError(400, 'too_many_attachments', 'You can upload up to four attachments.');
  const saved = [];
  for (const f of files) {
    if (f.data.length > MAX_ATTACH) throw new ApiError(413, 'attachment_too_large', 'Each attachment must be 50 MB or smaller.');
    if (!ALLOWED_EXT.test(f.filename)) throw new ApiError(400, 'unsupported_attachment', 'This file type is not supported.');
    const stored = `${Date.now()}-${crypto.randomBytes(4).toString('hex')}${path.extname(f.filename).toLowerCase()}`;
    fs.writeFileSync(path.join(DATA_DIR, 'uploads', stored), f.data);
    saved.push({ name: path.basename(f.filename), file: stored, size: f.data.length });
  }
  const fid = crypto.randomUUID();
  const t = now();
  db.prepare('INSERT INTO feedback(id,user_id,content,contact,attachments,submitted_at) VALUES(?,?,?,?,?,?)')
    .run(fid, id, content.slice(0, 5000), String(fields.contact || '').slice(0, 200), JSON.stringify(saved), t);
  // Submitting feedback unlocks downloads for this device (Beans behaviour).
  db.prepare('UPDATE devices SET download_unlocked=1 WHERE user_id=?').run(id);
  return { message: 'ok', feedback_id: fid, submitted_at: t, download_unlocked: true };
}

// ---------- routing ----------
const json = (res, status, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  res.end(body);
};

async function route(req, res) {
  const url = new URL(req.url, 'http://x');
  let p = url.pathname.replace(/\/+$/, '') || '/';
  if (p === '/health') return json(res, 200, { ok: true });
  if (!p.startsWith(BASE + '/') && p !== BASE) throw new ApiError(404, 'not_found', 'Not found.');
  p = p.slice(BASE.length) || '/';
  const m = req.method;

  if (m === 'GET' && (p === '/config.json' || p === '/config')) return json(res, 200, getConfig());
  if (m === 'GET' && p === '/') return json(res, 200, getSetting('update', { version: '', channel: 'stable', status: 'none', ipa_url: '', notes_image_url: '', notes_text_color: '' }));
  if (m === 'POST' && p === '/heartbeat') return json(res, 200, heartbeat(await readJson(req)));
  if (m === 'POST' && p === '/feedback') return json(res, 200, await submitFeedback(req));
  if (m === 'GET' && p === '/feedback') {
    const id = String(url.searchParams.get('user_id') || '').toLowerCase();
    if (!DEVICE_RE.test(id)) throw new ApiError(400, 'invalid_public_user_id', 'The device identifier is invalid.');
    const rows = db.prepare('SELECT * FROM feedback WHERE user_id=? ORDER BY submitted_at DESC LIMIT 50').all(id);
    const rep = db.prepare('SELECT content, created_at FROM feedback_replies WHERE feedback_id=? ORDER BY id');
    return json(res, 200, { records: rows.map(r => ({ feedback_id: r.id, content: r.content, submitted_at: r.submitted_at, feedback_replies: rep.all(r.id) })) });
  }
  if (m === 'POST' && p === '/feedback/delete') {
    const b = await readJson(req);
    const id = String(b.user_id || '').toLowerCase();
    const fid = String(b.feedback_id || '');
    const row = db.prepare('SELECT attachments FROM feedback WHERE id=? AND user_id=?').get(fid, id);
    if (!row) throw new ApiError(404, 'not_found', 'Not found.');
    for (const a of JSON.parse(row.attachments)) { try { fs.unlinkSync(path.join(DATA_DIR, 'uploads', path.basename(a.file))); } catch {} }
    db.prepare('DELETE FROM feedback_replies WHERE feedback_id=?').run(fid);
    db.prepare('DELETE FROM feedback WHERE id=?').run(fid);
    return json(res, 200, { message: 'ok' });
  }
  if (m === 'GET' && p.startsWith('/download/')) {
    const f = path.basename(p);
    const fp = path.join(DATA_DIR, 'uploads', f);
    if (!fs.existsSync(fp) || !fs.statSync(fp).isFile()) throw new ApiError(404, 'not_found', 'Not found.');
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': fs.statSync(fp).size, 'X-Content-Type-Options': 'nosniff' });
    return fs.createReadStream(fp).pipe(res);
  }

  // Profile card: public read by public ID, write by owning device.
  if (m === 'GET' && p.startsWith('/profile/')) {
    const d = findByPublic(decodeURIComponent(p.slice(9)));
    if (!d) throw new ApiError(404, 'device_not_found', 'That device was not found.');
    const pr = db.prepare('SELECT data, updated_at FROM profiles WHERE user_id=?').get(d.user_id);
    return json(res, 200, {
      public_user_id: d.exclusive_id || d.public_user_id, exclusive_id: d.exclusive_id || '', exclusive_badge_style: d.exclusive_badge_style,
      joined_at: d.created_at, listening_seconds: d.listening_seconds, listening_play_count: d.listening_play_count,
      profile: pr ? JSON.parse(pr.data) : null, updated_at: pr?.updated_at ?? null,
    });
  }
  if (m === 'PUT' && p === '/profile') {
    const b = await readJson(req);
    const id = String(b.user_id || '').toLowerCase();
    if (!DEVICE_RE.test(id) || !db.prepare('SELECT 1 FROM devices WHERE user_id=?').get(id)) throw new ApiError(404, 'device_not_found', 'That device was not found.');
    const data = JSON.stringify(b.profile ?? {});
    if (data.length > 64 * 1024) throw new ApiError(413, 'attachment_too_large', 'Profile too large.');
    const t = now();
    db.prepare('INSERT INTO profiles(user_id,data,updated_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET data=excluded.data,updated_at=excluded.updated_at').run(id, data, t);
    return json(res, 200, { message: 'ok', updated_at: t });
  }

  // Developer / admin
  if (p.startsWith('/developer/')) {
    if (m !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Use POST.');
    const b = await readJson(req);
    requireDeveloper(req, b);
    const op = p.slice(11);
    if (op === 'announcement') {
      const patch = {};
      if ('announcement' in b) patch.announcement = String(b.announcement);
      for (const k of ['announcement_enabled']) if (k in b) patch[k] = !!b[k];
      for (const k of ['announcement_image_url', 'announcement_media_url', 'announcement_media_type', 'announcement_text_color']) if (k in b) patch[k] = String(b[k]);
      return json(res, 200, saveConfig(patch));
    }
    if (op === 'download-global') {
      if ('enabled' in b) setSetting('download_global', !!b.enabled);
      return json(res, 200, { message: 'ok', enabled: !!getSetting('download_global', false) });
    }
    if (op === 'download-access') {
      if (!b.target_public_user_id) {
        const rows = db.prepare('SELECT * FROM devices WHERE download_unlocked=1 ORDER BY last_seen_at DESC LIMIT 200').all();
        return json(res, 200, { global_enabled: !!getSetting('download_global', false), records: rows.map(recordView) });
      }
      const d = mustTarget(b);
      return json(res, 200, { message: 'ok', enabled: !!d.download_unlocked, global_enabled: !!getSetting('download_global', false) });
    }
    if (op === 'grant-download') {
      const d = mustTarget(b);
      db.prepare('UPDATE devices SET download_unlocked=? WHERE user_id=?').run(b.enabled ? 1 : 0, d.user_id);
      return json(res, 200, { message: 'ok', enabled: !!b.enabled });
    }
    if (op === 'exclusive-access/status') { const d = mustTarget(b); return json(res, 200, { message: 'ok', enabled: !!d.exclusive_id, exclusive_id: d.exclusive_id || '', exclusive_badge_style: d.exclusive_badge_style }); }
    if (op === 'exclusive-access') {
      const rows = db.prepare("SELECT * FROM devices WHERE exclusive_id IS NOT NULL ORDER BY last_seen_at DESC LIMIT 200").all();
      return json(res, 200, { records: rows.map(recordView) });
    }
    if (op === 'grant-exclusive-id') {
      const d = mustTarget(b);
      const enabled = b.enabled !== false;
      if (!enabled) { db.prepare('UPDATE devices SET exclusive_id=NULL WHERE user_id=?').run(d.user_id); return json(res, 200, { message: 'ok', enabled: false }); }
      const want = String(b.assigned_public_user_id || '').trim();
      if (!want || /\s/.test(want) || [...want].length > 24) throw new ApiError(400, 'invalid_public_user_id', 'The public ID can contain up to 24 non-space characters.');
      const clash = db.prepare('SELECT user_id FROM devices WHERE (public_user_id=? OR exclusive_id=?) AND user_id<>?').get(want, want, d.user_id);
      if (clash) throw new ApiError(409, 'public_user_id_taken', 'That public ID is already assigned to another device.');
      const badge = BADGES.has(b.badge_style) ? b.badge_style : 'black_purple_gold';
      db.prepare('UPDATE devices SET exclusive_id=?, exclusive_badge_style=? WHERE user_id=?').run(want, badge, d.user_id);
      return json(res, 200, { message: 'ok', enabled: true, assigned_public_user_id: want, exclusive_badge_style: badge });
    }
    if (op === 'block') { const d = mustTarget(b); db.prepare('UPDATE devices SET blocked=? WHERE user_id=?').run(b.blocked ? 1 : 0, d.user_id); return json(res, 200, { message: 'ok', blocked: !!b.blocked }); }
    if (op === 'reply-feedback') {
      const fid = String(b.feedback_id || ''); const content = String(b.content || '').trim();
      if (!fid || !content || !db.prepare('SELECT 1 FROM feedback WHERE id=?').get(fid)) throw new ApiError(400, 'missing_required_fields', 'Please complete all required fields.');
      db.prepare('INSERT INTO feedback_replies(feedback_id,content,created_at) VALUES(?,?,?)').run(fid, content.slice(0, 5000), now());
      return json(res, 200, { message: 'ok' });
    }
    if (op === 'feedback-list') {
      const limit = Math.min(100, Math.max(1, Number(b.limit) || 50));
      const offset = Math.max(0, Number(b.offset) || 0);
      const unreplied = b.filter === 'unreplied';
      const q = String(b.query || '').trim();
      const conds = [];
      const args = [];
      if (unreplied) conds.push('NOT EXISTS (SELECT 1 FROM feedback_replies r WHERE r.feedback_id=f.id)');
      if (q) { conds.push('(f.content LIKE ? OR f.contact LIKE ? OR d.public_user_id=? OR d.exclusive_id=? OR f.user_id=?)'); args.push(`%${q}%`, `%${q}%`, q, q, q.toLowerCase()); }
      const where = conds.length ? 'WHERE ' + conds.join(' AND ') : '';
      const total = db.prepare(`SELECT COUNT(*) c FROM feedback f LEFT JOIN devices d ON d.user_id=f.user_id ${where}`).get(...args).c;
      const rows = db.prepare(`SELECT f.*, d.public_user_id, d.exclusive_id, d.device_model, d.system_name, d.system_version, d.app_version
        FROM feedback f LEFT JOIN devices d ON d.user_id=f.user_id ${where} ORDER BY f.submitted_at DESC LIMIT ? OFFSET ?`).all(...args, limit, offset);
      const rep = db.prepare('SELECT content, created_at FROM feedback_replies WHERE feedback_id=? ORDER BY id');
      return json(res, 200, { total, records: rows.map(r => ({
        feedback_id: r.id, user_id: r.user_id, public_user_id: r.exclusive_id || r.public_user_id || '',
        content: r.content, contact: r.contact || '', submitted_at: r.submitted_at,
        device: [r.device_model, r.system_name && `${r.system_name} ${r.system_version || ''}`.trim(), r.app_version && `v${r.app_version}`].filter(Boolean).join(' · '),
        attachments: JSON.parse(r.attachments || '[]').map(a => ({ name: a.name, size: a.size, file: a.file })),
        replies: rep.all(r.id),
      })) });
    }
    if (op === 'delete-feedback') {
      const fid = String(b.feedback_id || '');
      const row = db.prepare('SELECT attachments FROM feedback WHERE id=?').get(fid);
      if (!row) throw new ApiError(404, 'not_found', 'Not found.');
      for (const a of JSON.parse(row.attachments || '[]')) { try { fs.unlinkSync(path.join(DATA_DIR, 'uploads', path.basename(a.file))); } catch {} }
      db.prepare('DELETE FROM feedback_replies WHERE feedback_id=?').run(fid);
      db.prepare('DELETE FROM feedback WHERE id=?').run(fid);
      return json(res, 200, { message: 'ok' });
    }
    if (op === 'devices') {
      const limit = Math.min(200, Math.max(1, Number(b.limit) || 50));
      const offset = Math.max(0, Number(b.offset) || 0);
      const q = String(b.query || '').trim();
      const conds = [];
      const args = [];
      if (q) { conds.push('(public_user_id=? OR exclusive_id=? OR user_id=? OR device_model LIKE ? OR device_name LIKE ? OR exclusive_id LIKE ?)'); args.push(q, q, q.toLowerCase(), `%${q}%`, `%${q}%`, `%${q}%`); }
      if (b.filter === 'blocked') conds.push('blocked=1');
      if (b.filter === 'download') conds.push('download_unlocked=1');
      if (b.filter === 'exclusive') conds.push('exclusive_id IS NOT NULL');
      const where = conds.length ? 'WHERE ' + conds.join(' AND ') : '';
      const total = db.prepare(`SELECT COUNT(*) c FROM devices ${where}`).get(...args).c;
      const rows = db.prepare(`SELECT d.*, (SELECT COUNT(*) FROM feedback f WHERE f.user_id=d.user_id) AS feedback_count
        FROM devices d ${where.replaceAll('public_user_id', 'd.public_user_id')} ORDER BY d.last_seen_at DESC LIMIT ? OFFSET ?`).all(...args, limit, offset);
      return json(res, 200, { total, records: rows.map(d => ({
        ...recordView(d), created_at: d.created_at, blocked: !!d.blocked, download_unlocked: !!d.download_unlocked,
        listening_seconds: d.listening_seconds, listening_play_count: d.listening_play_count, feedback_count: d.feedback_count,
        is_developer: DEVELOPER_IDS.has(d.user_id),
      })) });
    }
    if (op === 'reset-public-id') {
      const d = mustTarget(b);
      const fresh = nextPublicId();
      db.prepare('UPDATE devices SET public_user_id=? WHERE user_id=?').run(fresh, d.user_id);
      return json(res, 200, { message: 'ok', public_user_id: fresh });
    }
    if (op === 'delete-profile') {
      const d = mustTarget(b);
      db.prepare('DELETE FROM profiles WHERE user_id=?').run(d.user_id);
      return json(res, 200, { message: 'ok' });
    }    if (op === 'update') { setSetting('update', b.update ?? {}); return json(res, 200, { message: 'ok' }); }
    if (op === 'stats') {
      const r = db.prepare('SELECT COUNT(*) c, COALESCE(SUM(listening_seconds),0) s, COALESCE(SUM(listening_play_count),0) p FROM devices').get();
      return json(res, 200, { devices: r.c, listening_seconds: r.s, listening_play_count: r.p });
    }
    throw new ApiError(404, 'not_found', 'Not found.');
  }
  throw new ApiError(404, 'not_found', 'Not found.');
}

http.createServer((req, res) => {
  route(req, res).catch(err => {
    if (err instanceof ApiError) return json(res, err.status, { error: err.code, message: err.message });
    console.error(err);
    json(res, 500, { error: 'server_error', message: 'The server could not process the request. Please try again later.' });
  });
}).listen(PORT, HOST, () => console.log(`moumusic-server listening on ${HOST}:${PORT}${BASE}${PUBLIC_URL ? ' (' + PUBLIC_URL + ')' : ''}`));

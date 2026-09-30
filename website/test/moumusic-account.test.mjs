import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  makeAdminPasswordHash,
  MoumusicAccountError,
  MoumusicAccountService,
} from '../src/moumusic-account.mjs'

async function withService(run) {
  const directory = await mkdtemp(join(tmpdir(), 'moumusic-account-'))
  const service = new MoumusicAccountService({
    dataDir: directory,
    adminUsername: 'owner',
    adminPasswordHash: makeAdminPasswordHash('correct-password'),
    adminID: 'moumusic-owner',
    serverID: 'srv_test',
  })
  try {
    return await run(service, directory)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

test('registers one stable public ID per device without storing the token', async () => {
  await withService(async (service, directory) => {
    const first = await service.register({ deviceID: 'device-1234567890', nickname: 'First device' })
    const second = await service.register({ deviceID: 'device-1234567890', nickname: 'Ignored rename' })

    assert.equal(first.profile.id, second.profile.id)
    assert.match(first.profile.id, /^[a-z0-9][a-z0-9._-]{2,31}$/)
    assert.equal(second.profile.nickname, 'First device')
    assert.equal(first.server.serverID, 'srv_test')
    assert.match(first.accessToken, /^[A-Za-z0-9_-]{32,}$/)

    const saved = await readFile(join(directory, 'moumusic-accounts.json'), 'utf8')
    assert.equal(saved.includes(first.accessToken), false)
    assert.equal(saved.includes('device-1234567890'), true)
  })
})

test('administrator login controls the download switch', async () => {
  await withService(async service => {
    const ordinary = await service.register({ deviceID: 'device-abcdefghijk', nickname: 'Listener' })
    const admin = await service.adminLogin({ username: 'owner', password: 'correct-password' })
    const adminRequest = { headers: { authorization: `Bearer ${admin.accessToken}` } }
    const ordinaryRequest = { headers: { authorization: `Bearer ${ordinary.accessToken}` } }

    assert.equal((await service.authenticate(adminRequest)).role, 'admin')
    assert.equal((await service.authenticate(ordinaryRequest)).role, 'user')
    const ordinaryUser = await service.authenticate(ordinaryRequest)
    await assert.rejects(
      () => service.updateAdminSettings(ordinaryUser, { downloadsEnabled: false }),
      error => error instanceof MoumusicAccountError && error.code === 'FORBIDDEN'
    )

    const config = await service.updateAdminSettings(
      await service.authenticate(adminRequest),
      { downloadsEnabled: false },
    )
    assert.equal(config.downloadsEnabled, false)
  })
})

test('profile changes are visible through the public profile endpoint', async () => {
  await withService(async service => {
    const session = await service.register({ deviceID: 'device-profile-1234', nickname: 'Old name' })
    const user = await service.authenticate({ headers: { authorization: `Bearer ${session.accessToken}` } })
    const profile = await service.updateProfile(user, {
      nickname: 'MouMou',
      avatarURL: 'https://example.com/avatar.png',
      signature: 'Keep making music.',
    })

    assert.deepEqual(await service.profile(profile.id), profile)
    assert.equal(profile.nickname, 'MouMou')
    assert.equal(profile.avatarURL, 'https://example.com/avatar.png')

    const renamed = await service.updateProfile(user, { publicID: 'moumou-profile' })
    assert.equal(renamed.id, 'moumou-profile')
    assert.deepEqual(await service.profile('moumou-profile'), renamed)
  })
})

test('rejects duplicate public IDs and lets the administrator manage profile cards', async () => {
  await withService(async service => {
    const first = await service.register({ deviceID: 'device-first-1234', nickname: 'First' })
    const second = await service.register({ deviceID: 'device-second-1234', nickname: 'Second' })
    const admin = await service.adminLogin({ username: 'owner', password: 'correct-password' })
    const adminUser = await service.authenticate({ headers: { authorization: `Bearer ${admin.accessToken}` } })

    await assert.rejects(
      () => service.updateUser(adminUser, first.profile.id, { publicID: second.profile.id }),
      error => error instanceof MoumusicAccountError && error.code === 'PUBLIC_ID_CONFLICT' && error.status === 409,
    )

    const updated = await service.updateUser(adminUser, first.profile.id, {
      publicID: 'managed-first',
      nickname: 'Managed first',
      signature: 'Managed by Moumusic admin',
      disabled: true,
    })
    assert.equal(updated.id, 'managed-first')
    assert.equal(updated.nickname, 'Managed first')
    assert.equal(updated.disabled, true)
    await assert.rejects(
      () => service.profile('managed-first'),
      error => error instanceof MoumusicAccountError && error.code === 'NOT_FOUND',
    )
  })
})

test('server-side admin public ID can promote an existing account after password verification', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'moumusic-admin-public-id-'))
  const userService = new MoumusicAccountService({ dataDir: directory, serverID: 'srv_test' })
  const user = await userService.register({ deviceID: 'device-promote-1234', nickname: 'Owner device' })
  const service = new MoumusicAccountService({
    dataDir: directory,
    adminUsername: 'owner',
    adminPasswordHash: makeAdminPasswordHash('correct-password'),
    adminID: 'moumusic-owner',
    adminPublicID: user.profile.id,
    serverID: 'srv_test',
  })
  try {
    const admin = await service.adminLogin({ username: 'owner', password: 'correct-password' })
    assert.equal(admin.profile.id, user.profile.id)
    assert.equal(admin.profile.role, 'admin')
    const authenticated = await service.authenticate({
      headers: { authorization: `Bearer ${admin.accessToken}` },
    })
    assert.doesNotThrow(() => service.requireAdmin(authenticated))
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

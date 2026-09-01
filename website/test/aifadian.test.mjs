import assert from 'node:assert/strict'
import test from 'node:test'

import { makeAfdianSignature, mapSponsor } from '../src/server.mjs'

test('creates the signature format documented by Afdian', () => {
  const signature = makeAfdianSignature({
    token: '123',
    userId: 'abc',
    timestamp: 1624339905,
    params: '{"a":333}',
  })
  assert.equal(signature, 'a4acc28b81598b7e5d84ebdc3e91710c')
})

test('maps a sponsor to the public shape without exposing raw identifiers', () => {
  const sponsor = mapSponsor({
    user_private_id: 'private-user-id',
    all_sum_amount: '13.00',
    create_time: 1576776221,
    last_pay_time: 1581083107,
    current_plan: { name: '高级支持者' },
    user: { user_id: 'raw-user-id', name: 'MouMou', avatar: 'https://pic1.afdiancdn.com/avatar.jpg' },
  }, { showAmount: true, token: 'server-only-token' })

  assert.deepEqual(sponsor, {
    id: 'fd6580a16ef769fd4ad6',
    name: 'MouMou',
    plan: '高级支持者',
    lastSupportTime: 1581083107,
    avatar: 'https://pic1.afdiancdn.com/avatar.jpg',
    amount: 13,
  })
  assert.equal(sponsor.id.includes('private-user-id'), false)
})

test('omits amount when amount privacy is disabled', () => {
  const sponsor = mapSponsor({
    all_sum_amount: '30.00',
    current_plan: { name: '' },
    user: { name: '匿名' },
  }, { showAmount: false, token: 'server-only-token' })

  assert.equal('amount' in sponsor, false)
  assert.equal(sponsor.plan, '持续支持中')
})

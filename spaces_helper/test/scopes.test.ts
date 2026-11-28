import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readOnlySpaces } from '../src/scopes.ts'

const types = ['org.atgrp.members', 'town.delve.space.feed']
const g = 'did:plc:group'

test('the AppView’s read grant passes', () => {
  const r = readOnlySpaces(
    'atproto space:org.atgrp.members?authority=self&action=read space:town.delve.space.feed?authority=self&action=read',
    types,
    g,
  )
  assert.equal(r.ok, true)
  assert.deepEqual(r.refused, [])
})

test('what a substring check would let through is refused', () => {
  for (const s of [
    // No action: read, create, update and delete.
    'space:town.delve.space.feed?authority=self',
    // read beside write.
    'space:town.delve.space.feed?authority=self&action=read&action=create',
    'space:org.atgrp.members?action=read&manage=update',
    // Another space type, or any.
    'space:org.atgrp.meta?action=read',
    'space:*?action=read',
    // Another authority.
    'space:org.atgrp.members?authority=did:plc:other&action=read',
    'transition:generic',
    'rpc:com.atproto.space.putRecord?aud=*',
  ]) {
    const r = readOnlySpaces(`atproto ${s}`, types, g)
    assert.equal(r.ok, false, s)
    assert.equal(r.refused.length, 1, s)
  }
})

test('the group’s own DID as authority passes; atproto alone grants nothing to approve', () => {
  assert.equal(readOnlySpaces(`atproto space:org.atgrp.members?authority=${g}&action=read`, types, g).ok, true)
  assert.equal(readOnlySpaces('atproto', types, g).ok, false)
})

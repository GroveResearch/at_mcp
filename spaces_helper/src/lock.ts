// A lock several processes on one state folder share: an exclusive lock
// file holding its owner's pid and time. It is written whole under another
// name first and then linked into place, which fails if the lock exists, so
// a lock file is never seen empty or half written, even when its owner is
// killed while taking it. A lock whose owner has died, or that is older
// than STALE_MS, is taken over; so is one that can't be read (left by an
// older helper that wrote its lock in place) once UNREADABLE_MS have passed. at_mcp runs
// one helper per installation, but several at_mcp processes (a service and a
// stdio client, say) may share a state folder, and an OAuth refresh token is
// good for one refresh: two refreshing at once would lose the session.
import { randomBytes } from 'node:crypto'
import { link, mkdir, readdir, readFile, stat, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const STALE_MS = 60_000
const WAIT_MS = 30_000
const UNREADABLE_MS = 2_000

function alive(pid: number) {
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM'
  }
}

/**
 * The lock file's name for a lock name (`oauth:<request>`, `store:<file>`):
 * the name with every character but letters, digits, `.`, `_` and `-`
 * written as `_`, cut to 120 characters. Lock names are AtMcp's own and
 * distinct within that length.
 */
export function lockFileName(name: string): string {
  return name.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 120) + '.lock'
}

export async function withFileLock<T>(dir: string, name: string, fn: () => Promise<T>): Promise<T> {
  await mkdir(dir, { recursive: true, mode: 0o700 })
  const path = join(dir, lockFileName(name))
  const deadline = Date.now() + WAIT_MS
  await removeDeadDrafts(dir)
  for (;;) {
    if (await take(path)) break
    let stale = false
    try {
      const held = JSON.parse(await readFile(path, 'utf8')) as { pid: number; at: number }
      stale = !alive(held.pid) || Date.now() - held.at > STALE_MS
    } catch {
      // Just removed, or unreadable: an unreadable lock that has stayed so
      // is not being written by anyone.
      stale = await stat(path).then(
        (st) => Date.now() - st.mtimeMs > UNREADABLE_MS,
        () => false,
      )
    }
    if (stale) {
      await unlink(path).catch(() => {})
      continue
    }
    if (Date.now() > deadline) throw new Error(`timed out waiting for the lock ${name}`)
    await new Promise((r) => setTimeout(r, 25 + Math.random() * 50))
  }
  try {
    return await fn()
  } finally {
    await unlink(path).catch(() => {})
  }
}

// Writes the lock whole under a draft name, then links it into place: true
// when this process now holds it, false when another does.
async function take(path: string): Promise<boolean> {
  const draft = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.draft`
  await writeFile(draft, JSON.stringify({ pid: process.pid, at: Date.now() }), { mode: 0o600, flag: 'wx' })
  try {
    await link(draft, path)
    return true
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
    return false
  } finally {
    await unlink(draft).catch(() => {})
  }
}

// A draft is left only by a process killed while taking a lock.
async function removeDeadDrafts(dir: string) {
  for (const file of await readdir(dir).catch(() => [] as string[])) {
    const pid = /\.(\d+)\.[0-9a-f]{8}\.draft$/.exec(file)?.[1]
    if (pid && !alive(Number(pid))) await unlink(join(dir, file)).catch(() => {})
  }
}

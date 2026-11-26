// A lock several processes on one state folder share: an exclusive lock
// file, created with O_EXCL, holding its owner's pid and time. A lock whose
// owner has died, or that is older than STALE_MS, is taken over. at_mcp runs
// one helper per installation, but several at_mcp processes (a service and a
// stdio client, say) may share a state folder, and an OAuth refresh token is
// good for one refresh: two refreshing at once would lose the session.
import { mkdir, open, readFile, unlink } from 'node:fs/promises'
import { join } from 'node:path'

const STALE_MS = 60_000
const WAIT_MS = 30_000

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
  for (;;) {
    try {
      const fh = await open(path, 'wx', 0o600)
      await fh.writeFile(JSON.stringify({ pid: process.pid, at: Date.now() }))
      await fh.close()
      break
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
      let stale = false
      try {
        const held = JSON.parse(await readFile(path, 'utf8')) as { pid: number; at: number }
        stale = !alive(held.pid) || Date.now() - held.at > STALE_MS
      } catch {
        // Being written, or just removed: look again.
      }
      if (stale) {
        await unlink(path).catch(() => {})
        continue
      }
      if (Date.now() > deadline) throw new Error(`timed out waiting for the lock ${name}`)
      await new Promise((r) => setTimeout(r, 25 + Math.random() * 50))
    }
  }
  try {
    return await fn()
  } finally {
    await unlink(path).catch(() => {})
  }
}

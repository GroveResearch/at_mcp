// Private files: read and written whole, mode 0600, never through a symlink.
// at_mcp's own AtMcp.PrivateFile is the rule this follows; the helper keeps
// only its own files (sessions, pending authorizations) and reads key files.
import { lstat, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname, join, basename } from 'node:path'
import { randomBytes } from 'node:crypto'

export class PrivateFileError extends Error {
  constructor(
    readonly code: 'file_missing' | 'file_insecure' | 'file_corrupt',
    message: string,
  ) {
    super(message)
    this.name = 'PrivateFileError'
  }
}

/** Refuses a symlink, or a file any other user may read or write. */
export async function checkPrivate(path: string): Promise<void> {
  let st
  try {
    st = await lstat(path)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new PrivateFileError('file_missing', `${path} does not exist`)
    }
    throw err
  }
  if (st.isSymbolicLink()) {
    throw new PrivateFileError('file_insecure', `${path} is a symlink`)
  }
  if ((st.mode & 0o077) !== 0) {
    throw new PrivateFileError(
      'file_insecure',
      `${path} is readable or writable by others (mode ${(st.mode & 0o777).toString(8)}); it must be 0600`,
    )
  }
}

export async function readPrivateJson<T>(path: string): Promise<T> {
  await checkPrivate(path)
  const text = await readFile(path, 'utf8')
  try {
    return JSON.parse(text) as T
  } catch {
    throw new PrivateFileError('file_corrupt', `${path} is not JSON`)
  }
}

/** Writes `value` to `path` whole: a 0600 temporary file, then a rename. */
export async function writePrivateJson(
  path: string,
  value: unknown,
  { exclusive = false } = {},
): Promise<void> {
  if (exclusive) {
    // `wx` fails if anything is at the path, a symlink included.
    const fh = await open(path, 'wx', 0o600)
    try {
      await fh.writeFile(JSON.stringify(value, null, 2) + '\n')
      await fh.sync()
    } finally {
      await fh.close()
    }
    return
  }
  const tmp = join(
    dirname(path),
    `.${basename(path)}.${randomBytes(6).toString('hex')}.tmp`,
  )
  const fh = await open(tmp, 'wx', 0o600)
  try {
    await fh.writeFile(JSON.stringify(value, null, 2) + '\n')
    await fh.sync()
  } finally {
    await fh.close()
  }
  try {
    await rename(tmp, path)
  } catch (err) {
    await unlink(tmp).catch(() => {})
    throw err
  }
}

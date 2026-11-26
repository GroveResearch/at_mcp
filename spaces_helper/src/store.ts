// A SimpleStore kept whole in one private JSON file, for one process.
// Writes are serialized, so a refresh and a login never interleave.
import { readPrivateJson, writePrivateJson, PrivateFileError } from './files.ts'

export class FileStore<V> {
  #chain: Promise<unknown> = Promise.resolve()
  constructor(readonly path: string) {}

  async #read(): Promise<Record<string, V>> {
    try {
      return await readPrivateJson<Record<string, V>>(this.path)
    } catch (err) {
      if (err instanceof PrivateFileError && err.code === 'file_missing') return {}
      throw err
    }
  }

  #serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.#chain.then(fn, fn)
    this.#chain = next.catch(() => {})
    return next
  }

  get(key: string): Promise<V | undefined> {
    return this.#serial(async () => (await this.#read())[key])
  }

  set(key: string, value: V): Promise<void> {
    return this.#serial(async () => {
      const all = await this.#read()
      all[key] = value
      await writePrivateJson(this.path, all)
    })
  }

  del(key: string): Promise<void> {
    return this.#serial(async () => {
      const all = await this.#read()
      if (!(key in all)) return
      delete all[key]
      await writePrivateJson(this.path, all)
    })
  }

  keys(): Promise<string[]> {
    return this.#serial(async () => Object.keys(await this.#read()))
  }
}

/** The same interface in memory, for state that lives only during a login. */
export class MemoryStore<V> {
  #map = new Map<string, V>()
  async get(key: string) { return this.#map.get(key) }
  async set(key: string, value: V) { this.#map.set(key, value) }
  async del(key: string) { this.#map.delete(key) }
}

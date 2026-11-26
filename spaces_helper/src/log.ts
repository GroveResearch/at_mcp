export type Log = (level: 'debug' | 'info' | 'warning' | 'error', message: string, meta?: Record<string, unknown>) => void

// Every failure the helper answers carries at_mcp's own classes
// (AtMcp.Effects.Failure): `refused` (the request was understood and turned
// down, nothing happened), `auth_refused` (the credential itself was refused)
// and `indeterminate` (the outcome is unknown: for a write, it may have
// happened). A `code` names the cause.
export type FailureClass = 'refused' | 'auth_refused' | 'indeterminate'

export class HelperError extends Error {
  constructor(
    readonly failureClass: FailureClass,
    readonly code: string,
    message: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message)
    this.name = 'HelperError'
  }
}

export const refused = (code: string, message: string, details?: Record<string, unknown>) =>
  new HelperError('refused', code, message, details)

export const authRefused = (code: string, message: string, details?: Record<string, unknown>) =>
  new HelperError('auth_refused', code, message, details)

export const indeterminate = (code: string, message: string, details?: Record<string, unknown>) =>
  new HelperError('indeterminate', code, message, details)

declare module 'pako' {
  export function gzip(data: string | Uint8Array): Uint8Array
  export function ungzip(data: string | Uint8Array, options: { to: 'string' }): string
  export function ungzip(data: string | Uint8Array): Uint8Array
}

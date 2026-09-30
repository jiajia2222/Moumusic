# Moumusic personal ID service

This service provides the Beans-style personal card used by the iOS app:

- a stable, unique public ID for each device;
- nickname, avatar URL, and signature;
- a server status card;
- administrator-only control of public downloads.

It does not store music-provider passwords or provider cookies. The iOS app
stores the opaque Moumusic session token in Keychain. The JSON datastore is
server-side only and is ignored by Git.

## Required server configuration

Copy `.env.example` to `.env` on the server and set:

```sh
MOUMUSIC_DATA_DIR=/var/lib/moumusic
MOUMUSIC_SERVER_ID=moumusic-main
MOUMUSIC_SERVER_VERSION=1.0.0
MOUMUSIC_ADMIN_USERNAME=your-admin-name
MOUMUSIC_ADMIN_ID=moumusic-admin
MOUMUSIC_ADMIN_PUBLIC_ID=moumusic-admin
MOUMUSIC_ADMIN_PASSWORD_HASH=...
MOUMUSIC_CORS_ORIGIN=https://music.nadev.xyz
```

Generate the password hash on a trusted machine. Do not put a plaintext
password in the repository, an IPA, or a public release:

```sh
node --input-type=module -e "import { makeAdminPasswordHash } from './src/moumusic-account.mjs'; console.log(makeAdminPasswordHash(process.argv[1]))" "your-password"
```

The optional `MOUMUSIC_SERVER_*` variables only describe the server in the
card. They are not used for authentication. Put the service behind HTTPS
before setting `MOUMUSIC_CORS_ORIGIN` and pointing the iOS `MOUMUSIC_SERVER_URL`
Info.plist value at it.

## API surface

```text
GET    /api/moumusic/config
POST   /api/moumusic/auth/register
POST   /api/moumusic/auth/admin/login
POST   /api/moumusic/auth/logout
GET    /api/moumusic/me
GET    /api/moumusic/profile/:id
PATCH  /api/moumusic/profile
GET    /api/moumusic/admin/settings
PATCH  /api/moumusic/admin/settings
GET    /api/moumusic/admin/users
PATCH  /api/moumusic/admin/users/:id
```

The `id` in a public profile is the visible public ID, not the internal
session user ID; internal IDs are never accepted by public profile routes.
IDs are case-insensitive and can contain 3–32 letters,
numbers, dots, underscores, or hyphens. Changing to an existing ID is
rejected with HTTP `409` and error code `PUBLIC_ID_CONFLICT`. The administrator
can update another user's ID, nickname, avatar, signature, or disabled state.

`MOUMUSIC_ADMIN_ID` remains the opaque server-side administrator identity;
`MOUMUSIC_ADMIN_PUBLIC_ID` is only its visible profile ID. A client-provided
ID never grants administrator access. Set these values on the server only.

All protected routes require `Authorization: Bearer <opaque-session-token>`.
The server returns sanitized profiles only; session hashes, device secrets,
and administrator credentials never appear in the response.

## Local verification

```sh
npm test
node --check src/server.mjs
node --check src/moumusic-account.mjs
```

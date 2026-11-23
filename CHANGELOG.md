# Changelog

Each entry is one version of this template. Breaking changes come first. Railway offers every merge to
`main` as an update to people who deployed the template; read the entry before you apply it.

## 0.14.0 (2026-11-23)

- First release: Archon 0.14.0 (`ghcr.io/coleam00/archon:0.14.0@sha256:2e63db617c76fa4ab8c86f20b32815993473d42609f56236a79ede3b23aaefa1`)
  with Railway Postgres.
- README: Deploy on Railway button for the published template `archon-2`.
- Archon's own login is on; the owner account is created on first boot from `ARCHON_ADMIN_EMAIL` and the
  generated `ARCHON_ADMIN_PASSWORD`. Signup stays closed.
- The trusted proxy identity header is renamed to a random value, so a client can't skip the login by
  sending `X-Archon-User`.
- `/.archon` (workspaces, worktrees, credential key and the agent CLIs' home) is on one Railway volume.

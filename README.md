# Archon on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/archon-2?utm_medium=integration&utm_source=button&utm_campaign=archon)

A one-click Railway template for [Archon](https://github.com/coleam00/Archon), the open-source harness
builder for AI coding: it runs Claude Code, Codex and Pi agents through repeatable YAML workflows (plan,
implement, validate, review, open a PR), with a web UI for chats, runs and approvals.

This repo is the template's source. Railway builds the `Archon` service from it, so when a new Archon
version is pinned here, everyone who deployed the template gets Railway's "update available" notice.

## What it deploys

| Service | What it does | Storage |
|---|---|---|
| **Archon** | Web UI and API on the public URL (`/api/health` is the health check). Built from this repo's `Dockerfile`: the official `ghcr.io/coleam00/archon:0.14.0` image pinned by digest, plus `railway-start.sh`. | Volume at `/.archon`: workspaces, worktrees, artifacts, the credential key and the agent CLIs' home (`~/.claude`, `~/.codex`, `~/.pi`, `~/.gitconfig`). |
| **Postgres** | Railway Postgres: conversations, workflow runs, users and logins. Archon creates and upgrades its schema on start. | Volume at `/var/lib/postgresql/data`. |

## Variables

| Variable | Default | Notes |
|---|---|---|
| `CLAUDE_API_KEY` | prompt | Your Anthropic API key (`sk-ant-api…`, from console.anthropic.com), or a Claude Pro/Max token from `claude setup-token` (`sk-ant-oat…`). Archon's default agent is Claude Code. |
| `ARCHON_ADMIN_EMAIL` | `admin@example.com` | Owner account login. Change it if you like; the account is created on first boot. |
| `ARCHON_ADMIN_PASSWORD` | generated | Owner password (in the service's Variables tab). Change it and redeploy to reset the password. |
| `BETTER_AUTH_SECRET` | generated | Signs login sessions. |
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | Private-network Postgres connection. |
| `PORT` | `3000` | Port Archon listens on. |

Optional, add them on the Archon service when you need them (see [Archon's configuration reference](https://archon.diy/reference/configuration/)):
`GH_TOKEN` (GitHub token for cloning private repos and opening PRs), `CODEX_API_KEY` (run Codex on an OpenAI
key), `OPENROUTER_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY` (Pi agent backends), `DEFAULT_AI_ASSISTANT`
(`claude`, `codex`, `pi` or `copilot`), `ARCHON_AUTH_ALLOWED_EMAILS` (invite teammates by email),
`MAX_CONCURRENT_CONVERSATIONS` (default 2 here), Slack/Telegram/Discord bot tokens, and
`BETTER_AUTH_URL=https://YOUR-DOMAIN` if you add a custom domain.

## After deploy

1. Open the Archon service's public URL and sign in with `ARCHON_ADMIN_EMAIL` and `ARCHON_ADMIN_PASSWORD`
   (Archon service → Variables).
2. Add a project: Settings → Projects, paste a GitHub URL (set `GH_TOKEN` for private repos).
3. Start a chat or run one of the bundled workflows (for example `archon-fix-github-issue`).

## How it's built

- `Dockerfile`: `FROM ghcr.io/coleam00/archon:<version>@sha256:<digest>` and the start script. No `VOLUME`,
  no `railway.json`: the health check (`/api/health`), restart policy and volume are set on the template.
- `railway-start.sh`:
  - keeps `/home/appuser` on the volume (`/.archon/home`), because Railway gives a service one volume;
  - creates the owner account with Archon bound to `127.0.0.1` only, makes it an Archon admin, and
    then starts Archon publicly with signup closed. A changed `ARCHON_ADMIN_PASSWORD` is applied on
    the next deploy and signs out old sessions;
  - sets `ARCHON_WEB_AUTH_HEADER` to a random name kept on the volume: Archon trusts that header as the
    signed-in user (for authenticating proxies), and Railway's edge would otherwise pass a client's
    `X-Archon-User` straight through;
  - sets `BETTER_AUTH_URL`/`WEB_UI_ORIGIN` from `RAILWAY_PUBLIC_DOMAIN`, `DEFAULT_AI_ASSISTANT=claude`
    and `MAX_CONCURRENT_CONVERSATIONS=2`, then runs the image's own entrypoint (which drops to the
    non-root `appuser`). If Archon stops, the container exits non-zero and Railway restarts it.

## Resources

Idle, Archon uses about 180 MB of RAM and fits Railway's 0.5 GB limit; each running agent (Claude Code,
Codex) adds a few hundred MB, so give the service 1–2 GB if you run workflows in parallel. The image is
large (about 1.3 GB compressed, it bundles git, gh, Chromium and the agent CLIs), so the first build takes
a few minutes. No Docker-in-Docker: agents run in git worktrees inside the container.

## Updating

Bump the `FROM` line (tag and digest together) in a pull request, add a `CHANGELOG.md` entry, and test it
on a scratch Railway project. A merge to `main` sends the update notice to deployers; Archon migrates its
Postgres schema on start, so no manual step is needed for minor versions.

Archon is MIT-licensed by Cole Medin and contributors. This template is not affiliated with the Archon project.

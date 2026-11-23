#!/bin/bash
# Archon on Railway: start script.
#  - keeps the whole state on the one Railway volume at /.archon (workspaces, worktrees, the credential
#    key, and the appuser home with Claude Code / Codex / Pi settings);
#  - turns on Archon's own login (Better Auth, Postgres) and creates the owner account on first boot,
#    before the public port opens, so the URL never serves an unclaimed install;
#  - stops Archon trusting a client-sent identity header (see "Identity header" below);
#  - then hands over to the image's entrypoint, which drops to the non-root appuser and starts Archon.
set -euo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] ERROR: $*" >&2; exit 1; }

BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-}"; ARCHON_ADMIN_PASSWORD="${ARCHON_ADMIN_PASSWORD:-}"
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is empty: it must reference the Postgres service"
[ "${#BETTER_AUTH_SECRET}" -ge 32 ] || die "BETTER_AUTH_SECRET must be at least 32 characters"
[ "${#ARCHON_ADMIN_PASSWORD}" -ge 12 ] || die "ARCHON_ADMIN_PASSWORD must be at least 12 characters"
export BETTER_AUTH_SECRET ARCHON_ADMIN_PASSWORD
export ARCHON_ADMIN_EMAIL="${ARCHON_ADMIN_EMAIL:-admin@example.com}"

# Login cookies and CSRF checks need the public https origin; Railway's proxy talks plain http to us.
# With a custom domain, set BETTER_AUTH_URL=https://YOUR-DOMAIN on the service.
if [ -z "${BETTER_AUTH_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export BETTER_AUTH_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
if [ -z "${WEB_UI_ORIGIN:-}" ] && [ -n "${BETTER_AUTH_URL:-}" ]; then export WEB_UI_ORIGIN="$BETTER_AUTH_URL"; fi

export PORT="${PORT:-3000}"
export HOST="${HOST:-0.0.0.0}"
# A Railway service has a few vCPUs and maybe 0.5 GB of RAM, not a workstation: keep parallel agent
# conversations low by default. Raise it with a MAX_CONCURRENT_CONVERSATIONS variable on bigger plans.
export MAX_CONCURRENT_CONVERSATIONS="${MAX_CONCURRENT_CONVERSATIONS:-2}"

# Claude: one variable takes either an Anthropic API key (sk-ant-api...) or a Claude subscription
# token from `claude setup-token` (sk-ant-oat...).
if [ -n "${CLAUDE_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  case "$CLAUDE_API_KEY" in
    sk-ant-oat*) export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_API_KEY"; unset CLAUDE_API_KEY
                 log "CLAUDE_API_KEY holds a Claude subscription token: using it as CLAUDE_CODE_OAUTH_TOKEN" ;;
  esac
fi

# --- Persistent home ------------------------------------------------------------------------------
# Railway gives a service one volume. Upstream persists both /.archon and /home/appuser, so the home
# lives in /.archon/home and /home/appuser points at it.
mkdir -p /.archon/workspaces /.archon/worktrees
if [ ! -d /.archon/home ]; then
  cp -a /home/appuser /.archon/home
  log "seeded /.archon/home from the image"
fi
if [ ! -L /home/appuser ]; then
  rm -r /home/appuser
  ln -s /.archon/home /home/appuser
fi
chown -h 1001:1001 /home/appuser

# --- Identity header ------------------------------------------------------------------------------
# Archon trusts a request header (X-Archon-User unless ARCHON_WEB_AUTH_HEADER names another) as the
# web user, for installs that sit behind an authenticating proxy, and it does so even with the login
# turned on. Railway's edge passes client headers through, so anyone could send that header and skip
# the login. Rename it to a random name kept on the volume, which nobody outside can know.
if [ -z "${ARCHON_WEB_AUTH_HEADER:-}" ]; then
  hf=/.archon/.railway-identity-header
  if [ ! -s "$hf" ]; then (umask 077; od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$hf"); fi
  export ARCHON_WEB_AUTH_HEADER="X-Archon-Private-$(cat "$hf")"
fi

# --- Owner account --------------------------------------------------------------------------------
# Archon's login has no first-run wizard and signup is closed by default. Create the owner account
# (role admin) from ARCHON_ADMIN_EMAIL / ARCHON_ADMIN_PASSWORD with Archon listening on localhost only,
# then start it publicly with signup still closed. A changed password variable is applied on the next
# deploy, which is also how you reset a lost password.
SETUP_PORT=3999
psql_q() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -v email="$ARCHON_ADMIN_EMAIL" "$@"; }

stop_setup_server() {
  if [ -n "${setup_pid:-}" ]; then
    kill -TERM -- "-$setup_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$setup_pid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$setup_pid" 2>/dev/null || true
    wait "$setup_pid" 2>/dev/null || true
    setup_pid=""
  fi
}

ensure_owner() {
  local marker=/.archon/.railway-owner want
  want=$(printf '%s\n%s\n' "$ARCHON_ADMIN_EMAIL" "$ARCHON_ADMIN_PASSWORD" | sha256sum | cut -c1-64)
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$want" ]; then
    log "owner account already set up"
    return 0
  fi

  # Wait for Postgres (Railway starts the services in parallel).
  for i in $(seq 1 60); do
    psql "$DATABASE_URL" -X -q -tAc 'select 1' >/dev/null 2>&1 && break
    [ "$i" = 60 ] && die "Postgres did not answer within 120 s"
    sleep 2
  done

  log "setting up the owner account (Archon on 127.0.0.1:$SETUP_PORT only)"
  setsid env HOST=127.0.0.1 PORT=$SETUP_PORT BETTER_AUTH_URL="http://127.0.0.1:$SETUP_PORT" \
    ARCHON_AUTH_ALLOWED_EMAILS="$ARCHON_ADMIN_EMAIL" ARCHON_AUTH_OPEN_SIGNUP= \
    /usr/local/bin/docker-entrypoint.sh > /tmp/archon-setup.log 2>&1 &
  setup_pid=$!
  trap stop_setup_server EXIT
  for i in $(seq 1 180); do
    curl -fsS -o /dev/null "http://127.0.0.1:$SETUP_PORT/api/health" 2>/dev/null && break
    if [ "$i" = 180 ] || ! kill -0 "$setup_pid" 2>/dev/null; then
      tail -n 40 /tmp/archon-setup.log >&2; die "Archon did not start for the owner setup"
    fi
    sleep 1
  done

  local exists
  exists=$(psql_q -tA <<'SQL'
select count(*) from remote_agent_auth_user where lower(email) = lower(:'email');
SQL
)
  if [ "$exists" = "0" ]; then
    local body code
    body=$(bun -e 'process.stdout.write(JSON.stringify({email: process.env.ARCHON_ADMIN_EMAIL, password: process.env.ARCHON_ADMIN_PASSWORD, name: "Owner"}))')
    code=$(curl -sS -o /tmp/archon-signup.json -w '%{http_code}' -X POST \
      "http://127.0.0.1:$SETUP_PORT/api/auth/sign-up/email" \
      -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$SETUP_PORT" --data-binary "$body")
    [ "$code" = "200" ] || { head -c 400 /tmp/archon-signup.json >&2; echo >&2; die "creating the owner account failed (HTTP $code)"; }
    log "owner account created for $ARCHON_ADMIN_EMAIL"
  else
    # Existing account: apply the current ARCHON_ADMIN_PASSWORD and sign out its old sessions.
    local hash
    hash=$(cd /app/packages/server && bun -e 'import { hashPassword } from "better-auth/crypto"; process.stdout.write(await hashPassword(process.env.ARCHON_ADMIN_PASSWORD));')
    [ -n "$hash" ] || die "hashing the password failed"
    psql_q -v hash="$hash" <<'SQL'
update remote_agent_auth_account set password = :'hash', "updatedAt" = now()
 where "providerId" = 'credential'
   and "userId" in (select id from remote_agent_auth_user where lower(email) = lower(:'email'));
delete from remote_agent_auth_session
 where "userId" in (select id from remote_agent_auth_user where lower(email) = lower(:'email'));
SQL
    log "owner password set from ARCHON_ADMIN_PASSWORD"
  fi

  # The owner is an Archon admin (new users are members), so it can act on every run.
  psql_q <<'SQL'
with a as (select id, name from remote_agent_auth_user where lower(email) = lower(:'email')),
missing as (select a.* from a where not exists (
  select 1 from remote_agent_user_identities i where i.platform = 'web' and i.platform_user_id = a.id)),
nu as (insert into remote_agent_users (display_name, role) select name, 'admin' from missing returning id)
insert into remote_agent_user_identities (user_id, platform, platform_user_id, platform_display_name)
select nu.id, 'web', missing.id, missing.name from nu, missing;
update remote_agent_users set role = 'admin'
 where id in (select user_id from remote_agent_user_identities
               where platform = 'web'
                 and platform_user_id in (select id from remote_agent_auth_user where lower(email) = lower(:'email')));
SQL

  stop_setup_server
  trap - EXIT
  for _ in $(seq 1 20); do curl -fs -o /dev/null "http://127.0.0.1:$SETUP_PORT/api/health" 2>/dev/null || break; sleep 1; done
  (umask 077; echo "$want" > "$marker")
  log "owner account ready (role admin)"
}
ensure_owner

# Hand over to the image's entrypoint. Signup stays closed unless you set ARCHON_AUTH_ALLOWED_EMAILS
# (invite list) or ARCHON_AUTH_OPEN_SIGNUP=true.
exec /usr/local/bin/docker-entrypoint.sh

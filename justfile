# Justfile for Fly.io deployment of the Rho umbrella.
#
# Required environment variables (loaded from .env):
#   NEON_URL              Neon Postgres connection string
#   SECRET_KEY_BASE       mix phx.gen.secret
#   OPENAI_API_KEY        ...and any other provider keys you use
#   PHX_HOST              e.g. rho.fly.dev (optional; defaults to fly.toml)
#
# Database is external (Neon) — no volume, no copy-db.

set dotenv-load := true

APP := "rho"

# Default recipe shows available commands.
default:
    @just --list

# Set all Fly.io secrets from current shell environment.
set-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Setting Fly.io secrets for {{APP}}..."
    fly secrets set --app "{{APP}}" \
        NEON_URL="${NEON_URL}" \
        SECRET_KEY_BASE="${SECRET_KEY_BASE}" \
        OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
        ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        FIREWORKS_API_KEY="${FIREWORKS_API_KEY:-}"
    echo "✓ Secrets set"

# Set a single secret.
set-secret name value:
    fly secrets set --app "{{APP}}" {{name}}="{{value}}"

# List current secrets.
list-secrets:
    fly secrets list --app "{{APP}}"

# Remove a secret.
remove-secret name:
    fly secrets unset --app "{{APP}}" {{name}}

# Create the Fly app (idempotent).
create-app:
    #!/usr/bin/env bash
    if fly apps list | grep -q "^{{APP}} "; then
        echo "✓ App {{APP}} already exists"
    else
        fly apps create "{{APP}}"
    fi

# Deploy.
deploy:
    fly deploy --app "{{APP}}"

# Run database migrations on the deployed release.
migrate:
    fly ssh console --app "{{APP}}" -C "/app/bin/rho_web eval 'RhoFrameworks.Release.migrate()'"

# Connect to a remote IEx session (auto-starts a stopped machine).
remote:
    #!/usr/bin/env bash
    set -euo pipefail
    MACHINE_INFO=$(fly machine list --app "{{APP}}" --json | jq -r '.[0]')
    MACHINE_ID=$(echo "$MACHINE_INFO" | jq -r '.id')
    MACHINE_STATE=$(echo "$MACHINE_INFO" | jq -r '.state')
    if [ "$MACHINE_STATE" != "started" ]; then
        echo "Machine is $MACHINE_STATE, starting..."
        fly machine start "$MACHINE_ID" --app "{{APP}}"
        sleep 5
    fi
    fly ssh console --app "{{APP}}" --pty -C "/app/bin/rho_web remote"

# App status / logs / open / restart.
status:
    fly status --app "{{APP}}"

logs:
    fly logs --app "{{APP}}"

open:
    fly open --app "{{APP}}"

restart:
    #!/usr/bin/env bash
    MACHINE_ID=$(fly machine list --app "{{APP}}" --json | jq -r '.[0].id')
    fly machine restart --app "{{APP}}" "$MACHINE_ID"

# First-time setup: create app → set secrets → deploy → migrate.
setup:
    just create-app
    just set-secrets
    just deploy
    just migrate
    @echo "✓ {{APP}} setup complete"

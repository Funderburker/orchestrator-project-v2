#!/bin/sh
# Wrapper for claude CLI that redirects requests to a local proxy (e.g. Kie.ai).
# Read key + URL from env — do NOT hardcode secrets here.
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://172.18.0.1:4100}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY before sourcing (see .env)}"
exec node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js "$@"

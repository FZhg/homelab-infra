#!/usr/bin/env bash
# Log in to OpenBao with this node's AppRole, read the KV paths its role is allowed to read,
# and write them to a root-only JSON file that Hiera uses as its top layer.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/homelab/openbao.env   # BAO_ADDR, ROLE_ID, SECRET_ID, SECRET_PATHS
OUT_DIR=/etc/puppetlabs/secrets

[ -n "${ROLE_ID:-}" ] || { echo "no AppRole credentials in /etc/homelab/openbao.env"; exit 1; }

token=$(curl -fsS -X POST "$BAO_ADDR/v1/auth/approle/login" \
  --data "$(jq -n --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id: $r, secret_id: $s}')" |
  jq -r '.auth.client_token')

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for path in $SECRET_PATHS; do
  curl -fsS -H "X-Vault-Token: $token" "$BAO_ADDR/v1/kv/data/$path" | jq '.data.data'
done | jq -s 'add // {}' > "$tmp"

# The token is short-lived anyway; revoke it so it can't be reused.
curl -fsS -X POST -H "X-Vault-Token: $token" "$BAO_ADDR/v1/auth/token/revoke-self" >/dev/null || true

install -d -m 0700 "$OUT_DIR"
install -m 0600 "$tmp" "$OUT_DIR/secrets.json"
echo "secrets refreshed: $(jq -r 'keys | join(", ")' "$OUT_DIR/secrets.json")"

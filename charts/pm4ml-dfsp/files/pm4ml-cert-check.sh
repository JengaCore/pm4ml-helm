#!/bin/sh
# DFSP side: watch this payment manager's client certificate, the one the hub
# signs in MCM.
#
# management-api asks MCM for a new client certificate 7 days before the current
# one expires. MCM notifies nobody, and the hub operator has to sign it. Unsigned
# at expiry, this DFSP can no longer send payments (it still receives them). This
# check reads, with the DFSP's own MCM credentials, what MCM holds for this DFSP:
#
#   renewal.pending  a renewal request waits for the hub's signature: tell the hub
#   cert.expiring    the signed certificate expires within WARN_DAYS
#   cert.expired     it has expired: no outgoing payments until a renewal is signed
#   cert.ok          nothing to do
#   check.failed     the check itself could not run (token, MCM, its answer)
#
# Exit status: 0 ok, 1 attention, 2 check failed. If ALERT_WEBHOOK_URL is set it
# posts a Slack-compatible message ({"text": ...}): Slack, Mattermost, Rocket.Chat,
# Teams workflows. With CHECK_INTERVAL_SECONDS it runs forever (Docker Compose),
# keeping ok / attention / failed in $STATUS_FILE for the container's healthcheck,
# re-reading SECRETS_ENV_FILE before each run (so a rotated client secret or a new
# webhook URL is picked up), and posting a check failure only on the first failed
# run after a good one.
#
# Environment: DFSP_ID, CLIENT_ID (default DFSP_ID), CLIENT_SECRET,
# CLIENT_SECRET_FILE or AUTH_CLIENT_SECRET, TOKEN_URL, MCM_URL (…/pm4mlapi),
# WARN_DAYS (14), CA_FILE (private CA of the switch's hosts), ALERT_WEBHOOK_URL or
# ALERT_WEBHOOK_URL_FILE, SECRETS_ENV_FILE, CHECK_INTERVAL_SECONDS,
# STATUS_FILE (/tmp/cert-status).
set -eu

DFSP="${DFSP_ID:?DFSP_ID is required}"
CID="${CLIENT_ID:-$DFSP}"
TOKEN_URL="${TOKEN_URL:?TOKEN_URL is required}"
MCM="${MCM_URL:?MCM_URL is required}"
WARN_DAYS="${WARN_DAYS:-14}"
STATUS_FILE="${STATUS_FILE:-/tmp/cert-status}"

emit() { # event, msg
  printf '{"ts":"%s","component":"pm4ml-cert-check","event":"%s","dfsp":"%s","msg":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$DFSP" \
    "$(printf '%s' "$2" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
c() { curl -sS --max-time 30 ${CA_FILE:+--cacert "$CA_FILE"} "$@"; }

load_secrets() { # the client secret and the webhook URL, read again on every run
  if [ -n "${SECRETS_ENV_FILE:-}" ] && [ -r "$SECRETS_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090  # rendered by Vault Agent at run time
    . "$SECRETS_ENV_FILE"
    set +a
  fi
  secret="${CLIENT_SECRET:-${AUTH_CLIENT_SECRET:-}}"
  [ -z "${CLIENT_SECRET_FILE:-}" ] || secret="$(cat "$CLIENT_SECRET_FILE")"
  hook="${ALERT_WEBHOOK_URL:-}"
  [ -z "${ALERT_WEBHOOK_URL_FILE:-}" ] || hook="$(cat "$ALERT_WEBHOOK_URL_FILE" 2>/dev/null || true)"
}

notify() { # text
  [ -n "${hook:-}" ] || return 0
  # Not c(): CA_FILE is the switch's private CA and would replace the public trust
  # store that Slack, Teams and similar webhooks need.
  curl -sS --max-time 30 -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg t "$1" '{text: $t}')" "$hook" \
    || emit "notify.failed" "could not post to the alert webhook"
}

failed() { # msg -> status 2
  emit "check.failed" "$1"
  failure_msg="$1"
  return 2
}

check() { # -> 0 ok, 1 attention, 2 the check failed
  load_secrets
  [ -n "$secret" ] || { failed "no client secret (CLIENT_SECRET, CLIENT_SECRET_FILE or AUTH_CLIENT_SECRET)"; return 2; }
  tok="$(c -X POST "$TOKEN_URL" -d grant_type=client_credentials --data-urlencode "client_id=$CID" \
           --data-urlencode "client_secret=$secret" | jq -r '.access_token // empty' 2>/dev/null || true)"
  [ -n "$tok" ] || { failed "no token from $TOKEN_URL (client secret rotated? Keycloak unreachable?)"; return 2; }
  out="$(c -w '\n%{http_code}' -H "Authorization: Bearer $tok" \
           "$MCM/dfsps/$(jq -rn --arg x "$DFSP" '$x|@uri')/enrollments/inbound" || printf '\n000')"
  code="$(printf '%s' "$out" | tail -n1)"
  [ "$code" = 200 ] || { failed "MCM answered HTTP $code"; return 2; }
  body="$(printf '%s' "$out" | sed '$d')"
  # A parse error must not read as "nothing signed yet": that would silence the alert.
  if ! expiry="$(printf '%s' "$body" | jq -er '[.[]? | select(.state=="CERT_SIGNED") | .certInfo.notAfter // empty
             | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdate] | max // ""' 2>&1)" \
     || ! pending="$(printf '%s' "$body" | jq -er '[.[]? | select(.state=="CSR_LOADED") | .id] | join(" ")' 2>&1)"; then
    failed "cannot read MCM's answer: ${expiry:-} ${pending:-}"; return 2
  fi
  now="$(date -u +%s)"
  if [ -z "$expiry" ]; then
    emit "awaiting.signature" "first enrolment not signed yet${pending:+ (request $pending)}"
    return 0
  fi
  days=$(( (expiry - now) / 86400 ))
  until_s="$(date -u -d "@$expiry" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$expiry")"
  rc=0
  if [ -n "$pending" ]; then
    emit "renewal.pending" "renewal request $pending waits for the hub's signature in MCM; current certificate expires $until_s ($days days)"
    notify "[$DFSP] Payment manager client certificate renewal waits for the hub's signature (MCM request $pending). The current certificate expires $until_s ($days days); unsigned by then, outgoing payments stop. Ask the hub operator to sign it."
    rc=1
  fi
  if [ "$expiry" -le "$now" ]; then
    emit "cert.expired" "client certificate expired $until_s: outgoing payments fail until a renewal is signed"
    notify "[$DFSP] Payment manager client certificate EXPIRED $until_s: outgoing payments fail until the hub signs the renewal."
    rc=1
  elif [ "$days" -lt "$WARN_DAYS" ]; then
    emit "cert.expiring" "client certificate expires $until_s ($days days)"
    [ -n "$pending" ] || notify "[$DFSP] Payment manager client certificate expires $until_s ($days days). The payment manager requests a renewal 7 days before; the hub has to sign it."
    rc=1
  else
    emit "cert.ok" "expires $until_s ($days days)"
  fi
  return $rc
}

failure_note() {
  notify "[$DFSP] The payment manager's certificate check cannot run: ${failure_msg:-unknown}. Until it runs again, a renewal waiting for the hub's signature goes unnoticed."
}

if [ -z "${CHECK_INTERVAL_SECONDS:-}" ]; then # one run (Kubernetes CronJob)
  rc=0; check || rc=$?
  [ "$rc" -ne 2 ] || failure_note
  exit "$rc"
fi
while :; do
  rc=0; check || rc=$?
  last="$(cat "$STATUS_FILE" 2>/dev/null || true)"
  case "$rc" in
    0) echo ok > "$STATUS_FILE" ;;
    1) echo attention > "$STATUS_FILE" ;;
    *) [ "$last" = failed ] || failure_note; echo failed > "$STATUS_FILE" ;;
  esac
  sleep "$CHECK_INTERVAL_SECONDS"
done

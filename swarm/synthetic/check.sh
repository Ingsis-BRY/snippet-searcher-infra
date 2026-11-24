#!/bin/sh
# Synthetic check: every CHECK_INTERVAL seconds, create, read and delete a snippet through the API,
# like a user would, and report the result to New Relic as metrics:
#   snippet_searcher.synthetic.success      1 when every step passed, 0 otherwise
#   snippet_searcher.synthetic.duration_ms  total time of the three calls
# Each run also prints one JSON line to stdout (`docker service logs snippet-searcher_synthetic-check`).
#
# It authenticates as an Auth0 machine-to-machine application authorized for the API
# (read:snippets, write:snippets), so it exercises the same JWT validation as the UI.

set -u

: "${BASE_URL:=http://snippet-service:8080}"
: "${CHECK_INTERVAL:=60}"
: "${CHECK_ENVIRONMENT:=unknown}"
: "${LANGUAGE_VERSION:=1.1}"
: "${NEW_RELIC_METRIC_API:=https://metric-api.newrelic.com/metric/v1}"
: "${AUTH0_DOMAIN:?AUTH0_DOMAIN must be set}"
: "${AUTH0_AUDIENCE:?AUTH0_AUDIENCE must be set}"
: "${SYNTHETIC_CLIENT_ID:?SYNTHETIC_CLIENT_ID must be set}"

CLIENT_SECRET="$(cat /run/secrets/SYNTHETIC_CLIENT_SECRET)"
NR_KEY="$(cat /run/secrets/NEW_RELIC_LICENSE_KEY 2>/dev/null || true)"
BODY=/tmp/synthetic-body

token=""
token_expires_at=0

log() { # status step detail duration_ms
    jq -nc --arg env "$CHECK_ENVIRONMENT" --arg status "$1" --arg step "$2" --arg detail "$3" --argjson ms "$4" \
        '{"check":"synthetic","environment":$env,"status":$status,"step":$step,"detail":$detail,"duration_ms":$ms}'
}

report() { # success(0|1) duration_ms failed_step
    [ -n "$NR_KEY" ] || return 0
    now="$(date +%s)"
    payload="$(jq -nc --argjson ok "$1" --argjson ms "$2" --arg step "$3" --arg env "$CHECK_ENVIRONMENT" --argjson ts "$now" \
        '[{"common":{"timestamp":$ts,"attributes":{"environment":$env,"failed_step":$step,"service":"synthetic-check"}},
           "metrics":[{"name":"snippet_searcher.synthetic.success","type":"gauge","value":$ok},
                      {"name":"snippet_searcher.synthetic.duration_ms","type":"gauge","value":$ms}]}]')"
    curl -sS -o /dev/null --max-time 10 -X POST "$NEW_RELIC_METRIC_API" \
        -H "Api-Key: $NR_KEY" -H 'Content-Type: application/json' -d "$payload" \
        || echo '{"check":"synthetic","status":"warn","detail":"could not send metrics to New Relic"}'
}

fetch_token() {
    now="$(date +%s)"
    [ -n "$token" ] && [ "$now" -lt $((token_expires_at - 60)) ] && return 0
    request="$(jq -nc --arg id "$SYNTHETIC_CLIENT_ID" --arg secret "$CLIENT_SECRET" --arg aud "$AUTH0_AUDIENCE" \
        '{"grant_type":"client_credentials","client_id":$id,"client_secret":$secret,"audience":$aud}')"
    response="$(curl -sS --max-time 10 -X POST "https://$AUTH0_DOMAIN/oauth/token" \
        -H 'Content-Type: application/json' -d "$request")" || return 1
    token="$(printf '%s' "$response" | jq -r '.access_token // empty')"
    expires_in="$(printf '%s' "$response" | jq -r '.expires_in // 0')"
    [ -n "$token" ] || return 1
    token_expires_at=$((now + expires_in))
}

# call METHOD PATH [JSON]: sets $status and adds the call's time to $elapsed_ms
call() {
    if [ $# -ge 3 ]; then
        out="$(curl -sS -o "$BODY" -w '%{http_code} %{time_total}' --max-time 15 -X "$1" "$BASE_URL$2" \
            -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$3")" || out="000 0"
    else
        out="$(curl -sS -o "$BODY" -w '%{http_code} %{time_total}' --max-time 15 -X "$1" "$BASE_URL$2" \
            -H "Authorization: Bearer $token")" || out="000 0"
    fi
    status="${out%% *}"
    seconds="${out#* }"
    elapsed_ms=$((elapsed_ms + $(awk "BEGIN { printf \"%d\", $seconds * 1000 }")))
}

run_once() {
    elapsed_ms=0
    if ! fetch_token; then
        log fail token "could not get an Auth0 token" 0; report 0 0 token; return
    fi

    name="synthetic-$(date +%s)"
    create="$(jq -nc --arg name "$name" --arg version "$LANGUAGE_VERSION" \
        '{"name":$name,"description":"synthetic check","language":"printscript","languageVersion":$version,"content":"println(\"synthetic\");"}')"
    call POST /snippets "$create"
    if [ "$status" != "201" ]; then
        log fail create "HTTP $status" "$elapsed_ms"; report 0 "$elapsed_ms" create; return
    fi
    id="$(jq -r '.id' "$BODY")"

    call GET "/snippets/$id"
    if [ "$status" != "200" ]; then
        log fail read "HTTP $status" "$elapsed_ms"; report 0 "$elapsed_ms" read
        call DELETE "/snippets/$id"
        return
    fi

    call DELETE "/snippets/$id"
    if [ "$status" != "204" ] && [ "$status" != "200" ]; then
        log fail delete "HTTP $status" "$elapsed_ms"; report 0 "$elapsed_ms" delete; return
    fi

    log ok all "" "$elapsed_ms"
    report 1 "$elapsed_ms" ""
}

while true; do
    run_once
    sleep "$CHECK_INTERVAL"
done

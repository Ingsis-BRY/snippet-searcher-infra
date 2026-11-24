#!/usr/bin/env bash
# Creates the New Relic alert policy for one environment, with its NRQL conditions, through NerdGraph.
# Run it once per environment from any machine (it doesn't touch the VM):
#
#   NEW_RELIC_API_KEY=<user key, NRAK-...> NEW_RELIC_ACCOUNT_ID=<account id> \
#   scripts/newrelic-alerts.sh dev
#
# The key is read from the environment and never printed. If the policy already exists it stops, so
# running it twice doesn't duplicate conditions (delete the policy in New Relic to recreate it).
# Notifications (email, Slack) are attached in New Relic: Alerts > Workflows, filtering by this policy.
#
# What it watches (the SLOs are in the README):
#   1. Synthetic check failing      snippet_searcher.synthetic.success < 1 for 3 minutes
#      ... or silent                no synthetic data for 5 minutes (the check itself is down)
#   2. API errors                   more than 5% of snippet-service-<env> transactions fail, for 5 minutes
#   3. API latency                  p95 of snippet-service transactions above 2 s, for 5 minutes
#   4. Background processing        worker logs more than 5 ERROR lines in 5 minutes

# The GraphQL documents below use NerdGraph variables ($account, $name, ...) inside single quotes on
# purpose: the shell must not expand them, jq passes their values separately.
# shellcheck disable=SC2016

set -euo pipefail

ENVIRONMENT="${1:-}"
if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" ]]; then
    echo "Usage: $0 dev|prod" >&2
    exit 1
fi
for var in NEW_RELIC_API_KEY NEW_RELIC_ACCOUNT_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var is not set." >&2
        exit 1
    fi
done
for tool in curl jq; do
    command -v "$tool" >/dev/null || { echo "Error: $tool is required." >&2; exit 1; }
done

ENDPOINT="${NEW_RELIC_GRAPHQL_URL:-https://api.newrelic.com/graphql}"
POLICY_NAME="Snippet Searcher ($ENVIRONMENT)"
ACCOUNT_ID="$NEW_RELIC_ACCOUNT_ID"

# nerdgraph QUERY VARIABLES_JSON -> prints the response, fails on GraphQL errors
nerdgraph() {
    local body response
    body="$(jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
    response="$(curl -sS --fail-with-body -X POST "$ENDPOINT" \
        -H "API-Key: $NEW_RELIC_API_KEY" -H 'Content-Type: application/json' -d "$body")"
    if [[ "$(jq '.errors // [] | length' <<<"$response")" != "0" ]]; then
        echo "NerdGraph error: $(jq -c '.errors' <<<"$response")" >&2
        exit 1
    fi
    printf '%s' "$response"
}

existing="$(nerdgraph 'query($account: Int!, $name: String) {
  actor { account(id: $account) { alerts { policiesSearch(searchCriteria: {name: $name}) { policies { id name } } } } }
}' "$(jq -nc --argjson account "$ACCOUNT_ID" --arg name "$POLICY_NAME" '{account: $account, name: $name}')" \
    | jq -r --arg name "$POLICY_NAME" '.data.actor.account.alerts.policiesSearch.policies[] | select(.name == $name) | .id' | head -n1)"
if [[ -n "$existing" ]]; then
    echo "Policy '$POLICY_NAME' already exists (id $existing). Delete it in New Relic to recreate it."
    exit 0
fi

policy_id="$(nerdgraph 'mutation($account: Int!, $name: String!) {
  alertsPolicyCreate(accountId: $account, policy: {name: $name, incidentPreference: PER_CONDITION}) { id }
}' "$(jq -nc --argjson account "$ACCOUNT_ID" --arg name "$POLICY_NAME" '{account: $account, name: $name}')" \
    | jq -r '.data.alertsPolicyCreate.id')"
echo "Created policy '$POLICY_NAME' (id $policy_id)."

# condition NAME NRQL OPERATOR THRESHOLD DURATION_SECONDS [EXPIRATION_SECONDS]
condition() {
    local vars
    vars="$(jq -nc --argjson account "$ACCOUNT_ID" --arg policy "$policy_id" --arg name "$1" --arg nrql "$2" \
        --arg operator "$3" --argjson threshold "$4" --argjson duration "$5" --arg expiration "${6:-}" '{
        account: $account, policy: $policy,
        condition: ({
          name: $name, enabled: true,
          nrql: {query: $nrql},
          signal: {aggregationWindow: 60, aggregationMethod: "EVENT_FLOW", aggregationDelay: 120},
          terms: [{priority: "CRITICAL", operator: $operator, threshold: $threshold,
                   thresholdDuration: $duration, thresholdOccurrences: "ALL"}],
          violationTimeLimitSeconds: 86400
        } + (if $expiration == "" then {} else
              {expiration: {expirationDuration: ($expiration | tonumber), openViolationOnExpiration: true, closeViolationsOnExpiration: false}}
             end))
      }')"
    nerdgraph 'mutation($account: Int!, $policy: ID!, $condition: AlertsNrqlConditionStaticInput!) {
      alertsNrqlConditionStaticCreate(accountId: $account, policyId: $policy, condition: $condition) { id name }
    }' "$vars" | jq -r '.data.alertsNrqlConditionStaticCreate | "  + \(.name) (id \(.id))"'
}

condition "Synthetic check failing or silent" \
    "SELECT latest(snippet_searcher.synthetic.success) FROM Metric WHERE environment = '$ENVIRONMENT'" \
    BELOW 1 180 300
condition "API error rate above 5%" \
    "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = 'snippet-service-$ENVIRONMENT'" \
    ABOVE 5 300
condition "API p95 latency above 2 s" \
    "SELECT percentile(duration, 95) FROM Transaction WHERE appName = 'snippet-service-$ENVIRONMENT'" \
    ABOVE 2 300
condition "Background worker errors" \
    "SELECT count(*) FROM Log WHERE entity.name = 'snippet-worker-$ENVIRONMENT' AND level = 'ERROR'" \
    ABOVE 5 300

echo "Done. Attach notifications in New Relic: Alerts > Workflows > filter by policy '$POLICY_NAME'."

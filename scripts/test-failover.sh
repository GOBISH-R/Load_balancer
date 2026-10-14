#!/usr/bin/env bash
# Failover test: stop the whole backend-1 EC2 instance while sending traffic through
# Nginx, confirm backend-2 serves everything, start backend-1, confirm sharing resumes.
# Usage: ./scripts/test-failover.sh [REQUESTS]
# Requires: terraform outputs from ../terraform, AWS CLI, curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
REQUESTS="${1:-20}"
URL="$(terraform -chdir="$TF_DIR" output -raw app_url)"
INSTANCE_ID="$(terraform -chdir="$TF_DIR" output -json backend_instance_ids | sed -E 's/.*"backend-1":"([^"]+)".*/\1/')"
REGION="$(aws configure get region || echo ap-south-1)"

total_fail=0

request() {
  local out status backend upstream ms
  out=$(curl -s -o /dev/null -D - --max-time 15 -H 'Accept: */*' \
        -w 'STATUS:%{http_code} TIME:%{time_total}\n' "$URL" 2>/dev/null || true)
  status=$(sed -n 's/^STATUS:\([0-9]*\).*/\1/p' <<<"$out")
  ms=$(sed -n 's/.*TIME:\([0-9.]*\).*/\1/p' <<<"$out" | awk '{printf "%d", $1 * 1000}')
  backend=$(grep -i '^x-backend-server:' <<<"$out" | cut -d' ' -f2- | tr -d '\r' || true)
  upstream=$(grep -i '^x-upstream-addr:' <<<"$out" | cut -d' ' -f2- | tr -d '\r' || true)
  printf '  %s  %s  %-10s upstream=%-32s %5s ms\n' "$(date +%T)" "${status:-000}" "${backend:--}" "${upstream:--}" "${ms:-0}"
  LAST_BACKEND="$backend"
  [[ "$status" == "200" ]] || total_fail=$((total_fail + 1))
}

state() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

echo "Failover test against $URL (backend-1 = $INSTANCE_ID, region $REGION)"

echo; echo "== 1. Baseline (both up)"
for _ in $(seq 1 "$REQUESTS"); do request; done

echo; echo ">> Stopping backend-1 instance $INSTANCE_ID"
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
echo "== 2. During shutdown"
n=0
while true; do
  request; n=$((n + 1))
  if (( n % 5 == 0 )) && [[ "$(state)" == "stopped" ]]; then break; fi
  sleep 0.5
done

echo; echo "== 3. Backend-1 stopped"
for _ in $(seq 1 "$REQUESTS"); do request; done

echo; echo ">> Starting backend-1 instance $INSTANCE_ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
echo "== 4. During recovery"
LAST_BACKEND=""
until [[ "$LAST_BACKEND" == "backend-1" ]]; do request; sleep 0.5; done

echo; echo "== 5. After recovery"
for _ in $(seq 1 "$REQUESTS"); do request; done

echo
if (( total_fail == 0 )); then
  echo "Overall: PASSED (0 failed requests)"
else
  echo "Overall: FAILED ($total_fail failed requests)"
  exit 1
fi

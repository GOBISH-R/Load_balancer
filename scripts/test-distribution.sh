#!/usr/bin/env bash
# Sends repeated requests through the Nginx proxy and shows how they were distributed.
# Usage: ./scripts/test-distribution.sh [URL] [COUNT]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-$(terraform -chdir="$SCRIPT_DIR/../terraform" output -raw app_url)}"
COUNT="${2:-20}"

declare -A hits=()
failures=0

echo "Sending $COUNT requests to $URL"
for i in $(seq 1 "$COUNT"); do
  out=$(curl -s -o /dev/null -D - --max-time 15 -H 'Accept: */*' \
        -w 'STATUS:%{http_code} TIME:%{time_total}\n' "$URL" 2>/dev/null || true)
  status=$(sed -n 's/^STATUS:\([0-9]*\).*/\1/p' <<<"$out")
  ms=$(sed -n 's/.*TIME:\([0-9.]*\).*/\1/p' <<<"$out" | awk '{printf "%d", $1 * 1000}')
  backend=$(grep -i '^x-backend-server:' <<<"$out" | cut -d' ' -f2- | tr -d '\r' || true)
  upstream=$(grep -i '^x-upstream-addr:' <<<"$out" | cut -d' ' -f2- | tr -d '\r' || true)

  printf '%3d. %s  %-10s upstream=%-32s %5s ms\n' "$i" "${status:-000}" "${backend:--}" "${upstream:--}" "${ms:-0}"
  if [[ "$status" == "200" && -n "$backend" ]]; then
    hits[$backend]=$(( ${hits[$backend]:-0} + 1 ))
  else
    failures=$((failures + 1))
  fi
done

echo
echo "Distribution:"
for b in "${!hits[@]}"; do
  printf '  %-10s %d\n' "$b" "${hits[$b]}"
done | sort
printf '  %-10s %d\n' "failed" "$failures"

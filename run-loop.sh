#!/usr/bin/env bash
# Optional external harness from the original brief: owns a wall clock and relaunches Claude Code
# one iteration at a time until time's up. Each run does ONE step per DIRECTIVE.md, then exits.
#
# NOTE: BrownBear's autonomous loop normally runs via the agent's own ScheduleWakeup mechanism,
# which ships reviewed PRs and keeps CI green. This script is provided for parity with the brief;
# run it only if you want the external-harness flavor (it commits + pushes unattended).
#
#   git switch -c autonomous-loop
#   chmod +x run-loop.sh
#   ./run-loop.sh        # 10 hours;  ./run-loop.sh 6  for 6
set -uo pipefail
HOURS="${1:-10}"
PROMPT_FILE="DIRECTIVE.md"
END=$(( $(date +%s) + HOURS * 3600 ))
mkdir -p loop-logs
i=0
while [ "$(date +%s)" -lt "$END" ]; do
  i=$((i + 1)); left=$(( (END - $(date +%s)) / 60 ))
  echo "=== iter $i | ${left} min left | $(date) ==="
  claude -p "$(cat "$PROMPT_FILE")

Iteration $i, about ${left} min left. Do exactly ONE step per the protocol, then stop." \
    --permission-mode acceptEdits \
    --allowedTools "Read,Edit,Write,Bash" \
    --output-format json 2>&1 | tee "loop-logs/iter-$i.log" || true
  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -m "loop checkpoint $i" && git push || true
  fi
  sleep 5
done
echo "done: $i iterations"

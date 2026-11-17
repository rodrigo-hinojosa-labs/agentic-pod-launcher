#!/bin/bash
# T067: el render completo de un agent.yml de modo docker sin repositorio y el de uno
# de modo local, desde la rama y desde la copia de origin/main (T003), no deben tener
# diferencias en ningun archivo derivado; el crontab de heartbeatctl reload tampoco.
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
S="${BR046_WORK:-$HOME/.cache/agentic-046}"
BASE="$S/base"
W="${BR046_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WORK="$S/t067-work"
rm -rf "$WORK"
mkdir -p "$WORK/bin"
[ "$(git -C "$BASE" rev-parse HEAD)" = "10f22a7e1e802c3cafb0fe351a5bc3f3b7fbdc1b" ] || { echo "base is not 10f22a7"; exit 1; }

printf '#!/bin/sh\necho "2.1.0 (Claude Code)"\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/claude"

render() {  # SRC MODE OUT  (renders at one fixed path so absolute paths match, then moves)
  local src="$1" mode="$2" out="$3" r="$WORK/ws"
  rm -rf "$r"
  mkdir -p "$r"
  cp -R "$src/scripts" "$src/modules" "$r/"
  [ -d "$src/docker" ] && cp -R "$src/docker" "$r/"
  cp "$src/setup.sh" "$src/VERSION" "$r/" 2> /dev/null || cp "$src/setup.sh" "$r/"
  cp "$BASE/tests/fixtures/sample-agent.yml" "$r/agent.yml"
  if [ "$mode" = "local" ]; then
    yq -i ".deployment.mode = \"local\" | .deployment.claude_cli = \"$WORK/bin/claude\"" "$r/agent.yml"
  fi
  : > "$r/.env"
  (cd "$r" && echo n | ./setup.sh --regenerate > "$out.out" 2>&1)
  echo "rc=$? ($src $mode)" >> "$WORK/rc.txt"
  mv "$r" "$out"
}

status=0
for mode in docker local; do
  render "$BASE" "$mode" "$WORK/base-$mode"
  render "$W" "$mode" "$WORK/branch-$mode"
  # Derived files only: leave out the inputs (agent.yml backfilled by design, .env)
  # and the copied launcher trees, which differ by construction.
  if diff -r -x agent.yml -x agent.yml.prev -x .env -x scripts -x modules -x docker -x setup.sh -x VERSION -x .state \
       "$WORK/base-$mode" "$WORK/branch-$mode" > "$WORK/diff-$mode.txt"; then
    echo "$mode: derived files identical"
  else
    echo "$mode: DIFFERENCES (see $WORK/diff-$mode.txt)"; status=1
  fi
  # Rendered scripts under scripts/ that are derived (local units, heartbeat.conf).
  for f in scripts/heartbeat/heartbeat.conf; do
    if [ -f "$WORK/base-$mode/$f" ] || [ -f "$WORK/branch-$mode/$f" ]; then
      cmp -s "$WORK/base-$mode/$f" "$WORK/branch-$mode/$f" && echo "$mode: $f identical" || { echo "$mode: $f DIFFERS"; status=1; }
    fi
  done
  if [ -d "$WORK/base-$mode/scripts/local" ] || [ -d "$WORK/branch-$mode/scripts/local" ]; then
    diff -r "$WORK/base-$mode/scripts/local" "$WORK/branch-$mode/scripts/local" > "$WORK/diff-$mode-local.txt" \
      && echo "$mode: scripts/local identical" || { echo "$mode: scripts/local DIFFERS"; status=1; }
  fi
done

# Crontab from heartbeatctl reload: docker agent without repo, with and without a fork.
for case in nodest fork; do
  for side in base branch; do
    src="$BASE"; [ "$side" = branch ] && src="$W"
    ws="$WORK/cron-$case-$side"
    mkdir -p "$ws/scripts/heartbeat/logs"
    if [ "$case" = fork ]; then
      cp "$W/tests/fixtures/backup-repo/agent-fork.yml" "$ws/agent.yml"
    else
      cp "$BASE/tests/fixtures/sample-agent.yml" "$ws/agent.yml"
    fi
    HEARTBEATCTL_WORKSPACE="$ws" HEARTBEATCTL_CRONTAB_FILE="$ws/crontab" \
    HEARTBEATCTL_LIB_DIR="$src/docker/scripts/lib" \
      bash "$src/docker/scripts/heartbeatctl" reload > "$ws/reload.out" 2>&1
  done
  cmp -s "$WORK/cron-$case-base/crontab" "$WORK/cron-$case-branch/crontab" \
    && echo "crontab $case: identical" || { echo "crontab $case: DIFFERS"; status=1; }
done
cat "$WORK/rc.txt"
exit $status

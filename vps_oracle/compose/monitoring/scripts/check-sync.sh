#!/usr/bin/env bash
# Emit a node-exporter textfile metric reporting whether the two-account Claude
# config mirror (~/.claude -> ~/.claude-configs/sub2 symlink mirror) is in sync.
# Runs on the HOST via cron (not in any container: it reads ~/.claude which
# holds .credentials.json). Output goes to the node-exporter textfile dir.
set -u

MAIN=/home/ubuntu/.claude
SUB2=/home/ubuntu/.claude-configs/sub2
OUT=/etc/monitoring/node-exporter-textfile/claude_config_mirror.prom
TMP="${OUT}.tmp.$$"

missing=""
guard_bad=""

# Every top-level entry in ~/.claude must be mirrored into sub2 as a symlink
# pointing back to ~/.claude/<same-name>. The one deliberate exception is
# .credentials.json (per-account login token — never mirrored).
while IFS= read -r -d '' e; do
  name=$(basename "$e")
  [ "$name" = ".credentials.json" ] && continue
  target="$SUB2/$name"
  if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$MAIN/$name" ]; then
    missing="$missing,$name"
  fi
done < <(find "$MAIN" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# Guards: sub2's identity files must stay real files, not symlinks to ~/.claude.
for id in .credentials.json .claude.json; do
  if [ -L "$SUB2/$id" ]; then
    guard_bad="$guard_bad,$id"
  fi
done

drift=0
[ -n "$missing" ] && drift=1
[ -n "$guard_bad" ] && drift=1

{
  echo "# HELP claude_config_mirror_drift 1 if ~/.claude has top-level entries not mirrored to sub2 (or an identity guard is violated), 0 if in sync"
  echo "# TYPE claude_config_mirror_drift gauge"
  echo "claude_config_mirror_drift $drift"
  if [ -n "$missing" ]; then
    echo "# HELP claude_config_mirror_missing_entry 1 for each ~/.claude entry lacking a sub2 mirror symlink"
    echo "# TYPE claude_config_mirror_missing_entry gauge"
    for n in ${missing#,}; do
      echo "claude_config_mirror_missing_entry{entry=\"$n\"} 1"
    done
  fi
} > "$TMP"
mv "$TMP" "$OUT"

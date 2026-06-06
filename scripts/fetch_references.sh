#!/usr/bin/env bash
#
# fetch_references.sh — clone the study references into a git-ignored ./.references/
#
# We learn architecture from these repos; we do NOT vendor their (GPL/AGPL) source into
# BrownBear's MIT tree. They are cloned shallow, outside version control. Runestone is MIT and
# is consumed as a SwiftPM dependency (see project.yml), not via this script.
#
# Usage:  ./scripts/fetch_references.sh           # clone/update all
#         ./scripts/fetch_references.sh chromium  # just one
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/.references"
mkdir -p "$DEST"

log() { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }

clone_shallow() {
  local name="$1" url="$2"
  if [ -d "$DEST/$name/.git" ]; then
    log "$name: updating"; git -C "$DEST/$name" pull --ff-only --depth 1 || true
  else
    log "$name: cloning (shallow)"; git clone --depth 1 "$url" "$DEST/$name"
  fi
}

clone_chromium_ios() {
  # Chromium is multi-GB; sparse-checkout ONLY the iOS browser UI we study.
  local name="chromium" dir="$DEST/chromium"
  if [ -d "$dir/.git" ]; then
    log "chromium: updating sparse ios"; git -C "$dir" pull --ff-only || true; return
  fi
  log "chromium: sparse shallow clone of ios/chrome/browser/ui (large, be patient)"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/chromium/chromium.git "$dir"
  git -C "$dir" sparse-checkout set ios/chrome/browser/ui
}

target="${1:-all}"
case "$target" in
  chromium)   clone_chromium_ios ;;
  scriptcat)  clone_shallow scriptcat  https://github.com/scriptscat/scriptcat.git ;;
  userscripts)clone_shallow userscripts https://github.com/quoid/userscripts.git ;;
  runestone)  clone_shallow runestone  https://github.com/simonbs/Runestone.git ;;
  all)
    clone_shallow scriptcat   https://github.com/scriptscat/scriptcat.git
    clone_shallow userscripts https://github.com/quoid/userscripts.git
    clone_shallow runestone   https://github.com/simonbs/Runestone.git
    clone_chromium_ios
    ;;
  *) echo "unknown target: $target (use: chromium|scriptcat|userscripts|runestone|all)"; exit 1 ;;
esac

log "done -> $DEST"

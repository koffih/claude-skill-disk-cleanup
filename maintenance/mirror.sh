#!/usr/bin/env bash
# Maintainer only: bring scripts/ in line with the working copy of the tool.
#
#   maintenance/mirror.sh <folder holding nettoyage-disque.sh>            report the gap
#   maintenance/mirror.sh <folder holding nettoyage-disque.sh> --apply    copy, then test
#
# The four files are copied as they are. --apply then runs the sandbox bench in a
# throwaway container when Docker is available.
set -euo pipefail

SRC="${1:-}"
APPLY="${2:-}"
[ -n "$SRC" ] && [ -f "$SRC/nettoyage-disque.sh" ] || { sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

gap=0
for f in nettoyage-disque.sh installer-sur-serveur.sh nettoyage-disque.conf.exemple banc-essai.sh; do
  if cmp -s "$SRC/$f" "$HERE/$f"; then
    echo "same:    $f"
  elif [ "$APPLY" = --apply ]; then
    cp -p "$SRC/$f" "$HERE/$f"
    echo "copied:  $f"
  else
    gap=1
    echo "differs: $f"
  fi
done

if [ "$APPLY" = --apply ]; then
  for f in "$HERE"/*.sh; do bash -n "$f"; done
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker run --rm -v "$HERE":/ref:ro ubuntu:24.04 bash /ref/banc-essai.sh | tail -1
  else
    echo "docker unavailable: run the bench by hand before pushing"
  fi
fi
exit $gap

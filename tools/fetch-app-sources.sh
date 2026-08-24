#!/usr/bin/env bash
# =============================================================================
# KONEKT OS — fetch the products' source, for a build that wants to ship it.
#
# Read this before you use it. Most of the KONEKT product repositories are
# private, and the ISO is published for anyone to download. A build that ships
# their source publishes that source to everyone who downloads the image. The
# default build does not do this, and does not need to: every product is
# installed as a real application window onto its own deployment either way.
#
# If you do want the source in the image — a private build, an offline build,
# an air-gapped machine — run this on a machine that can already read those
# repositories, then build with KONEKT_APP_SOURCES=1. The credential stays
# here, in whatever credential helper git already uses. It is never written
# into the image, and dist/ is not tracked by this repository.
#
#     bash tools/fetch-app-sources.sh
#     KONEKT_APP_SOURCES=1 bash iso/build.sh
# =============================================================================
set -euo pipefail

# A repository we cannot read must fail, never sit waiting for a password that
# nobody is there to type. This is what hung the build before.
export GIT_TERMINAL_PROMPT=0

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$REPO/dist/appsrc"
mkdir -p "$CACHE"

bold=$'\033[1m'; off=$'\033[0m'
say() { echo "${bold}[sources]${off} $*"; }

ok=0
skipped=0

for spec in \
  "konekt|https://github.com/vapesnuseu-cmyk/konekt.git" \
  "koach|https://github.com/vapesnuseu-cmyk/konekt-kouch.git" \
  "studio|https://github.com/vapesnuseu-cmyk/lastochka-studio.git" \
  "repo|https://github.com/vapesnuseu-cmyk/konekt-repo.git" ; do
  id="${spec%%|*}"; url="${spec##*|}"
  dest="$CACHE/$id"

  if [ -d "$dest/.git" ]; then
    if git -C "$dest" fetch --depth 1 origin HEAD --quiet 2>/dev/null \
       && git -C "$dest" reset --hard FETCH_HEAD --quiet 2>/dev/null; then
      say "$id — updated"
      ok=$((ok + 1))
      continue
    fi
    rm -rf "$dest"
  fi

  rm -rf "$dest"
  if git clone --depth 1 --quiet "$url" "$dest" 2>/dev/null; then
    say "$id — fetched"
    ok=$((ok + 1))
  else
    echo "  skipped $id: cannot read $url from here"
    skipped=$((skipped + 1))
  fi
done

echo
say "$ok fetched, $skipped skipped — in $CACHE"
if [ "$skipped" -gt 0 ]; then
  echo "     A skipped repository is one this machine has no access to."
  echo "     Sign in to it the way you normally would, then run this again."
fi
echo "     Build with the source:  KONEKT_APP_SOURCES=1 bash iso/build.sh"
echo "     Remember what that means: the source ships to everyone who gets the ISO."

#!/usr/bin/env bash
# Fetch one stock boot input, accepting either a browser release link or a direct URL.
#
# A private release asset is not served at its browser URL: github.com/<owner>/<repo>/releases/download/
# <tag>/<file> answers 404 even with a token, and only the API asset endpoint with
# Accept: application/octet-stream returns the bytes. This resolves the tag and name to the asset id
# first, so the documented link can be passed as-is.
#
# Usage: fetch-stock-input.sh URL OUTPUT [SHA256]
#   URL      browser release link, direct https URL, or file path URL
#   OUTPUT   where to write the bytes
#   SHA256   expected digest; empty skips the check
#
# Environment: ASSETS_TOKEN (required for github.com and api.github.com URLs).
set -euo pipefail

url=${1:?usage: fetch-stock-input.sh URL OUTPUT [SHA256]}
out=${2:?usage: fetch-stock-input.sh URL OUTPUT [SHA256]}
expected=${3:-}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

auth_header() {
  printf 'Authorization: Bearer %s' "${ASSETS_TOKEN:?set ASSETS_TOKEN: a private release asset rejects an anonymous request}"
}

case "$url" in
  https://github.com/*/releases/download/*)
    rest=${url#https://github.com/}
    owner=${rest%%/*}
    rest=${rest#*/}
    repo=${rest%%/*}
    rest=${rest#*/releases/download/}
    tag=${rest%%/*}
    name=${rest#*/}
    api="https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
    # Keep the HTTP status: a 401/404 here is a token or repo problem, not a missing asset, and the
    # two have to be told apart in the annotation.
    body=$(curl -sSL -H "$(auth_header)" -H 'Accept: application/vnd.github+json' \
      -w '\n%{http_code}' "$api") || { echo "::error::cannot reach $api" >&2; exit 1; }
    code=${body##*$'\n'}
    json=${body%$'\n'*}
    if [ "$code" != "200" ]; then
      echo "::error::release lookup $owner/$repo@$tag returned HTTP $code: $(printf '%s' "$json" | head -c 300)" >&2
      exit 1
    fi
    id=$(printf '%s' "$json" \
      | jq -r --arg n "$name" '(.assets // [])[] | select(.name == $n) | .id' | head -1)
    if [ -z "$id" ]; then
      echo "::error::release $owner/$repo@$tag has no asset named $name (assets: $(printf '%s' "$json" | jq -r '[.assets[]?.name] | join(", ")'))" >&2
      exit 1
    fi
    url="https://api.github.com/repos/$owner/$repo/releases/assets/$id"
    ;;
esac

case "$url" in
  https://github.com/*|https://api.github.com/*)
    curl -fsSL --retry 3 --retry-delay 5 -H "$(auth_header)" \
      -H 'Accept: application/octet-stream' -o "$out" "$url"
    ;;
  *)
    curl -fsSL --retry 3 --retry-delay 5 -o "$out" "$url"
    ;;
esac

size=$(wc -c < "$out" | tr -d ' ')
if [ -z "$expected" ]; then
  echo "::warning::$out: no expected sha256 supplied; the integrity check was skipped"
  echo "$(basename "$out"): $size bytes"
  exit 0
fi

got=$(digest "$out")
echo "$(basename "$out"): $size bytes sha256=$got"
if [ "$got" != "$(printf '%s' "$expected" | tr -d '[:space:]' | tr 'A-F' 'a-f')" ]; then
  echo "::error::$out sha256 $got does not match the expected $expected" >&2
  exit 1
fi

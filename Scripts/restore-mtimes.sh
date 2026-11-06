#!/bin/sh
# A fresh checkout stamps every file with the time of the checkout, so a restored
# build directory sees all of them as changed and rebuilds everything. Giving each
# tracked file the time of the commit that last touched it makes the build see only
# what really changed. Needs the full history (fetch-depth: 0).
set -eu

git log --format='@%ct' --name-only --no-renames |
    awk '/^@/ { stamp = substr($0, 2); next } NF && !seen[$0]++ { print stamp "\t" $0 }' |
    while IFS="$(printf '\t')" read -r stamp path; do
        [ -f "$path" ] || continue
        touch -t "$(date -r "$stamp" +%Y%m%d%H%M.%S)" "$path"
    done

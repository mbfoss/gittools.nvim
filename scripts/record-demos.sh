#!/usr/bin/env sh
# Record the README demos from demo/*.scene with nvim-demo.
#
#   scripts/record-demos.sh                    # every scene
#   scripts/record-demos.sh demo/graph.scene   # just one
#
# Each scene writes its GIF and cast to demo-out/. Needs nvim, agg and pyte.
# nvim-demo (https://github.com/mbfoss/nvim-demo-generator) is cloned into
# $XDG_CACHE_HOME/gittools.nvim when missing. Set NVIM_DEMO to a checkout's
# bin/nvim-demo to use that instead.
#
# The scenes record in demo/fixture, a throwaway repository rebuilt from
# demo/setup-fixture.sh before recording. Neither directory is tracked.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${NVIM_DEMO:-}" ]; then
    demo=$NVIM_DEMO
else
    tool=${XDG_CACHE_HOME:-$HOME/.cache}/gittools.nvim/nvim-demo-generator
    demo=$tool/bin/nvim-demo
    if [ ! -x "$demo" ]; then
        mkdir -p "${tool%/*}"
        git clone --depth 1 \
            https://github.com/mbfoss/nvim-demo-generator "$tool"
    fi
fi

"$root/demo/setup-fixture.sh" "$root/demo/fixture"

if [ "$#" -eq 0 ]; then
    set -- "$root"/demo/*.scene
fi

for scene in "$@"; do
    printf '=== %s\n' "$(basename "$scene")"
    "$demo" record "$scene"
done

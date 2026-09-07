#!/usr/bin/env sh
# Build the throwaway repository the demo scenes record in.
#
#   demo/setup-fixture.sh [DIR]        # default: demo/fixture
#
# Authors, dates and contents are fixed, so recordings are reproducible.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dir=${1:-$root/demo/fixture}

rm -rf "$dir"
mkdir -p "$dir/lua"
cd "$dir"

git init -q
git symbolic-ref HEAD refs/heads/main
git config user.name "Alice"
git config user.email "alice@example.com"
git config commit.gpgsign false
git config tag.gpgsign false

# commit NAME EMAIL DATE MESSAGE -- stages everything, then commits.
commit() {
    name=$1 email=$2 date=$3 message=$4
    git add -A
    GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_AUTHOR_DATE=$date \
        GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email \
        GIT_COMMITTER_DATE=$date \
        git commit -q -m "$message"
}

cat >README.md <<'EOF'
# sample

A small repository used to record the gittools.nvim demos.

## Commands

- `:Sample toggle` turns the toggle on or off.
- `:Sample status` prints the current options.
EOF

cat >lua/app.lua <<'EOF'
local M = {}

--- Return the option table, with defaults filled in.
function M.options(user)
    local opts = {
        width = 80,
        height = 24,
        verbose = false,
    }
    for key, value in pairs(user or {}) do
        opts[key] = value
    end
    return opts
end

--- Print a short description of the view.
function M.describe(opts)
    return ("%dx%d%s"):format(
        opts.width,
        opts.height,
        opts.verbose and " (verbose)" or ""
    )
end

return M
EOF

cat >lua/config.lua <<'EOF'
return {
    width = 100,
    height = 30,
}
EOF

commit Alice alice@example.com "2025-01-05T10:00:00 +0100" \
    "chore: initial commit"

cat >lua/config.lua <<'EOF'
return {
    width = 100,
    height = 30,
    title = "gittools demo",
}
EOF
commit Alice alice@example.com "2025-01-08T09:30:00 +0100" \
    "feat: add the window title"

git switch -q -c feat/toggle

cat >lua/app.lua <<'EOF'
local M = {}

--- Return the option table, with defaults filled in.
function M.options(user)
    local opts = {
        width = 80,
        height = 24,
        toggle = true,
        verbose = false,
    }
    for key, value in pairs(user or {}) do
        opts[key] = value
    end
    return opts
end

--- Print a short description of the view.
function M.describe(opts)
    return ("%dx%d%s"):format(
        opts.width,
        opts.height,
        opts.toggle and " [on]" or " [off]"
    )
end

return M
EOF
commit Bob bob@example.com "2025-01-10T14:15:00 +0100" \
    "feat: add the toggle option"

cat >lua/app.lua <<'EOF'
local M = {}

--- Return the option table, with defaults filled in.
function M.options(user)
    local opts = {
        width = 80,
        height = 24,
        toggle = true,
        verbose = false,
    }
    for key, value in pairs(user or {}) do
        opts[key] = value
    end
    return opts
end

--- Print a short description of the view.
function M.describe(opts)
    if not opts then return "no options" end
    return ("%dx%d%s"):format(
        opts.width,
        opts.height,
        opts.toggle and " [on]" or " [off]"
    )
end

return M
EOF
commit Bob bob@example.com "2025-01-12T16:40:00 +0100" \
    "fix: handle an empty option table"

git switch -q main

cat >README.md <<'EOF'
# sample

A small repository used to record the gittools.nvim demos.

## Commands

- `:Sample toggle` turns the toggle on or off.
- `:Sample status` prints the current options.

## Options

Set `width`, `height` and `toggle` in `lua/config.lua`.
EOF
commit Alice alice@example.com "2025-01-14T08:20:00 +0100" \
    "docs: describe the options"

GIT_AUTHOR_NAME=Alice GIT_AUTHOR_EMAIL=alice@example.com \
    GIT_AUTHOR_DATE="2025-01-20T11:00:00 +0100" \
    GIT_COMMITTER_NAME=Alice GIT_COMMITTER_EMAIL=alice@example.com \
    GIT_COMMITTER_DATE="2025-01-20T11:00:00 +0100" \
    git merge -q --no-ff feat/toggle -m "Merge branch 'feat/toggle'"

GIT_COMMITTER_NAME=Alice GIT_COMMITTER_EMAIL=alice@example.com \
    GIT_COMMITTER_DATE="2025-01-20T11:05:00 +0100" \
    git tag -a v1.0.0 -m "v1.0.0"

# Working tree: one unstaged edit, one staged edit, one untracked file.
cat >lua/app.lua <<'EOF'
local M = {}

--- Return the option table, with defaults filled in.
function M.options(user)
    local opts = {
        width = 80,
        height = 24,
        toggle = true,
        verbose = true,
    }
    for key, value in pairs(user or {}) do
        opts[key] = value
    end
    return opts
end

--- Print a short description of the view.
function M.describe(opts)
    if not opts then return "no options" end
    return ("%dx%d%s"):format(
        opts.width,
        opts.height,
        opts.toggle and " [on]" or " [off]"
    )
end

--- Print the current status.
function M.status(opts)
    return ("status: %s, %s"):format(
        M.describe(opts),
        opts.toggle and "enabled" or "disabled"
    )
end

return M
EOF

cat >lua/config.lua <<'EOF'
return {
    width = 120,
    height = 36,
    title = "gittools demo",
    toggle = true,
}
EOF
git add lua/config.lua

cat >notes.txt <<'EOF'
Ideas for the next release:

- an option to hide the title
- a `:Sample reset` command
- tests for the toggle
EOF

printf 'fixture: %s\n' "$dir"

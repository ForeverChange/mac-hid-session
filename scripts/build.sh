#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream_dir=${HID_UPSTREAM_DIR:-"$root_dir/.deps/karabiner"}
if [ ! -f "$upstream_dir/vendor/vendor/include/nlohmann/json.hpp" ]; then
  echo 'Dependencies missing. Run scripts/fetch-deps.sh or set HID_UPSTREAM_DIR.' >&2
  exit 1
fi
mkdir -p "$root_dir/build"
xcrun clang++ -std=c++23 -O2 -Wall -Wextra -Werror -fobjc-arc \
  -isystem "$upstream_dir/include" \
  -isystem "$upstream_dir/vendor/vendor/include" \
  -framework AppKit -framework CoreGraphics \
  "$root_dir/src/session.mm" -o "$root_dir/build/hid-session"
echo "Built $root_dir/build/hid-session"

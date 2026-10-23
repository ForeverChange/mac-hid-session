#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root_dir/.deps/karabiner"
commit=9036bc771259ff8d61341f4d1b7072b954fdb2fa
mkdir -p "$root_dir/.deps"
if [ ! -d "$destination/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git "$destination"
  git -C "$destination" sparse-checkout init --cone
  git -C "$destination" sparse-checkout set include vendor
  git -C "$destination" checkout --detach "$commit"
fi
[ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ] || { echo 'Dependency revision mismatch; refusing to reset existing files.' >&2; exit 1; }
# This release already tracks its complete vendored header snapshot. Re-running the upstream
# vendoring target needlessly downloads dependencies and can copy the GSL directory into itself.
[ -f "$destination/vendor/vendor/include/nlohmann/json.hpp" ]
[ -f "$destination/vendor/vendor/include/pqrs/hid.hpp" ]
echo 'Pinned upstream and vendored headers are ready; no CMake dependency rebuild needed.'

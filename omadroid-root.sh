#!/bin/bash
# Root side of Omadroid, run through pkexec. It only does what a user cannot:
# look inside Android, and reinstall libhoudini into the Waydroid images.
set -u

netcheck() {
  if ! waydroid shell -- true >/dev/null 2>&1; then
    echo '{"reachable":false}'
    return
  fi
  local network=false internet=false dns=false
  waydroid shell -- dumpsys connectivity 2>/dev/null | grep -m1 'Active default network' | grep -qv 'none' && network=true
  waydroid shell -- ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && internet=true
  waydroid shell -- ping -c1 -W3 google.com >/dev/null 2>&1 && dns=true
  echo "{\"reachable\":true,\"network\":$network,\"internet\":$internet,\"dns\":$dns}"
}

# waydroid_script only ships libhoudini for the Android versions Waydroid images use.
houdini() {
  local dir="$1" version="$2"
  case "$version" in 11|13) ;; *) echo "libhoudini needs Android 11 or 13, this image runs Android ${version:-unknown}" >&2; exit 1 ;; esac
  [ -f "$dir/main.py" ] && [ -x "$dir/venv/bin/python" ] || { echo "waydroid_script not found in $dir" >&2; exit 1; }
  cd "$dir" && "$dir/venv/bin/python" -W ignore main.py -a "$version" install libhoudini
}

case "${1:-}" in
  netcheck) netcheck ;;
  houdini)  houdini "${2:?waydroid_script directory}" "${3:?Android version}" ;;
  *) echo "usage: $0 netcheck|houdini <waydroid_script dir> <android version>" >&2; exit 2 ;;
esac

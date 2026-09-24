#!/bin/bash
# Backend for the Omadroid bar widget. Everything here runs as the user:
# the few checks that need root live in omadroid-root.sh, behind pkexec.
set -u

WAYDROID_LIB=/var/lib/waydroid
CGROUP=/sys/fs/cgroup/lxc.payload.waydroid

# Every command answers in one line of JSON, so the widget never parses prose.
json_bool() { [ "$1" = 1 ] && echo true || echo false; }

field() { printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1; }

status() {
  local out session container ip booted=0
  out=$(waydroid status 2>/dev/null)
  session=$(field "$out" Session)
  container=$(field "$out" Container)
  ip=$(field "$out" "IP address")
  [ "$session" = RUNNING ] && [ "$(waydroid prop get sys.boot_completed 2>/dev/null)" = 1 ] && booted=1

  # A kernel with binder built in lists it as a filesystem; the DKMS module shows up in /sys/module.
  local binder=0
  { grep -qw binder /proc/filesystems || [ -d /sys/module/binder_linux ]; } && binder=1

  local dkms=none
  if command -v dkms >/dev/null; then
    dkms=$(dkms status binder -k "$(uname -r)" 2>/dev/null | sed -n 's/.*: //p' | head -1)
    [ -z "$dkms" ] && dkms=missing
  fi

  local houdini=0
  [ -f "$WAYDROID_LIB/overlay/system/lib64/libhoudini.so" ] && houdini=1

  # Android needs DHCP, DNS and forwarding on waydroid0, or it boots without network.
  local ufw_active=0 ufw_rules=0
  systemctl is-active --quiet ufw && ufw_active=1
  if [ -r /etc/ufw/user.rules ]; then
    grep -q -- '-i waydroid0 -p udp --dport 67 -j ACCEPT' /etc/ufw/user.rules &&
      grep -q -- '-i waydroid0 -p udp --dport 53 -j ACCEPT' /etc/ufw/user.rules &&
      grep -q -- '-A ufw-user-forward -i waydroid0 -j ACCEPT' /etc/ufw/user.rules &&
      grep -q -- '-A ufw-user-forward -o waydroid0 -j ACCEPT' /etc/ufw/user.rules &&
      ufw_rules=1
  fi

  # Anonymous memory is what Android really holds; "file" is the image page cache the kernel gives back.
  local anon=0 cpu_usec=0
  [ -r "$CGROUP/memory.stat" ] && anon=$(awk '$1=="anon"{print $2; exit}' "$CGROUP/memory.stat")
  [ -r "$CGROUP/cpu.stat" ] && cpu_usec=$(awk '$1=="usage_usec"{print $2; exit}' "$CGROUP/cpu.stat")

  # Android apps run under uids 10000-19999, which have no name on the host.
  local apps
  apps=$(ps -eo uid=,rss=,args= 2>/dev/null |
    awk '$1>=10000 && $1<20000 && $3 ~ /^[a-z][a-z0-9_]*(\.[a-zA-Z0-9_]+)+(:.*)?$/ {split($3,p,":"); rss[p[1]]+=$2}
         END {for (k in rss) printf "%s\t%d\n", k, rss[k]}' |
    sort -t$'\t' -k2,2nr | head -6 |
    jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {pkg: .[0], rssKb: (.[1]|tonumber)})')

  jq -n -c \
    --arg session "${session:-STOPPED}" --arg container "${container:-STOPPED}" --arg ip "${ip:-}" \
    --argjson booted "$(json_bool $booted)" --argjson binder "$(json_bool $binder)" --arg dkms "$dkms" \
    --argjson houdini "$(json_bool $houdini)" --argjson ufwActive "$(json_bool $ufw_active)" \
    --argjson ufwRules "$(json_bool $ufw_rules)" --argjson anonBytes "${anon:-0}" \
    --argjson cpuUsec "${cpu_usec:-0}" --argjson now "$(date +%s%3N)" --argjson apps "${apps:-[]}" \
    '{session:$session, container:$container, ip:$ip, booted:$booted, binder:$binder, dkms:$dkms,
      houdini:$houdini, ufwActive:$ufwActive, ufwRules:$ufwRules, anonBytes:$anonBytes,
      cpuUsec:$cpuUsec, now:$now, apps:$apps}'
}

# Only apps with a launcher entry: services and providers have nothing to open.
apps() {
  waydroid app list 2>/dev/null | awk '
    /^Name:/        { if (name != "" && launcher) print name "\t" pkg; name=substr($0, 7); pkg=""; launcher=0 }
    /^packageName:/ { pkg=$2 }
    /LAUNCHER/      { launcher=1 }
    END             { if (name != "" && launcher) print name "\t" pkg }' |
    sort -f | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {name: .[0], pkg: .[1]})'
}

props() {
  local w h m t v
  w=$(waydroid prop get persist.waydroid.width 2>/dev/null)
  h=$(waydroid prop get persist.waydroid.height 2>/dev/null)
  m=$(waydroid prop get persist.waydroid.multi_windows 2>/dev/null)
  t=$(waydroid prop get persist.waydroid.fake_touch 2>/dev/null)
  v=$(waydroid prop get ro.build.version.release 2>/dev/null)
  jq -n -c --arg w "$w" --arg h "$h" --arg m "$m" --arg t "$t" --arg v "$v" \
    '{width:$w, height:$h, multiWindows:($m=="true"), fakeTouch:($t | split(",") | map(select(length>0))), androidVersion:$v}'
}

# The session belongs to this Wayland session, so it is started detached from the widget's process.
detach() { setsid "$@" >/dev/null 2>&1 < /dev/null & }

case "${1:-}" in
  status)  status ;;
  apps)    apps ;;
  props)   props ;;
  start)   detach waydroid session start ;;
  show)    detach waydroid show-full-ui ;;
  stop)    waydroid session stop ;;
  restart)
    waydroid session stop
    sleep 2
    detach waydroid show-full-ui
    ;;
  launch)  detach waydroid app launch "$2" ;;
  setprop) waydroid prop set "$2" "${3:-}" ;;
  *)
    echo "usage: $0 status|apps|props|start|show|stop|restart|launch <pkg>|setprop <key> [value]" >&2
    exit 2
    ;;
esac

#!/bin/bash
# Runs build/wlanstart.sh in the real image with a fake docker CLI and a fake
# hostapd (test/stubs), using a dummy interface as the wifi card. Checks that
# the hotspot waits for a late card, hands the card back on stop, and restarts
# when hostapd dies or the AP stops being enabled.
#
# Usage: test/run-tests.sh   (needs Docker; builds the image first)
set -u
cd "$(dirname "$0")/.." || exit 1
IMAGE=wifi-test-image
docker buildx build --platform linux/amd64 --load -q -t "$IMAGE" build >/dev/null || exit 1

STUBS="$(pwd)/test/stubs"
WORK=$(mktemp -d)
PASS=0; FAIL=0
C=wifi-test

ok()   { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# start <pre-shell-commands> [extra docker args...]
start() {
  local pre=$1; shift
  docker rm -f $C >/dev/null 2>&1
  rm -rf "$WORK/sim"; mkdir -p "$WORK/sim"
  docker run -d --name $C --privileged --platform linux/amd64 \
    -v "$STUBS:/stubs:ro" -v "$WORK/sim:/tmp/sim" \
    -e PATH=/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e CHECK_INTERVAL=1 -e START_GRACE=3 -e MAX_FAILED_CHECKS=3 \
    "$@" --entrypoint /bin/sh "$IMAGE" -c "$pre; exec /bin/wlanstart.sh" >/dev/null
}
logs() { docker logs $C 2>&1; }
# wait_for <seconds> <condition>
wait_for() {
  local t=0
  while [ $t -lt $(( $1 * 2 )) ]; do eval "$2" && return 0; sleep 0.5; t=$((t + 1)); done
  return 1
}
events() { cat "$WORK/sim/events" 2>/dev/null; }
state() { docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.RestartCount}}' $C 2>/dev/null; }

echo "1. card present: starts the AP"
start "touch /tmp/sim/present"
check "hostapd started" "wait_for 10 'logs | grep -q \"Starting hostapd\"'"
check "card claimed and renamed to wlan0" "docker exec $C ip link show wlan0 >/dev/null 2>&1"
check "dnsmasq running" "wait_for 5 'docker exec $C pgrep dnsmasq >/dev/null'"
check "NAT rule (legacy)" "docker exec $C iptables-legacy -t nat -S POSTROUTING | grep -q '172.33.12.0/24.*MASQUERADE'"
check "hostapd.conf has ssid + ctrl_interface" "docker exec $C grep -q '^ssid=AVADO' /etc/hostapd.conf && docker exec $C grep -q '^ctrl_interface=' /etc/hostapd.conf"
check "default password kept" "docker exec $C grep -q '^wpa_passphrase=avado123' /etc/hostapd.conf"
check "no PTK rekey (drivers like iwlwifi cannot rekey safely)" "! docker exec $C grep -q '^wpa_ptk_rekey' /etc/hostapd.conf"
check "WPA2 CCMP kept" "docker exec $C grep -q '^wpa=2' /etc/hostapd.conf && docker exec $C grep -q '^rsn_pairwise=CCMP' /etc/hostapd.conf"
check "ip_forward on" "[ \"\$(docker exec $C cat /proc/sys/net/ipv4/ip_forward)\" = 1 ]"
sleep 6
check "watchdog quiet on a healthy AP" "! logs | grep -q Warning"

echo "2. docker stop: fast, exit 0, card handed back"
T0=$(date +%s); docker stop -t 60 $C >/dev/null; T1=$(date +%s)
check "stopped in <= 5 s (took $((T1 - T0)) s)" "[ $((T1 - T0)) -le 5 ]"
check "exit code 0" "[ \"\$(state | cut -d' ' -f2)\" = 0 ]"
check "hostapd got TERM" "events | grep -q hostapd-term"
check "card handed back" "events | grep -q handed-back"

echo "3. card missing at start, appears later"
start "true"
check "waits and says so" "wait_for 5 'logs | grep -q \"No wifi interface on the host yet\"'"
sleep 3; touch "$WORK/sim/present"
check "claims it once it shows up" "wait_for 25 'logs | grep -q \"Starting hostapd\"'"
check "still running" "[ \"\$(state | cut -d' ' -f1)\" = running ]"

echo "4. card in use on the host: waits, then claims when free"
start "touch /tmp/sim/present; echo up > /tmp/sim/opstate"
check "does not take it" "wait_for 5 'logs | grep -q \"is in use on the host\"' && ! events | grep -q claimed"
echo down > "$WORK/sim/opstate"
check "claims it when down" "wait_for 25 'logs | grep -q \"Starting hostapd\"'"

echo "5. hostapd dies: restart via restart policy, card claimed again"
start "touch /tmp/sim/present" --restart always
wait_for 10 'logs | grep -q "Starting hostapd"'
touch "$WORK/sim/hostapd_die"
check "logs the exit" "wait_for 15 'logs | grep -q \"hostapd exited (code 3)\"'"
check "card handed back" "wait_for 5 'events | grep -q handed-back'"
check "container restarted" "wait_for 20 '[ \"\$(state | cut -d\" \" -f3)\" -ge 1 ]'"
check "AP up again after restart" "wait_for 20 '[ \$(events | grep -c claimed) -ge 2 ] && [ \$(logs | grep -c \"Starting hostapd\") -ge 2 ]'"

echo "6. AP disabled (driver reset): restart after 3 failed checks"
start "touch /tmp/sim/present"
wait_for 10 'logs | grep -q "Starting hostapd"'
echo DISABLED > "$WORK/sim/apstate"
check "counts failed checks" "wait_for 15 'logs | grep -q \"Check 3/3\"'"
check "exits 1" "wait_for 15 '[ \"\$(state)\" = \"exited 1 0\" ]'"
check "card handed back" "events | grep -q handed-back"

echo "7. hostapd stops answering: restart"
start "touch /tmp/sim/present"
wait_for 10 'logs | grep -q "Starting hostapd"'
sleep 4; touch "$WORK/sim/cli_hang"
check "restarts on no answer" "wait_for 40 'logs | grep -q \"no answer from hostapd.*Restarting\"'"

echo "7b. interface vanishes (driver/firmware reset): restart at once"
start "touch /tmp/sim/present"
wait_for 10 'logs | grep -q "Starting hostapd"'
sleep 4; docker exec $C ip link del wlan0
check "restarts on missing interface" "wait_for 10 'logs | grep -q \"wifi interface is gone.*Restarting\"'"
check "exits 1" "wait_for 15 '[ \"\$(state)\" = \"exited 1 0\" ]'"

echo "7c. interface left AP mode: restart after 3 failed checks"
start "touch /tmp/sim/present"
wait_for 10 'logs | grep -q "Starting hostapd"'
sleep 4; touch "$WORK/sim/not_ap"
check "restarts" "wait_for 20 'logs | grep -q \"not in access point mode. Restarting\"'"

echo "8. password too short: waits, stops fast"
start "touch /tmp/sim/present" -e WPA_PASSPHRASE=short
check "explains the problem" "wait_for 5 'logs | grep -q \"must be 8 to 63 characters\"'"
check "does not claim the card" "! events | grep -q claimed"
T0=$(date +%s); docker stop -t 60 $C >/dev/null; T1=$(date +%s)
check "stops in <= 3 s, exit 0" "[ $((T1 - T0)) -le 3 ] && [ \"\$(state | cut -d' ' -f2)\" = 0 ]"

echo "9. hand-back fails: still stops cleanly"
start "touch /tmp/sim/present; touch /tmp/sim/handback_fails"
wait_for 10 'logs | grep -q "Starting hostapd"'
docker stop -t 60 $C >/dev/null
check "logs the fallback" "logs | grep -q 'kernel returns it'"
check "exit 0" "[ \"\$(state | cut -d' ' -f2)\" = 0 ]"

echo "10. a client gets a DHCP lease (dnsmasq)"
start "touch /tmp/sim/present /tmp/sim/veth"
wait_for 10 'logs | grep -q "Starting hostapd"'
sleep 2
# shellcheck disable=SC2034  # read inside check's eval
LEASE=$(docker exec $C udhcpc -i cli0 -n -q -t 5 -s /bin/true 2>&1)
check "lease in 172.33.12.100-253" "echo \"\$LEASE\" | grep -Eq 'lease of 172\.33\.12\.(1[0-9][0-9]|2[0-4][0-9]|25[0-3]) obtained'"
check "router + DNS offered" "docker exec $C udhcpc -i cli0 -n -q -t 5 -s /stubs/print-lease 2>/dev/null | grep -q 'router=172.33.12.254 dns=172.33.1.2'"
check "lease recorded" "docker exec $C cat /var/lib/misc/dnsmasq.leases | grep -q 172.33.12."

docker rm -f $C >/dev/null 2>&1
rm -rf "$WORK"
echo
echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]

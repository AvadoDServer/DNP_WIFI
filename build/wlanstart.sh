#!/bin/bash
#
# AVADO WiFi access point.
#
# Moves the host's wifi card (phy) into this container's network namespace and
# runs hostapd (the access point) and dnsmasq (DHCP for wifi clients) on it.
#
# What this script makes sure of:
# - The wifi card can be missing for a while (driver still loading, or the card
#   is still on its way back from a previous container: that takes up to ~2
#   minutes, see dappnode/DNP_WIFI#33). We keep looking for it instead of giving
#   up, so the hotspot comes back on its own without a reboot.
# - On stop (update, restart, reboot) the card is handed straight back to the
#   host, so the next start finds it at once.
# - A watchdog checks the access point every few seconds. If hostapd dies, the
#   AP gets disabled (driver/firmware reset) or hostapd stops answering, the
#   container exits and Docker starts it again (restart: always), which sets
#   the card up from scratch.

# Default values
true ${SUBNET:=172.33.12.0}
true ${AP_ADDR:=172.33.12.254}
true ${DNS:=172.33.1.2}
true ${NAT:=true}
true ${INTERFACE:=}
true ${SSID:=AVADO}
true ${CHANNEL:=11}
true ${WPA_PASSPHRASE:=avado123}
true ${HW_MODE:=g}
true ${DRIVER:=nl80211}
true ${MODE:=admin}

# Watchdog: seconds between checks, how many failed checks in a row make us
# restart, and a grace period after start. Overridable for tests.
true ${CHECK_INTERVAL:=10}
true ${MAX_FAILED_CHECKS:=3}
true ${START_GRACE:=60}

WLAN=wlan0
HOSTAPD_CONF=/etc/hostapd.conf
HOSTAPD_CTRL=/var/run/hostapd
DNSMASQ_CONF=/etc/dnsmasq-wifi.conf
DNSMASQ_LEASES=/var/lib/misc/dnsmasq.leases

PHY=""
HOSTAPD_PID=""
DNSMASQ_PID=""

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [wifi] $*"
}

# Sleep that a SIGTERM interrupts at once (bash runs traps only between
# commands, so a plain foreground sleep would delay a stop).
pause() {
  sleep "$1" &
  wait $! 2>/dev/null
}

if [ ! -w "/sys" ]; then
  log "[Error] Not running in privileged mode."
  exit 1
fi

# WPA2-PSK needs 8..63 characters; hostapd refuses anything else. Restarting
# would not help, so wait for the user to fix the setting (that recreates the
# container).
PASS_LEN=${#WPA_PASSPHRASE}
if [ "$PASS_LEN" -lt 8 ] || [ "$PASS_LEN" -gt 63 ]; then
  log "[Error] The WiFi password must be 8 to 63 characters long (it is ${PASS_LEN}). Change it in the WiFi package settings."
  trap 'exit 0' TERM INT
  while true; do pause 3600; done
fi

# Guest mode: own subnet and no NAT
if [ "$MODE" == "guest" ]; then
  SUBNET=172.33.100.0
  AP_ADDR=172.33.100.254
  NAT=false
fi

CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' "${HOSTNAME}")
CONTAINER_IMAGE=$(docker inspect -f '{{.Config.Image}}' "${HOSTNAME}")
if [ -z "$CONTAINER_PID" ] || [ -z "$CONTAINER_IMAGE" ]; then
  log "[Error] Cannot inspect this container through the Docker socket."
  exit 1
fi

# Run a command in the host's network namespace.
on_host() {
  docker run --rm --privileged --net=host --pid=host --entrypoint /bin/sh "${CONTAINER_IMAGE}" -c "$1" 2>/dev/null | tr -d '\r'
}

# Run a command in this container's network namespace with the host's PID
# namespace, so "pid 1" is the host's init. Used to hand the card back.
on_container_with_host_pid() {
  docker run --rm --privileged --pid=host --net="container:${HOSTNAME}" --entrypoint /bin/sh "${CONTAINER_IMAGE}" -c "$1" >/dev/null 2>&1
}

# Poll fast at first, then slower, so a box without wifi does not spawn a
# helper container every few seconds forever.
wait_delay() {
  local attempt=$1
  if [ "$attempt" -lt 12 ]; then echo 10      # first 2 minutes
  elif [ "$attempt" -lt 40 ]; then echo 60    # until ~30 minutes
  else echo 600
  fi
}

# Find the wifi interface on the host and move its phy into this container.
claim_interface() {
  local attempt=0 iface opstate
  while true; do
    if [ -n "$INTERFACE" ]; then
      iface=$(on_host "test -d /sys/class/net/${INTERFACE}/phy80211 && echo ${INTERFACE}")
    else
      iface=$(on_host "iw dev" | awk '/Interface/ {print $2; exit}')
    fi

    if [ -z "$iface" ]; then
      [ $((attempt % 6)) -eq 0 ] && log "No wifi interface on the host yet, waiting (attempt $((attempt + 1)))."
    else
      opstate=$(on_host "cat /sys/class/net/${iface}/operstate")
      if [ "$opstate" != "down" ]; then
        # The host is using the card (e.g. connected to a network). Do not take it.
        [ $((attempt % 6)) -eq 0 ] && log "Interface ${iface} is in use on the host (state '${opstate}'), waiting."
      else
        PHY=$(on_host "cat /sys/class/net/${iface}/phy80211/name")
        if [ -z "$PHY" ]; then
          log "Could not read the phy of ${iface}, retrying."
        else
          log "Moving ${iface} (${PHY}) into the container."
          on_host "iw phy ${PHY} set netns ${CONTAINER_PID}"
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ip link show "$iface" >/dev/null 2>&1; then
              if [ "$iface" != "$WLAN" ]; then
                ip link set "$iface" down
                ip link set "$iface" name "$WLAN"
              fi
              return 0
            fi
            pause 1
          done
          log "Interface ${iface} did not arrive in the container, retrying."
          PHY=""
        fi
      fi
    fi

    pause "$(wait_delay "$attempt")"
    attempt=$((attempt + 1))
  done
}

write_hostapd_conf() {
  cat > "$HOSTAPD_CONF" <<EOF
interface=${WLAN}
driver=${DRIVER}
ctrl_interface=${HOSTAPD_CTRL}
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
wpa=2
wpa_passphrase=${WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
# TKIP is not secure anymore
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_ptk_rekey=600
wmm_enabled=1
EOF
}

write_dnsmasq_conf() {
  mkdir -p "$(dirname "$DNSMASQ_LEASES")"
  cat > "$DNSMASQ_CONF" <<EOF
# DHCP only, no DNS server (clients use ${DNS})
port=0
interface=${WLAN}
except-interface=lo
bind-dynamic
dhcp-authoritative
dhcp-range=${SUBNET::-1}100,${SUBNET::-1}253,255.255.255.0,12h
dhcp-option=option:router,${AP_ADDR}
dhcp-option=option:dns-server,${DNS}
dhcp-leasefile=${DNSMASQ_LEASES}
log-facility=-
EOF
}

# iptables-legacy keeps the same backend as the previous images.
IPTABLES=iptables
command -v iptables-legacy >/dev/null 2>&1 && IPTABLES=iptables-legacy

setup_network() {
  local int
  rfkill unblock wlan 2>/dev/null
  ip link set "$WLAN" up
  ip addr flush dev "$WLAN"
  ip addr add "${AP_ADDR}/24" dev "$WLAN"

  echo 1 > /proc/sys/net/ipv4/ip_dynaddr
  echo 1 > /proc/sys/net/ipv4/ip_forward

  if [ "$NAT" != "true" ]; then
    echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp
  fi

  if [ -n "${OUTGOINGS}" ]; then
    for int in ${OUTGOINGS//,/ }; do
      $IPTABLES -t nat -D POSTROUTING -s "${SUBNET}/24" -o "$int" -j MASQUERADE >/dev/null 2>&1
      $IPTABLES -t nat -A POSTROUTING -s "${SUBNET}/24" -o "$int" -j MASQUERADE
    done
  elif [ "$NAT" = "true" ]; then
    $IPTABLES -t nat -D POSTROUTING -s "${SUBNET}/24" -j MASQUERADE >/dev/null 2>&1
    $IPTABLES -t nat -A POSTROUTING -s "${SUBNET}/24" -j MASQUERADE
  fi
}

start_dnsmasq() {
  dnsmasq --keep-in-foreground --conf-file="$DNSMASQ_CONF" &
  DNSMASQ_PID=$!
}

start_hostapd() {
  rm -rf "$HOSTAPD_CTRL"
  hostapd "$HOSTAPD_CONF" &
  HOSTAPD_PID=$!
}

alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# Stop the daemons and give the card back to the host.
release() {
  local pid _
  for pid in "$HOSTAPD_PID" "$DNSMASQ_PID"; do
    alive "$pid" || continue
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      alive "$pid" || break
      sleep 0.5
    done
    alive "$pid" && kill -9 "$pid" 2>/dev/null
  done
  if [ -n "$PHY" ]; then
    ip link set "$WLAN" down 2>/dev/null
    log "Handing ${PHY} back to the host."
    if ! on_container_with_host_pid "iw phy ${PHY} set netns 1"; then
      log "Could not hand ${PHY} back; the kernel returns it when this container is gone."
    fi
  fi
}

on_stop() {
  trap '' TERM INT
  log "Stopping."
  release
  exit 0
}
trap on_stop TERM INT

# Restart the whole container (Docker's restart policy brings it back).
restart_container() {
  log "[Error] $1. Restarting the access point."
  release
  pause 5
  exit 1
}

##########
#  MAIN  #
##########

claim_interface
write_hostapd_conf
write_dnsmasq_conf
setup_network

log "Starting DHCP (dnsmasq) on ${WLAN}: ${SUBNET::-1}100-253, router ${AP_ADDR}, DNS ${DNS}."
start_dnsmasq
log "Starting hostapd: SSID '${SSID}', channel ${CHANNEL}."
start_hostapd

STARTED_AT=$(date +%s)
FAILED=0
while true; do
  pause "$CHECK_INTERVAL"

  if ! alive "$HOSTAPD_PID"; then
    wait "$HOSTAPD_PID" 2>/dev/null
    restart_container "hostapd exited (code $?)"
  fi

  if ! alive "$DNSMASQ_PID"; then
    log "[Warning] dnsmasq exited, starting it again."
    start_dnsmasq
  fi

  # A driver or firmware reset removes the interface; the card comes back as a
  # new phy on the host. hostapd keeps saying "ENABLED" then (seen with
  # mac80211_hwsim on the test box), so check the interface itself.
  if ! ip link show "$WLAN" >/dev/null 2>&1; then
    restart_container "The wifi interface is gone (driver or firmware reset)"
  fi

  PROBLEM=""
  if ! timeout 5 iw dev "$WLAN" info 2>/dev/null | grep -q "type AP"; then
    PROBLEM="the wifi interface is not in access point mode"
  else
    STATE=$(timeout 5 hostapd_cli -p "$HOSTAPD_CTRL" -i "$WLAN" status 2>/dev/null | awk -F= '$1 == "state" {print $2}')
    [ "$STATE" = "ENABLED" ] || PROBLEM="access point state is '${STATE:-no answer from hostapd}'"
  fi

  if [ -z "$PROBLEM" ]; then
    [ "$FAILED" -gt 0 ] && log "Access point is enabled again."
    FAILED=0
    continue
  fi

  # Still starting up
  [ $(( $(date +%s) - STARTED_AT )) -lt "$START_GRACE" ] && continue

  FAILED=$((FAILED + 1))
  log "[Warning] Check ${FAILED}/${MAX_FAILED_CHECKS}: ${PROBLEM}."
  [ "$FAILED" -ge "$MAX_FAILED_CHECKS" ] && restart_container "$PROBLEM"
done

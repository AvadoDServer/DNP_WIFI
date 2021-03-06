#!/bin/bash -e

# Check if running in privileged mode
if [ ! -w "/sys" ] ; then
    echo "[Error] Not running in privileged mode."
    exit 1
fi

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

# Attach interface to container in guest mode
# This will force NAT to be disabled!
if [ "$MODE" == "guest"  ]; then
  SUBNET=172.33.100.0
  AP_ADDR=172.33.100.254
  NAT=false
fi

CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' ${HOSTNAME})
CONTAINER_IMAGE=$(docker inspect -f '{{.Config.Image}}' ${HOSTNAME})
if [ -z ${INTERFACE} ]; then
  INTERFACE=$(docker run -t --privileged --net=host --pid=host --rm --entrypoint /bin/sh ${CONTAINER_IMAGE} -c "iw dev" | grep 'Interface' | awk 'NR==1{print $2}')
fi

if [ -z ${INTERFACE} ]; then
  echo "[Warning] No interface found. Entering sleep mode."
  while true; do sleep 1; done
fi

echo "Attaching interface ${INTERFACE} to container"
IFACE_OPSTATE=$(docker run -t --privileged --net=host --pid=host --rm --entrypoint /bin/sh ${CONTAINER_IMAGE} -c "cat /sys/class/net/${INTERFACE}/operstate")
if [ ${IFACE_OPSTATE::-1} = "down" ]; then
  docker run -t --privileged --net=host --pid=host --rm --entrypoint /bin/sh ${CONTAINER_IMAGE} -c "
    PHY=\$(echo phy\$(iw dev ${INTERFACE} info | grep wiphy | tr ' ' '\n' | tail -n 1))
    iw phy \$PHY set netns ${CONTAINER_PID}"
  ip link set ${INTERFACE} name wlan0
  INTERFACE=wlan0
else
  echo "[Warning] Interface ${INTERFACE} already connected. Entering sleep mode."
  while true; do sleep 1; done
fi

if [ ! -f "/etc/hostapd.conf" ]; then
    cat > "/etc/hostapd.conf" <<EOF
interface=${INTERFACE}
driver=${DRIVER}
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
wpa=2
wpa_passphrase=${WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
# TKIP is no secure anymore
#wpa_pairwise=TKIP CCMP
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_ptk_rekey=600
wmm_enabled=1
EOF

fi

# unblock wlan
rfkill unblock wlan

echo "Setting interface ${INTERFACE}"

# Setup interface and restart DHCP service 
ip link set ${INTERFACE} up
ip addr flush dev ${INTERFACE}
ip addr add ${AP_ADDR}/24 dev ${INTERFACE}

# IP forwarding
echo "Enabling ip_dynaddr, ip_forward"
for i in ip_dynaddr ip_forward ; do 
  if [ $(cat /proc/sys/net/ipv4/$i) ]; then
    echo $i already 1 
  else
    echo "1" > /proc/sys/net/ipv4/$i
  fi
done

cat /proc/sys/net/ipv4/ip_dynaddr 
cat /proc/sys/net/ipv4/ip_forward

# Wihout NAT: Proxy ARP mode
if [ $NAT != 'true' ]; then
  echo "Enablig Proxy ARP"
  echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp
fi

if [ "${OUTGOINGS}" ] ; then
   ints="$(sed 's/,\+/ /g' <<<"${OUTGOINGS}")"
   for int in ${ints}
   do
      echo "Setting iptables for outgoing traffics on ${int}..."
      iptables -t nat -D POSTROUTING -s ${SUBNET}/24 -o ${int} -j MASQUERADE > /dev/null 2>&1 || true
      iptables -t nat -A POSTROUTING -s ${SUBNET}/24 -o ${int} -j MASQUERADE
   done
elif [ $NAT = 'true' ]; then
   echo "Setting iptables for outgoing traffics on all interfaces..."
   iptables -t nat -D POSTROUTING -s ${SUBNET}/24 -j MASQUERADE > /dev/null 2>&1 || true
   iptables -t nat -A POSTROUTING -s ${SUBNET}/24 -j MASQUERADE
fi

echo "Configuring DHCP server .."
mkdir -p /etc/dhcp
cat > "/etc/dhcp/dhcpd.conf" <<EOF
option domain-name-servers ${DNS};
option subnet-mask 255.255.255.0;
option routers ${AP_ADDR};
subnet ${SUBNET} netmask 255.255.255.0 {
  range ${SUBNET::-1}100 ${SUBNET::-1}253;
}
EOF
echo "1"
ls /etc/dhcp
echo "2"
cat /etc/dhcp/dhcpd.conf
echo "3"


echo "Starting DHCP server .."
dhcpd ${INTERFACE}

echo "Starting HostAP daemon ..."
cat /etc/hostapd.conf
/usr/sbin/hostapd /etc/hostapd.conf 

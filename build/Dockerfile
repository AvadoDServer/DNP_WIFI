# Alpine 3.24, pinned by digest (multi-arch index) so builds are reproducible.
# DHCP for wifi clients is dnsmasq: Alpine dropped the ISC dhcp server after 3.20.
FROM --platform=linux/amd64 alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache bash hostapd iptables iptables-legacy dnsmasq docker-cli iproute2 iw
ADD wlanstart.sh /bin/wlanstart.sh
RUN chmod +x /bin/wlanstart.sh

ENTRYPOINT [ "/bin/wlanstart.sh" ]

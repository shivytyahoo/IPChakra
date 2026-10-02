#!/bin/bash
# ============================================================
# IPChakra TRIAL - VPS setup script (Ubuntu 22.04 / 24.04)
#
# Kya karta hai:
#   1. WireGuard server install + configure (phone isi se judega)
#   2. redsocks install + configure (saara TCP traffic residential
#      SOCKS5 proxy pool se nikalega - yahi "residential IP" wala part)
#   3. iptables rules (wg0 se aane wala TCP -> redsocks -> proxy pool)
#
# CHALANE SE PEHLE: neeche PROXY_* me apne provider ke credentials bhardo.
# Chalao:  sudo bash 01-server-setup.sh
# ============================================================
set -e

# ---------- APNE CREDENTIALS YAHAN BHARO ----------
PROXY_HOST="__PROXY_HOST__"   # jaise: gw.dataimpulse.com
PROXY_PORT="__PROXY_PORT__"   # jaise: 823
PROXY_USER="__PROXY_USER__"   # provider ka proxy username
PROXY_PASS="__PROXY_PASS__"   # provider ka proxy password
# ---------------------------------------------------

WG_PORT=51820
REDSOCKS_PORT=12345
SERVER_VPN_IP="10.8.0.1"
CLIENT_VPN_IP="10.8.0.2"

if [ "$EUID" -ne 0 ]; then echo "sudo se chalao: sudo bash $0"; exit 1; fi
if [[ "$PROXY_HOST" == __* ]]; then echo "PEHLE script ke upar PROXY_* credentials bhro!"; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard redsocks iptables-persistent curl > /dev/null
echo "[1/5] packages installed"

# IP forwarding on
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# WireGuard keys (server + trial client)
mkdir -p /etc/wireguard
umask 077
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub
SERVER_PUB=$(cat /etc/wireguard/server.pub)
CLIENT_PUB=$(cat /etc/wireguard/client.pub)
SERVER_PRIV=$(cat /etc/wireguard/server.key)
CLIENT_PRIV=$(cat /etc/wireguard/client.key)
echo "[2/5] wireguard keys generated"

# WireGuard server config
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $SERVER_VPN_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV

[Peer]
# IPChakra trial phone client
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_VPN_IP/32
EOF

# redsocks config - saara TCP residential proxy pool se
cat > /etc/redsocks.conf <<EOF
base {
  log_debug = off;
  log_info = off;
  log = "syslog:daemon";
  daemon = on;
  redirector = iptables;
}
redsocks {
  local_ip = 127.0.0.1;
  local_port = $REDSOCKS_PORT;
  ip = $PROXY_HOST;
  port = $PROXY_PORT;
  type = socks5;
  login = "$PROXY_USER";
  password = "$PROXY_PASS";
  autoproxy = 0;
}
EOF
echo "[3/5] wireguard + redsocks configured"

systemctl enable --now redsocks
systemctl enable --now wg-quick@wg0
echo "[4/5] services started"

# iptables: wg0 se aane wala TCP -> redsocks (residential chain)
iptables -t nat -C PREROUTING -i wg0 -p tcp -j REDIRECT --to-port $REDSOCKS_PORT 2>/dev/null \
  || iptables -t nat -A PREROUTING -i wg0 -p tcp -j REDIRECT --to-port $REDSOCKS_PORT
# UDP trial me seedha VPS se niklega (NOTE: UDP residential nahi hoga - trial limitation)
iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -j MASQUERADE
netfilter-persistent save > /dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 || true
echo "[5/5] iptables rules applied"

PUBLIC_IP=$(curl -s --max-time 15 https://ifconfig.me || echo "__VPS_PUBLIC_IP__")

# Client config (official WireGuard app me import karna)
cat > /root/ipchakra-trial-client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_VPN_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $PUBLIC_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 /root/ipchakra-trial-client.conf

echo "=============================================="
echo "HO GAYA!"
echo "Client config: /root/ipchakra-trial-client.conf"
echo "Ise apne phone me official WireGuard app me import karo."
echo "Phir test-rotation.sh se IP rotation verify karo."
echo "=============================================="

#!/bin/bash
# ============================================================
# IPChakra TRIAL - rotation + speed test (VPS pe chalao)
#
# Kya karta hai:
#   1. Proxy pool se 5 baar exit IP nikalta hai (rotation dikhega -
#      har baar alag residential IP aana chahiye)
#   2. Proxy chain se 25MB download karke speed batata hai
#   3. Bina proxy seedha VPS ka IP dikhata hai (compare ke liye)
#
# Chalao:
#   PROXY_HOST=gw.dataimpulse.com PROXY_PORT=823 \
#   PROXY_USER=tumhara_user PROXY_PASS=tumhara_pass \
#   bash test-rotation.sh
# ============================================================
set -e

: "${PROXY_HOST:?PROXY_HOST set karo}"
: "${PROXY_PORT:?PROXY_PORT set karo}"
: "${PROXY_USER:?PROXY_USER set karo}"
: "${PROXY_PASS:?PROXY_PASS set karo}"

PROXY_URL="socks5h://$PROXY_USER:$PROXY_PASS@$PROXY_HOST:$PROXY_PORT"

echo "=== 1. Exit IP - 5 baar (rotation check) ==="
for i in 1 2 3 4 5; do
  IP=$(curl -s --max-time 25 -x "$PROXY_URL" https://ifconfig.me || echo "FAIL")
  echo "try $i : $IP"
  sleep 2
done

echo ""
echo "=== 2. Speed test - 25MB download (proxy chain se) ==="
curl -s --max-time 180 -x "$PROXY_URL" -o /dev/null \
  -w "download speed: %{speed_download} bytes/sec\n" \
  "https://speed.cloudflare.com/__down?bytes=25000000" || echo "speed test fail"

echo ""
echo "=== 3. Seedha VPS IP (bina proxy - compare ke liye) ==="
curl -s --max-time 20 https://ifconfig.me || echo "FAIL"
echo ""
echo "=== khatam ==="

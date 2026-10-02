#!/bin/bash
# Binary assets ko base64 chunks se wapas banata hai.
# GitHub push me binary files nahi ja sakti thi, isliye gzip+base64 karke
# tools/binaries/ me chunks me rakhi hain. CI build se pehle ye script chalao.
#
# MANIFEST.txt format: chunk_prefix|dest_path|is_gz|num_chunks
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/tools/binaries"

# Pehle bade Windows binaries (exe/dll — alag naming se)
WG_LIB="$ROOT/packages/wireguard_flutter/windows/lib"
mkdir -p "$WG_LIB/wireguard_svc/amd64" "$WG_LIB/wireguard/amd64" "$WG_LIB/tunnel/amd64"
echo "[restore] wireguard_svc.exe ..."
cat "$BIN"/exe_part_* | base64 -d | gunzip -c > "$WG_LIB/wireguard_svc/amd64/wireguard_svc.exe"
echo "[restore] wireguard.dll ..."
cat "$BIN"/wg_part_* | base64 -d | gunzip -c > "$WG_LIB/wireguard/amd64/wireguard.dll"
echo "[restore] tunnel.dll ..."
cat "$BIN"/tun_part_* | base64 -d | gunzip -c > "$WG_LIB/tunnel/amd64/tunnel.dll"

# Baaki sab MANIFEST se
echo "[restore] $(grep -c . "$BIN/MANIFEST.txt") binary files ..."
while IFS='|' read -r prefix dest is_gz nchunks; do
  [ -z "$prefix" ] && continue
  mkdir -p "$ROOT/$(dirname "$dest")"
  if [ "$is_gz" = "1" ]; then
    cat "$BIN"/${prefix}_*.b64 | base64 -d | gunzip -c > "$ROOT/$dest"
  else
    cat "$BIN"/${prefix}_*.b64 | base64 -d > "$ROOT/$dest"
  fi
done < "$BIN/MANIFEST.txt"

echo "[restore] done."

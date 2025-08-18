#!/bin/sh
# sing-box 1.12+ / 1.14-ready WARP-in-WARP config generator
# - endpoints named warp-out / warp-in (no -ep)
# - outbounds named warp-out-o / warp-in-o (these are dialers; detour must point to them)
# - resolves engage.cloudflareclient.com to IP and uses that for peers
# - fixed IPv6 leak: peers allowed_ips include ::/0
set -e

sleep 3

_WARP_SERVER=engage.cloudflareclient.com
_WARP_PORT=2408
_NET_PORT=1080

WARP_SERVER="${WARP_SERVER:-$_WARP_SERVER}"
WARP_PORT="${WARP_PORT:-$_WARP_PORT}"
NET_PORT="${NET_PORT:-$_NET_PORT}"
DISABLE_IPV6="${DISABLE_IPV6:-0}"

# choose where DNS should detour (change to warp-in-o if you prefer inner)
DNS_DETOUR="${DNS_DETOUR:-warp-out-o}"

# Interface names for system WireGuard endpoints (used by bind_interface outbounds)
WARP_OUT_IF="${WARP_OUT_IF:-wg-warp-out}"
WARP_IN_IF="${WARP_IN_IF:-wg-warp-in}"

# Resolve a name to IPv4/IPv6 (prefer v4). Uses getent, then dig, then host.
_resolve_ips() {
  name="$1"
  v4=""
  v6=""
  if command -v getent >/dev/null 2>&1; then
    v4=$(getent ahosts "$name" | awk '/^[0-9]/ {print $1; exit}')
    v6=$(getent ahosts "$name" | awk '/:/' | awk '{print $1; exit}')
  fi

  if [ -z "$v4" ] && command -v dig >/dev/null 2>&1; then
    v4=$(dig +short A "$name" | head -n1)
  fi
  if [ -z "$v6" ] && command -v dig >/dev/null 2>&1; then
    v6=$(dig +short AAAA "$name" | head -n1)
  fi

  if [ -z "$v4" ] && command -v host >/dev/null 2>&1; then
    v4=$(host -t A "$name" 2>/dev/null | awk '/has address/ {print $4; exit}')
  fi
  if [ -z "$v6" ] && command -v host >/dev/null 2>&1; then
    v6=$(host -t AAAA "$name" 2>/dev/null | awk '/has IPv6 address/ {print $5; exit}')
  fi

  printf "%s %s" "$v4" "$v6"
}

# Try to resolve the WARP server now so endpoints can use IP instead of hostname.
read RESOLVED_V4 RESOLVED_V6 <<EOF
$(_resolve_ips "$_WARP_SERVER")
EOF

# Prefer IPv4 when present, else IPv6, else fall back to hostname
if [ -n "$RESOLVED_V4" ]; then
  WARP_SERVER_ADDR="$RESOLVED_V4"
elif [ -n "$RESOLVED_V6" ]; then
  WARP_SERVER_ADDR="[$RESOLVED_V6]"
else
  WARP_SERVER_ADDR="$_WARP_SERVER"
fi

fetch_warp() {
    curl -fsSL https://raw.githubusercontent.com/Mon-ius/XTPU/refs/heads/main/cloudflare/create-cloudflare-warp.sh | sh -s
}

RES_OUT=$(fetch_warp)
RES_IN=$(fetch_warp)

CF_OUT_CLIENT_ID=$(echo "$RES_OUT" | grep -o '"client":"[^"]*' | cut -d'"' -f4 | head -n1)
CF_OUT_ADDR_V4=$(echo "$RES_OUT" | grep -o '"v4":"[^"]*' | cut -d'"' -f4 | tail -n1)
CF_OUT_ADDR_V6=$(echo "$RES_OUT" | grep -o '"v6":"[^"]*' | cut -d'"' -f4 | tail -n1)
CF_OUT_PUBLIC_KEY=$(echo "$RES_OUT" | grep -o '"key":"[^"]*' | cut -d'"' -f4 | head -n1)
CF_OUT_PRIVATE_KEY=$(echo "$RES_OUT" | grep -o '"secret":"[^"]*' | cut -d'"' -f4 | head -n1)
reserved_out=$(echo "$CF_OUT_CLIENT_ID" | base64 -d | od -An -t u1 | awk '{print "["$1", "$2", "$3"]"}' | head -n1)

CF_IN_CLIENT_ID=$(echo "$RES_IN" | grep -o '"client":"[^"]*' | cut -d'"' -f4 | head -n1)
CF_IN_ADDR_V4=$(echo "$RES_IN" | grep -o '"v4":"[^"]*' | cut -d'"' -f4 | tail -n1)
CF_IN_ADDR_V6=$(echo "$RES_IN" | grep -o '"v6":"[^"]*' | cut -d'"' -f4 | tail -n1)
CF_IN_PUBLIC_KEY=$(echo "$RES_IN" | grep -o '"key":"[^"]*' | cut -d'"' -f4 | head -n1)
CF_IN_PRIVATE_KEY=$(echo "$RES_IN" | grep -o '"secret":"[^"]*' | cut -d'"' -f4 | head -n1)
reserved_in=$(echo "$CF_IN_CLIENT_ID" | base64 -d | od -An -t u1 | awk '{print "["$1", "$2", "$3"]"}' | head -n1)

if [ "$DISABLE_IPV6" -eq 1 ]; then
    OUT_ADDR="[\"${CF_OUT_ADDR_V4}/32\"]"
    IN_ADDR="[\"${CF_IN_ADDR_V4}/32\"]"
    TUN_ADDR='"address": ["172.31.100.1/32"]'
else
    OUT_ADDR="[\"${CF_OUT_ADDR_V4}/32\", \"${CF_OUT_ADDR_V6}/128\"]"
    IN_ADDR="[\"${CF_IN_ADDR_V4}/32\", \"${CF_IN_ADDR_V6}/128\"]"
    TUN_ADDR='"address": ["172.31.100.1/32", "2606:4700:110:82bf:4e06:f866:35d8:406f/128"]'
fi

cat <<EOF > ./config.json
{
  "log": { "level": "error" },

  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "metacubexd",
      "external_ui_download_url": "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip",
      "external_ui_download_detour": "${DNS_DETOUR}",
      "default_mode": "global"
    }
  },

  "dns": {
    "servers": [
      { "tag": "remote", "type": "tls", "server": "1.1.1.1", "domain_resolver": "local", "detour": "${DNS_DETOUR}" },
      { "tag": "local",  "type": "tls", "server": "1.0.0.1", "detour": "${DNS_DETOUR}" }
    ],
    "final": "remote",
    "reverse_mapping": true
  },

  "route": {
    "rules": [
      { "inbound": "mixed-in", "action": "sniff" },
      { "inbound": "tun-in",   "action": "sniff"  },
      { "protocol": "dns", "action": "hijack-dns" },

      { "ip_is_private": true, "outbound": "direct-out" },
      {
        "ip_cidr": [
          "0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16",
          "172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4",
          "52.80.0.0/16","112.95.0.0/16"
        ],
        "outbound": "direct-out"
      }
    ],
    "auto_detect_interface": true,
    "final": "warp-in-o",
    "default_domain_resolver": "local"
  },

  "inbounds": [
    {
      "type": "tun",
      "stack": "gvisor",
      "tag": "tun-in",
      "mtu": 1280,
      ${TUN_ADDR},
      "auto_route": true,
      "strict_route": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${NET_PORT}
    }
  ],

  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "system": true,
      "name": "${WARP_OUT_IF}",
      "mtu": 1280,
      "address": ${OUT_ADDR},
      "private_key": "${CF_OUT_PRIVATE_KEY}",
      "peers": [
        {
          "address": "${WARP_SERVER_ADDR}",
          "port": ${WARP_PORT},
          "public_key": "${CF_OUT_PUBLIC_KEY}",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": ${reserved_out}
        }
      ],
      "domain_resolver": "local",
      "workers": 4
    },

    {
      "type": "wireguard",
      "tag": "warp-in",
      "system": true,
      "name": "${WARP_IN_IF}",
      "mtu": 1280,
      "address": ${IN_ADDR},
      "private_key": "${CF_IN_PRIVATE_KEY}",
      "peers": [
        {
          "address": "${WARP_SERVER_ADDR}",
          "port": ${WARP_PORT},
          "public_key": "${CF_IN_PUBLIC_KEY}",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": ${reserved_in}
        }
      ],
      "domain_resolver": "local",
      "detour": "warp-out-o",
      "workers": 4
    }
  ],

  "outbounds": [
    { "type": "direct", "tag": "direct-out" },

    {
      "type": "direct",
      "tag": "warp-out-o",
      "bind_interface": "${WARP_OUT_IF}"
    },

    {
      "type": "direct",
      "tag": "warp-in-o",
      "bind_interface": "${WARP_IN_IF}"
    }
  ]
}
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="new-agent"
APP_TITLE="New Agent"
APP_VERSION="0.4.1"

if [[ -z "${LANG:-}" || "${LANG}" != *UTF-8* ]]; then
  export LANG=C.UTF-8
fi
if [[ -z "${LC_ALL:-}" || "${LC_ALL}" != *UTF-8* ]]; then
  export LC_ALL=C.UTF-8
fi

STATE_DIR="/etc/${APP_NAME}"
STATE_FILE="${STATE_DIR}/credentials.env"
TOKEN_FILE="${STATE_DIR}/sub_token"
CERT_DIR="${STATE_DIR}/certs"
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="${SING_BOX_CONFIG_DIR}/config.json"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
SUB_ROOT="/opt/${APP_NAME}/public"
SUB_SERVER="/opt/${APP_NAME}/server.py"
SUB_SCRIPT="/usr/local/bin/${APP_NAME}-subscription"
SHOW_SCRIPT="/usr/local/bin/${APP_NAME}-show"
MENU_SCRIPT="/usr/local/bin/${APP_NAME}"
SHORT_SCRIPT="/usr/local/bin/na"
UNIT_SUB="/etc/systemd/system/${APP_NAME}-subscription.service"
UNIT_HOP="/etc/systemd/system/${APP_NAME}-port-hopping.service"
LEGACY_STATE_FILE="/etc/proxy-node/credentials.env"
LEGACY_TOKEN_FILE="/etc/proxy-node/sub_token"
LEGACY_CERT_DIR="/etc/proxy-node/certs"
LEGACY_SUB_GENERATOR="/root/setup_subscription_gui_compat.sh"
LEGACY_LINKS_FILE="/root/proxy-subscription-links.txt"
SUB_PORT="2053"

DOMAIN=""
SERVER_NAME=""
EMAIL=""
REALITY_TARGET=""
CERT_MODE="auto"
TLS_INSECURE="false"
FORCE="0"
SKIP_CERT="0"

log() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${APP_TITLE} ${APP_VERSION}

Usage:
  bash install.sh
  bash install.sh [--domain example.com] [--email admin@example.com] [--reality-target www.cuhk.edu.hk] [--yes]
  bash install.sh install [--domain example.com] [options]
  bash install.sh change-domain
  bash install.sh detect
  bash install.sh show
  bash install.sh sh
  bash install.sh status
  bash install.sh uninstall

Options:
  --domain DOMAIN              Optional. If provided, ACME certificate and auto-renew are enabled.
  --email EMAIL                Optional ACME email when --domain is provided.
  --reality-target DOMAIN      Optional Reality/ShadowTLS camouflage target. Auto-selected when empty.
  --skip-cert                  Force self-signed certificate even when --domain is provided.
  -y, --yes                    Non-interactive install.
  -h, --help                   Show help.
EOF
}

ACTION="menu"
if [[ $# -gt 0 ]]; then
  case "$1" in
    install|uninstall|status|show|change-domain|detect|menu|sh|shell)
      ACTION="$1"
      shift
      ;;
    *)
      ACTION="install"
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    --reality-target)
      REALITY_TARGET="${2:-}"
      shift 2
      ;;
    --skip-cert)
      SKIP_CERT="1"
      shift
      ;;
    -y|--yes)
      FORCE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Unsupported system: missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  case "${OS_ID} ${OS_LIKE}" in
    *debian*|*ubuntu*) PKG="apt" ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*) PKG="dnf" ;;
    *) die "Unsupported Linux distribution: ${PRETTY_NAME:-unknown}" ;;
  esac
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) SING_ARCH="amd64"; XRAY_ARCH="64" ;;
    aarch64|arm64) SING_ARCH="arm64"; XRAY_ARCH="arm64-v8a" ;;
    *) die "Unsupported CPU architecture: $ARCH" ;;
  esac
}

install_packages() {
  info "Installing dependencies"
  if [[ "$PKG" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl wget ca-certificates tar unzip openssl socat cron python3 iptables iproute2 jq uuid-runtime
  else
    dnf install -y curl wget ca-certificates tar unzip openssl socat cronie python3 iptables iproute jq util-linux
    systemctl enable --now crond >/dev/null 2>&1 || true
  fi
}

random_hex() { openssl rand -hex "${1:-8}"; }
random_b64() { openssl rand -base64 "${1:-24}" | tr -d '\n'; }
new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else cat /proc/sys/kernel/random/uuid; fi
}

public_ip() {
  local ip
  ip="$(curl -4fsSL --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsSL --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ -n "$ip" ]] || die "Failed to detect public IPv4. Please use --domain or check network."
  printf '%s\n' "$ip"
}

choose_reality_target() {
  if [[ -n "$REALITY_TARGET" ]]; then
    info "Using configured Reality target: ${REALITY_TARGET}"
    return
  fi
  info "Auto-selecting a reachable university Reality target"
  REALITY_TARGET="$(python3 <<'PY'
import socket
import ssl
import time

candidates = [
    "www.cuhk.edu.hk",
    "www.hku.hk",
    "www.nus.edu.sg",
    "www.ntu.edu.sg",
    "www.u-tokyo.ac.jp",
    "www.kyoto-u.ac.jp",
    "www.ucla.edu",
    "www.stanford.edu",
    "www.mit.edu",
    "www.harvard.edu",
    "www.ox.ac.uk",
    "www.cam.ac.uk",
    "www.ubc.ca",
    "www.utoronto.ca",
    "www.unimelb.edu.au",
    "www.sydney.edu.au",
]

best = None
for host in candidates:
    start = time.time()
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, 443), timeout=3) as sock:
            with ctx.wrap_socket(sock, server_hostname=host):
                elapsed = time.time() - start
        if best is None or elapsed < best[0]:
            best = (elapsed, host)
    except Exception:
        pass

print(best[1] if best else "www.cuhk.edu.hk")
PY
)"
  log "Selected Reality target: ${REALITY_TARGET}"
}

prepare_server_name() {
  if [[ -n "$DOMAIN" ]]; then
    SERVER_NAME="$DOMAIN"
  else
    SERVER_NAME="$(public_ip)"
  fi
  if [[ -n "$DOMAIN" && "$SKIP_CERT" != "1" ]]; then
    CERT_MODE="acme"
    TLS_INSECURE="false"
  else
    CERT_MODE="self-signed"
    TLS_INSECURE="true"
  fi
  info "Server address: ${SERVER_NAME}"
  info "Certificate mode: ${CERT_MODE}"
}

github_latest() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    log "sing-box already installed: $(sing-box version | head -n1)"
    return
  fi
  local ver url tmp
  ver="$(github_latest SagerNet/sing-box)"
  [[ -n "$ver" && "$ver" != "null" ]] || die "Failed to resolve latest sing-box version"
  tmp="$(mktemp -d)"
  url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-${SING_ARCH}.tar.gz"
  info "Installing sing-box ${ver}"
  curl -fL "$url" -o "${tmp}/sing-box.tar.gz"
  tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"
  install -m 0755 "$(find "$tmp" -type f -name sing-box | head -n1)" /usr/local/bin/sing-box
  ln -sf /usr/local/bin/sing-box /usr/bin/sing-box
  rm -rf "$tmp"
}

install_xray() {
  if command -v xray >/dev/null 2>&1; then
    log "Xray already installed: $(xray version | head -n1)"
    return
  fi
  local ver url tmp
  ver="$(github_latest XTLS/Xray-core)"
  [[ -n "$ver" && "$ver" != "null" ]] || die "Failed to resolve latest Xray version"
  tmp="$(mktemp -d)"
  url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${XRAY_ARCH}.zip"
  info "Installing Xray ${ver}"
  curl -fL "$url" -o "${tmp}/xray.zip"
  unzip -q "${tmp}/xray.zip" -d "$tmp"
  install -m 0755 "${tmp}/xray" /usr/local/bin/xray
  rm -rf "$tmp"
}

enable_bbr() {
  info "Enabling BBR"
  cat >/etc/sysctl.d/99-${APP_NAME}-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null || true
}

write_state() {
  mkdir -p "$STATE_DIR" "$CERT_DIR"
  chmod 700 "$STATE_DIR"
  if [[ -f "$STATE_FILE" && "$FORCE" != "1" ]]; then
    warn "Existing state found: $STATE_FILE"
    warn "Use --yes to overwrite, or run '${SHOW_SCRIPT}' to show current links."
    exit 1
  fi
  cat >"$STATE_FILE" <<EOF
DOMAIN='${DOMAIN}'
SERVER_NAME='${SERVER_NAME}'
REALITY_TARGET='${REALITY_TARGET}'
CERT_MODE='${CERT_MODE}'
TLS_INSECURE='${TLS_INSECURE}'
VLESS_UUID='$(new_uuid)'
TUIC_UUID='$(new_uuid)'
XRAY_UUID='$(new_uuid)'
XHTTP_PATH='/xhttp-$(random_hex 8)'
HY2_PASS='$(random_b64 24)'
HY2_OBFS_PASS='$(random_b64 18)'
TUIC_PASS='$(random_b64 24)'
NAIVE_USER='naive$(random_hex 3)'
NAIVE_PASS='$(random_b64 24)'
ANYTLS_PASS='$(random_b64 24)'
ANYTLS_REALITY_PASS='$(random_b64 24)'
SHADOWTLS_PASS='$(random_b64 24)'
SHADOWTLS_SS_PASS='$(random_b64 24)'
EOF
  chmod 600 "$STATE_FILE"
  openssl rand -hex 16 >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

issue_cert() {
  mkdir -p "$CERT_DIR"
  if [[ "$CERT_MODE" == "self-signed" ]]; then
    local san
    if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      san="IP:${SERVER_NAME}"
    else
      san="DNS:${SERVER_NAME}"
    fi
    warn "Generating self-signed certificate for ${SERVER_NAME}."
    warn "Clients must enable skip certificate verification/insecure for certificate-based nodes and subscription import."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=${SERVER_NAME}" \
      -addext "subjectAltName=${san}" \
      -keyout "${CERT_DIR}/privkey.pem" \
      -out "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1
    return
  fi
  if [[ ! -d "$HOME/.acme.sh" ]]; then
    info "Installing acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL:-admin@${DOMAIN}}"
  fi
  export PATH="$HOME/.acme.sh:$PATH"
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null
  info "Issuing certificate for ${DOMAIN}"
  systemctl stop sing-box xray "${APP_NAME}-subscription" >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl restart sing-box ${APP_NAME}-subscription xray >/dev/null 2>&1 || true"
  chmod 600 "${CERT_DIR}/privkey.pem"
}

generate_keys() {
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  local sb_keys any_keys xray_keys
  sb_keys="$(sing-box generate reality-keypair)"
  any_keys="$(sing-box generate reality-keypair)"
  xray_keys="$(xray x25519)"
  SB_PRIVATE_KEY="$(printf '%s\n' "$sb_keys" | awk '/PrivateKey:/ {print $2}')"
  SB_PUBLIC_KEY="$(printf '%s\n' "$sb_keys" | awk '/PublicKey:/ {print $2}')"
  ANYTLS_PRIVATE_KEY="$(printf '%s\n' "$any_keys" | awk '/PrivateKey:/ {print $2}')"
  ANYTLS_PUBLIC_KEY="$(printf '%s\n' "$any_keys" | awk '/PublicKey:/ {print $2}')"
  XRAY_PRIVATE_KEY="$(printf '%s\n' "$xray_keys" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')"
  XRAY_PUBLIC_KEY="$(printf '%s\n' "$xray_keys" | awk -F': *' '/PublicKey|Public key|Password \\(PublicKey\\)/ {print $2; exit}')"
  [[ -n "$SB_PRIVATE_KEY" && -n "$SB_PUBLIC_KEY" ]] || die "Failed to generate sing-box Reality key pair."
  [[ -n "$ANYTLS_PRIVATE_KEY" && -n "$ANYTLS_PUBLIC_KEY" ]] || die "Failed to generate AnyTLS Reality key pair."
  [[ -n "$XRAY_PRIVATE_KEY" && -n "$XRAY_PUBLIC_KEY" ]] || die "Failed to generate Xray Reality key pair."
  SB_SHORT_ID="$(random_hex 4)"
  ANYTLS_SHORT_ID="$(random_hex 4)"
  XRAY_SHORT_ID="$(random_hex 4)"
  cat >>"$STATE_FILE" <<EOF
SB_PRIVATE_KEY='${SB_PRIVATE_KEY}'
SB_PUBLIC_KEY='${SB_PUBLIC_KEY}'
SB_SHORT_ID='${SB_SHORT_ID}'
ANYTLS_PRIVATE_KEY='${ANYTLS_PRIVATE_KEY}'
ANYTLS_PUBLIC_KEY='${ANYTLS_PUBLIC_KEY}'
ANYTLS_SHORT_ID='${ANYTLS_SHORT_ID}'
XRAY_PRIVATE_KEY='${XRAY_PRIVATE_KEY}'
XRAY_PUBLIC_KEY='${XRAY_PUBLIC_KEY}'
XRAY_SHORT_ID='${XRAY_SHORT_ID}'
EOF
}

write_sing_box_config() {
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  mkdir -p "$SING_BOX_CONFIG_DIR"
  cat >"$SING_BOX_CONFIG" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [{"name": "main", "uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_TARGET}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${REALITY_TARGET}", "server_port": 443},
          "private_key": "${SB_PRIVATE_KEY}",
          "short_id": ["${SB_SHORT_ID}"],
          "max_time_difference": "1m"
        }
      }
    },
    {
      "type": "naive",
      "tag": "naive",
      "listen": "0.0.0.0",
      "listen_port": 9443,
      "users": [{"username": "${NAIVE_USER}", "password": "${NAIVE_PASS}"}],
      "quic_congestion_control": "bbr",
      "tls": {"enabled": true, "server_name": "${SERVER_NAME}", "certificate_path": "${CERT_DIR}/fullchain.pem", "key_path": "${CERT_DIR}/privkey.pem"}
    },
    {
      "type": "anytls",
      "tag": "anytls-tls",
      "listen": "0.0.0.0",
      "listen_port": 7443,
      "users": [{"name": "main", "password": "${ANYTLS_PASS}"}],
      "tls": {"enabled": true, "server_name": "${SERVER_NAME}", "certificate_path": "${CERT_DIR}/fullchain.pem", "key_path": "${CERT_DIR}/privkey.pem"}
    },
    {
      "type": "anytls",
      "tag": "anytls-reality",
      "listen": "0.0.0.0",
      "listen_port": 5443,
      "users": [{"name": "main", "password": "${ANYTLS_REALITY_PASS}"}],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_TARGET}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${REALITY_TARGET}", "server_port": 443},
          "private_key": "${ANYTLS_PRIVATE_KEY}",
          "short_id": ["${ANYTLS_SHORT_ID}"],
          "max_time_difference": "1m"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": 30000,
      "obfs": {"type": "salamander", "password": "${HY2_OBFS_PASS}"},
      "users": [{"name": "main", "password": "${HY2_PASS}"}],
      "tls": {"enabled": true, "server_name": "${SERVER_NAME}", "certificate_path": "${CERT_DIR}/fullchain.pem", "key_path": "${CERT_DIR}/privkey.pem"}
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "0.0.0.0",
      "listen_port": 30001,
      "users": [{"name": "main", "uuid": "${TUIC_UUID}", "password": "${TUIC_PASS}"}],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {"enabled": true, "server_name": "${SERVER_NAME}", "certificate_path": "${CERT_DIR}/fullchain.pem", "key_path": "${CERT_DIR}/privkey.pem"}
    },
    {
      "type": "shadowtls",
      "tag": "shadowtls-v3",
      "listen": "0.0.0.0",
      "listen_port": 8444,
      "version": 3,
      "users": [{"name": "main", "password": "${SHADOWTLS_PASS}"}],
      "handshake": {"server": "${REALITY_TARGET}", "server_port": 443},
      "strict_mode": true,
      "detour": "shadowtls-ss-in"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowtls-ss-in",
      "method": "aes-128-gcm",
      "password": "${SHADOWTLS_SS_PASS}",
      "network": "tcp"
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {"final": "direct"}
}
EOF
}

write_xray_config() {
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  mkdir -p "$XRAY_CONFIG_DIR"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${XRAY_UUID}", "flow": "", "email": "xhttp-reality"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "${XHTTP_PATH}"},
        "security": "reality",
        "realitySettings": {
          "target": "${REALITY_TARGET}:443",
          "serverNames": ["${REALITY_TARGET}"],
          "privateKey": "${XRAY_PRIVATE_KEY}",
          "shortIds": ["${XRAY_SHORT_ID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
}

write_subscription_tools() {
  mkdir -p "$(dirname "$SUB_SCRIPT")" "$SUB_ROOT" "$(dirname "$SUB_SERVER")"
  cat >"$SUB_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_NAME="new-agent"
STATE_FILE="/etc/${APP_NAME}/credentials.env"
TOKEN_FILE="/etc/${APP_NAME}/sub_token"
SUB_ROOT="/opt/${APP_NAME}/public"
SUB_PORT="2053"

. "$STATE_FILE"
SUB_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
SUB_DIR="${SUB_ROOT}/sub/${SUB_TOKEN}"
mkdir -p "$SUB_DIR"
export DOMAIN SERVER_NAME REALITY_TARGET CERT_MODE TLS_INSECURE SUB_DIR SUB_TOKEN SUB_PORT
export VLESS_UUID TUIC_UUID ANYTLS_PASS HY2_PASS HY2_OBFS_PASS TUIC_PASS
export SB_PUBLIC_KEY SB_SHORT_ID
export XRAY_UUID XRAY_PUBLIC_KEY XRAY_SHORT_ID XHTTP_PATH
export NAIVE_USER NAIVE_PASS ANYTLS_REALITY_PASS ANYTLS_PUBLIC_KEY ANYTLS_SHORT_ID SHADOWTLS_PASS SHADOWTLS_SS_PASS

python3 <<'PY'
import base64
import json
import os
from urllib.parse import quote

server_name = os.environ["SERVER_NAME"]
reality_target = os.environ["REALITY_TARGET"]
sub_dir = os.environ["SUB_DIR"]
tls_insecure = os.environ.get("TLS_INSECURE", "false").lower() == "true"

def env(name):
    return os.environ[name]

def enc(value):
    return quote(value, safe="")

def cert_tls(name):
    tls = {"enabled": True, "server_name": name}
    if tls_insecure:
        tls["insecure"] = True
    return tls

nodes = [
    {
        "type": "vless",
        "tag": "vps-vless-reality-vision",
        "server": server_name,
        "server_port": 443,
        "uuid": env("VLESS_UUID"),
        "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True,
            "server_name": reality_target,
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {"enabled": True, "public_key": env("SB_PUBLIC_KEY"), "short_id": env("SB_SHORT_ID")},
        },
    },
    {
        "type": "hysteria2",
        "tag": "vps-hysteria2",
        "server": server_name,
        "server_port": 30000,
        "password": env("HY2_PASS"),
        "obfs": {"type": "salamander", "password": env("HY2_OBFS_PASS")},
        "tls": cert_tls(server_name),
    },
    {
        "type": "tuic",
        "tag": "vps-tuic-bbr",
        "server": server_name,
        "server_port": 30001,
        "uuid": env("TUIC_UUID"),
        "password": env("TUIC_PASS"),
        "congestion_control": "bbr",
        "udp_relay_mode": "native",
        "tls": cert_tls(server_name),
    },
    {
        "type": "naive",
        "tag": "vps-naiveproxy",
        "server": server_name,
        "server_port": 9443,
        "username": env("NAIVE_USER"),
        "password": env("NAIVE_PASS"),
        "quic_congestion_control": "bbr",
        "tls": cert_tls(server_name),
    },
    {
        "type": "anytls",
        "tag": "vps-anytls",
        "server": server_name,
        "server_port": 7443,
        "password": env("ANYTLS_PASS"),
        "tls": cert_tls(server_name),
    },
    {
        "type": "anytls",
        "tag": "vps-anytls-reality",
        "server": server_name,
        "server_port": 5443,
        "password": env("ANYTLS_REALITY_PASS"),
        "tls": {
            "enabled": True,
            "server_name": reality_target,
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {"enabled": True, "public_key": env("ANYTLS_PUBLIC_KEY"), "short_id": env("ANYTLS_SHORT_ID")},
        },
    },
    {
        "type": "shadowsocks",
        "tag": "vps-shadowtls-v3",
        "server": server_name,
        "server_port": 8444,
        "method": "aes-128-gcm",
        "password": env("SHADOWTLS_SS_PASS"),
        "detour": "vps-shadowtls-v3-transport",
    },
    {
        "type": "shadowtls",
        "tag": "vps-shadowtls-v3-transport",
        "server": server_name,
        "server_port": 8444,
        "version": 3,
        "password": env("SHADOWTLS_PASS"),
        "tls": {"enabled": True, "server_name": reality_target},
    },
]
visible = [node["tag"] for node in nodes if node["tag"] != "vps-shadowtls-v3-transport"]

with open(os.path.join(sub_dir, "singbox.json"), "w", encoding="utf-8") as f:
    json.dump({"outbounds": nodes}, f, indent=2, ensure_ascii=False)
    f.write("\n")

full_config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}],
    "outbounds": [
        {"type": "selector", "tag": "proxy", "outbounds": ["光锥云", *visible], "default": "光锥云"},
        {"type": "selector", "tag": "光锥云", "outbounds": visible},
        *nodes,
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ],
    "route": {"auto_detect_interface": True, "final": "proxy"},
}
with open(os.path.join(sub_dir, "singbox-full.json"), "w", encoding="utf-8") as f:
    json.dump(full_config, f, indent=2, ensure_ascii=True)
    f.write("\n")

insecure_query = "&insecure=1" if tls_insecure else ""
share_links = [
    f"vless://{env('VLESS_UUID')}@{server_name}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni={reality_target}&fp=chrome&pbk={env('SB_PUBLIC_KEY')}&sid={env('SB_SHORT_ID')}&type=tcp&headerType=none#vps-vless-reality-vision",
    f"vless://{env('XRAY_UUID')}@{server_name}:8443?encryption=none&security=reality&sni={reality_target}&fp=chrome&pbk={env('XRAY_PUBLIC_KEY')}&sid={env('XRAY_SHORT_ID')}&type=xhttp&path={enc(env('XHTTP_PATH'))}#vps-vless-xhttp-reality-xray",
    f"hysteria2://{enc(env('HY2_PASS'))}@{server_name}:30000?sni={server_name}&obfs=salamander&obfs-password={enc(env('HY2_OBFS_PASS'))}&mport=40000-40100{insecure_query}#vps-hysteria2-hop",
    f"tuic://{env('TUIC_UUID')}:{enc(env('TUIC_PASS'))}@{server_name}:30001?sni={server_name}&congestion_control=bbr&udp_relay_mode=native&mport=41000-41100{insecure_query}#vps-tuic-bbr",
    f"naive+https://{enc(env('NAIVE_USER'))}:{enc(env('NAIVE_PASS'))}@{server_name}:9443?insecure={1 if tls_insecure else 0}#vps-naiveproxy",
    f"anytls://{enc(env('ANYTLS_PASS'))}@{server_name}:7443?sni={server_name}{insecure_query}#vps-anytls",
    f"anytls://{enc(env('ANYTLS_REALITY_PASS'))}@{server_name}:5443?security=reality&sni={reality_target}&fp=chrome&pbk={env('ANYTLS_PUBLIC_KEY')}&sid={env('ANYTLS_SHORT_ID')}#vps-anytls-reality",
    f"ss://{enc('aes-128-gcm:' + env('SHADOWTLS_SS_PASS'))}@{server_name}:8444#vps-shadowtls-v3",
    f"shadowtls://{enc(env('SHADOWTLS_PASS'))}@{server_name}:8444?version=3&sni={reality_target}#vps-shadowtls-v3-transport",
]
share_text = "\n".join(share_links) + "\n"
with open(os.path.join(sub_dir, "share.txt"), "w", encoding="utf-8") as f:
    f.write(share_text)
with open(os.path.join(sub_dir, "share-base64.txt"), "w", encoding="utf-8") as f:
    f.write(base64.b64encode(share_text.encode()).decode() + "\n")
PY

python3 -m json.tool "${SUB_DIR}/singbox.json" >/dev/null
python3 -m json.tool "${SUB_DIR}/singbox-full.json" >/dev/null
cat >&2 <<'NOTE'
[INFO] Subscription JSON generated.
[INFO] Skipping sing-box client subscription check on the server.
[INFO] Reason: NaiveProxy outbound requires Cronet on some Linux clients and can make server-side checks fail even when the server config is valid.
NOTE
EOF
  chmod +x "$SUB_SCRIPT"

  cat >"$SHOW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
. "${STATE_FILE}"
TOKEN="\$(tr -d '\r\n' < "${TOKEN_FILE}")"
NOTE=""
if [[ "\${CERT_MODE:-}" == "self-signed" ]]; then
  NOTE="Self-signed certificate mode: enable insecure/skip certificate verification when importing the subscription or using certificate-based nodes."
fi
cat <<LINKS
SingBox GUI subscription:
https://\${SERVER_NAME}:${SUB_PORT}/sub/\${TOKEN}/singbox.json

Full sing-box config:
https://\${SERVER_NAME}:${SUB_PORT}/sub/\${TOKEN}/singbox-full.json

Raw share links:
https://\${SERVER_NAME}:${SUB_PORT}/sub/\${TOKEN}/share.txt

Base64 share links:
https://\${SERVER_NAME}:${SUB_PORT}/sub/\${TOKEN}/share-base64.txt

\${NOTE}
LINKS
EOF
  chmod +x "$SHOW_SCRIPT"

  cat >"$SUB_SERVER" <<EOF
#!/usr/bin/env python3
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os
import ssl

root = "${SUB_ROOT}"
cert = "${CERT_DIR}/fullchain.pem"
key = "${CERT_DIR}/privkey.pem"
port = ${SUB_PORT}

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

httpd = HTTPServer(("0.0.0.0", port), partial(Handler, directory=root))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
EOF
  chmod +x "$SUB_SERVER"
}

write_systemd() {
  local sing_box_bin xray_bin
  sing_box_bin="$(command -v sing-box || true)"
  xray_bin="$(command -v xray || true)"
  [[ -n "$sing_box_bin" ]] || die "sing-box binary not found."
  [[ -n "$xray_bin" ]] || die "xray binary not found."
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=${sing_box_bin} run -c ${SING_BOX_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
ExecStart=${xray_bin} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

  cat >"$UNIT_SUB" <<EOF
[Unit]
Description=${APP_TITLE} subscription HTTPS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SUB_SERVER}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat >"$UNIT_HOP" <<'EOF'
[Unit]
Description=New Agent UDP port hopping redirects
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp --dport 40000:40100 -j REDIRECT --to-ports 30000 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport 40000:40100 -j REDIRECT --to-ports 30000; iptables -t nat -C PREROUTING -p udp --dport 41000:41100 -j REDIRECT --to-ports 30001 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport 41000:41100 -j REDIRECT --to-ports 30001'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp --dport 40000:40100 -j REDIRECT --to-ports 30000 2>/dev/null || true; iptables -t nat -D PREROUTING -p udp --dport 41000:41100 -j REDIRECT --to-ports 30001 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
}

check_ports() {
  local ports=(80 443 5443 7443 8443 8444 9443 2053 30000 30001)
  for p in "${ports[@]}"; do
    if ss -lntup 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"; then
      warn "Port ${p} appears to be in use. Installation may fail if it is not owned by this stack."
    fi
  done
}

start_services() {
  "$SUB_SCRIPT"
  sing-box check -c "$SING_BOX_CONFIG"
  xray run -test -config "$XRAY_CONFIG" >/dev/null
  systemctl daemon-reload
  systemctl enable --now sing-box xray "${APP_NAME}-subscription" "${APP_NAME}-port-hopping"
}

install_shortcuts() {
  if [[ -r "${BASH_SOURCE[0]}" ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "$MENU_SCRIPT"
  else
    cat >"$MENU_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec bash <(curl -fsSL https://raw.githubusercontent.com/uentc/new-agent/main/install.sh) "$@"
EOF
    chmod +x "$MENU_SCRIPT"
  fi
  ln -sf "$MENU_SCRIPT" "$SHORT_SCRIPT"
}

install_all() {
  need_root
  if legacy_stack_present && [[ "$FORCE" != "1" ]]; then
    warn "Detected existing lightcone/proxy-node stack at ${LEGACY_STATE_FILE}."
    warn "Use menu option 2 to change its domain, option 3 to show links, or option 6 to inspect it."
    warn "Run install with --yes only if you intentionally want to overwrite the existing stack."
    return 0
  fi
  detect_os
  install_packages
  prepare_server_name
  choose_reality_target
  check_ports
  if [[ "$FORCE" != "1" ]]; then
    read -r -p "Install ${APP_TITLE} for ${SERVER_NAME}? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Cancelled"
  fi
  install_sing_box
  install_xray
  enable_bbr
  write_state
  generate_keys
  issue_cert
  write_sing_box_config
  write_xray_config
  write_subscription_tools
  write_systemd
  start_services
  install_shortcuts
  log "Installation completed"
  "$SHOW_SCRIPT"
}

show_status() {
  need_root
  if legacy_stack_present; then
    systemctl --no-pager --full status sing-box xray proxy-subscription proxy-port-hopping || true
  else
    systemctl --no-pager --full status sing-box xray "${APP_NAME}-subscription" "${APP_NAME}-port-hopping" || true
  fi
}

show_links() {
  need_root
  if [[ -f "$LEGACY_LINKS_FILE" ]]; then
    cat "$LEGACY_LINKS_FILE"
  elif [[ -x "$SHOW_SCRIPT" ]]; then
    "$SHOW_SCRIPT"
  else
    die "Not installed or missing ${SHOW_SCRIPT}"
  fi
}

show_existing_nodes() {
  need_root
  local found="0"
  local legacy_links_printed="0"
  echo
  echo "Known subscription links / 已知订阅链接"
  echo "----------------------------------------"
  if [[ -f "$LEGACY_LINKS_FILE" ]]; then
    found="1"
    legacy_links_printed="1"
    cat "$LEGACY_LINKS_FILE"
    echo
  elif [[ -x "$SHOW_SCRIPT" ]]; then
    found="1"
    "$SHOW_SCRIPT" || true
    echo
  fi
  if [[ "$legacy_links_printed" != "1" && -f /etc/proxy-node/credentials.env && -f /etc/proxy-node/sub_token ]]; then
    # shellcheck disable=SC1091
    . /etc/proxy-node/credentials.env
    local token
    token="$(tr -d '\r\n' </etc/proxy-node/sub_token)"
    if [[ -n "${DOMAIN:-}" && -n "$token" ]]; then
      found="1"
      cat <<EOF
Legacy proxy-node subscription:
https://${DOMAIN}:${SUB_PORT}/sub/${token}/singbox.json

Legacy raw share links:
https://${DOMAIN}:${SUB_PORT}/sub/${token}/share.txt

EOF
    fi
  fi
  if [[ "$found" == "0" ]]; then
    warn "No known subscription link file was found / 未找到已知订阅链接文件"
  fi

  echo
  echo "Detected local services and inbounds / 检测到的本机服务与入站"
  echo "------------------------------------------------------------"
  systemctl --no-pager --plain --type=service --state=running 2>/dev/null | grep -Ei 'sing-box|xray|hysteria|tuic|naive|lightclone|new-agent|proxy' || true
  echo
  ss -lntup 2>/dev/null | grep -E '(:443|:2053|:5443|:7443|:8443|:8444|:9443|:30000|:30001)' || true
  echo
  python3 <<'PY'
import json
from pathlib import Path

paths = [
    Path("/etc/sing-box/config.json"),
    Path("/usr/local/etc/xray/config.json"),
    Path("/etc/xray/config.json"),
]

for path in paths:
    if not path.exists():
        continue
    print(f"\nConfig: {path}")
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        print(f"  failed to parse: {exc}")
        continue
    for inbound in data.get("inbounds", []):
        tag = inbound.get("tag") or inbound.get("protocol") or "-"
        typ = inbound.get("type") or inbound.get("protocol") or "-"
        port = inbound.get("listen_port") or inbound.get("port") or "-"
        listen = inbound.get("listen", "-")
        network = inbound.get("streamSettings", {}).get("network", "")
        security = inbound.get("streamSettings", {}).get("security", "")
        print(f"  - tag={tag} type={typ} listen={listen}:{port} network={network} security={security}")
PY

  echo
  warn "If lightclone stores credentials in a private custom path, this script can only show detected ports/configs unless that path is known."
  warn "如果 lightclone 把密钥存在私有路径，本脚本不知道路径时只能显示检测到的端口和配置摘要。"
}

quote_state_value() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

set_state_value() {
  local key="$1" value="$2" escaped
  escaped="$(quote_state_value "$value")"
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}='${escaped}'|" "$STATE_FILE"
  else
    printf "%s='%s'\n" "$key" "$escaped" >>"$STATE_FILE"
  fi
}

set_file_value() {
  local file="$1" key="$2" value="$3" escaped
  escaped="$(quote_state_value "$value")"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}='${escaped}'|" "$file"
  else
    printf "%s='%s'\n" "$key" "$escaped" >>"$file"
  fi
  chmod 600 "$file"
}

legacy_stack_present() {
  [[ -f "$LEGACY_STATE_FILE" && -f "$LEGACY_TOKEN_FILE" && -x "$LEGACY_SUB_GENERATOR" ]]
}

sync_legacy_to_new_agent_state() {
  mkdir -p "$STATE_DIR" "$CERT_DIR"
  install -m 600 "$LEGACY_STATE_FILE" "$STATE_FILE"
  install -m 600 "$LEGACY_TOKEN_FILE" "$TOKEN_FILE" 2>/dev/null || true
  if [[ -d "$LEGACY_CERT_DIR" ]]; then
    cp -f "$LEGACY_CERT_DIR"/fullchain.pem "$LEGACY_CERT_DIR"/privkey.pem "$CERT_DIR"/ 2>/dev/null || true
    chmod 600 "$CERT_DIR"/* 2>/dev/null || true
  fi
}

repair_legacy_sing_box_service() {
  local sing_box_bin
  sing_box_bin="$(command -v sing-box || true)"
  [[ -n "$sing_box_bin" ]] || return 0
  if [[ ! -x /usr/local/bin/sing-box ]] && systemctl cat sing-box 2>/dev/null | grep -q '/usr/local/bin/sing-box'; then
    cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
User=sing-box
StateDirectory=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${sing_box_bin} -D /var/lib/sing-box -C /etc/sing-box run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
}

change_legacy_domain() {
  need_root
  # shellcheck disable=SC1090
  . "$LEGACY_STATE_FILE"
  echo
  echo "Detected lightcone/proxy-node stack. New Agent will adapt it instead of overwriting it."
  echo "Current server: ${DOMAIN:-unknown}"
  read -r -p "New domain, blank for VPS IP self-signed mode: " DOMAIN
  if [[ -n "$DOMAIN" ]]; then
    read -r -p "ACME email, optional: " EMAIL
    read -r -p "Force self-signed cert? [y/N]: " cert_ans
    if [[ "$cert_ans" =~ ^[Yy]$ ]]; then
      SKIP_CERT="1"
    else
      SKIP_CERT="0"
    fi
  else
    EMAIL=""
    SKIP_CERT="0"
  fi
  prepare_server_name
  local legacy_domain_value="$SERVER_NAME"
  set_file_value "$LEGACY_STATE_FILE" DOMAIN "$legacy_domain_value"
  set_file_value "$LEGACY_STATE_FILE" SERVER_NAME "$SERVER_NAME"
  set_file_value "$LEGACY_STATE_FILE" CERT_MODE "$CERT_MODE"
  set_file_value "$LEGACY_STATE_FILE" TLS_INSECURE "$TLS_INSECURE"

  local saved_cert_dir="$CERT_DIR"
  CERT_DIR="$LEGACY_CERT_DIR"
  issue_cert
  if [[ "$CERT_MODE" == "acme" && -x "$HOME/.acme.sh/acme.sh" ]]; then
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$SERVER_NAME" --ecc \
      --fullchain-file "${LEGACY_CERT_DIR}/fullchain.pem" \
      --key-file "${LEGACY_CERT_DIR}/privkey.pem" \
      --reloadcmd "systemctl restart sing-box xray proxy-subscription.service >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
  CERT_DIR="$saved_cert_dir"

  sync_legacy_to_new_agent_state
  systemctl disable --now "${APP_NAME}-subscription" "${APP_NAME}-port-hopping" >/dev/null 2>&1 || true
  "$LEGACY_SUB_GENERATOR"
  repair_legacy_sing_box_service
  systemctl restart sing-box xray proxy-subscription proxy-port-hopping >/dev/null 2>&1 || true
  install_shortcuts
  log "Legacy lightcone domain changed without overwriting the working stack."
  [[ -f "$LEGACY_LINKS_FILE" ]] && cat "$LEGACY_LINKS_FILE"
}

prompt_install_options() {
  read -r -p "请输入域名，可留空使用 VPS IP / Domain, blank for VPS IP: " DOMAIN
  if [[ -n "$DOMAIN" ]]; then
    read -r -p "请输入邮箱，可留空 / ACME email, optional: " EMAIL
    read -r -p "是否强制使用自签证书？[y/N] / Force self-signed cert? [y/N]: " cert_ans
    if [[ "$cert_ans" =~ ^[Yy]$ ]]; then
      SKIP_CERT="1"
    fi
  fi
  read -r -p "Reality 目标域名，可留空自动选择 / Reality target, blank for auto: " REALITY_TARGET
}

change_domain() {
  need_root
  if legacy_stack_present; then
    change_legacy_domain
    return
  fi
  [[ -f "$STATE_FILE" ]] || die "New Agent is not installed."
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  echo
  echo "当前地址 / Current server: ${SERVER_NAME:-${DOMAIN:-unknown}}"
  read -r -p "请输入新域名，可留空改为 VPS IP 自签 / New domain, blank for VPS IP: " DOMAIN
  if [[ -n "$DOMAIN" ]]; then
    read -r -p "请输入邮箱，可留空 / ACME email, optional: " EMAIL
    read -r -p "是否强制使用自签证书？[y/N] / Force self-signed cert? [y/N]: " cert_ans
    if [[ "$cert_ans" =~ ^[Yy]$ ]]; then
      SKIP_CERT="1"
    else
      SKIP_CERT="0"
    fi
  else
    EMAIL=""
    SKIP_CERT="0"
  fi
  prepare_server_name
  set_state_value DOMAIN "$DOMAIN"
  set_state_value SERVER_NAME "$SERVER_NAME"
  set_state_value CERT_MODE "$CERT_MODE"
  set_state_value TLS_INSECURE "$TLS_INSECURE"
  issue_cert
  write_sing_box_config
  write_xray_config
  write_subscription_tools
  write_systemd
  start_services
  install_shortcuts
  log "Domain changed / 域名已更换"
  "$SHOW_SCRIPT"
}

uninstall_all() {
  need_root
  local old_domain=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    old_domain="${DOMAIN:-}"
  fi
  warn "Stopping and removing ${APP_TITLE}"
  systemctl disable --now sing-box xray "${APP_NAME}-subscription" "${APP_NAME}-port-hopping" >/dev/null 2>&1 || true
  iptables -t nat -D PREROUTING -p udp --dport 40000:40100 -j REDIRECT --to-ports 30000 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 41000:41100 -j REDIRECT --to-ports 30001 2>/dev/null || true
  if [[ -n "$old_domain" && -x "$HOME/.acme.sh/acme.sh" ]]; then
    "$HOME/.acme.sh/acme.sh" --remove -d "$old_domain" --ecc >/dev/null 2>&1 || true
    rm -rf "$HOME/.acme.sh/${old_domain}_ecc" "$HOME/.acme.sh/${old_domain}"
  fi
  rm -f "$UNIT_SUB" "$UNIT_HOP" /etc/systemd/system/sing-box.service /etc/systemd/system/xray.service
  rm -rf /etc/systemd/system/sing-box.service.d /etc/systemd/system/xray.service.d
  systemctl daemon-reload
  rm -rf "$STATE_DIR" "/opt/${APP_NAME}" "$SUB_SCRIPT" "$SHOW_SCRIPT" "$SING_BOX_CONFIG_DIR" "$XRAY_CONFIG_DIR" /var/lib/sing-box
  rm -f /usr/local/bin/sing-box /usr/bin/sing-box /usr/local/bin/xray /etc/sysctl.d/99-${APP_NAME}-bbr.conf
  sysctl --system >/dev/null 2>&1 || true
  log "Uninstalled cleanly / 已彻底卸载"
}

main_menu() {
  need_root
  while true; do
    cat <<EOF

${APP_TITLE} ${APP_VERSION}
==============================
1. 一键安装 / Install
2. 更换域名 / Change domain
3. 查看订阅 / Show links
4. 查看状态 / Status
5. 一键彻底卸载 / Clean uninstall
6. 查看已有节点 / Detect existing nodes
0. 退出 / Exit
==============================
EOF
    read -r -p "请选择 / Select: " choice
    case "$choice" in
      1)
        prompt_install_options
        install_all
        ;;
      2)
        change_domain
        ;;
      3)
        show_links
        ;;
      4)
        show_status
        ;;
      5)
        read -r -p "确认彻底卸载？此操作会删除配置、证书、订阅和核心文件。[y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && uninstall_all || warn "Cancelled / 已取消"
        ;;
      6)
        show_existing_nodes
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Invalid choice / 无效选项"
        ;;
    esac
  done
}

case "$ACTION" in
  menu|sh|shell) main_menu ;;
  install) install_all ;;
  change-domain) change_domain ;;
  status) show_status ;;
  show) show_links ;;
  detect) show_existing_nodes ;;
  uninstall) uninstall_all ;;
esac

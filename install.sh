#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/etc/xray-reality"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_DIR="${STATE_DIR}/backups"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-xray-reality-bbr.conf"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_PORT="443"
DEFAULT_SNI="github.githubassets.com"
DEFAULT_FINGERPRINT="random"

PORT=""
SNI_DOMAIN=""
SERVER_ADDRESS=""
UUID_VALUE=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
FINGERPRINT="${DEFAULT_FINGERPRINT}"

usage() {
	cat <<EOF
Usage:
  ${SCRIPT_NAME} install [--port PORT] [--sni DOMAIN] [--server ADDRESS]
  ${SCRIPT_NAME} uninstall
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} url [--qr]
  ${SCRIPT_NAME} show-state
  ${SCRIPT_NAME} logs
  ${SCRIPT_NAME} start
  ${SCRIPT_NAME} stop
  ${SCRIPT_NAME} restart
  ${SCRIPT_NAME} backup
  ${SCRIPT_NAME} set-port PORT
  ${SCRIPT_NAME} set-sni DOMAIN
  ${SCRIPT_NAME} set-server ADDRESS
  ${SCRIPT_NAME} rotate-secrets
  ${SCRIPT_NAME} help

Notes:
  - First install generates random UUID, Reality keys, and Short ID.
  - Reruns reuse saved values from ${STATE_FILE}.
  - Install enables BBR congestion control when the kernel supports it.
  - Use rotate-secrets if you want brand new client credentials.
EOF
}

say() {
	printf '[*] %s\n' "$*"
}

warn() {
	printf '[!] %s\n' "$*" >&2
}

die() {
	printf '[x] %s\n' "$*" >&2
	exit 1
}

require_root() {
	[[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

require_command() {
	command_exists "$1" || die "Missing required command: $1"
}

require_install_capabilities() {
	require_command bash
	require_command curl
	require_command apt-get
	require_command dpkg
}

require_uninstall_capabilities() {
	require_command bash
	require_command curl
}

install_config_file() {
	local source_file="$1"

	if id -u xray >/dev/null 2>&1 && getent group xray >/dev/null 2>&1; then
		install -o root -g xray -m 640 "${source_file}" "${CONFIG_FILE}"
	elif id -u nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
		install -o root -g nogroup -m 640 "${source_file}" "${CONFIG_FILE}"
	else
		install -m 644 "${source_file}" "${CONFIG_FILE}"
	fi
}

prompt_default() {
	local prompt="$1"
	local default_value="$2"
	local reply

	read -r -p "${prompt} [${default_value}]: " reply
	printf '%s' "${reply:-$default_value}"
}

ensure_directories() {
	mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${CONFIG_DIR}"
	chmod 700 "${STATE_DIR}"
}

configure_bbr() {
	local available_controls current_control

	require_command sysctl

	cat >"${BBR_SYSCTL_FILE}" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

	if ! sysctl -q -p "${BBR_SYSCTL_FILE}" >/dev/null 2>&1; then
		warn "Failed to apply BBR settings immediately. The sysctl file was still written to ${BBR_SYSCTL_FILE}."
		return 0
	fi

	available_controls="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
	current_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

	if [[ "${available_controls}" != *bbr* ]]; then
		warn "Kernel does not report BBR as available."
		return 0
	fi

	if [[ "${current_control}" == "bbr" ]]; then
		say "BBR congestion control enabled."
	else
		warn "BBR settings were written, but the active congestion control is still ${current_control:-unknown}."
	fi
}

cleanup_bbr() {
	if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
		rm -f "${BBR_SYSCTL_FILE}"
		say "Removed ${BBR_SYSCTL_FILE}"
		if command_exists sysctl; then
			sysctl --system >/dev/null 2>&1 || warn "Failed to reload sysctl settings after removing BBR config."
		fi
	fi
}

detect_public_ipv4() {
	local ip=""
	ip="$(curl -fsS4 --max-time 3 https://api.ipify.org 2>/dev/null || true)"
	if [[ -z "${ip}" ]]; then
		ip="$(curl -fsS4 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)"
	fi
	printf '%s' "${ip}"
}

detect_public_ipv6() {
	local ip=""
	ip="$(curl -fsS6 --max-time 3 https://api64.ipify.org 2>/dev/null || true)"
	if [[ -z "${ip}" ]]; then
		ip="$(curl -fsS6 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)"
	fi
	printf '%s' "${ip}"
}

default_server_address() {
	local ipv4 ipv6
	ipv4="$(detect_public_ipv4)"
	ipv6="$(detect_public_ipv6)"

	if [[ -n "${ipv4}" ]]; then
		printf '%s' "${ipv4}"
		return 0
	fi

	if [[ -n "${ipv6}" ]]; then
		printf '%s' "${ipv6}"
		return 0
	fi

	printf '%s' "your.server.ip"
}

install_packages() {
	local packages=()
	local pkg

	for pkg in curl ca-certificates jq qrencode openssl; do
		if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
			packages+=("${pkg}")
		fi
	done

	if ((${#packages[@]} > 0)); then
		say "Installing required packages: ${packages[*]}"
		apt-get update -qq
		apt-get install -y "${packages[@]}"
	fi
}

install_or_update_xray() {
	say "Installing or updating Xray."
	bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install
	bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install-geodata
}

remove_xray() {
	say "Removing Xray."
	bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ remove --purge
}

generate_uuid() {
	cat /proc/sys/kernel/random/uuid
}

generate_short_id() {
	openssl rand -hex 8
}

extract_x25519_field() {
	local key_output="$1"
	local field="$2"

	case "${field}" in
	private)
		printf '%s\n' "${key_output}" | awk -F': *' 'tolower($1) ~ /private/ { print $2; exit }'
		;;
	public)
		printf '%s\n' "${key_output}" | awk -F': *' 'tolower($1) ~ /public/ { print $2; exit }'
		;;
	*)
		die "Unknown x25519 field requested: ${field}"
		;;
	esac
}

generate_reality_keys() {
	local key_output

	key_output="$(xray x25519)"
	PRIVATE_KEY="$(extract_x25519_field "${key_output}" private)"
	PUBLIC_KEY="$(extract_x25519_field "${key_output}" public)"

	[[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Failed to generate Reality keys from xray x25519 output."
}

derive_public_key() {
	local key_output

	[[ -n "${PRIVATE_KEY}" ]] || die "Cannot derive a public key without a private key."
	key_output="$(xray x25519 -i "${PRIVATE_KEY}")"
	PRIVATE_KEY="$(extract_x25519_field "${key_output}" private)"
	PUBLIC_KEY="$(extract_x25519_field "${key_output}" public)"

	[[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "Failed to derive the public key from xray x25519 output."
}

load_state() {
	if [[ -f "${STATE_FILE}" ]]; then
		# shellcheck disable=SC1090
		. "${STATE_FILE}"
	fi

	PORT="${PORT:-${DEFAULT_PORT}}"
	SNI_DOMAIN="${SNI_DOMAIN:-${DEFAULT_SNI}}"
	SERVER_ADDRESS="${SERVER_ADDRESS:-}"
	UUID_VALUE="${UUID_VALUE:-}"
	PRIVATE_KEY="${PRIVATE_KEY:-}"
	PUBLIC_KEY="${PUBLIC_KEY:-}"
	SHORT_ID="${SHORT_ID:-}"
	FINGERPRINT="${FINGERPRINT:-${DEFAULT_FINGERPRINT}}"
}

save_state() {
	ensure_directories

	umask 077
	{
		printf 'PORT=%q\n' "${PORT}"
		printf 'SNI_DOMAIN=%q\n' "${SNI_DOMAIN}"
		printf 'SERVER_ADDRESS=%q\n' "${SERVER_ADDRESS}"
		printf 'UUID_VALUE=%q\n' "${UUID_VALUE}"
		printf 'PRIVATE_KEY=%q\n' "${PRIVATE_KEY}"
		printf 'PUBLIC_KEY=%q\n' "${PUBLIC_KEY}"
		printf 'SHORT_ID=%q\n' "${SHORT_ID}"
		printf 'FINGERPRINT=%q\n' "${FINGERPRINT}"
	} >"${STATE_FILE}"
	chmod 600 "${STATE_FILE}"
}

import_state_from_config() {
	[[ -f "${CONFIG_FILE}" ]] || return 0
	command_exists jq || return 0

	say "Importing values from the current Xray config."

	PORT="$(jq -r '.inbounds[0].port // empty' "${CONFIG_FILE}")"
	SNI_DOMAIN="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "${CONFIG_FILE}")"
	UUID_VALUE="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "${CONFIG_FILE}")"
	PRIVATE_KEY="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "${CONFIG_FILE}")"
	SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "${CONFIG_FILE}")"

	PORT="${PORT:-${DEFAULT_PORT}}"
	SNI_DOMAIN="${SNI_DOMAIN:-${DEFAULT_SNI}}"
}

ensure_state() {
	load_state

	if [[ ! -f "${STATE_FILE}" && -f "${CONFIG_FILE}" ]]; then
		import_state_from_config
	fi

	if [[ -z "${SERVER_ADDRESS}" ]]; then
		SERVER_ADDRESS="$(default_server_address)"
	fi

	if [[ -z "${UUID_VALUE}" ]]; then
		UUID_VALUE="$(generate_uuid)"
	fi

	if [[ -n "${PRIVATE_KEY}" && -z "${PUBLIC_KEY}" ]]; then
		derive_public_key
	elif [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
		generate_reality_keys
	fi

	if [[ -z "${SHORT_ID}" ]]; then
		SHORT_ID="$(generate_short_id)"
	fi

	save_state
}

validate_port() {
	[[ "$1" =~ ^[0-9]+$ ]] || die "Port must be a number."
	(("$1" >= 1 && "$1" <= 65535)) || die "Port must be between 1 and 65535."
}

validate_short_id() {
	[[ "$1" =~ ^[a-f0-9]{0,16}$ ]] || die "Short ID must be 0-16 lowercase hex characters."
	((${#1} % 2 == 0)) || die "Short ID must have an even number of hex characters."
}

backup_config() {
	local stamp backup_file

	[[ -f "${CONFIG_FILE}" ]] || return 0

	stamp="$(date +%Y%m%d-%H%M%S)"
	backup_file="${BACKUP_DIR}/config-${stamp}.json"
	cp -a "${CONFIG_FILE}" "${backup_file}"
	say "Backed up config to ${backup_file}"
}

render_config() {
	local tmp_config test_output

	[[ -n "${SNI_DOMAIN}" ]] || die "SNI domain cannot be empty."
	[[ -n "${SERVER_ADDRESS}" ]] || die "Server address cannot be empty."
	validate_port "${PORT}"
	validate_short_id "${SHORT_ID}"
	ensure_directories
	tmp_config="$(mktemp "${TMPDIR:-/tmp}/xray-config-XXXXXX.json")"

	cat >"${tmp_config}" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_VALUE}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${SNI_DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

	if ! test_output="$(xray run -test -config "${tmp_config}" 2>&1)"; then
		warn "Generated config validation failed."
		printf '%s\n' "${test_output}" >&2
		warn "Generated config was left at ${tmp_config} for inspection."
		die "Xray rejected the generated config."
	fi
	backup_config
	install_config_file "${tmp_config}"
	rm -f "${tmp_config}"
	say "Wrote ${CONFIG_FILE}"
}

service_action() {
	local action="$1"

	if command_exists systemctl; then
		systemctl "${action}" xray
	else
		service xray "${action}"
	fi
}

enable_service() {
	if command_exists systemctl; then
		systemctl enable xray >/dev/null
	else
		warn "systemctl is not available, skipping service enable."
	fi
}

show_status() {
	load_state

	printf 'Installed: %s\n' "$([[ -x /usr/local/bin/xray ]] && echo yes || echo no)"
	printf 'Config file: %s\n' "$([[ -f "${CONFIG_FILE}" ]] && echo present || echo missing)"
	printf 'State file: %s\n' "$([[ -f "${STATE_FILE}" ]] && echo present || echo missing)"

	if command_exists systemctl; then
		printf 'Service: %s\n' "$(systemctl is-active xray 2>/dev/null || true)"
	fi

	if [[ -f "${STATE_FILE}" ]]; then
		printf 'Server address: %s\n' "${SERVER_ADDRESS:-unset}"
		printf 'SNI domain: %s\n' "${SNI_DOMAIN:-unset}"
		printf 'Port: %s\n' "${PORT:-unset}"
		printf 'UUID: %s\n' "${UUID_VALUE:-unset}"
		printf 'Public key: %s\n' "${PUBLIC_KEY:-unset}"
		printf 'Short ID: %s\n' "${SHORT_ID:-unset}"
	fi
}

show_state() {
	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."
	printf 'Server address: %s\n' "${SERVER_ADDRESS}"
	printf 'SNI domain: %s\n' "${SNI_DOMAIN}"
	printf 'Port: %s\n' "${PORT}"
	printf 'UUID: %s\n' "${UUID_VALUE}"
	printf 'Private key: %s\n' "${PRIVATE_KEY}"
	printf 'Public key: %s\n' "${PUBLIC_KEY}"
	printf 'Short ID: %s\n' "${SHORT_ID}"
	printf 'Fingerprint: %s\n' "${FINGERPRINT}"
}

url_host() {
	if [[ "${SERVER_ADDRESS}" == *:* && "${SERVER_ADDRESS}" != \[*\] ]]; then
		printf '[%s]' "${SERVER_ADDRESS}"
	else
		printf '%s' "${SERVER_ADDRESS}"
	fi
}

show_url() {
	local host url show_qr="${1:-0}"

	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."

	host="$(url_host)"
	url="vless://${UUID_VALUE}@${host}:${PORT}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${SNI_DOMAIN}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#xray-reality"
	printf '%s\n' "${url}"

	if [[ "${show_qr}" == "1" ]]; then
		qrencode -t ANSIUTF8 "${url}"
	fi
}

show_logs() {
	if command_exists journalctl; then
		journalctl -u xray -n 50 --no-pager
	else
		die "journalctl is not available on this system."
	fi
}

confirm_uninstall() {
	local reply

	if [[ -t 0 ]]; then
		read -r -p "Remove Xray, config, logs, and saved state? [y/N]: " reply
		[[ "${reply}" =~ ^[Yy]$ ]] || die "Uninstall cancelled."
	fi
}

interactive_install_values() {
	if [[ -t 0 ]]; then
		SERVER_ADDRESS="$(prompt_default "Server address for client URL" "${SERVER_ADDRESS}")"
		SNI_DOMAIN="$(prompt_default "Reality target domain" "${SNI_DOMAIN}")"
		PORT="$(prompt_default "Listening port" "${PORT}")"
	fi
}

apply_install_overrides() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--port)
			[[ $# -ge 2 ]] || die "Missing value for --port."
			PORT="$2"
			shift 2
			;;
		--sni)
			[[ $# -ge 2 ]] || die "Missing value for --sni."
			SNI_DOMAIN="$2"
			shift 2
			;;
		--server)
			[[ $# -ge 2 ]] || die "Missing value for --server."
			SERVER_ADDRESS="$2"
			shift 2
			;;
		*)
			die "Unknown install option: $1"
			;;
		esac
	done
}

install_flow() {
	require_root
	require_install_capabilities
	install_packages
	configure_bbr
	install_or_update_xray
	ensure_state
	apply_install_overrides "$@"
	interactive_install_values
	validate_port "${PORT}"
	save_state
	render_config
	enable_service
	service_action restart
	say "Install complete."
	show_status
	printf '\nClient URL:\n'
	show_url 0
}

set_port_flow() {
	require_root
	[[ $# -eq 1 ]] || die "Usage: ${SCRIPT_NAME} set-port PORT"
	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."
	validate_port "$1"
	PORT="$1"
	save_state
	render_config
	service_action restart
	say "Port updated to ${PORT}"
}

set_sni_flow() {
	require_root
	[[ $# -eq 1 ]] || die "Usage: ${SCRIPT_NAME} set-sni DOMAIN"
	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."
	[[ -n "$1" ]] || die "SNI domain cannot be empty."
	SNI_DOMAIN="$1"
	save_state
	render_config
	service_action restart
	say "SNI domain updated to ${SNI_DOMAIN}"
}

set_server_flow() {
	require_root
	[[ $# -eq 1 ]] || die "Usage: ${SCRIPT_NAME} set-server ADDRESS"
	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."
	[[ -n "$1" ]] || die "Server address cannot be empty."
	SERVER_ADDRESS="$1"
	save_state
	say "Server address updated to ${SERVER_ADDRESS}"
	show_url 0
}

rotate_secrets_flow() {
	require_root
	load_state
	[[ -f "${STATE_FILE}" ]] || die "No installation state found."
	UUID_VALUE="$(generate_uuid)"
	SHORT_ID="$(generate_short_id)"
	generate_reality_keys
	save_state
	render_config
	service_action restart
	warn "Secrets rotated. Existing client profiles must be updated."
	show_url 0
}

backup_flow() {
	require_root
	ensure_directories
	backup_config
	if [[ -f "${STATE_FILE}" ]]; then
		cp -a "${STATE_FILE}" "${BACKUP_DIR}/state-$(date +%Y%m%d-%H%M%S).env"
		say "Backed up state file to ${BACKUP_DIR}"
	fi
}

uninstall_flow() {
	require_root
	require_uninstall_capabilities
	confirm_uninstall

	if [[ -x /usr/local/bin/xray || -f /etc/systemd/system/xray.service || -d "${CONFIG_DIR}" ]]; then
		remove_xray
	else
		warn "Xray does not appear to be installed. Skipping upstream removal."
	fi

	if [[ -d "${STATE_DIR}" ]]; then
		rm -rf "${STATE_DIR}"
		say "Removed ${STATE_DIR}"
	fi

	cleanup_bbr

	say "Uninstall complete."
}

interactive_menu() {
	while true; do
		cat <<EOF

Toby's Xray Manager (VLESS + Reality)
1) Install or refresh setup
2) Uninstall
3) Status
4) Show client URL
5) Restart service
6) Stop service
7) Start service
8) Set SNI domain
9) Set server address
10) Set port
11) Rotate secrets
12) Show saved state
13) Backup config and state
14) Show recent logs
0) Exit
EOF

		read -r -p "Choose an action: " choice

		case "${choice}" in
		1) install_flow ;;
		2) uninstall_flow ;;
		3) show_status ;;
		4) show_url 1 ;;
		5)
			require_root
			service_action restart
			;;
		6)
			require_root
			service_action stop
			;;
		7)
			require_root
			service_action start
			;;
		8)
			read -r -p "New SNI domain: " choice
			set_sni_flow "${choice}"
			;;
		9)
			read -r -p "New server address: " choice
			set_server_flow "${choice}"
			;;
		10)
			read -r -p "New port: " choice
			set_port_flow "${choice}"
			;;
		11) rotate_secrets_flow ;;
		12) show_state ;;
		13) backup_flow ;;
		14) show_logs ;;
		0) exit 0 ;;
		*) warn "Invalid choice." ;;
		esac
	done
}

main() {
	local command="${1:-}"

	case "${command}" in
	"")
		interactive_menu
		;;
	install)
		shift
		install_flow "$@"
		;;
	uninstall)
		uninstall_flow
		;;
	status)
		show_status
		;;
	url)
		shift
		if [[ "${1:-}" == "--qr" ]]; then
			show_url 1
		else
			show_url 0
		fi
		;;
	show-state)
		show_state
		;;
	logs)
		show_logs
		;;
	start | stop | restart)
		require_root
		service_action "${command}"
		;;
	backup)
		backup_flow
		;;
	set-port)
		shift
		set_port_flow "$@"
		;;
	set-sni)
		shift
		set_sni_flow "$@"
		;;
	set-server)
		shift
		set_server_flow "$@"
		;;
	rotate-secrets)
		rotate_secrets_flow
		;;
	help | -h | --help)
		usage
		;;
	*)
		die "Unknown command: ${command}"
		;;
	esac
}

main "$@"

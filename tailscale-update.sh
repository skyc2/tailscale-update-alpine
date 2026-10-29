#!/bin/sh
# tailscale-update: keep Tailscale on Alpine Linux at the latest official release.
#
# Alpine's tailscale package (even in edge/testing) regularly lags behind the
# upstream releases and their security fixes. This script replaces it with the
# official static builds from pkgs.tailscale.com, checks for new releases from
# a daily cron job, and rolls back to the last known-good version when a new
# release does not come up healthy.
#
# The update is safe to run over an SSH session that itself goes through
# Tailscale: everything is downloaded and verified before tailscaled is
# stopped, and the work runs detached from the terminal so it finishes (or
# rolls back) even if the connection drops while tailscaled restarts.
#
# https://github.com/skyc2/tailscale-update-alpine
#
# 'local' is not POSIX but is supported by busybox ash (and dash).
# shellcheck disable=SC3043

set -u

PROG=tailscale-update
PROG_VERSION=1.0.0

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

CONFIG_FILE=${TSU_CONFIG:-/etc/tailscale-update.conf}
if [ -r "$CONFIG_FILE" ]; then
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
fi

# Settings; override them in $CONFIG_FILE.
: "${TRACK:=stable}"                      # stable or unstable
: "${PKGS_URL:=https://pkgs.tailscale.com}"
# Release signature check: yes (installs openssl if needed), auto (only if
# openssl 3 is installed) or no (rely on HTTPS and SHA-256 only).
: "${VERIFY_SIGNATURE:=yes}"
: "${SERVICE:=tailscale}"                 # OpenRC service name
: "${INSTALL_DIR:=/opt/tailscale}"        # one sub-directory per installed version
: "${BIN_DIR:=/usr/local/bin}"
: "${SBIN_DIR:=/usr/local/sbin}"
: "${STATE_DIR:=/var/lib/tailscale-update}"
: "${LOG_FILE:=/var/log/tailscale-update.log}"
: "${HEALTH_TIMEOUT:=120}"                # seconds to wait for tailscaled to come up
: "${KEEP_VERSIONS:=3}"                   # versions kept in $INSTALL_DIR for rollback
: "${CRON_SCHEDULE:=17 4 * * *}"         # when the daily check runs (crontab syntax)
: "${CRON_MAX_DELAY:=3600}"               # random delay (seconds) before a cron run
: "${COMPAT_LINKS:=yes}"                  # link /usr/sbin/tailscaled and /usr/bin/tailscale

INIT_SCRIPT=/etc/init.d/$SERVICE
CONFD=/etc/conf.d/$SERVICE
SELF_PATH=$SBIN_DIR/$PROG
BACKUP_DIR=$STATE_DIR/backup
LOCK_DIR=$STATE_DIR/lock
MARKER="Managed by $PROG"
CRON_TAG="# $PROG"
APK_PACKAGES="tailscale tailscale-openrc tailscale-doc tailscale-bash-completion
	tailscale-fish-completion tailscale-zsh-completion tailscale-systemd"
# Files of Alpine's tailscale-openrc package that are kept when it is removed.
APK_KEEP_FILES="/etc/conf.d/tailscale /etc/logrotate.d/tailscale
	/etc/doas.d/tailscale.conf /usr/libexec/tailscale/resolvconf"

# Root keys that certify Tailscale's release signing keys, from
# https://github.com/tailscale/tailscale/tree/main/clientupdate/distsign/roots
: "${DISTSIGN_ROOTS:=Psrabv2YNiEDhPlnLVSMtB5EKACm7zxvKxfvYD4i7X8=
ZjjKhUHBtLNRSO1dhOTjrXJGJ8lDe1594WM2XDuheVQ=}"

ARCH=
TS_SOCKET=/run/tailscale/tailscaled.sock
TS_STATEDIR=/var/lib/tailscale
DS_STATE=
DS_VERSION=
START=0
WANT=
STAGING=
LOCKED=0
WORKER_PID=$$

# --- Helpers -----------------------------------------------------------------

log() {
	local line
	line="$(date '+%Y-%m-%d %H:%M:%S') $*"
	printf '%s\n' "$line" >&2
	if [ "${TSU_TEE:-0}" = 1 ]; then
		printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null
	fi
	return 0
}

warn() { log "WARNING: $*"; }

die() {
	log "ERROR: $*"
	exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "$PROG must be run as root"; }

usage() {
	cat <<EOF
Usage: $PROG [options] [command]

Replace Alpine's tailscale package with the official Tailscale build, keep it
up to date and roll back automatically when an update fails.

Commands:
  update        Install the latest release, migrating from the Alpine
                packages on first use (default)
  rollback      Switch back to the previous known-good version and skip the
                current one until a newer release is out
  status        Show installed, known-good and latest versions
  install-cron  Install this script as $SELF_PATH and run it daily
  remove-cron   Remove the daily cron job
  print-init-script
                Print the OpenRC script that is installed as $INIT_SCRIPT

Options:
  -f, --force        Retry a version that failed before, or downgrade
  -t, --track NAME   Release track: stable (default) or unstable
      --no-cron      Do not install the daily cron job
      --foreground   Do not detach from the terminal
      --cron         Run as the cron job (random delay, log to file only)
  -V, --version      Print the version of this script
  -h, --help         Show this help

Settings can be changed in $CONFIG_FILE. The log is written to $LOG_FILE.
EOF
}

# fetch URL DEST: download URL to DEST ('-' for stdout).
fetch() {
	if have curl; then
		curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 -o "$2" "$1"
	else
		wget -q -T 60 -O "$2" "$1"
	fi
}

# Print Tailscale's name for this machine's architecture.
ts_arch() {
	local m
	m=$(apk --print-arch 2>/dev/null) || m=$(uname -m)
	case $m in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	armhf | armv7 | armv7l | armv6l) echo arm ;;
	x86 | i386 | i486 | i586 | i686) echo 386 ;;
	riscv64) echo riscv64 ;;
	*) return 1 ;;
	esac
}

valid_version() {
	case $1 in
	'' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	return 0
}

# Print '<', '=' or '>' comparing version $1 to $2.
vercmp() { apk version -t "$1" "$2"; }

# Version number of an installed version id ("1.80.2" or "1.78.1-apk").
ver_of() { printf '%s\n' "${1%%-*}"; }

state_get() { cat "$STATE_DIR/$1" 2>/dev/null; }

state_set() {
	mkdir -p "$STATE_DIR" && printf '%s\n' "$2" >"$STATE_DIR/$1"
}

is_failed() {
	grep -qxF "$1" "$STATE_DIR/failed" 2>/dev/null
}

mark_failed() {
	is_failed "$1" && return 0
	mkdir -p "$STATE_DIR" && printf '%s\n' "$1" >>"$STATE_DIR/failed"
}

clear_failed() {
	local rest
	[ -f "$STATE_DIR/failed" ] || return 0
	rest=$(grep -vxF "$1" "$STATE_DIR/failed")
	printf '%s\n' "$rest" | sed '/^$/d' >"$STATE_DIR/failed"
}

# Print the value of variable $1 as set by $CONFD, or $2.
confd_value() {
	(
		set +u
		if [ -r "$CONFD" ]; then
			# shellcheck source=/dev/null
			. "$CONFD" >/dev/null 2>&1
		fi
		eval "value=\${$1:-}"
		# shellcheck disable=SC2154 # assigned by eval
		printf '%s\n' "${value:-$2}"
	)
}

load_service_config() {
	TS_SOCKET=$(confd_value socket /run/tailscale/tailscaled.sock)
	TS_STATEDIR=$(confd_value statedir /var/lib/tailscale)
}

# Absolute path of this script, if it is a file on disk.
script_path() {
	local p
	case $0 in
	*/*) p=$0 ;;
	*)
		# "sh tailscale-update.sh" reads the script from the current directory.
		if [ -f "$0" ]; then
			p=./$0
		else
			p=$(command -v -- "$0" 2>/dev/null) || return 1
		fi
		;;
	esac
	[ -f "$p" ] && grep -q "^PROG=$PROG\$" "$p" 2>/dev/null || return 1
	printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

trim_log() {
	local size
	[ -f "$LOG_FILE" ] || return 0
	size=$(wc -c <"$LOG_FILE")
	[ "$size" -gt 1048576 ] || return 0
	tail -n 5000 "$LOG_FILE" >"$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
}

# --- Service and daemon ------------------------------------------------------

svc_running() { rc-service -q "$SERVICE" status >/dev/null 2>&1; }

svc_stop() {
	svc_running || return 0
	log "Stopping $SERVICE"
	rc-service "$SERVICE" stop || warn "failed to stop $SERVICE"
}

svc_start() {
	log "Starting $SERVICE"
	if svc_running; then
		rc-service "$SERVICE" restart
	else
		rc-service "$SERVICE" start
	fi
}

ts_cli() {
	local cli="$BIN_DIR/tailscale"
	[ -x "$cli" ] || cli=$(command -v tailscale 2>/dev/null) || return 1
	"$cli" --socket="$TS_SOCKET" "$@"
}

json_field() {
	printf '%s\n' "$1" |
		sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" |
		head -n 1
}

# Query the running daemon; sets DS_STATE and DS_VERSION.
daemon_status() {
	local json
	json=$(ts_cli status --json --peers=false 2>/dev/null)
	[ -n "$json" ] || json=$(ts_cli status --json 2>/dev/null)
	DS_STATE=$(json_field "$json" BackendState)
	DS_VERSION=$(json_field "$json" Version)
	[ -n "$DS_STATE" ]
}

# Note how tailscale runs now, to get back to the same after a switch: sets
# START (1 if the service is up) and WANT (Running if it is connected).
probe_service() {
	START=0
	WANT=
	svc_running || return 0
	START=1
	if daemon_status && [ "$DS_STATE" = Running ]; then
		WANT=Running
	fi
	return 0
}

# wait_healthy ID WANT_STATE: wait for tailscaled of version ID to be up and,
# if WANT_STATE is set, in that backend state.
wait_healthy() {
	local ver want="$2" waited=0
	ver=$(ver_of "$1")
	while :; do
		DS_STATE=
		DS_VERSION=
		if svc_running && daemon_status; then
			case $DS_VERSION in
			"$ver" | "$ver"-*)
				if [ -n "$want" ]; then
					[ "$DS_STATE" = "$want" ] && break
				elif [ "$DS_STATE" != NoState ]; then
					break
				fi
				;;
			esac
		fi
		if [ "$waited" -ge "$HEALTH_TIMEOUT" ]; then
			log "tailscaled $ver is not healthy after ${HEALTH_TIMEOUT}s" \
				"(daemon version ${DS_VERSION:-none}, state ${DS_STATE:-none}${want:+, expected $want})"
			return 1
		fi
		sleep 2
		waited=$((waited + 2))
	done
	log "tailscaled ${DS_VERSION} is up (state $DS_STATE)"
}

# --- Versions on disk --------------------------------------------------------

# Print the id of the version the managed links point to.
current_id() {
	local t
	t=$(readlink "$SBIN_DIR/tailscaled" 2>/dev/null) || return 1
	case $t in
	"$INSTALL_DIR"/*/tailscaled) ;;
	*) return 1 ;;
	esac
	t=${t#"$INSTALL_DIR"/}
	printf '%s\n' "${t%/tailscaled}"
}

# Print the path of a tailscaled not managed by this script.
find_unmanaged() {
	local p
	for p in /usr/sbin/tailscaled "$SBIN_DIR/tailscaled" "$(command -v tailscaled 2>/dev/null)"; do
		if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	done
	return 1
}

bin_version() { "$1" --version 2>/dev/null | head -n 1; }

# import_id TAILSCALED SUFFIX: print the id to keep TAILSCALED under.
import_id() {
	local v
	v=$(bin_version "$1")
	valid_version "$v" || die "cannot tell the version of $1 ('$v')"
	printf '%s-%s\n' "$v" "$2"
}

apk_installed() {
	local p out=''
	for p in $APK_PACKAGES; do
		if apk info -e "$p" >/dev/null 2>&1; then
			out="$out $p"
		fi
	done
	printf '%s\n' "${out# }"
}

# import_binaries TAILSCALED ID: copy an existing installation into
# $INSTALL_DIR/ID so that it can be rolled back to.
import_binaries() {
	local src="$1" dest="$INSTALL_DIR/$2" cli=''
	[ -x "$dest/tailscaled" ] && [ -x "$dest/tailscale" ] && return 0
	log "Keeping a copy of the installed tailscale ($src) as $dest for rollback"
	rm -rf "$dest.tmp"
	mkdir -p "$dest.tmp" || return 1
	cp -L "$src" "$dest.tmp/tailscaled" || return 1
	for cli in /usr/bin/tailscale "$BIN_DIR/tailscale" "$(command -v tailscale 2>/dev/null)" ''; do
		[ -n "$cli" ] && [ -x "$cli" ] && break
	done
	if [ -z "$cli" ] || [ "$(readlink -f "$cli")" = "$(readlink -f "$src")" ]; then
		# Alpine builds a single binary that acts as the CLI when invoked as
		# "tailscale".
		ln -s tailscaled "$dest.tmp/tailscale" || return 1
	else
		cp -L "$cli" "$dest.tmp/tailscale" || return 1
	fi
	if ! "$dest.tmp/tailscale" version >/dev/null 2>&1; then
		log "the installed tailscale CLI does not work from $dest.tmp"
		return 1
	fi
	rm -rf "$dest"
	mv "$dest.tmp" "$dest"
}

# link_version ID: point the binaries on PATH at version ID.
link_version() {
	local d="$INSTALL_DIR/$1" p
	if [ ! -x "$d/tailscaled" ] || [ ! -x "$d/tailscale" ]; then
		log "missing binaries in $d"
		return 1
	fi
	mkdir -p "$SBIN_DIR" "$BIN_DIR" || return 1
	ln -sfn "$d/tailscaled" "$SBIN_DIR/tailscaled" || return 1
	ln -sfn "$d/tailscale" "$BIN_DIR/tailscale" || return 1
	if [ "$COMPAT_LINKS" = yes ]; then
		for p in /usr/sbin/tailscaled:"$SBIN_DIR/tailscaled" /usr/bin/tailscale:"$BIN_DIR/tailscale"; do
			if [ "${p%%:*}" != "${p#*:}" ] && { [ -L "${p%%:*}" ] || [ ! -e "${p%%:*}" ]; }; then
				ln -sfn "${p#*:}" "${p%%:*}"
			fi
		done
	fi
	log "Linked $SBIN_DIR/tailscaled and $BIN_DIR/tailscale to $d"
}

prune_versions() {
	local good prev n=0 d
	good=$(state_get good)
	prev=$(state_get previous)
	# shellcheck disable=SC2045 # version directory names have no spaces
	for d in $(ls -1t "$INSTALL_DIR" 2>/dev/null); do
		[ -d "$INSTALL_DIR/$d" ] || continue
		n=$((n + 1))
		if [ "$d" = "$good" ] || [ "$d" = "$prev" ] || [ "$n" -le "$KEEP_VERSIONS" ]; then
			continue
		fi
		log "Removing old version $INSTALL_DIR/$d"
		rm -rf "${INSTALL_DIR:?}/$d"
	done
}

# --- Download and verification -----------------------------------------------

# Print the latest version on $TRACK that has a tarball for $ARCH.
latest_version() {
	local json ver
	json=$(fetch "$PKGS_URL/$TRACK/?mode=json&os=linux" -) || return 1
	ver=$(printf '%s' "$json" | tr -d '\r\n' |
		sed -n 's/.*"TarballsVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if ! valid_version "$ver"; then
		log "could not find TarballsVersion in $PKGS_URL/$TRACK/?mode=json"
		return 1
	fi
	case $json in
	*"tailscale_${ver}_${ARCH}.tgz"*) ;;
	*)
		log "Tailscale $ver has no tarball for $ARCH"
		return 1
		;;
	esac
	printf '%s\n' "$ver"
}

openssl_usable() {
	have openssl && openssl dgst -blake2s256 /dev/null >/dev/null 2>&1 &&
		openssl version 2>/dev/null | grep -q '^OpenSSL [3-9]'
}

# Decide whether signatures can be checked; installs openssl if required.
setup_signature_check() {
	case $VERIFY_SIGNATURE in
	no) return 0 ;;
	yes | auto) ;;
	*) die "VERIFY_SIGNATURE must be yes, auto or no" ;;
	esac
	openssl_usable && return 0
	if [ "$VERIFY_SIGNATURE" = yes ]; then
		log "Installing openssl to verify release signatures"
		apk add -q openssl || die "openssl is needed to verify signatures (set VERIFY_SIGNATURE=no to skip)"
		openssl_usable || die "openssl 3 with BLAKE2s support is needed to verify signatures"
	else
		warn "openssl 3 not found; release signatures will not be verified"
		VERIFY_SIGNATURE=no
	fi
}

# ed25519_verify PUBKEY_BASE64 MESSAGE_FILE SIGNATURE_FILE
ed25519_verify() {
	local der="$STAGING/key.der"
	{
		# DER SubjectPublicKeyInfo header for a raw Ed25519 key.
		printf '\060\052\060\005\006\003\053\145\160\003\041\000'
		printf '%s' "$1" | openssl base64 -d -A
	} >"$der" 2>/dev/null || return 1
	[ "$(wc -c <"$der")" -eq 44 ] || return 1
	openssl pkeyutl -verify -pubin -keyform DER -inkey "$der" -rawin \
		-in "$2" -sigfile "$3" >/dev/null 2>&1
}

# verify_any KEYS MESSAGE_FILE SIGNATURE_FILE: succeed if any key verifies.
verify_any() {
	local k
	for k in $1; do
		ed25519_verify "$k" "$2" "$3" && return 0
	done
	return 1
}

# Print the base64 keys of a PEM bundle, one per line, if all blocks are of
# type $2.
pem_keys() {
	awk -v type="$2" '
		/^-----BEGIN / { t = $0; sub(/^-----BEGIN /, "", t); sub(/-----$/, "", t)
			if (t != type) exit 1; key = ""; inside = 1; next }
		/^-----END / { if (inside) print key; inside = 0; next }
		inside { gsub(/[ \t\r]/, ""); key = key $0 }
	' "$1"
}

# verify_signature FILE URL: check FILE against Tailscale's signature URL.sig.
verify_signature() {
	local file="$1" url="$2" keys size i b
	if ! fetch "$PKGS_URL/distsign.pub" "$STAGING/distsign.pub" ||
		! fetch "$PKGS_URL/distsign.pub.sig" "$STAGING/distsign.pub.sig"; then
		log "could not download the release signing keys"
		return 1
	fi
	if ! verify_any "$DISTSIGN_ROOTS" "$STAGING/distsign.pub" "$STAGING/distsign.pub.sig"; then
		log "the release signing keys are not signed by a known Tailscale root key"
		return 1
	fi
	keys=$(pem_keys "$STAGING/distsign.pub" "SIGNING PUBLIC KEY") || keys=
	if [ -z "$keys" ]; then
		log "could not parse the release signing keys"
		return 1
	fi
	if ! fetch "$url.sig" "$STAGING/file.sig"; then
		log "could not download $url.sig"
		return 1
	fi
	# The signed message is the BLAKE2s-256 hash of the file followed by its
	# length as a little-endian uint64.
	size=$(wc -c <"$file")
	{
		openssl dgst -blake2s256 -binary "$file"
		i=0
		while [ "$i" -lt 8 ]; do
			b=$(((size >> (8 * i)) & 255))
			# shellcheck disable=SC2059 # octal escape built on purpose
			printf "\\$(printf '%03o' "$b")"
			i=$((i + 1))
		done
	} >"$STAGING/file.msg" || return 1
	if ! verify_any "$keys" "$STAGING/file.msg" "$STAGING/file.sig"; then
		log "BAD SIGNATURE for $url"
		return 1
	fi
	log "Signature OK"
}

# stage_release VERSION: download, verify and unpack VERSION into
# $INSTALL_DIR/VERSION.
stage_release() {
	local ver="$1" dest="$INSTALL_DIR/$1" name="tailscale_${1}_$ARCH" url want got
	if [ -x "$dest/tailscaled" ] && [ -x "$dest/tailscale" ] &&
		[ "$(bin_version "$dest/tailscaled")" = "$ver" ]; then
		log "Tailscale $ver is already downloaded"
		return 0
	fi
	mkdir -p "$INSTALL_DIR" || return 1
	STAGING=$(mktemp -d "$INSTALL_DIR/.staging.XXXXXX") || return 1
	url=$PKGS_URL/$TRACK/$name.tgz

	log "Downloading $url"
	fetch "$url" "$STAGING/$name.tgz" || {
		log "download of $url failed"
		return 1
	}
	if fetch "$url.sha256" "$STAGING/$name.tgz.sha256"; then
		want=$(awk '{ print $1; exit }' "$STAGING/$name.tgz.sha256")
		got=$(sha256sum "$STAGING/$name.tgz" | awk '{ print $1 }')
		if [ "$want" != "$got" ]; then
			log "SHA-256 mismatch for $name.tgz: expected '$want', got '$got'"
			return 1
		fi
		log "SHA-256 OK"
	elif [ "$VERIFY_SIGNATURE" = no ]; then
		log "could not download $url.sha256"
		return 1
	else
		warn "could not download $url.sha256; relying on the signature"
	fi
	if [ "$VERIFY_SIGNATURE" != no ]; then
		verify_signature "$STAGING/$name.tgz" "$url" || return 1
	fi

	tar -xzf "$STAGING/$name.tgz" -C "$STAGING" || return 1
	mkdir "$STAGING/out" || return 1
	for got in tailscale tailscaled; do
		if [ ! -f "$STAGING/$name/$got" ]; then
			log "$name.tgz does not contain $got"
			return 1
		fi
		mv "$STAGING/$name/$got" "$STAGING/out/$got" && chmod 0755 "$STAGING/out/$got" || return 1
	done
	got=$(bin_version "$STAGING/out/tailscaled")
	if [ "$got" != "$ver" ]; then
		log "the downloaded tailscaled does not run on this machine (reports '$got', expected $ver)"
		return 1
	fi
	rm -rf "$dest"
	mv "$STAGING/out" "$dest" || return 1
	rm -rf "$STAGING"
	STAGING=
	log "Tailscale $ver unpacked to $dest"
}

# --- Service files -----------------------------------------------------------

render_init_script() {
	sed "s|@SBIN_DIR@|$SBIN_DIR|g; s|@MARKER@|$MARKER|g; s|@CONFD@|$CONFD|g" <<'EOF'
#!/sbin/openrc-run
# shellcheck shell=sh disable=SC2034,SC2154
# @MARKER@; local changes will be overwritten.
# Settings are read from @CONFD@, which is compatible with the
# file installed by Alpine's tailscale-openrc package.

: "${capabilities=^cap_net_admin,cap_net_raw}"
: "${logfile=${TAILSCALED_LOGFILE:-/var/log/tailscaled.log}}"
: "${no_logs_no_support:=no}"
: "${port:=${TAILSCALED_PORT:-41641}}"
: "${socket:=/run/tailscale/tailscaled.sock}"
: "${statedir:=/var/lib/tailscale}"
: "${supervisor=supervise-daemon}"
: "${verbose:=0}"
if [ -z "${command_user:-}" ]; then
	if grep -q '^tailscale:' /etc/group 2>/dev/null; then
		command_user="root:tailscale"
	else
		command_user="root"
	fi
fi

name="Tailscale"
description="Tailscale node agent (official build)"
command="@SBIN_DIR@/tailscaled"
command_args="--socket=$socket --state=$statedir/tailscaled.state --port=$port --verbose=$verbose ${TAILSCALED_OPTS:-} ${command_args:-}"
command_background=yes
pidfile="/run/$RC_SVCNAME.pid"
output_log="$logfile"
error_log="$logfile"

# Alpine uses the nftables backend; tailscaled's "auto" detection may pick
# iptables instead. See https://tailscale.com/kb/1294/firewall-mode
export TS_DEBUG_FIREWALL_MODE="${firewall_mode:-nftables}"

depend() {
	need net
	after firewall
	use logger dns
}

start_pre() {
	if yesno "$no_logs_no_support"; then
		command_args="$command_args --no-logs-no-support"
	fi
	if [ -e /usr/sbin/resolvconf ] && command -v doas >/dev/null; then
		# Lets an unprivileged tailscaled update /etc/resolv.conf via doas.
		export PATH="/usr/local/libexec/tailscale:$PATH"
	fi
	[ -e /dev/net/tun ] || modprobe -q tun 2>/dev/null || true
	if [ -n "$logfile" ]; then
		checkpath -f -m 0640 -o "$command_user" "$logfile" || return 1
	fi
	checkpath -d -m 0755 -o "$command_user" "${socket%/*}" || return 1
	if [ ! -d "$statedir" ]; then
		checkpath -d -m 0700 -o "$command_user" "$statedir" || return 1
	fi
}
EOF
}

write_default_confd() {
	cat >"$CONFD" <<'EOF'
# Settings for /etc/init.d/tailscale; uncomment to change the defaults.
#port=41641                        # UDP port for WireGuard, 0 picks one
#firewall_mode=nftables            # nftables, iptables or auto
#no_logs_no_support=no             # yes: send no logs (and get no support)
#verbose=0                         # tailscaled log verbosity
#logfile=/var/log/tailscaled.log   # empty: no log file
#socket=/run/tailscale/tailscaled.sock
#statedir=/var/lib/tailscale
#command_args=                     # extra tailscaled options
#command_user=root
EOF
}

# Copy the files from Alpine's packages that are worth keeping.
backup_apk_files() {
	local f
	rm -rf "$BACKUP_DIR/files"
	for f in $APK_KEEP_FILES; do
		[ -f "$f" ] || continue
		mkdir -p "$BACKUP_DIR/files${f%/*}" && cp -p "$f" "$BACKUP_DIR/files$f" || return 1
	done
}

restore_apk_files() {
	local f dest
	for f in $APK_KEEP_FILES; do
		[ -f "$BACKUP_DIR/files$f" ] || continue
		case $f in
		/usr/libexec/*) dest=/usr/local/libexec/${f#/usr/libexec/} ;;
		*) dest=$f ;;
		esac
		[ -e "$dest" ] && continue
		mkdir -p "${dest%/*}" && cp -p "$BACKUP_DIR/files$f" "$dest" &&
			log "Kept $dest from the Alpine package"
	done
}

install_service_files() {
	restore_apk_files
	[ -f "$CONFD" ] || write_default_confd || return 1
	if [ -f "$INIT_SCRIPT" ] && ! grep -q "$MARKER" "$INIT_SCRIPT"; then
		mkdir -p "$BACKUP_DIR" && cp -p "$INIT_SCRIPT" "$BACKUP_DIR/init.d.$SERVICE.orig"
		warn "replacing $INIT_SCRIPT (saved as $BACKUP_DIR/init.d.$SERVICE.orig)"
	fi
	render_init_script >"$INIT_SCRIPT.tmp" && chmod 0755 "$INIT_SCRIPT.tmp" &&
		mv -f "$INIT_SCRIPT.tmp" "$INIT_SCRIPT" || return 1
	if [ -d /etc/logrotate.d ] && [ ! -e /etc/logrotate.d/tailscale ]; then
		printf '%s\n' '/var/log/tailscaled.log {' '	missingok' '	notifempty' \
			'	copytruncate' '}' >/etc/logrotate.d/tailscale
	fi
}

# prepare_apk_removal PACKAGES: make sure removing PACKAGES works and keeps
# their dependencies (e.g. openresolv), before tailscale is stopped.
prepare_apk_removal() {
	local out keep
	# shellcheck disable=SC2086
	if ! out=$(apk del -s $1 2>&1); then
		log "apk refuses to remove $1:"
		printf '%s\n' "$out" >&2
		return 1
	fi
	case $out in
	*"not removed"*)
		log "apk would not remove $1:"
		printf '%s\n' "$out" >&2
		return 1
		;;
	esac
	keep=$(printf '%s\n' "$out" |
		sed -n 's/^([0-9]*\/[0-9]*) Purging \([^ ]*\) .*/\1/p' | grep -v '^tailscale')
	if [ -n "$keep" ]; then
		keep=$(printf '%s\n' "$keep" | tr '\n' ' ' | sed 's/ *$//')
		log "Keeping dependencies of the Alpine package: $keep"
		# shellcheck disable=SC2086
		apk add -q $keep || return 1
	fi
	backup_apk_files
}

# --- Locking, state and cron -------------------------------------------------

acquire_lock() {
	local pid
	mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			die "another $PROG is running (pid $pid)"
		fi
		rm -rf "$LOCK_DIR"
		mkdir "$LOCK_DIR" || die "cannot create $LOCK_DIR"
	fi
	echo "$WORKER_PID" >"$LOCK_DIR/pid"
	LOCKED=1
}

on_exit() {
	rc=$?
	[ -n "$STAGING" ] && rm -rf "$STAGING"
	[ "$LOCKED" = 1 ] && rm -rf "$LOCK_DIR"
	if [ -n "${TSU_RESULT:-}" ]; then
		echo "$rc" >"$TSU_RESULT"
	fi
	exit "$rc"
}

# tailscaled may run as an unprivileged user (command_user) who owns the state
# directory and could plant links there to redirect root's reads and writes.
# While tailscaled is stopped, the state is copied with the directory made
# root-only, so that nobody else can change its entries meanwhile. The original
# owner and mode are kept in a file until they are put back, so an interrupted
# run can restore them.
lock_statedir() {
	if [ ! -f "$STATE_DIR/statedir.perms" ]; then
		stat -L -c '%u:%g %a' "$TS_STATEDIR" >"$STATE_DIR/statedir.perms" || return 1
	fi
	chown root:root "$TS_STATEDIR" && chmod 700 "$TS_STATEDIR"
}

unlock_statedir() {
	local owner mode
	[ -f "$STATE_DIR/statedir.perms" ] || return 0
	read -r owner mode <"$STATE_DIR/statedir.perms"
	chown "$owner" "$TS_STATEDIR" && chmod "$mode" "$TS_STATEDIR" &&
		rm -f "$STATE_DIR/statedir.perms"
}

# Save the state of the stopped tailscaled for rollback_to. Without a backup a
# rollback keeps the current state.
backup_state() {
	local f="$TS_STATEDIR/tailscaled.state" result=0
	rm -f "$BACKUP_DIR/tailscaled.state" "$BACKUP_DIR/tailscaled.state.perms"
	[ -e "$f" ] || [ -L "$f" ] || return 0
	mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" && lock_statedir || result=1
	if [ "$result" = 0 ]; then
		if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %h "$f")" = 1 ]; then
			stat -c '%u:%g %a' "$f" >"$BACKUP_DIR/tailscaled.state.perms" &&
				(umask 077 && cp "$f" "$BACKUP_DIR/tailscaled.state") || result=1
		else
			log "$f is not a regular file"
			result=1
		fi
	fi
	unlock_statedir || result=1
	if [ "$result" != 0 ]; then
		rm -f "$BACKUP_DIR/tailscaled.state" "$BACKUP_DIR/tailscaled.state.perms"
		warn "not backing up $f; a rollback will keep its current state"
	fi
	return 0
}

restore_state() {
	local f="$TS_STATEDIR/tailscaled.state" perms result=0
	read -r perms <"$BACKUP_DIR/tailscaled.state.perms" || return 1
	lock_statedir || return 1
	rm -f "$f" && (umask 077 && cp "$BACKUP_DIR/tailscaled.state" "$f") &&
		chown "${perms% *}" "$f" && chmod "${perms#* }" "$f" || result=1
	unlock_statedir || result=1
	return "$result"
}

# set_pending FROM TO START WANT: remember an update in progress, so that an
# interrupted update is rolled back on the next run.
set_pending() {
	state_set pending "${1:--} ${2:--} ${3:-0} ${4:--}"
}

clear_pending() { rm -f "$STATE_DIR/pending"; }

install_self() {
	local src
	if ! src=$(script_path); then
		warn "cannot locate this script on disk; not installing $SELF_PATH"
		return 1
	fi
	[ "$src" = "$SELF_PATH" ] && return 0
	cmp -s "$src" "$SELF_PATH" 2>/dev/null && return 0
	mkdir -p "$SBIN_DIR" && cp "$src" "$SELF_PATH.tmp" && chmod 0755 "$SELF_PATH.tmp" &&
		mv -f "$SELF_PATH.tmp" "$SELF_PATH" || return 1
	log "Installed $SELF_PATH"
}

cron_line() {
	local opts=''
	[ "$TRACK" = stable ] || opts=" --track $TRACK"
	printf '%s %s --cron%s >/dev/null 2>&1 %s\n' "$CRON_SCHEDULE" "$SELF_PATH" "$opts" "$CRON_TAG"
}

our_cron_line() { crontab -l 2>/dev/null | grep "$CRON_TAG\$"; }

other_cron_lines() { crontab -l 2>/dev/null | grep -v "$CRON_TAG\$"; }

# Replace root's crontab with stdin.
write_crontab() {
	local tmp result
	tmp=$(mktemp) || return 1
	cat >"$tmp"
	crontab "$tmp"
	result=$?
	rm -f "$tmp"
	return "$result"
}

install_cron() {
	local line
	have crontab || {
		warn "crontab not found; daily update checks are not set up"
		return 1
	}
	install_self || return 1
	line=$(cron_line)
	if [ "$(our_cron_line)" != "$line" ]; then
		{
			other_cron_lines | sed '/./,$!d'
			printf '%s\n' "$line"
		} | write_crontab || return 1
		log "Installed cron job: $line"
	fi
	if [ -e /etc/init.d/crond ]; then
		[ -e /etc/runlevels/default/crond ] || rc-update add crond default >/dev/null 2>&1
		rc-service -q crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 ||
			warn "could not start crond"
	fi
	return 0
}

remove_cron() {
	[ -n "$(our_cron_line)" ] || return 0
	other_cron_lines | write_crontab || return 1
	log "Removed the $PROG cron job"
}

# --- Activation and rollback -------------------------------------------------

# Keep going when interrupted while tailscaled is being switched. Signals are
# caught rather than ignored: ignored signals would be inherited by tailscaled.
defer_signals() {
	trap 'warn "interrupt ignored while switching versions"' INT TERM
}

# start_healthy ID WANT: start tailscaled and wait until version ID is healthy.
start_healthy() {
	svc_start || warn "$SERVICE failed to start"
	wait_healthy "$1" "$2"
}

# activate ID START WANT: switch to version ID; when START is 1, start
# tailscaled and wait for it to become healthy.
activate() {
	svc_stop
	link_version "$1" || return 1
	[ "$2" = 1 ] || return 0
	start_healthy "$1" "$3"
}

# rollback_to ID START WANT
rollback_to() {
	log "Rolling back to $1"
	activate "$1" "$2" "$3" && return 0
	[ "$2" = 1 ] && [ -f "$BACKUP_DIR/tailscaled.state.perms" ] || return 1
	log "Restoring the tailscaled state saved before the update"
	svc_stop
	restore_state || return 1
	start_healthy "$1" "$3"
}

# Finish or roll back an update that was interrupted (e.g. by a reboot).
recover_pending() {
	local from to start want
	[ -f "$STATE_DIR/pending" ] || return 0
	read -r from to start want <"$STATE_DIR/pending"
	[ "$from" = - ] && from=
	[ "$want" = - ] && want=
	warn "an earlier update from ${from:-nothing} to $to did not finish"
	if [ "$(current_id)" = "$to" ] && { [ "$start" != 1 ] || wait_healthy "$to" "$want"; }; then
		log "$to is working; keeping it"
		[ -n "$from" ] && state_set previous "$from"
		state_set good "$to"
	elif [ -n "$from" ] && [ -d "$INSTALL_DIR/$from" ]; then
		install_service_files || warn "could not install $INIT_SCRIPT"
		rollback_to "$from" "$start" "$want" || warn "$from is not healthy either"
		mark_failed "$(ver_of "$to")"
	fi
	clear_pending
}

check_requirements() {
	need_root
	have apk || die "apk not found; this script is for Alpine Linux"
	have rc-service && [ -x /sbin/openrc-run ] || die "OpenRC is required"
	for c in tar sha256sum awk sed readlink mktemp; do
		have "$c" || die "$c not found"
	done
	have curl || have wget || die "curl or wget is required"
	ARCH=$(ts_arch) || die "unsupported architecture: $(uname -m)"
	case $TRACK in
	stable | unstable) ;;
	*) die "unknown track '$TRACK'" ;;
	esac
}

# --- Commands ----------------------------------------------------------------

cmd_update() {
	local latest old='' import='' apk_pkgs cmp v result=0

	if [ "$NO_CRON" != 1 ]; then
		install_cron || warn "could not set up the daily cron job"
	fi
	latest=$(latest_version) || die "could not get the latest $TRACK version from $PKGS_URL"
	apk_pkgs=$(apk_installed)
	if [ -n "$apk_pkgs" ] && [ -x /usr/sbin/tailscaled ] && [ ! -L /usr/sbin/tailscaled ]; then
		import=/usr/sbin/tailscaled
		old=$(import_id "$import" apk) || exit 1
	elif old=$(current_id); then
		:
	elif import=$(find_unmanaged); then
		old=$(import_id "$import" local) || exit 1
	fi
	v=$(ver_of "$old")
	log "Installed: ${old:-none}${apk_pkgs:+ (Alpine packages: $apk_pkgs)}; latest $TRACK: $latest"

	if [ -n "$v" ]; then
		cmp=$(vercmp "$v" "$latest")
		if [ -z "$import" ] && [ "$cmp" = = ]; then
			log "Tailscale is up to date"
			return 0
		fi
		if [ "$cmp" = '>' ] && [ "$FORCE" != 1 ]; then
			log "The installed $v is newer than the latest $TRACK release; use --force to downgrade"
			return 0
		fi
	fi
	if is_failed "$latest" && [ "$FORCE" != 1 ]; then
		log "Skipping $latest: it failed or was rolled back before (use --force to retry)"
		return 0
	fi

	# Everything that needs the network or may fail happens before tailscaled
	# is stopped.
	setup_signature_check
	stage_release "$latest" || die "could not download Tailscale $latest"
	if [ -n "$import" ]; then
		import_binaries "$import" "$old" || die "could not keep a copy of $import for rollback"
	fi
	if [ -n "$apk_pkgs" ]; then
		prepare_apk_removal "$apk_pkgs" || die "cannot remove the Alpine tailscale packages"
	fi
	probe_service
	[ -n "$old" ] || START=1 # fresh install

	log "Switching to Tailscale $latest; tailscale connections will drop for a few seconds"
	defer_signals
	set_pending "$old" "$latest" "$START" "$WANT"
	svc_stop
	backup_state
	if [ -n "$apk_pkgs" ]; then
		log "Removing Alpine packages: $apk_pkgs"
		# shellcheck disable=SC2086
		if ! apk del -q $apk_pkgs; then
			clear_pending
			[ "$START" = 1 ] && rc-service "$SERVICE" start
			die "apk del failed; the Alpine package was left in place"
		fi
	fi
	install_service_files || warn "could not install all service files"
	if [ -z "$old" ] || ! ls /etc/runlevels/*/"$SERVICE" >/dev/null 2>&1; then
		rc-update add "$SERVICE" default >/dev/null && log "Enabled $SERVICE at boot"
	fi

	if activate "$latest" "$START" "$WANT"; then
		[ -n "$old" ] && state_set previous "$old"
		state_set good "$latest"
		clear_failed "$latest"
	elif [ -z "$old" ]; then
		log "ERROR: Tailscale $latest did not come up and there is no older version to roll back to"
		result=1
	elif rollback_to "$old" "$START" "$WANT"; then
		mark_failed "$latest"
		log "Rolled back to $old; $latest will be skipped until a newer release is out"
		result=1
	else
		warn "$old is not healthy either; it was left in place (is the network up?)"
		result=1
	fi
	clear_pending
	trap 'exit 130' INT TERM
	[ "$result" = 0 ] || exit 1

	prune_versions
	log "Tailscale is now at $latest"
	[ "$START" = 1 ] || log "$SERVICE was not running and has not been started"
}

cmd_rollback() {
	local cur prev result=0
	[ -z "$(apk_installed)" ] || die "the Alpine tailscale package is installed; run '$PROG update' first"
	cur=$(current_id) || die "tailscale is not managed by $PROG yet"
	prev=$(state_get previous)
	[ -n "$prev" ] && [ "$prev" != "$cur" ] || die "no previous version recorded"
	[ -d "$INSTALL_DIR/$prev" ] || die "$INSTALL_DIR/$prev no longer exists"
	probe_service

	log "Rolling back from $cur to $prev"
	defer_signals
	set_pending "$cur" "$prev" "$START" "$WANT"
	svc_stop
	backup_state
	if rollback_to "$prev" "$START" "$WANT"; then
		state_set good "$prev"
		state_set previous "$cur"
		mark_failed "$(ver_of "$cur")"
	else
		warn "$prev did not come up; going back to $cur"
		rollback_to "$cur" "$START" "$WANT" || warn "$cur is not healthy either"
		result=1
	fi
	clear_pending
	[ "$result" = 0 ] || exit 1
	log "Now at $prev; $(ver_of "$cur") will be skipped until a newer release is out"
}

cmd_status() {
	local cur latest line
	load_service_config
	ARCH=$(ts_arch) || ARCH=unknown
	cur=$(current_id) || cur="not managed by $PROG"
	echo "Script:          $PROG $PROG_VERSION"
	echo "Architecture:    $ARCH"
	echo "Track:           $TRACK"
	echo "Installed:       $cur"
	echo "Known-good:      $(state_get good)"
	echo "Previous:        $(state_get previous)"
	echo "Alpine packages: $(apk_installed 2>/dev/null)"
	if svc_running && daemon_status; then
		echo "Daemon:          $DS_VERSION ($DS_STATE)"
	else
		echo "Daemon:          not running"
	fi
	if [ "$ARCH" != unknown ] && latest=$(latest_version 2>/dev/null); then
		echo "Latest $TRACK:   $latest"
	else
		echo "Latest $TRACK:   unknown (could not reach $PKGS_URL)"
	fi
	echo "Skipped:         $(tr '\n' ' ' <"$STATE_DIR/failed" 2>/dev/null)"
	line=$(our_cron_line)
	echo "Cron job:        ${line:-not installed}"
	echo "Log:             $LOG_FILE"
}

# Leave the cgroup of the tailscale service, if we are in it (e.g. when run
# from a Tailscale SSH session), so that stopping the service cannot kill us.
leave_service_cgroup() {
	local f
	grep -q "$SERVICE" /proc/self/cgroup 2>/dev/null || return 0
	for f in /sys/fs/cgroup/cgroup.procs /sys/fs/cgroup/*/cgroup.procs; do
		{ printf '%s\n' "$WORKER_PID" >"$f"; } 2>/dev/null || :
	done
}

run_worker() {
	trap on_exit EXIT
	trap 'exit 130' INT TERM
	trap : HUP
	if [ -n "${TSU_RESULT:-}" ]; then
		echo "$WORKER_PID" >"$TSU_RESULT.pid"
	fi
	log "=== $PROG $PROG_VERSION: $1 ==="
	check_requirements
	leave_service_cgroup
	acquire_lock
	load_service_config
	unlock_statedir
	recover_pending
	case $1 in
	update) cmd_update ;;
	rollback) cmd_rollback ;;
	esac
}

# Re-run this script in its own session, logging to $LOG_FILE, and follow the
# log until it finishes. The worker survives losing the terminal, so the
# update completes even when tailscaled carries this SSH connection.
run_detached() {
	local self result size tail_pid pid rc=1 waited=0
	need_root
	mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" || die "cannot create $STATE_DIR"
	trim_log
	: >>"$LOG_FILE"
	result=$STATE_DIR/result.$$
	rm -f "$result" "$result.pid"
	size=$(wc -c <"$LOG_FILE")
	tail -c +"$((size + 1))" -f "$LOG_FILE" &
	tail_pid=$!

	if self=$(script_path) && have setsid; then
		TSU_WORKER=1 TSU_RESULT=$result setsid sh "$self" "$@" </dev/null >>"$LOG_FILE" 2>&1 &
	else
		(
			trap : HUP
			# $$ is still the parent's PID in a subshell.
			read -r WORKER_PID _ </proc/self/stat || WORKER_PID=$$
			TSU_RESULT=$result
			run_worker "$CMD"
		) </dev/null >>"$LOG_FILE" 2>&1 &
	fi
	echo "$PROG is running in the background and will finish even if this" \
		"connection drops. Log: $LOG_FILE" >&2

	trap 'kill "$tail_pid" 2>/dev/null; echo "Detached; follow with: tail -f $LOG_FILE" >&2; exit 0' INT
	while [ ! -s "$result" ]; do
		sleep 1
		waited=$((waited + 1))
		pid=$(cat "$result.pid" 2>/dev/null)
		if [ -n "$pid" ]; then
			kill -0 "$pid" 2>/dev/null || break
		elif [ "$waited" -gt 30 ]; then
			break
		fi
	done
	sleep 1
	kill "$tail_pid" 2>/dev/null
	[ -s "$result" ] && rc=$(cat "$result")
	rm -f "$result" "$result.pid"
	exit "$rc"
}

# --- Main --------------------------------------------------------------------

CMD=update
FORCE=0
NO_CRON=0
FOREGROUND=0
CRON_MODE=0

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) FORCE=1 ;;
		-t | --track)
			[ $# -ge 2 ] || {
				echo "$PROG: $1 needs an argument" >&2
				exit 2
			}
			TRACK=$2
			shift
			;;
		--track=*) TRACK=${1#*=} ;;
		--no-cron) NO_CRON=1 ;;
		--foreground) FOREGROUND=1 ;;
		--cron) CRON_MODE=1 ;;
		-V | --version)
			echo "$PROG $PROG_VERSION"
			exit 0
			;;
		-h | --help)
			usage
			exit 0
			;;
		update | rollback | status | install-cron | remove-cron | print-init-script) CMD=$1 ;;
		*)
			echo "$PROG: unknown argument '$1' (see --help)" >&2
			exit 2
			;;
		esac
		shift
	done
}

parse_args "$@"

case $CMD in
status)
	cmd_status
	;;
print-init-script)
	render_init_script
	;;
install-cron)
	need_root
	install_cron || exit 1
	;;
remove-cron)
	need_root
	remove_cron
	;;
update | rollback)
	if [ "${TSU_WORKER:-0}" = 1 ]; then
		run_worker "$CMD"
	elif [ "$CRON_MODE" = 1 ]; then
		mkdir -p "$(dirname "$LOG_FILE")"
		trim_log
		exec >>"$LOG_FILE" 2>&1 </dev/null
		NO_CRON=1
		delay=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
		delay=$((${delay:-$$} % (CRON_MAX_DELAY + 1)))
		[ "$delay" -gt 0 ] && sleep "$delay"
		run_worker "$CMD"
	elif [ "$FOREGROUND" = 1 ]; then
		mkdir -p "$(dirname "$LOG_FILE")"
		TSU_TEE=1
		run_worker "$CMD"
	else
		run_detached "$@"
	fi
	;;
esac

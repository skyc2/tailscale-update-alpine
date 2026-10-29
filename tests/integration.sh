#!/bin/sh
# Integration tests for tailscale-update.sh.
#
# apk, OpenRC, tailscaled and pkgs.tailscale.com are replaced by mocks, so the
# tests run offline and exercise the migration from the Alpine package, updates,
# automatic and manual rollback, interrupted updates and detaching from a
# terminal that goes away.
#
# The tests overwrite system files: only run them as root in a throwaway
# Alpine container, e.g.
#
#   docker run --rm -v "$PWD:/src:ro" alpine sh /src/tests/integration.sh
#
# Release signatures are tested when openssl 3 is installed (apk add openssl).
#
# shellcheck disable=SC3043 # 'local' is supported by busybox ash

set -u

if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ "${TSU_TEST_ALLOW:-}" != 1 ]; then
	echo "refusing to run outside a container (set TSU_TEST_ALLOW=1 to override)" >&2
	exit 1
fi
[ -f /etc/alpine-release ] || {
	echo "these tests need Alpine Linux" >&2
	exit 1
}
[ "$(id -u)" -eq 0 ] || {
	echo "these tests must run as root" >&2
	exit 1
}

SRC=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=/root/tailscale-update.sh
FAKE=/opt/fake
RUN=/run/fake-ts
PKGS=/srv/pkgs
APKDB=/var/lib/fake-apk
LOG=/var/log/tailscale-update.log
case $(apk --print-arch) in
x86_64) TSARCH=amd64 ;;
aarch64) TSARCH=arm64 ;;
armhf | armv7) TSARCH=arm ;;
x86) TSARCH=386 ;;
*) TSARCH=$(apk --print-arch) ;;
esac
if openssl version 2>/dev/null | grep -q '^OpenSSL [3-9]'; then
	HAVE_OPENSSL=1
else
	HAVE_OPENSSL=0
fi

PASS=0
FAIL=0

ok() {
	PASS=$((PASS + 1))
	echo "  ok   - $1"
}

not_ok() {
	FAIL=$((FAIL + 1))
	echo "  FAIL - $1"
}

# check DESCRIPTION COMMAND...
check() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else not_ok "$desc"; fi
}

section() {
	echo
	echo "== $*"
}

# --- Mocks -------------------------------------------------------------------

setup_mocks() {
	mkdir -p "$FAKE" "$RUN" "$PKGS/stable" "$APKDB" /usr/local/sbin /etc/init.d /etc/conf.d \
		/etc/logrotate.d /etc/runlevels/default
	: >"$APKDB/installed"
	: >"$APKDB/world"

	# pkgs.tailscale.com: wget/curl serve files from $PKGS.
	cat >/usr/local/sbin/wget <<'EOF'
#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
	case $1 in
	-O | -o) out=$2; shift ;;
	-q | -fsSL) ;;
	-T | --retry | --connect-timeout | --max-time) shift ;;
	*) url=$1 ;;
	esac
	shift
done
path=${url#http://pkgs.test/}
case $path in
*\?mode=json*) path=${path%%\?*}index.json ;;
esac
[ -f "/srv/pkgs/$path" ] || { echo "wget: 404 $url" >&2; exit 1; }
if [ "$out" = - ]; then cat "/srv/pkgs/$path"; else cp "/srv/pkgs/$path" "$out"; fi
EOF
	chmod 755 /usr/local/sbin/wget
	cp /usr/local/sbin/wget /usr/local/sbin/curl

	# apk: a fake package database; version comparison uses the real apk.
	cat >/usr/sbin/apk <<'EOF'
#!/bin/sh
DB=/var/lib/fake-apk
echo "apk $*" >>$DB/calls
case $1 in
--print-arch | version) exec /sbin/apk "$@" ;;
info)
	[ "$2" = -e ] && grep -qx "$3" $DB/installed && echo "$3" && exit 0
	exit 1
	;;
add)
	shift
	for p; do
		case $p in -*) continue ;; esac
		grep -qx "$p" $DB/installed || { echo "ERROR: unable to select packages: $p"; exit 1; }
		grep -qx "$p" $DB/world || echo "$p" >>$DB/world
	done
	;;
del)
	shift
	sim=0 pkgs=
	for p; do
		case $p in
		-s) sim=1 ;;
		-*) ;;
		*) pkgs="$pkgs $p" ;;
		esac
	done
	purge=$pkgs
	# openresolv was pulled in as a dependency of tailscale.
	case " $pkgs " in *" tailscale "*)
		grep -qx openresolv $DB/installed && ! grep -qx openresolv $DB/world && purge="$purge openresolv" ;;
	esac
	n=0
	for p in $purge; do n=$((n + 1)); done
	i=0
	for p in $purge; do
		i=$((i + 1))
		echo "($i/$n) Purging $p (1.0-r0)"
		[ $sim = 1 ] && continue
		case $p in
		tailscale) rm -f /usr/sbin/tailscaled /usr/bin/tailscale ;;
		tailscale-openrc)
			rm -f /etc/init.d/tailscale /etc/logrotate.d/tailscale
			cmp -s /etc/conf.d/tailscale $DB/confd.orig && rm -f /etc/conf.d/tailscale
			;;
		esac
		grep -vx "$p" $DB/installed >$DB/tmp; mv $DB/tmp $DB/installed
		grep -vx "$p" $DB/world >$DB/tmp; mv $DB/tmp $DB/world
	done
	echo "OK: 1 MiB in 10 packages"
	;;
*) echo "apk mock: unsupported: $*" >&2; exit 1 ;;
esac
EOF
	chmod 755 /usr/sbin/apk

	# OpenRC: rc-service sources the init script like openrc-run would.
	printf '#!/bin/sh\nexit 0\n' >/sbin/openrc-run
	chmod 755 /sbin/openrc-run
	cat >/usr/sbin/rc-service <<'EOF'
#!/bin/sh
[ "$1" = -q ] && shift
svc=$1 act=$2
RUN=/run/fake-ts
pidf=$RUN/$svc.pid
[ "$svc" = tailscale ] || exit 1
[ -f "/etc/init.d/$svc" ] || { echo " * rc-service: service \`$svc' does not exist" >&2; exit 1; }
running() { [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; }
start() {
	running && return 0
	(
		RC_SVCNAME=$svc
		yesno() { case $1 in [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee] | [Oo][Nn] | 1) return 0 ;; esac; return 1; }
		checkpath() { :; }
		set +u
		[ -f "/etc/conf.d/$svc" ] && . "/etc/conf.d/$svc"
		. "/etc/init.d/$svc"
		start_pre || exit 1
		echo "$command $command_args" >$RUN/cmdline
		# shellcheck disable=SC2086
		setsid $command $command_args </dev/null >>$RUN/daemon.log 2>&1 &
		echo $! >"$pidf"
	)
	sleep 0.2
}
stop() {
	running || { rm -f "$pidf"; return 0; }
	pid=$(cat "$pidf")
	kill "$pid"
	i=0
	while kill -0 "$pid" 2>/dev/null; do
		i=$((i + 1))
		if [ $i -gt 50 ]; then
			echo "$pid" >>$RUN/needed-sigkill
			kill -9 "$pid"
		fi
		sleep 0.1
	done
	rm -f "$pidf"
}
case $act in
status) running ;;
start) start ;;
stop) stop ;;
restart) stop; start ;;
*) exit 1 ;;
esac
EOF
	chmod 755 /usr/sbin/rc-service
	cat >/usr/sbin/rc-update <<'EOF'
#!/bin/sh
[ "$1" = add ] || exit 0
mkdir -p "/etc/runlevels/${3:-default}"
ln -sf "/etc/init.d/$2" "/etc/runlevels/${3:-default}/$2"
EOF
	chmod 755 /usr/sbin/rc-update

	# tailscaled and tailscale: shell scripts; BEHAVIOR decides whether the
	# daemon reaches Running, stays Starting or crashes.
	cat >"$FAKE/daemon.sh" <<'EOF'
V=$1 B=$2
shift 2
D=/run/fake-ts
echo "$V" >$D/version
echo NoState >$D/state
echo "$*" >$D/args
trap 'exit 0' TERM
# Test hooks: every version gets stuck; the service user plants a symlink.
[ -f $D/force-stuck ] && B=stuck
[ -f $D/plant-link ] && rm $D/plant-link && ln -sfn /root/canary /var/lib/tailscale/tailscaled.state
[ "$B" = crash ] && exit 1
sleep 1
case $B in
good) echo Running >$D/state ;;
stuck) echo Starting >$D/state ;;
esac
while :; do sleep 1; done
EOF
	cat >"$FAKE/cli.sh" <<'EOF'
V=$1
shift
D=/run/fake-ts
case $1 in --socket=*) shift ;; esac
case $1 in
version | --version) echo "$V" ;;
status)
	if [ -f $D/tailscale.pid ] && kill -0 "$(cat $D/tailscale.pid)" 2>/dev/null && [ -f $D/state ]; then
		printf '{\n  "Version": "%s-tfake-gfake",\n  "TUN": true,\n  "BackendState": "%s",\n  "Self": {\n    "ID": "n1"\n  }\n}\n' \
			"$(cat $D/version)" "$(cat $D/state)"
	else
		echo "failed to connect to local tailscaled" >&2
		exit 1
	fi
	;;
*) exit 0 ;;
esac
EOF
}

# make_bins VERSION BEHAVIOR DIR
make_bins() {
	mkdir -p "$3"
	cat >"$3/tailscaled" <<EOF
#!/bin/sh
case \${0##*/} in tailscale) exec sh $FAKE/cli.sh $1 "\$@" ;; esac
case \${1:-} in --version | -version) printf '%s\n  tailscale commit: fake\n' $1; exit 0 ;; esac
exec sh $FAKE/daemon.sh $1 $2 "\$@"
EOF
	printf '#!/bin/sh\nexec sh %s/cli.sh %s "$@"\n' "$FAKE" "$1" >"$3/tailscale"
	chmod 755 "$3/tailscaled" "$3/tailscale"
}

setup_keys() {
	[ "$HAVE_OPENSSL" = 1 ] || return 0
	mkdir -p "$FAKE/keys"
	cd "$FAKE/keys" || exit 1
	openssl genpkey -algorithm ed25519 -out root.pem 2>/dev/null
	openssl genpkey -algorithm ed25519 -out signing.pem 2>/dev/null
	ROOT_PUB=$(openssl pkey -in root.pem -pubout -outform DER | tail -c 32 | openssl base64 -A)
	{
		echo "-----BEGIN SIGNING PUBLIC KEY-----"
		openssl pkey -in signing.pem -pubout -outform DER | tail -c 32 | openssl base64 -A
		echo
		echo "-----END SIGNING PUBLIC KEY-----"
	} >"$PKGS/distsign.pub"
	openssl pkeyutl -sign -inkey root.pem -rawin -in "$PKGS/distsign.pub" -out "$PKGS/distsign.pub.sig"
	cd / || exit 1
}

# sign_file FILE: write FILE.sig like Tailscale's distsign.
sign_file() {
	local size i b
	[ "$HAVE_OPENSSL" = 1 ] || return 0
	size=$(wc -c <"$1")
	{
		openssl dgst -blake2s256 -binary "$1"
		i=0
		while [ $i -lt 8 ]; do
			b=$(((size >> (8 * i)) & 255))
			# shellcheck disable=SC2059
			printf "\\$(printf '%03o' "$b")"
			i=$((i + 1))
		done
	} >"$FAKE/msg"
	openssl pkeyutl -sign -inkey "$FAKE/keys/signing.pem" -rawin -in "$FAKE/msg" -out "$1.sig"
}

# release VERSION BEHAVIOR: build and publish a release as the latest.
release() {
	local name="tailscale_${1}_$TSARCH" b="$FAKE/build"
	rm -rf "$b"
	make_bins "$1" "$2" "$b/$name"
	mkdir -p "$b/$name/systemd"
	echo "[Unit]" >"$b/$name/systemd/tailscaled.service"
	tar -czf "$PKGS/stable/$name.tgz" -C "$b" "$name"
	sha256sum "$PKGS/stable/$name.tgz" | awk '{ print $1 }' >"$PKGS/stable/$name.tgz.sha256"
	sign_file "$PKGS/stable/$name.tgz"
	printf '{"Version":"%s","Tarballs":{"%s":"%s.tgz"},"TarballsVersion":"%s"}\n' \
		"$1" "$TSARCH" "$name" "$1" >"$PKGS/stable/index.json"
}

# Install a fake Alpine tailscale package at VERSION and start it.
install_apk_tailscale() {
	make_bins "$1" good "$FAKE/apk"
	cp "$FAKE/apk/tailscaled" /usr/sbin/tailscaled
	ln -sf /usr/sbin/tailscaled /usr/bin/tailscale
	cp "$SRC/tests/fixtures/alpine-tailscale.initd" /etc/init.d/tailscale
	cp "$SRC/tests/fixtures/alpine-tailscale.confd" /etc/conf.d/tailscale
	cp /etc/conf.d/tailscale "$APKDB/confd.orig"
	echo 'port=12345' >>/etc/conf.d/tailscale
	printf '/var/log/tailscaled.log {\n\tmissingok\n}\n' >/etc/logrotate.d/tailscale
	printf 'tailscale\ntailscale-openrc\ntailscale-doc\nopenresolv\n' >"$APKDB/installed"
	printf 'tailscale\n' >"$APKDB/world"
	mkdir -p /var/lib/tailscale
	echo "state-$1" >/var/lib/tailscale/tailscaled.state
	rc-update add tailscale default
	rc-service tailscale start
	sleep 1.5
}

write_config() {
	cat >/etc/tailscale-update.conf <<EOF
PKGS_URL=http://pkgs.test
HEALTH_TIMEOUT=6
CRON_MAX_DELAY=0
EOF
	if [ "$HAVE_OPENSSL" = 1 ]; then
		printf 'VERIFY_SIGNATURE=yes\nDISTSIGN_ROOTS=%s\n' "$ROOT_PUB" >>/etc/tailscale-update.conf
	else
		echo 'VERIFY_SIGNATURE=auto' >>/etc/tailscale-update.conf
	fi
}

reset_env() {
	rc-service tailscale stop 2>/dev/null
	rm -rf /opt/tailscale /var/lib/tailscale-update /var/lib/tailscale /usr/local/sbin/tailscaled \
		/usr/local/sbin/tailscale-update /usr/local/bin/tailscale /usr/sbin/tailscaled \
		/usr/bin/tailscale /etc/init.d/tailscale /etc/conf.d/tailscale /etc/logrotate.d/tailscale \
		/etc/runlevels/default/tailscale "$LOG" "${RUN:?}"/*
	: >"$APKDB/installed"
	: >"$APKDB/world"
	: >"$APKDB/calls"
	crontab -r 2>/dev/null
	return 0
}

# --- Assertions --------------------------------------------------------------

daemon_version() { cat "$RUN/version" 2>/dev/null; }
daemon_pid() { cat "$RUN/tailscale.pid" 2>/dev/null; }
daemon_running() { rc-service tailscale status; }
good() { cat /var/lib/tailscale-update/good 2>/dev/null; }
previous() { cat /var/lib/tailscale-update/previous 2>/dev/null; }
skipped() { grep -qx "$1" /var/lib/tailscale-update/failed; }
linked_to() { [ "$(readlink /usr/local/sbin/tailscaled)" = "/opt/tailscale/$1/tailscaled" ]; }
eq() { [ "$1" = "$2" ]; }
log_has() { grep -qF -- "$1" "$LOG"; }

update() { sh "$SCRIPT" "$@" >>"$FAKE/out" 2>&1; }

# --- Tests -------------------------------------------------------------------

test_migration() {
	section "migrate from the Alpine package to the official build"
	install_apk_tailscale 1.80.0
	release 1.90.0 good
	update update --foreground
	check "update exits 0" eq $? 0
	check "daemon runs 1.90.0" eq "$(daemon_version)" 1.90.0
	check "daemon is running" daemon_running
	check "links point to 1.90.0" linked_to 1.90.0
	check "known-good is 1.90.0" eq "$(good)" 1.90.0
	check "previous is the Alpine build" eq "$(previous)" 1.80.0-apk
	check "the Alpine build is kept for rollback" test -x /opt/tailscale/1.80.0-apk/tailscaled
	check "the kept Alpine CLI works" /opt/tailscale/1.80.0-apk/tailscale version
	check "tailscale packages are removed" sh -c "! grep -q '^tailscale' $APKDB/installed"
	check "openresolv is kept (added to world)" grep -qx openresolv "$APKDB/world"
	check "conf.d with local changes is kept" grep -qx 'port=12345' /etc/conf.d/tailscale
	check "conf.d settings reach tailscaled" grep -q -- '--port=12345' "$RUN/args"
	check "Alpine's no_logs_no_support is honoured" grep -q -- '--no-logs-no-support' "$RUN/args"
	check "init script is ours" grep -q 'Managed by tailscale-update' /etc/init.d/tailscale
	check "init script runs /usr/local/sbin/tailscaled" grep -q '^command="/usr/local/sbin/tailscaled"' /etc/init.d/tailscale
	check "logrotate config is kept" test -f /etc/logrotate.d/tailscale
	check "compat link /usr/sbin/tailscaled" test "$(readlink /usr/sbin/tailscaled)" = /usr/local/sbin/tailscaled
	check "compat link /usr/bin/tailscale" test "$(readlink /usr/bin/tailscale)" = /usr/local/bin/tailscale
	check "tailscale CLI on PATH is 1.90.0" eq "$(/usr/local/bin/tailscale version)" 1.90.0
	check "script installed to /usr/local/sbin" cmp -s "$SCRIPT" /usr/local/sbin/tailscale-update
	check "daily cron job installed" sh -c "crontab -l | grep -q '/usr/local/sbin/tailscale-update --cron.*# tailscale-update\$'"
	if [ "$HAVE_OPENSSL" = 1 ]; then
		check "signature verified" log_has "Signature OK"
	else
		check "warns that signatures are not verified" log_has "release signatures will not be verified"
	fi
	check "sha256 verified" log_has "SHA-256 OK"
	check "no pending update left" test ! -e /var/lib/tailscale-update/pending
}

test_up_to_date() {
	section "nothing to do when up to date"
	local pid
	pid=$(daemon_pid)
	update update --foreground
	check "update exits 0" eq $? 0
	check "daemon was not restarted" eq "$(daemon_pid)" "$pid"
	check "reports up to date" log_has "Tailscale is up to date"
	check "cron job not duplicated" eq "$(crontab -l | grep -c '# tailscale-update$')" 1
}

test_failed_update_rolls_back() {
	section "a release that does not come up is rolled back"
	release 1.92.0 stuck
	update update --foreground
	check "update exits 1" eq $? 1
	check "daemon runs 1.90.0 again" eq "$(daemon_version)" 1.90.0
	check "daemon is running" daemon_running
	check "links point to 1.90.0" linked_to 1.90.0
	check "known-good is still 1.90.0" eq "$(good)" 1.90.0
	check "1.92.0 is skipped from now on" skipped 1.92.0
	check "tailscaled stops on SIGTERM" test ! -e "$RUN/needed-sigkill"
	check "no pending update left" test ! -e /var/lib/tailscale-update/pending

	local pid
	pid=$(daemon_pid)
	update update --cron
	check "cron run exits 0" eq $? 0
	check "cron run skips 1.92.0" log_has "Skipping 1.92.0"
	check "daemon was not restarted" eq "$(daemon_pid)" "$pid"
}

test_crash_rolls_back() {
	section "a release that crashes is rolled back"
	release 1.93.0 crash
	update update --foreground
	check "update exits 1" eq $? 1
	check "daemon runs 1.90.0 again" eq "$(daemon_version)" 1.90.0
	check "daemon is running" daemon_running
	check "1.93.0 is skipped from now on" skipped 1.93.0
}

test_good_update() {
	section "a newer good release is installed"
	release 1.94.0 good
	update update --foreground
	check "update exits 0" eq $? 0
	check "daemon runs 1.94.0" eq "$(daemon_version)" 1.94.0
	check "known-good is 1.94.0" eq "$(good)" 1.94.0
	check "previous is 1.90.0" eq "$(previous)" 1.90.0
	check "state file untouched" eq "$(cat /var/lib/tailscale/tailscaled.state)" state-1.80.0
}

test_prune() {
	section "old versions are pruned"
	release 1.95.0 good
	update update --foreground
	release 1.96.0 good
	update update --foreground
	check "daemon runs 1.96.0" eq "$(daemon_version)" 1.96.0
	check "at most 3 versions kept" test "$(find /opt/tailscale -mindepth 1 -maxdepth 1 -type d ! -name ".*" | wc -l)" -le 3
	check "previous (1.95.0) kept" test -d /opt/tailscale/1.95.0
	check "1.90.0 removed" test ! -e /opt/tailscale/1.90.0
}

test_manual_rollback() {
	section "manual rollback"
	update rollback --foreground
	check "rollback exits 0" eq $? 0
	check "daemon runs 1.95.0" eq "$(daemon_version)" 1.95.0
	check "known-good is 1.95.0" eq "$(good)" 1.95.0
	check "1.96.0 is skipped from now on" skipped 1.96.0
	update update --foreground
	check "update does not reinstall 1.96.0" eq "$(daemon_version)" 1.95.0
	update update --foreground --force
	check "--force reinstalls 1.96.0" eq "$(daemon_version)" 1.96.0
	check "1.96.0 no longer skipped" sh -c '! grep -qx 1.96.0 /var/lib/tailscale-update/failed'
}

test_bad_downloads() {
	section "bad downloads are rejected before tailscale is stopped"
	local pid name="tailscale_1.97.0_$TSARCH"
	pid=$(daemon_pid)
	release 1.97.0 good
	echo 0000000000000000000000000000000000000000000000000000000000000000 >"$PKGS/stable/$name.tgz.sha256"
	update update --foreground
	check "update exits 1 on sha256 mismatch" eq $? 1
	check "reports the mismatch" log_has "SHA-256 mismatch"
	check "daemon was not restarted" eq "$(daemon_pid)" "$pid"
	if [ "$HAVE_OPENSSL" = 1 ]; then
		release 1.97.0 good
		cp "$PKGS/distsign.pub.sig" "$PKGS/stable/$name.tgz.sig"
		update update --foreground
		check "update exits 1 on a bad signature" eq $? 1
		check "reports the bad signature" log_has "BAD SIGNATURE"
		check "daemon was not restarted" eq "$(daemon_pid)" "$pid"

		release 1.97.0 good
		cp "$PKGS/distsign.pub.sig" "$FAKE/keys.sig"
		head -c 64 /dev/urandom >"$PKGS/distsign.pub.sig"
		update update --foreground
		check "update exits 1 on untrusted signing keys" eq $? 1
		check "reports untrusted signing keys" log_has "not signed by a known Tailscale root key"
		check "daemon was not restarted" eq "$(daemon_pid)" "$pid"
		cp "$FAKE/keys.sig" "$PKGS/distsign.pub.sig"
	fi
	check "no staging directories left" sh -c '! ls -d /opt/tailscale/.staging.* 2>/dev/null'
}

test_interrupted_update() {
	section "an interrupted update is rolled back on the next run"
	release 1.98.0 stuck
	make_bins 1.98.0 stuck /opt/tailscale/1.98.0
	echo "1.96.0 1.98.0 1 Running" >/var/lib/tailscale-update/pending
	ln -sfn /opt/tailscale/1.98.0/tailscaled /usr/local/sbin/tailscaled
	ln -sfn /opt/tailscale/1.98.0/tailscale /usr/local/bin/tailscale
	rc-service tailscale restart
	update update --foreground
	check "daemon runs 1.96.0 again" eq "$(daemon_version)" 1.96.0
	check "1.98.0 is skipped" skipped 1.98.0
	check "pending marker removed" test ! -e /var/lib/tailscale-update/pending
}

test_detached() {
	section "the update survives losing its terminal"
	release 1.99.0 good
	: >"$FAKE/out"
	# Run in a new session, like an SSH login, and hang it up as soon as the
	# update starts, like a dropped connection.
	setsid sh -c "sh $SCRIPT update >$FAKE/out 2>&1" &
	local i=0
	while [ $i -lt 50 ] && [ ! -d /var/lib/tailscale-update/lock ]; do
		sleep 0.1
		i=$((i + 1))
	done
	pkill -HUP -f "sh $SCRIPT update" 2>/dev/null
	pkill -KILL -f "sh -c sh $SCRIPT update" 2>/dev/null
	i=0
	while [ $i -lt 100 ] && [ -d /var/lib/tailscale-update/lock ]; do
		sleep 0.2
		i=$((i + 1))
	done
	check "worker finished" test ! -d /var/lib/tailscale-update/lock
	check "daemon runs 1.99.0" eq "$(daemon_version)" 1.99.0
	check "known-good is 1.99.0" eq "$(good)" 1.99.0
	check "log shows completion" log_has "Tailscale is now at 1.99.0"

	section "detached update reports its exit status"
	release 2.0.0 stuck
	sh "$SCRIPT" update >"$FAKE/out" 2>&1
	check "exits 1 when rolled back" eq $? 1
	check "terminal shows the log" grep -q "Rolled back to 1.99.0" "$FAKE/out"
	check "daemon runs 1.99.0" eq "$(daemon_version)" 1.99.0

	section "the update works when the script is piped to sh"
	release 2.1.0 good
	sh -s update <"$SCRIPT" >"$FAKE/out" 2>&1
	check "exits 0" eq $? 0
	check "daemon runs 2.1.0" eq "$(daemon_version)" 2.1.0
	check "terminal shows the log" grep -q "Tailscale is now at 2.1.0" "$FAKE/out"

	section "a piped update keeps its lock after losing its terminal"
	release 2.2.0 stuck
	setsid sh -c "sh -s update <$SCRIPT >$FAKE/out 2>&1" &
	i=0
	while [ $i -lt 50 ] && [ ! -s /var/lib/tailscale-update/lock/pid ]; do
		sleep 0.1
		i=$((i + 1))
	done
	# The worker is a subshell with the same command line; it ignores HUP.
	pkill -HUP -f "sh -s update" 2>/dev/null
	sleep 0.5
	check "the lock names a live process" kill -0 "$(cat /var/lib/tailscale-update/lock/pid 2>/dev/null)"
	sh "$SCRIPT" update --foreground >>"$FAKE/out" 2>&1
	check "a second run is refused while the first is busy" eq $? 1
	check "it reports the running update" log_has "another tailscale-update is running"
	i=0
	while [ $i -lt 100 ] && [ -d /var/lib/tailscale-update/lock ]; do
		sleep 0.2
		i=$((i + 1))
	done
	check "worker finished" test ! -d /var/lib/tailscale-update/lock
	check "daemon runs 2.1.0 after the rollback" eq "$(daemon_version)" 2.1.0
}

test_fresh_install() {
	section "fresh install without any tailscale"
	reset_env
	release 1.90.0 good
	update update --foreground
	check "update exits 0" eq $? 0
	check "daemon runs 1.90.0" eq "$(daemon_version)" 1.90.0
	check "service enabled at boot" test -L /etc/runlevels/default/tailscale
	check "default conf.d written" test -f /etc/conf.d/tailscale
	check "known-good is 1.90.0" eq "$(good)" 1.90.0
	check "no previous version" test -z "$(previous)"
	check "status works" sh "$SCRIPT" status
}

test_state_owned_by_service_user() {
	section "the state backup cannot be abused by the service user"
	adduser -S -D -H tailscale 2>/dev/null
	chown -R tailscale /var/lib/tailscale
	chmod 600 /var/lib/tailscale/tailscaled.state
	echo state-before >/var/lib/tailscale/tailscaled.state
	echo canary >/root/canary
	# The new and the old version both fail, so the saved state is restored,
	# after the service user has replaced the state file with a link to a
	# root file.
	touch "$RUN/force-stuck" "$RUN/plant-link"
	release 2.3.0 good
	update update --foreground
	check "update exits 1" eq $? 1
	check "the saved state is restored" log_has "Restoring the tailscaled state"
	check "root's file is not overwritten" eq "$(cat /root/canary)" canary
	check "state is a regular file again" test ! -L /var/lib/tailscale/tailscaled.state
	check "state has the saved content" eq "$(cat /var/lib/tailscale/tailscaled.state)" state-before
	check "state is owned by the service user" sh -c \
		'find /var/lib/tailscale/tailscaled.state -user tailscale -perm 600 | grep -q .'
	check "backup is root-only" sh -c \
		'find /var/lib/tailscale-update/backup/tailscaled.state -user 0 -perm 600 | grep -q .'
	rm -f "$RUN/force-stuck" "$RUN/plant-link"

	section "the state backup cannot be used to read root's files"
	echo secret >/root/secret
	chmod 600 /root/secret
	ln -sfn /root/secret /var/lib/tailscale/tailscaled.state
	rc-service tailscale restart
	local pid
	pid=$(daemon_pid)
	update update --foreground
	check "update exits 1" eq $? 1
	check "daemon was not restarted" eq "$(daemon_pid)" "$pid"
	check "backup does not contain root's file" sh -c \
		'! grep -q secret /var/lib/tailscale-update/backup/tailscaled.state 2>/dev/null'
	rm -f /var/lib/tailscale/tailscaled.state
}

test_cli() {
	section "command line"
	check "--help" sh "$SCRIPT" --help
	check "--version" sh -c "sh $SCRIPT --version | grep -q '^tailscale-update '"
	check "unknown option fails" sh -c "! sh $SCRIPT --bogus"
	check "remove-cron" sh "$SCRIPT" remove-cron
	check "cron job removed" sh -c "! crontab -l 2>/dev/null | grep -q '# tailscale-update'"
	check "install-cron" sh "$SCRIPT" install-cron
	check "cron job installed" sh -c "crontab -l | grep -q '# tailscale-update$'"
}

cp "$SRC/tailscale-update.sh" "$SCRIPT"
setup_mocks
setup_keys
write_config
echo "Alpine $(cat /etc/alpine-release), arch $TSARCH, openssl: $([ "$HAVE_OPENSSL" = 1 ] && echo yes || echo no)"

test_migration
test_up_to_date
test_failed_update_rolls_back
test_crash_rolls_back
test_good_update
test_prune
test_manual_rollback
test_bad_downloads
test_interrupted_update
test_detached
test_state_owned_by_service_user
test_cli
test_fresh_install

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
	echo
	echo "--- $LOG"
	cat "$LOG"
	echo "--- script output"
	cat "$FAKE/out"
	exit 1
fi

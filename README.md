# tailscale-update-alpine

[![CI](https://github.com/skyc2/tailscale-update-alpine/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/skyc2/tailscale-update-alpine/actions/workflows/ci.yml?query=branch%3Amain)
[![Tests](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fskyc2%2Ftailscale-update-alpine%2Fbadges%2Ftests.json)](https://github.com/skyc2/tailscale-update-alpine/actions/workflows/ci.yml?query=branch%3Amain)

Keep [Tailscale](https://tailscale.com) on Alpine Linux at the latest official
release.

Alpine's `tailscale` package, even in edge/testing, often trails the upstream
releases by weeks or months. During that time the machine is exposed to
vulnerabilities that Tailscale has already fixed (see the
[security bulletins](https://tailscale.com/security-bulletins)).
`tailscale-update.sh` is a single POSIX shell script (busybox ash compatible)
that:

- replaces the Alpine packages with the official static build from
  [pkgs.tailscale.com](https://pkgs.tailscale.com), keeping your
  `/etc/conf.d/tailscale` settings and your node identity
- checks Tailscale's release signature and the SHA-256 checksum of each
  download
- installs a daily cron job that checks for and installs new releases
- runs health checks after each upgrade and rolls back to the last known-good
  version if the new one doesn't come up
- can safely run over an SSH session that goes through Tailscale itself

## Quick start

As root:

```sh
wget https://raw.githubusercontent.com/skyc2/tailscale-update-alpine/main/tailscale-update.sh
less tailscale-update.sh   # read it before running anything as root
sh tailscale-update.sh
```

From a regular account, run the last command with `doas` or `sudo` if one of
them is installed (neither is by default on Alpine).

On first run the script:

1. downloads and verifies the latest stable release while Tailscale is still
   up
2. keeps a copy of the Alpine build (`/opt/tailscale/<version>-apk`) to roll
   back to
3. installs itself as `/usr/local/sbin/tailscale-update` and adds a daily
   cron job
4. stops `tailscaled`, removes the `tailscale*` packages with `apk del`
   (dependencies such as `openresolv` stay installed), installs an
   OpenRC script that runs the official build, and starts it again
5. waits until `tailscaled` is back in the state it was in before (normally
   `Running`); if it doesn't get there within two minutes, the script switches
   back to the previous build

Tailscale is down only for the few seconds it takes to restart `tailscaled`.

After that, run `tailscale-update` at any time, or leave it to the cron job.

## Running it over a Tailscale connection

Restarting `tailscaled` drops connections that go through it, which would
normally kill the SSH session, and the script running in it, halfway through.
To avoid that, the script:

- downloads and verifies everything before it touches the running daemon
- starts the actual work in a separate session (`setsid`), detached from the
  terminal, with output going to `/var/log/tailscale-update.log`. The terminal
  just follows that log
- leaves the OpenRC service's cgroup if it was started from a Tailscale SSH
  session, so stopping the service can't kill it

If the connection drops, the update still finishes, or rolls back. Reconnect
and check the result:

```sh
tailscale-update status
tail -n 30 /var/log/tailscale-update.log
```

Pressing Ctrl-C only stops following the log; the update keeps running in the
background. Use `--foreground` to run it attached to the terminal instead.

## Usage

`tailscale-update --help` lists all commands and options. The common ones:

```sh
tailscale-update              # update now (the default command)
tailscale-update status       # installed, known-good and latest versions
tailscale-update rollback     # go back to the previous known-good version
tailscale-update --force      # retry a release that was rolled back before
tailscale-update --track unstable
```

## Rollback

Each version lives in its own directory under `/opt/tailscale/`. The binaries
on `PATH` are symlinks to one of them:

```
/usr/local/sbin/tailscaled -> /opt/tailscale/1.90.2/tailscaled
/usr/local/bin/tailscale   -> /opt/tailscale/1.90.2/tailscale
```

`/usr/sbin/tailscaled` and `/usr/bin/tailscale` link to the same binaries, so
scripts that use the old paths keep working.

After an upgrade, `tailscaled` is restarted and `tailscale status` is polled
until the daemon reports the new version and is back in the state it was in
before (`Running` if it was connected). If that doesn't happen within
`HEALTH_TIMEOUT` seconds, the script:

1. switches the links back to the last known-good version and restarts
   `tailscaled`
2. if that version doesn't come up either, also restores the
   `tailscaled.state` file it saved before the upgrade
3. records the failed version so the daily job doesn't retry it. The next
   newer release is installed as usual, and `--force` retries the failed
   one

If the update itself is interrupted (for example by a power cut), the next run
detects that and rolls back, unless the new version turned out to be healthy.

`tailscale-update rollback` does a manual rollback to the previous known-good
version and skips the current version from then on. The last
`KEEP_VERSIONS` versions (3 by default) are kept on disk, plus the known-good
and previous ones.

## Verification

Downloads come from `pkgs.tailscale.com` over HTTPS and are checked in two ways
before anything is unpacked:

- **Signature**: Tailscale signs every release with keys that are certified by
  root keys built into the `tailscale` client (see
  [distsign](https://github.com/tailscale/tailscale/tree/main/clientupdate/distsign)).
  The script ships the same root keys and checks the chain with `openssl`
  (installed automatically if it's missing, see `VERIFY_SIGNATURE`), just like
  `tailscale update` does.
- **SHA-256**: the published `.sha256` checksum.

As a final check, the new `tailscaled` must run on this machine and report the
expected version.

## Configuration

Settings can be overridden in `/etc/tailscale-update.conf`, a shell file that
is sourced before the defaults are applied. The settings block at the top of
`tailscale-update.sh` lists every setting with its default and a short
description. For example:

```sh
TRACK=unstable          # follow the unstable track
HEALTH_TIMEOUT=300      # wait longer for slow links before rolling back
CRON_SCHEDULE="5 3 * * *"
```

`tailscaled` itself is still configured in `/etc/conf.d/tailscale`, which uses
the same settings as Alpine's `tailscale-openrc` package (`port`,
`firewall_mode`, `no_logs_no_support`, `command_args`, `command_user`, ...).

## Files

| Path | Purpose |
| --- | --- |
| `/usr/local/sbin/tailscale-update` | the installed script |
| `/opt/tailscale/<version>/` | installed versions |
| `/usr/local/sbin/tailscaled`, `/usr/local/bin/tailscale` | links to the active version |
| `/etc/init.d/tailscale` | OpenRC script (replaces the one from `tailscale-openrc`) |
| `/etc/conf.d/tailscale` | `tailscaled` settings (kept from the Alpine package) |
| `/var/lib/tailscale-update/` | known-good, previous and skipped versions, backups |
| `/var/log/tailscale-update.log` | log of all runs |
| root's crontab | the daily `tailscale-update --cron` job |

## Requirements

- Alpine Linux with OpenRC
- root: a root shell, or `doas` or `sudo` if installed
- `wget` (busybox, with `ssl_client`) or `curl`
- an architecture with an official build: x86_64, aarch64, armv7/armhf, x86
  or riscv64

## Going back to the Alpine package

```sh
tailscale-update remove-cron
rc-service tailscale stop
rm /etc/init.d/tailscale /usr/sbin/tailscaled /usr/bin/tailscale \
   /usr/local/sbin/tailscaled /usr/local/bin/tailscale /usr/local/sbin/tailscale-update
apk add tailscale tailscale-openrc
rc-service tailscale start
rm -rf /opt/tailscale /var/lib/tailscale-update
```

Your node state in `/var/lib/tailscale` and `/etc/conf.d/tailscale` are left
in place.

## Development

CI runs [ShellCheck](https://www.shellcheck.net) on the scripts and on the
generated OpenRC script. It also runs the integration tests on several Alpine
releases. The tests mock apk, OpenRC, `tailscaled` and pkgs.tailscale.com
(including release signatures), and cover the migration, upgrades, automatic
and manual rollback, interrupted updates and losing the terminal mid-update.
The test count badge adds up the checks that passed across all the Alpine
configurations in the latest CI run on `main`. The tests change system files,
so only run them in a throwaway container:

```sh
shellcheck --shell=sh tailscale-update.sh tests/integration.sh
docker run --rm -v "$PWD:/src:ro" alpine sh -c 'apk add -q openssl && sh /src/tests/integration.sh'
```

#!/usr/bin/env bash
# dispatch.sh: Amp self-hosted orb dispatch program backed by OrbStack machines.
#
# Run by `amp orb provider` once per job with ORB_OPERATION, ORB_ID, ORB_IMAGE,
# ORB_SNAPSHOT_ID, and (spawn only) ORB_TOKEN and AMP_URL. Every operation is
# idempotent. See README.md.
set -euo pipefail

: "${ORB_OPERATION:?ORB_OPERATION is required}"
: "${ORB_ID:?ORB_ID is required}"

ORBCTL_BIN="${ORBCTL_BIN:-orbctl}"
DISTRO="${ORBSTACK_DISTRO:-ubuntu:26.04}"
# Isolated machines can't see the Mac's files, other machines, or host ports.
read -r -a CREATE_ARGS <<<"${ORBSTACK_CREATE_ARGS---isolated --isolate-network}"
SERVICE="amp-bootstrap"
NAME="$ORB_ID"
SNAP=""
if [[ -n "${ORB_SNAPSHOT_ID:-}" ]]; then
	SNAP="amp-snap-$(printf '%s' "$ORB_SNAPSHOT_ID" | tr -c 'A-Za-z0-9._-' '-')"
fi

trap 'echo "orbstack: $ORB_OPERATION $NAME failed at line $LINENO" >&2' ERR

orbctl() { command "$ORBCTL_BIN" "$@"; }

# state <machine>: prints running/stopped, or nothing if the machine doesn't exist.
state() { orbctl info "$1" -f json 2>/dev/null | jq -r '.record.state' || true; }
exists() { [[ -n "$(state "$1")" ]]; }

# root <cmd...>: run a command as root inside the orb.
root() { orbctl run -m "$NAME" -u root "$@"; }

# Runs as root on every spawn. Package setup runs once (the disk persists across
# stop, so the marker keeps later spawns fast); the service unit is always rewritten.
PROVISION=$(cat <<'EOF'
set -euo pipefail
marker=/etc/amp-orb-provisioned-v1

if [[ ! -f "$marker" ]]; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		ca-certificates curl git tmux ripgrep gh nodejs npm openssh-client unzip >/dev/null

	# `orbctl create -u user` already provides the contract's `user` account with
	# passwordless sudo (/etc/sudoers.d/orbstack).
	sudo -u user -H bash -c '[[ -x ~/.amp/bin/amp ]] || curl -fsSL https://ampcode.com/install.sh | bash'
	ln -sf /home/user/.amp/bin/amp /usr/local/bin/amp
	touch "$marker"
fi

# Not enabled at boot: each spawn writes a fresh token and starts it explicitly, so a
# machine cloned from a snapshot never connects with a stale token.
cat >/etc/systemd/system/amp-bootstrap.service <<'UNIT'
[Unit]
Description=Amp orb bootstrap
After=network-online.target
Wants=network-online.target

[Service]
User=user
WorkingDirectory=/home/user
EnvironmentFile=/etc/amp-orb/env
ExecStart=/usr/local/bin/amp orb bootstrap
Restart=always
RestartSec=5
UNIT
systemctl daemon-reload
EOF
)

spawn() {
	: "${ORB_TOKEN:?ORB_TOKEN is required for spawn}"

	if ! exists "$NAME"; then
		# A concurrent spawn may win the race; only fail if the machine still isn't there.
		if [[ -n "$SNAP" ]] && exists "$SNAP"; then
			echo "orbstack: creating $NAME from snapshot $SNAP"
			orbctl clone "$SNAP" "$NAME" || exists "$NAME"
		else
			echo "orbstack: creating $NAME ($DISTRO)"
			orbctl create ${CREATE_ARGS[@]+"${CREATE_ARGS[@]}"} -u user "$DISTRO" "$NAME" >/dev/null || exists "$NAME"
		fi
	fi

	[[ "$(state "$NAME")" == running ]] || orbctl start "$NAME"

	echo "orbstack: provisioning $NAME"
	root bash -c "$PROVISION"

	# printf is a builtin and the env goes over stdin, so ORB_TOKEN never appears in argv.
	{
		printf 'ORB_TOKEN=%s\n' "$ORB_TOKEN"
		if [[ -n "${AMP_URL:-}" ]]; then printf 'AMP_URL=%s\n' "$AMP_URL"; fi
	} | root bash -c 'install -d -m 0700 /etc/amp-orb && umask 077 && cat >/etc/amp-orb/env'

	echo "orbstack: starting $SERVICE on $NAME"
	# Restart so a resumed orb picks up the fresh token.
	root systemctl restart "$SERVICE"
}

pause() {
	local s
	s=$(state "$NAME")
	[[ -n "$s" ]] || return 0

	if [[ "$s" == running ]]; then
		# Drop the token before the disk is stopped or copied into a snapshot.
		root bash -c "systemctl stop $SERVICE 2>/dev/null; rm -f /etc/amp-orb/env" || true
		echo "orbstack: stopping $NAME"
		orbctl stop "$NAME"
	fi

	[[ -n "$SNAP" ]] || return 0
	# Clone to a temp name first, so an existing snapshot is replaced only once the copy exists.
	echo "orbstack: saving snapshot $SNAP"
	local tmp="$SNAP.tmp"
	if exists "$tmp"; then orbctl delete -f "$tmp"; fi
	orbctl clone "$NAME" "$tmp"
	if exists "$SNAP"; then orbctl delete -f "$SNAP"; fi
	orbctl rename "$tmp" "$SNAP"
}

delete() {
	exists "$NAME" || return 0
	echo "orbstack: deleting $NAME"
	orbctl delete -f "$NAME"
}

case "$ORB_OPERATION" in
	spawn) spawn ;;
	pause) pause ;;
	delete) delete ;;
	*) echo "orbstack: unknown ORB_OPERATION '$ORB_OPERATION'" >&2; exit 2 ;;
esac

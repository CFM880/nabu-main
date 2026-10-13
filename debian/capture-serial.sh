#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Continuously capture the nabu-debian USB CDC-ACM debug console.
#
# The tablet may reboot, and the tty can come back as a different
# /dev/ttyACM*; so this waits for the gadget, reads until the device goes
# away, then reconnects and keeps appending to the same log until Ctrl-C.
#
# Run it on the host PC attached to the tablet's USB-C port.

set -u

BAUD=115200
DEVICE=
OUTPUT=
TIMESTAMP=0
QUIET=0
READER=

usage() {
	cat <<EOF
usage: $0 [options]

Continuously capture the nabu-debian USB serial debug console, reconnecting
across tablet reboots and USB re-plugs.

  -d, --device DEV    tty device (default: auto-detect the nabu gadget)
  -b, --baud N        baud rate (default: 115200)
  -o, --output FILE   log file (default: nabu-serial-<date>.log)
  -t, --timestamp     prefix each captured line with a host timestamp
  -q, --quiet         do not echo captured data on the terminal
  -h, --help          show this help

Examples:
  $0                          # auto-detect, log to nabu-serial-<date>.log
  $0 -t -o nabu-boot.log      # timestamped lines into nabu-boot.log
EOF
}

logmsg() { printf 'capture-serial: %s\n' "$*" >&2; }

# Read a USB sysfs attribute from an ancestor of a tty device.  The depth to
# the USB device node differs between drivers (ttyACM vs ttyUSB), so walk up.
usb_attr() {
	_tty=$1
	_attr=$2
	[ -e "/sys/class/tty/$_tty/device" ] || return 1
	_dir=$(readlink -f "/sys/class/tty/$_tty/device") || return 1
	_i=0
	while [ "$_i" -lt 5 ]; do
		if [ -f "$_dir/$_attr" ]; then
			cat "$_dir/$_attr"
			return 0
		fi
		_dir=$(dirname "$_dir")
		_i=$((_i + 1))
	done
	return 1
}

is_nabu_gadget() {
	_tty=$1
	_v=$(usb_attr "$_tty" idVendor)
	_p=$(usb_attr "$_tty" idProduct)
	# 0525:a4a7 = legacy g_serial CDC-ACM (kernel built-in gadget)
	# 1d6b:0104 = configfs multifunction gadget (older service setup)
	case "$_v:$_p" in
	0525:a4a7 | 1d6b:0104) return 0 ;;
	esac
	return 1
}

find_device() {
	if [ -n "$DEVICE" ]; then
		[ -e "$DEVICE" ] && printf '%s\n' "$DEVICE" && return 0
		return 1
	fi
	# 1) the USB ids used by the kernel-built-in / configfs nabu gadget
	for _tty in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
		[ -e "$_tty" ] || continue
		_name=$(basename "$_tty")
		if is_nabu_gadget "$_name"; then
			printf '/dev/%s\n' "$_name"
			return 0
		fi
	done
	# 2) any other ACM/USB serial adapter
	for _node in /dev/ttyACM* /dev/ttyUSB*; do
		[ -e "$_node" ] && printf '%s\n' "$_node" && return 0
	done
	return 1
}

# Read $dev until it goes away.  Runs as a single background process (the
# subshell exec()s the reader) so INT/TERM can kill exactly that process.
emit() {
	if [ "$TIMESTAMP" -eq 1 ] && [ "$QUIET" -eq 1 ]; then
		exec awk -v out="$OUTPUT" '
			{ s = strftime("%Y-%m-%d %H:%M:%S") " " $0; print s >> out; fflush(out) }'
	elif [ "$TIMESTAMP" -eq 1 ]; then
		exec awk -v out="$OUTPUT" '
			{ s = strftime("%Y-%m-%d %H:%M:%S") " " $0; print s; print s >> out; fflush(out); fflush() }'
	elif [ "$QUIET" -eq 1 ]; then
		exec cat >>"$OUTPUT"
	else
		exec tee -a "$OUTPUT"
	fi
}

cleanup() {
	[ -n "$READER" ] && kill "$READER" 2>/dev/null
	READER=
	logmsg "stopped; log: $OUTPUT"
	exit 0
}

# --- options --------------------------------------------------------------
while [ $# -gt 0 ]; do
	case $1 in
	-d | --device)
		[ $# -ge 2 ] || { logmsg "missing argument for $1"; exit 2; }
		DEVICE=$2
		shift
		;;
	-b | --baud)
		[ $# -ge 2 ] || { logmsg "missing argument for $1"; exit 2; }
		BAUD=$2
		shift
		;;
	-o | --output)
		[ $# -ge 2 ] || { logmsg "missing argument for $1"; exit 2; }
		OUTPUT=$2
		shift
		;;
	-t | --timestamp) TIMESTAMP=1 ;;
	-q | --quiet) QUIET=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		logmsg "unknown option: $1"
		usage >&2
		exit 2
		;;
	esac
	shift
done

if [ "$TIMESTAMP" -eq 1 ] && ! command -v awk >/dev/null 2>&1; then
	logmsg "awk not found; --timestamp disabled"
	TIMESTAMP=0
fi

[ -n "$OUTPUT" ] || OUTPUT="nabu-serial-$(date +%Y%m%d-%H%M%S).log"
trap cleanup INT TERM HUP

if ! : >>"$OUTPUT" 2>/dev/null; then
	logmsg "cannot write $OUTPUT"
	exit 1
fi
logmsg "logging to $OUTPUT (baud $BAUD)"
if [ -n "$DEVICE" ] && [ ! -e "$DEVICE" ]; then
	logmsg "waiting for $DEVICE to appear..."
fi

connected=0
while :; do
	dev=$(find_device) || {
		[ "$connected" -eq 1 ] && logmsg "device gone; waiting for the gadget..."
		connected=0
		sleep 1
		continue
	}

	if [ ! -r "$dev" ]; then
		logmsg "$dev is not readable; run with sudo or add $(id -un) to the 'dialout' group"
		sleep 2
		continue
	fi

	if ! stty -F "$dev" "$BAUD" raw -echo -echoe -echok 2>/dev/null; then
		sleep 1
		continue
	fi

	connected=1
	printf '===== connected %s @ %s  %s =====\n' "$dev" "$BAUD" \
		"$(date '+%Y-%m-%d %H:%M:%S')" >>"$OUTPUT"
	logmsg "connected $dev"

	# Background reader: exits on unplug/reboot, or is killed by cleanup().
	emit <"$dev" &
	READER=$!
	wait "$READER"
	READER=

	logmsg "disconnected $dev"
	sleep 1
done

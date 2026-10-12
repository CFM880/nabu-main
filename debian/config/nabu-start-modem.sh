#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Start the modem/WPSS remoteproc on nabu.
#
# qcom_q6v5_pas marks the mpss remote processor auto_boot=false, so the kernel
# never starts it on its own.  On nabu that processor also brings up the
# WCN3990 (ath10k) WLAN firmware: modemuw.jsn describes the modem's wlan_pd
# subdomain depending on the "wlan/fw" service, so WiFi stays down until it
# runs.  Runtime "stop" hard-hangs the SoC, so only ever start it.
set -eu

i=0
while [ "$i" -lt 30 ]; do
	for d in /sys/class/remoteproc/remoteproc*; do
		[ -e "$d/name" ] || continue
		[ "$(cat "$d/name" 2>/dev/null)" = modem ] || continue
		if [ "$(cat "$d/state" 2>/dev/null)" = running ]; then
			echo "nabu-start-modem: modem already running"
			exit 0
		fi
		echo start >"$d/state"
		echo "nabu-start-modem: started modem ($d)"
		exit 0
	done
	sleep 1
	i=$((i + 1))
done

echo "nabu-start-modem: no modem remoteproc found" >&2
exit 0

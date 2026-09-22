#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Expose a CDC-ACM USB gadget so a host can capture the kernel log (an
# out-of-band recovery channel when the tablet's display/desktop is wedged).
#
# The ttyGS console is only *registered* here (the acm.usb0 "console"
# attribute).  It only becomes a printk console, with the boot log replayed,
# when the cmdline also carries "console=ttyGS0".  Without that entry the port
# exists but nothing is written to it.
#
# This is a deliberately inert debug tool.  It used to be installed and enabled
# by nabu-main with a matching "console=ttyGS0" on the cmdline, which wedged
# early boot on this tablet when nothing was attached to USB-C, so it is now
# manual: copy it to /usr/local/lib/nabu/ and enable
# systemd/nabu-usb-console.service by hand when a recovery channel is needed,
# and remember to remove console=ttyGS0 again afterwards.
set -eu

GADGET=/sys/kernel/config/usb_gadget/nabu-console
UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)

if [ -z "$UDC" ]; then
    echo "nabu-usb-console: no USB device controller" >&2
    exit 0
fi

if [ ! -d /sys/kernel/config/usb_gadget ]; then
    echo "nabu-usb-console: configfs gadget support is not mounted" >&2
    exit 0
fi

# Tear down a stale instance from a previous run.
if [ -d "$GADGET" ]; then
    printf '' > "$GADGET/UDC" 2>/dev/null || true
    rm -f "$GADGET/configs/c.1/acm.usb0"
    rmdir "$GADGET/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "$GADGET/configs/c.1" 2>/dev/null || true
    rmdir "$GADGET/functions/acm.usb0" 2>/dev/null || true
    rmdir "$GADGET/strings/0x409" 2>/dev/null || true
    rmdir "$GADGET" 2>/dev/null || true
fi

mkdir -p "$GADGET"
cd "$GADGET"
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "nabu" > strings/0x409/manufacturer
echo "nabu-console" > strings/0x409/product
echo "$(cat /etc/machine-id 2>/dev/null || cat /sys/class/net/lo/address 2>/dev/null || echo 0123456789)" \
    > strings/0x409/serialnumber

mkdir -p configs/c.1/strings/0x409
echo "acm" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/acm.usb0
ln -s functions/acm.usb0 configs/c.1/

# Register the ttyGS console for this ACM port.  Together with the
# "console=ttyGS0" cmdline entry this makes the gadget a printk console and
# replays the kernel log buffer to it (CON_PRINTBUFFER).
if [ -e functions/acm.usb0/console ]; then
    echo 1 > functions/acm.usb0/console
fi

echo "$UDC" > UDC
echo "nabu-usb-console: bound $UDC"

# Give udev a moment so /dev/ttyGS0 is present before the unit reports done.
for _ in $(seq 1 20); do
    [ -c /dev/ttyGS0 ] && break
    sleep 0.1
done
if [ -c /dev/ttyGS0 ]; then
    echo "nabu-usb-console: /dev/ttyGS0 ready"
else
    echo "nabu-usb-console: warning: /dev/ttyGS0 did not appear" >&2
fi

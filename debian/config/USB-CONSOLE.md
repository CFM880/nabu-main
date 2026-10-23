# USB serial debug console

`nabu-debian` gets its kernel from the `production` product (default
`KERNEL_RELEASE=6.14.11-nabu-full`).  That kernel enables the **configfs**
CDC-ACM function (`CONFIG_USB_CONFIGFS_ACM=y`) but **not** the legacy
`CONFIG_USB_G_SERIAL`, so `/dev/ttyGS0` is only created once userspace builds
the configfs gadget.  `nabu-platform` ships `nabu-usb-console.sh` +
`nabu-usb-console.service` (enabled at `multi-user.target`) to do exactly that,
and `config/debian.cmdline` carries `console=tty0 console=ttyGS0`, so kernel
printk goes to the serial port as well as the panel.

The ttyGS console carries `CON_PRINTBUFFER`: the whole boot ring buffer is
replayed as soon as the gadget is created, so a hang that happens before USB
comes up is still visible.

## On the tablet

- `nabu-usb-console.service` binds the `acm.usb0` function to the first UDC and
  exits; `/dev/ttyGS0` then appears (and the host sees `/dev/ttyACM*`).
- `serial-getty@ttyGS0.service` is **masked** (`/etc/systemd/system/
  serial-getty@ttyGS0.service -> /dev/null`).  `console=ttyGS0` would otherwise
  make systemd-start the generator's getty, and because ttyGS0 only appears
  once a host enumerates the gadget, its `dev-ttyGS0.device` dependency stalled
  `multi-user.target` for the full 90 s device timeout on every boot without a
  host cable (which in turn stalled `hexagonrpcd` → the SSC sensor proxy).  For
  a serial *login* while a host is attached anyway:
  ```sh
  sudo systemctl start serial-getty@ttyGS0.service
  ```
- The `serial-debug` product drops `nabu-power` (PM8150B SMB5 + LN8000), so
  the downstream charger drivers cannot keep the Type-C port in host role or
  grab the HS PHY's D+/D- for APSD/QC detection.  With the charging stack out
  of the way the mainline `pm8150b` TCPM puts the port in device role when a
  host is attached.  The port cannot charge or act as an OTG host on this
  build.

## On the host PC

Connect a USB data cable and look for a new ACM device:

```sh
dmesg | tail            # cdc_acm 1-1:1.0: ttyACM0: USB ACM device
ls /dev/ttyACM*
```

The gadget presents the Linux Foundation ids `1d6b:0104`.  Then read the kernel
console (the whole boot log is replayed):

```sh
sudo chmod a+rw /dev/ttyACM0   # or add yourself to the dialout group
picocom -b 115200 /dev/ttyACM0 # or: screen /dev/ttyACM0 115200
```

`debian/capture-serial.sh` (in this repository) captures the console for long
runs: it auto-detects the gadget, reconnects after a reboot or re-plug, and
keeps appending to one log until Ctrl-C:

```sh
./capture-serial.sh -t -o nabu-boot.log
```

## If it never enumerates

- Make sure the USB-C port is connected to the PC as a **device** (it is forced
  to peripheral mode on this build) and that the UKI was rebuilt from a kernel
  with `CONFIG_USB_CONFIGFS_ACM=y` and the peripheral-mode DTB above.
- Check the gadget service ran: `systemctl status nabu-usb-console.service` and
  `ls /sys/kernel/config/usb_gadget/nabu-console`.

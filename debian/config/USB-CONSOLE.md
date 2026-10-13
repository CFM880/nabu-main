# USB serial debug console

`nabu-debian` gets its kernel from the `production` product (default
`KERNEL_RELEASE=6.14.11-nabu-full`), which builds in the legacy CDC-ACM gadget
(`CONFIG_USB_G_SERIAL=y`, see `nabu-main/config/nabu-usb-console.config`).  The
kernel therefore creates `ttyGS0` by itself at boot, **with no userspace service
and no configfs setup**, but the UKI command line does **not** carry `console=ttyGS0` any more
(removed 2026-10-08 — only `console=tty0` remains, and `ignore_loglevel` is gone
too).  Kernel printk therefore never reaches the serial port: the previous
setup flooded it with `ignore_loglevel` + `ath10k_snoc: chan info: invalid
frequency 0 (idx 41 out of bounds)` (~189 lines per boot), which pushed
`serial_cmd.py`'s first login off the prompt.  Log in and run `dmesg` for the
complete early-boot ring buffer: `console=` only picks the *output*, printk
always records to the ring buffer.

## On the tablet (login getty removed 2026-10-13)

- The kernel gadget (legacy `g_serial`) defaults to `use_acm=1` and binds as
  soon as the USB device controller is in device role.  `/dev/ttyGS0` only
  appears once a USB **host** has enumerated the gadget, though.
- `serial-getty@ttyGS0.service` is **not** enabled any more.  It used to be
  symlinked into `getty.target.wants`, which made systemd wait for
  `dev-ttyGS0.device` for the full 90 s device timeout on every boot without a
  host cable; that stalled `multi-user.target` → `hexagonrpcd` → the SSC sensor
  proxy and broke auto-rotation until a re-login.  To get a serial login
  anyway, plug in a host and start it on demand:
  ```sh
  sudo systemctl start serial-getty@ttyGS0.service
  ```
- No `nabu-usb-console.service` / configfs helper is installed.

## On the host PC

Connect a USB data cable and look for a new ACM device:

```sh
dmesg | tail            # cdc_acm 1-1:1.0: ttyACM0: USB ACM device
ls /dev/ttyACM*
```

The gadget presents NetChip ids `0525:a4a7` ("Gadget Serial v2.4").  Then read
the log / log in (user `nabu`, password `nabu` by default):

```sh
sudo chmod a+rw /dev/ttyACM0   # or add yourself to the dialout group
picocom -b 115200 /dev/ttyACM0 # or: screen /dev/ttyACM0 115200
```

By default nothing is printed on the serial port until you log in: run `dmesg`
in the serial getty for the complete early-boot log (the ring buffer records
everything regardless of `console=`).

To watch a boot live, put `console=ttyGS0` (after `console=tty0`) back into
`config/debian.cmdline`, rebuild with `./build.sh --uki-only` and refresh
`\EFI\debian\nabu-debian.efi` on the ESP.  The ttyGS console carries
`CON_PRINTBUFFER`, so the whole boot ring buffer is replayed as soon as the
gadget is created and a hang from before USB came up stays visible.

`debian/capture-serial.sh` (in this repository) captures the console for long
runs: it auto-detects the gadget, reconnects after a reboot or re-plug, and
keeps appending to one log until Ctrl-C (with the default command line it
captures the login/interactive session, not the boot log):

```sh
./capture-serial.sh -t -o nabu-boot.log
```

## If it never enumerates

- The USB-C port is forced to **device role** on this debug build
  (`&usb_1_dwc3 { dr_mode = "peripheral"; }` in `nabu-platform`), because the
  mainline `pm8150b` TCPM and the downstream `qcom_pmi8998_charger` both drive
  the PM8150B Type-C power-role register and otherwise leave the port as host.
  The USB-C port therefore cannot act as an OTG host while this is set.
- Make sure the UKI was rebuilt from a kernel built with both
  `CONFIG_USB_G_SERIAL=y` and the peripheral-mode DTB above.

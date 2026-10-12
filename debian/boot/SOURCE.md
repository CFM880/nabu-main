# boot/nabu-dualboot-efi.zip

Dual-boot EFI payload for the ESP image, vendored so `make-img.sh` works
offline. It is the exact boot chain the other nabu Linux distributions put on
the ESP, stripped of the source distribution's own kernel:

```
EFI/BOOT/bootaa64.efi        rEFInd AA64 (rodriguezst/rEFInd-nabu)
EFI/BOOT/fbaa64.efi          rEFInd fallback
EFI/BOOT/refind.conf         distro default (make-img.sh replaces it)
EFI/BOOT/drivers_aa64/       rEFInd filesystem/rotation drivers
EFI/BOOT/icons/              default rEFInd icons
EFI/BOOT/themes/             refind-theme-regular
EFI/BOOT/vars/PreviousBoot
EFI/Android/Reboot2Android.efi  rodriguezst/Reboot2AndroidPkg
```

## Provenance

Taken from the Fedora-for-nabu release bundle `efi-files-43.0.zip`
(<https://github.com/jhuang6451/nabu_fedora/releases/tag/release-20260417-1049>),
which packages the upstream binaries above. The `EFI/fedora/` kernel was
removed; `make-img.sh` adds our `EFI/debian/nabu-debian.efi` instead.

Upstream components:

- rEFInd AA64, `refind_aa64.efi` sha256 `c563b52e4068d2e8a836c43b10465b4ea066ca7f3d1266107b6b11698270ee4c`
  (<https://github.com/rodriguezst/rEFInd-nabu/releases/tag/v1.0.0>)
- `Reboot2Android.efi`
  (<https://github.com/rodriguezst/Reboot2AndroidPkg/releases/tag/v1.0.2>)

Source archive sha256:
`15361b7d1ccf1631308745a0cc73cc27a14de15de2c5191ceca8cd0989daa213`

Vendored archive sha256: see `make-img.sh` output / `sha256sum boot/nabu-dualboot-efi.zip`.

To refresh from the pinned (or a newer) release, run `./fetch-efi.sh`.

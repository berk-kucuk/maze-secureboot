# maze-secureboot

The Secure Boot / Unified Kernel Image machinery that keeps a Maze system
bootable across kernel updates — **as a pacman package**, so it can be fixed
after a machine has already shipped.

## Why this package exists

Every file in here used to be written per-machine, as inline heredocs, by the
installer (`maze-installer/.../deploy-to-target.sh`) into `/usr/local/bin`,
`/etc/pacman.d/hooks`, `/etc/kernel/install.d` and `/etc/systemd/system`.

That made them **unreachable**. pacman owned none of those files, so a bug in
the signer — or an upstream `systemd` change that broke the `kernel-install`
contract — could never be fixed on an already-installed machine. The one
subsystem whose failure mode is *"the computer does not boot"* was the one
subsystem with no update path.

Now a fix is `pkgrel++` and a publish to `[mazelinux]`. `maze-meta` depends on
this package, so every existing Maze install picks it up on the next
`pacman -Syu`.

## What it ships

**Keeping the chain current and signed**

| Path | Role |
|---|---|
| `/usr/bin/maze-sb-sign` | Signs the UKI with the machine MOK, installs it as `EFI/BOOT/grubx64.efi` (shim's second stage), reinstalls shim, keeps a rollback copy, prunes stale UKIs. `flock`-serialised. |
| `/usr/bin/maze-kernel-install-add` | Runs `kernel-install add` for each upgraded kernel — the step stock Arch never performs. |
| `/usr/share/libalpm/hooks/85-maze-kernel-install.hook` | Fires on `usr/lib/modules/*/vmlinuz`; rebuilds the UKI **before** the re-sign pass. |
| `/usr/share/libalpm/hooks/zz-maze-secureboot.hook` | Idempotent re-sign after kernel/nvidia/dkms/mkinitcpio/systemd changes. |
| `/usr/lib/kernel/install.d/95-maze-sb-sign.install` | Signs inline during every `kernel-install add`, including manual ones. |
| `/usr/lib/systemd/system/maze-sb-resign.{service,path}` | Self-heal for kernel writes with no pacman transaction. |
| `/usr/lib/systemd/system/systemd-boot-update.service.d/99-maze-resign.conf` | Repairs the chain after `bootctl update` overwrites `BOOTX64.EFI`. |

**Refusing to let you reboot into a broken chain**

| Path | Role |
|---|---|
| `/usr/bin/maze-boot-check` | End-to-end verification of the whole chain — 11 checks, each with the command that fixes it. `--repair` rebuilds and re-signs. |
| `/usr/share/libalpm/hooks/zzz-maze-boot-verify.hook` | Last hook of every relevant transaction; runs the check and raises the flag. |
| `/usr/bin/maze-boot-guard` + `.service` / `.path` | Holds a logind shutdown inhibitor while `/var/lib/maze/boot-unsafe` exists. |
| `/usr/bin/maze-boot-notify` + `etc/xdg/autostart` | Critical desktop notification at login. |
| `/etc/profile.d/maze-boot-warning.sh` | Same warning on TTY and SSH, where notifications never arrive. |
| `maze-boot-check.timer` | 3 min after boot, then daily — catches drift outside any transaction. |

### Why a separate end-to-end check

Every layer above fails loudly in its own lane, but until now nothing verified
the chain as a whole. A machine can pass every individual step and still not
boot. The clearest case: a UKI that builds and signs perfectly but carries an
initramfs with no `encrypt` hook on a LUKS root. It boots, cannot unlock its own
disk, and no signer, hook or unit anywhere reports a problem.

`maze-boot-check` verifies UKI coverage for every installed kernel, that
`grubx64.efi` points at a kernel whose modules are still on disk, that it is
byte-identical to the UKI it claims to be, its MOK signature, shim's presence,
MOK enrolment when Secure Boot is actually on, the `encrypt` hook against a LUKS
root, that the cmdline's UUIDs resolve to real devices, `layout=uki`, ESP
headroom, and that nothing in `/etc` is shadowing the packaged files.

### What the guard does and does not stop

Blocked, with the reason printed: Plasma's log-out menu, `systemctl reboot` from
a session, anything else that goes through logind. **Not** blocked, on purpose:
`systemctl reboot -i` and `reboot -f`. An administrator keeps the last word on
their own machine; the job here is to make the decision an informed one, not to
lock anyone out of their computer.

## What stays per-machine (installer-owned, not packaged)

* `/var/lib/maze-secureboot/MOK.{key,crt,cer}` — the per-machine signing key
* `/var/lib/maze-secureboot/{shim,mm}x64.efi` — shim binaries copied off the ISO
* `/etc/kernel/cmdline` and `/etc/kernel/install.conf` (`layout=uki`)
* the `Maze Linux` NVRAM boot entry, and `ENROLLMENT.txt`

## Migration off the old layout

Machines installed from an older ISO carry installer-written copies at the old
paths, and those **shadow** the packaged ones — a hook in `/etc/pacman.d/hooks`
overrides the same-named hook in `/usr/share/libalpm/hooks`, and likewise for
`/etc/kernel/install.d` over `/usr/lib/kernel/install.d` and
`/etc/systemd/system` over `/usr/lib/systemd/system`. pacman reports no file
conflict, because the packaged paths are all different. Without migration the
package would install and change nothing, while looking applied.

`maze-secureboot.install` therefore:

1. replaces the old `/usr/local/bin/maze-{sb-sign,kernel-install-add}` with exec
   shims pointing at `/usr/bin` — pacman has *already* read the hook directories
   by the time the scriptlet runs, so the old hooks can still fire once, at
   PostTransaction of this very transaction. If that same `pacman -Syu` also
   upgraded the kernel, a broken run there would fail exactly when the UKI needed
   rebuilding. The shims make every path lead to the packaged implementation;
2. deletes the shadowing hooks, kernel-install plugin, units and drop-in
   (including the pre-`zz-` name `95-maze-secureboot.hook`);
3. drops enablement symlinks left dangling by (2), reloads systemd, unmasks
   `systemd-boot-update.service`, applies the preset;
4. warns if `/etc/kernel/install.conf` has lost `layout=uki` on a machine that
   has a MOK key — that combination silently stops kernel updates from ever
   reaching the boot chain;
5. on **first** install only, rebuilds the UKI for every installed kernel and
   re-signs, in case the old unmanaged copies had been failing quietly.

`post_remove` deletes the shims (marked with `# maze-secureboot-compat-shim`) so
they never point at a binary that is gone.

## Installation

> **Part of Maze Linux.** Every Maze Linux system already has it (pulled in by `maze-meta`). It is built around Maze's own system layout, so installing it on another distribution is not supported.

### From the Maze repository

**On Maze Linux** the repository is already configured:

```bash
sudo pacman -S maze-secureboot
```

**On Arch Linux and Arch-based distributions**, add the repository once:

1. Import and trust the Maze signing key:

   ```bash
   curl -O https://mazerepo.berkkucukk.com.tr/packages/mazelinux.gpg
   gpg --show-keys --with-fingerprint mazelinux.gpg
   sudo pacman-key --add mazelinux.gpg
   sudo pacman-key --lsign-key 7C4D515A6B930CB04794CEF6147C8159B3E2EE5F
   ```

   The fingerprint `gpg` prints must be `7C4D 515A 6B93 0CB0 4794  CEF6 147C 8159 B3E2 EE5F`.

2. Add the repository to the end of `/etc/pacman.conf`:

   ```ini
   [mazelinux]
   SigLevel = Required DatabaseOptional
   Server = https://mazerepo.berkkucukk.com.tr/packages
   ```

3. Sync and install:

   ```bash
   sudo pacman -Syu maze-secureboot
   ```

Optionally install `mazelinux-keyring` as well; it keeps the signing key up to date through pacman.

Remove with `sudo pacman -Rns maze-secureboot`.

### Build from source

```bash
sudo pacman -S --needed base-devel git
git clone https://github.com/berk-kucuk/maze-secureboot.git
cd maze-secureboot
makepkg -si
```

## Build

```bash
./build.sh                       # -> maze-secureboot-1.1.0-1-any.pkg.tar.zst
./build.sh --install             # build + pacman -U
./build.sh --repo ../MazeLinux/localrepo
```

Publish to `[mazelinux]` **before** bumping `maze-meta`, or `pacman -Syu` fails
with "target not found" on every existing machine.

## Boot-default pinning and rollback

`maze-sb-sign` reads `/etc/maze/kernel-default` — the pkgbase pinned by
`maze-kernel-helper set-default` — and installs **that** kernel's UKI as
`grubx64.efi`. It used to always take the newest installed kernel, so every
kernel install or update silently discarded the user's choice (the switcher had
to warn about it after each `set-default`). The pin is advisory: if the pinned
kernel is not installed, or has no UKI on the ESP, the signer falls back to the
newest and says why.

Because shim chainloads `grubx64.efi` and nothing else — there is no
systemd-boot menu, and the sd-boot NVRAM entry is deliberately removed — a bad
kernel used to leave no way back except a live USB. The signer now keeps the
outgoing image as `grubx64.efi.maze-prev`, rotating it only when the kernel
*version* changes (tracked in `grubx64.efi.maze-kver`), so the three
signer invocations of a single kernel upgrade cannot overwrite the fallback with
the image it is a fallback for. Recovery is a copy:

```bash
cp -f /boot/EFI/BOOT/grubx64.efi.maze-prev /boot/EFI/BOOT/grubx64.efi
```

Stale UKIs are now pruned **before** signing as well as after. The after-only
prune meant a run that kept failing could never reclaim the space causing the
failure — and a full ESP is the obvious way for `sbsign` to fail, so the one
situation the cleanup existed for was the one where it never ran. UKIs of
installed kernels are never touched, which is what makes a second kernel (and
the pin) work.

## Still not handled

Out-of-tree modules (nvidia, dkms) are not signed. That is harmless while the
Arch kernel does not enforce lockdown, but it would break those modules if
upstream ever enables it under Secure Boot.

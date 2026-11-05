# kombain

A fast, small and hardened Void Linux desktop for developers and gamers. Every
layer is picked by what it really adds to the system, measured from the Void
package index.

![fdash in foot under the netline panel](docs/desktop.png)

*fdash in foot under netline. Captured on sway with software rendering, because
mango needs a real DRM device; see Status below.*

## The stack

"Adds" is the installed size a package pulls in on top of `base-system` with
mango, dependencies included, from the Void x86_64 index in November 2026.

| Layer | Pick | Adds | Instead of |
|---|---|---|---|
| Scripts | dash (`/bin/sh`) | already there | bash |
| Interactive shell | [fdash](fdash/) | 0.3 MiB | fish (19.3 MiB) |
| Prompt, history | built into fdash | 0 | starship (12 MiB), atuin (28 MiB) |
| Compositor | mangowc | 53.5 MiB, libraries included | |
| Panel, launcher, Wi-Fi, Bluetooth, wallpaper, power, calendar | [netline](https://github.com/FalconBinary/netline) | 1.3 MiB | waybar, rofi, swaybg, nmcli |
| Terminal | foot, as a server | 1 MiB | alacritty (8.6 MiB), kitty (80.5 MiB) |
| Screen lock | swaylock | 0.1 MiB | |
| Firewall | nftables, loaded before the network | 25.4 MiB | |
| Temperatures | [zcool](zcool/): a limit per chip, fans first, then a little power | 0.1 MiB | |
| Search | ripgrep, fd, fzf, jq | 15.3 MiB | |
| Multiplexer | tmux | 1.6 MiB | zellij (49.3 MiB) |
| Files | nnn | 0.4 MiB | yazi (41.2 MiB) |
| Processes | htop | 0.4 MiB | btop (1.9 MiB) |
| Version control | git | 129.6 MiB | |

With `--extras`, because they only pay off when used: neovim (35.5 MiB, helix is
207.2 MiB), ccache (2 MiB), mold (49.4 MiB). Left out for the same reason: podman
(219.7 MiB).

## Install

On Void Linux with glibc, as root. [docs/void-install-guide.md](docs/void-install-guide.md)
covers the system below this (LUKS, XFS, Limine, iwd, a separate gaming mode), in Russian.

```sh
git clone https://github.com/FalconBinary/kombain
cd kombain
./install.sh --user NAME
chsh -s /usr/local/bin/fdash NAME
```

Then log in on tty1. It is safe to run again: `/bin/sh` stays dash, and existing
dotfiles and `/etc/nftables.conf` are kept. It also enables the `dbus` and `elogind`
services. The firewall starts right away and drops new incoming connections, so if
you reach this machine over ssh, open port 22 first (the script warns about it).

It also installs the kernel hardening settings in `config/sysctl.conf`. They take
effect right away, and some cannot be undone until a reboot. That includes
`kernel.yama.ptrace_scope=1`, so attaching a debugger to a running process needs root.
Kernel lockdown is set in the bootloader, so the script only reminds you about it.
fdash, netline and zcool are built as `nobody`, and netline is pinned to one commit.

It also builds the gconv cache that Void's glibc lacks and refreshes it at every
boot. In our measurements that made programs under a UTF-8 locale start about
twice as fast (`bash -c true`: 1.11 ms to 0.50 ms). Void's zig is too old for netline
and zcool, so the script fetches a checksummed Zig 0.17.1 for the build and removes it
afterwards.

| Keys | Action |
|---|---|
| `Alt+Return` | Terminal |
| `Super+D`, `Alt+Space` | Applications |
| `Super+Shift+R` | Run a command |
| `Super+W`, `Super+B` | Wi-Fi, Bluetooth |
| `Super+P` | Wallpaper |
| `Super+C` | Calendar |
| `Super+Escape` | Power menu |
| `Alt+Shift` | Switch between us and ru |

## Status

Checked in Void Linux containers on arm64:

- fdash: 51 tests through a real pty, also under ASan and UBSan, with scripts
  compared against unmodified dash of the same version.
- `install.sh`: from a clean image, twice.
- `mango -p` accepts the config.
- Firewall: `tests/firewall.sh` sends real traffic between network namespaces, on
  the Colima kernel (6.8), including a broken config and a missing one.
- gconv cache: `tests/gconv-cache.sh`, including a stale and a damaged cache.
- zcool: unit tests and a thermal simulator, `zcool/tests/sim.py`. It has not touched real hardware.
- netline and fdash together on a wlroots compositor (sway), as in the screenshot.

Not checked yet:

- **mango with this config on a real GPU.** It needs a DRM device, which the test VM lacks.
- **netline's mango integration** (tags, IPC), for the same reason.
- **fdash on x86_64.** netline cross-compiles for it, but the shell has only run on arm64.
- **zcool on a real machine.** Real drivers, fans and chips differ from the model. Start with `--dry-run`.
- Steam and gamescope in the gaming mode from the guide.

## Licenses

[GPL-3.0-or-later](LICENSE). The vendored code keeps its own licenses, which allow
this: [dash](fdash/dash/COPYING) is BSD-3-Clause and [isocline](fdash/isocline/LICENSE) is MIT.

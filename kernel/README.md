# kernel: Void's kernel with sched_ext, for the GF63

`linux6.18-kombain` is Void's `linux6.18` built again with three changes, so that sched_ext
schedulers (Void's `scx`: `scx_lavd`, `scx_bpfland`; later UniVoidDistro's `vh-sched`) can run
on this machine and be compared per mode with `kombain-bench`. The stock Void kernel stays
installed and stays the default entry in Limine: this one is picked by name, and removed with
one command if it misbehaves.

Nothing here is called faster. The rows decide (`bench/README.md`): `boot`, `idle`, `jitter`
and `build` with the label `6.18.62-kombain_1/runit` beside the stock kernel's.

## What changes, and why

The template is Void's `srcpkgs/linux6.18` from void-packages at the commit in
[void-packages.commit](void-packages.commit), with Void's x86_64 config, `mv-debug` and
patches byte for byte (CI checks that). The config changes are
[srcpkgs/linux6.18-kombain/files/kombain.config](srcpkgs/linux6.18-kombain/files/kombain.config),
every line with its reason:

| Change | Why |
|---|---|
| `CONFIG_SCHED_CLASS_EXT=y` | sched_ext: schedulers as BPF programs. Void's kernel has it off; what it depends on (`BPF_SYSCALL`, `BPF_JIT`, `DEBUG_INFO_BTF`) Void has on |
| `CONFIG_PREEMPT=y`, `CONFIG_PREEMPT_DYNAMIC=y` kept | full preemption as the build default, where Void defaults to voluntary; `preempt=voluntary`, `preempt=lazy` and `preempt=none` still select at boot, so the modes can be measured without a rebuild |
| `CONFIG_LOCALVERSION="-kombain"` | the kernel's name: `6.18.62-kombain_1` next to Void's `6.18.62_1` in `uname -r`, `/boot`, `/usr/lib/modules`, the Limine menu and kombain-bench's default label |

The template itself differs from Void's in: the name, `archs="x86_64*"`, `_kernver` with
`-kombain` in it (so files and modules directory match the kernel's own release string),
`KBUILD_BUILD_USER`/`HOST` = `kombain`, and `do_configure`, which merges the fragment with
`scripts/kconfig/merge_config.sh`, runs `olddefconfig`, then fails the build if any line of the
fragment is missing from the result, and prints `scripts/diffconfig` against Void's config.
Everything else, `do_build`, `do_install`, the `-headers` and `-dbg` subpackages, module
compression and signing, is Void's. Modules stay on, module signing stays without
enforcement: NVIDIA's unsigned DKMS modules load, as they do on the stock kernel. Lockdown
stays off on this machine for the same reason, so kCFI and a kernel without modules are not
options here.

What is not changed on purpose: HZ 1000, every mitigation, `NR_CPUS`, the compiler (gcc, no
LTO), `-march` (generic x86-64). `-march=skylake` and clang ThinLTO are step 2, each as its own
build and release, after this kernel has booted and has rows.

## How it is built

[.github/workflows/kernel.yml](../.github/workflows/kernel.yml) runs when the kernel itself
changes: a push to a `kernel*` branch that touches the template, `build.sh` or the pinned
commit, or by hand (Actions, "kernel", Run workflow) once the workflow is on `main`, since
GitHub dispatches only workflows that exist on the default branch. It runs
[build.sh](build.sh) in `ghcr.io/void-linux/void-buildroot-glibc`,
the image that is a bootstrapped xbps-src masterdir (`base-chroot`: the same gcc 14.2 Void's
kernel is built with): void-packages at the pinned commit, the template copied in, the
container itself as xbps-src's chroot (`XBPS_CHROOT_CMD=ethereal`, no privileges needed; in that
mode `binary-bootstrap` has nothing to do, which is why the plain `void-glibc-full` image, with
no `patch` or `gcc`, cannot build it), `xlint`, then `./xbps-src -j4 pkg linux6.18-kombain`.
Void's full config with debug info for BTF takes a few
hours on the runner's four cores and tens of GB of disk; the workflow clears the runner's
unused SDKs first and allows six hours. The results go to a release
`kernel-<version>-kombain-r<revision>` (the template's `version` and `revision`):

- `linux6.18-kombain-<version>_<revision>.x86_64.xbps`: the kernel, its modules, `config-*`, `System.map`
- `linux6.18-kombain-headers-<version>_<revision>.x86_64.xbps`: what DKMS needs to build NVIDIA's modules
- `config-<release>`: the kernel's final `.config`; `diffconfig-void-to-kombain.txt`: what differs from Void's
- `BUILD`: the void-packages commit, the kombain commit, the compiler; `SHA256SUMS` over all of it

The `-dbg` package is built (Void's template does) and not published. A push build always
publishes; "Publish" off in the dispatch form keeps everything as a workflow artifact
instead. The same tag again is refused unless the dispatch form's "Replace" is on: a new
config is a new `revision`, so the rows keep telling the kernels apart.

Before any of that, the config can be checked in minutes on any machine with Docker
(x86_64, or Apple silicon through Rosetta):

```sh
docker run --rm --platform linux/amd64 -v "$PWD/kernel:/kernel:ro" -v "$PWD/kernel-build:/build" -w /build \
  -e BUILD=/build -e OUT=/build/out ghcr.io/void-linux/void-buildroot-glibc sh /kernel/build.sh configure
cat kernel-build/out/diffconfig-void-to-kombain.txt
```

## Install on the GF63

The stock kernel stays. Everything below is additive; the last section takes it out again.

```sh
mkdir -p ~/kernel && cd ~/kernel
tag=kernel-6.18.62-kombain-r1
for f in linux6.18-kombain-6.18.62_1.x86_64.xbps linux6.18-kombain-headers-6.18.62_1.x86_64.xbps SHA256SUMS; do
  curl -fLO "https://github.com/FalconBinary/kombain/releases/download/$tag/$f"
done
sha256sum --ignore-missing -c SHA256SUMS
xbps-rindex -a ./*.xbps
doas xbps-install --repository="$PWD" linux6.18-kombain linux6.18-kombain-headers
```

`xbps-install` will say the repository is unsigned and ask; that is this directory. What the
install runs, through Void's `kernel-hooks` trigger with the version `6.18.62-kombain_1`,
exactly as for the stock kernel:

1. `/etc/kernel.d/post-install/10-dkms` (from the `dkms` package) builds every DKMS module in
   `/var/lib/dkms`, NVIDIA's included, against the new `-headers` package. The headers are
   found at `/usr/lib/modules/6.18.62-kombain_1/build`; both packages are unpacked before
   either is configured, so the order on the command line does not matter.
2. `20-dracut` builds `/boot/initramfs-6.18.62-kombain_1.img` with the same
   `/etc/dracut.conf.d/10-local.conf` as the stock one: host-only strict, NVIDIA left out.
3. `60-limine` (the guide's step 5) rebuilds `limine.conf`, and signs it when Secure Boot is on.

### The Limine menu

The guide's hook now takes the newest kernel *without a dash* in its name as "Void Dev" and
"Void Gaming", so Void's kernel stays the default and the first two entries whatever version
each has. Every kernel is also listed by name; one with a dash gets both modes:

```
Void Dev                          6.18.62_1          default, the stock kernel
Void Gaming                       6.18.62_1
Void Dev 6.18.62_1
Void Dev 6.18.62-kombain_1
Void Gaming 6.18.62-kombain_1
```

A hook installed from the guide before this change has two lines to update in
`/etc/kernel.d/post-install/60-limine`, then runs once:

```sh
doas sed -i -e "s|^newest=\$(echo \$kernels \| cut -d' ' -f1)\$|newest=\$(echo \$kernels \| tr ' ' '\\\\n' \| grep -v -- - \| head -1)\\n[ -n \"\$newest\" ] \|\| newest=\$(echo \$kernels \| cut -d' ' -f1)|" \
  -e 's|^\t\tentry "Void Dev \$v" "\$v" "\$DEV_CMD"$|&\n\t\tcase $v in *-*) entry "Void Gaming $v" "$v" "$GAME_CMD" ;; esac|' \
  /etc/kernel.d/post-install/60-limine
doas /etc/kernel.d/post-install/60-limine
grep -E '^/' /boot/limine.conf
```

If the `sed` finds nothing to change (the hook was edited by hand), make the two edits
yourself: the `newest=` line and the `for v in $kernels` loop, as in the guide's step 5.
Without the change the old hook still lists `Void Dev 6.18.62-kombain_1`, just without a
Gaming entry, and would make a kombain kernel the default once its version is newer than the
stock one's.

### Check

```sh
uname -r                             # 6.18.62-kombain_1 after picking its entry in Limine
ls /sys/kernel/sched_ext             # enable_seq  hotplug_seq  nr_rejected  root  state  switch_all
cat /sys/kernel/sched_ext/state      # disabled: the class is there, no scheduler loaded yet
doas dmesg | grep 'Dynamic Preempt'  # Dynamic Preempt: full, in both entries (Gaming's preempt=full now changes nothing)
lsmod | grep '^nvidia'               # nvidia, nvidia_modeset, nvidia_drm; nvidia_uvm once something uses CUDA
dkms status                          # nvidia/…, 6.18.62-kombain_1, x86_64: installed
```

`dmesg | grep -i sched_ext` says nothing until a scheduler is loaded.

### Rows

Boot the new kernel, let the desktop settle, then the same four measurements the stock
kernel has rows for, with the default label (`uname -r` and PID 1):

```sh
doas kombain-bench boot
doas kombain-bench idle
kombain-bench jitter
kombain-bench build
kombain-bench summary
```

Ten boots and five of each long measurement per kernel before the summary means anything,
alternating with the stock kernel; `bench/README.md` has the method. The stock kernel's rows
are already there under `6.18.62_1/runit`.

### A scheduler, by hand

```sh
doas xbps-install -S scx                 # Void's package: scx_lavd, scx_bpfland, scx_rusty, scx_rustland and more
doas scx_lavd                            # a terminal: the scheduler runs while this does; Ctrl-C hands back EEVDF
cat /sys/kernel/sched_ext/root/ops       # lavd, in another terminal
cat /sys/kernel/sched_ext/state          # enabled
```

`scx_lavd --help` lists its modes (`--performance`, `--powersave`, `--autopilot`). Rows with a
scheduler running are a variant of their own: `kombain-bench jitter --label 6.18.62-kombain_1/scx_lavd`.
Switching schedulers by mode belongs to ztune and comes after the rows, not here.

### Back out

```sh
doas xbps-remove linux6.18-kombain linux6.18-kombain-headers
```

The `pre-remove` and `post-remove` hooks run with the same version: DKMS removes NVIDIA's
modules for it, dracut removes its initramfs, the Limine hook drops its entries. `vkpurge`
never lists this kernel while the package is installed (it skips kernels a package owns) and
has nothing left to list after. The stock kernel was never touched. If the kombain entry does
not boot, the firmware's menu or Limine's shows the stock entry as before: it is the default.

## Updating

Void moves `linux6.18` every week or two. `kernel/refresh.sh <void-packages commit>` takes the
template's version and checksums and the config, `mv-debug` and patches from that commit,
writes the commit to `void-packages.commit` and shows what else Void changed in its template,
for a person to port. Then `revision=1`, commit, dispatch. The GF63 then has `6.18.70_1` and
`6.18.70-kombain_1` side by side, as before.

## Step 2, later

`-march=skylake` as `KCFLAGS` (the i5-10500H is Comet Lake, Skylake's core), then clang ThinLTO
(`LLVM=1`), each a build and release of its own with its own revision, so the rows tell them
apart. Only after this kernel has booted and has its rows. kCFI is out: NVIDIA's module is not
built with it.

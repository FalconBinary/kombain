# Void Linux: Dev + Gaming на XFS, LUKS, Limine и iwd

Версия 3: графическая среда теперь ставится из репозитория kombain (`mangowc`, `netline`, `fdash`).

> ⚠️ Шаг 0 можно выполнить где угодно. Всё остальное выполняется **на целевом ПК из live ISO**. Шаг 2 стирает диск.
> Сначала прогоните установку в VM. На реальном железе вся схема ещё не проверялась.

## Схема

| Раздел | Содержимое | Dev | Gaming |
|---|---|---|---|
| `p1` 1 ГБ, FAT32 | `/boot` (ядра, Limine) | смонтирован | смонтирован |
| `p2` LUKS + LVM `vg0` | `root` и `gamer` (XFS) | открыт | открыт |
| `p3` LUKS со **своим паролем** | `/home/dev` (XFS) | открыт | **закрыт, ключа нет в памяти** |

Режим выбирается пунктом меню Limine. Слово `gaming` в параметрах ядра включает отдельный набор сервисов runit.

## 0. Проверка ISO

Скачайте **base**-образ x86_64 (glibc, не musl), `sha256sum.txt` и `sha256sum.sig` с `https://repo-default.voidlinux.org/live/current/`. Ключ `void-release-*.pub` возьмите из каталога `void-release-keys` в Git-репозитории Void.

```bash
minisign -V -p void-release-ДАТА.pub -x sha256sum.sig -m sha256sum.txt
shasum -a 256 -c sha256sum.txt --ignore-missing
```

Должно быть `Signature and comment signature verified` и `OK`. В Linux вместо `shasum -a 256` используйте `sha256sum`. Иначе образ не используйте.

В BIOS: режим UEFI, Secure Boot **пока выключен** (он включается на шаге 12).

## 1. Live-система

Вход: `root` / `voidlinux`. На live ISO работает SSH с этим общеизвестным паролем, поэтому сначала выключите его.

```bash
sv down sshd
```

Wi-Fi (по кабелю сеть поднимется сама):

```bash
wpa_passphrase "ИМЯ_СЕТИ" "ПАРОЛЬ" >> /etc/wpa_supplicant/wpa_supplicant.conf
sv restart wpa_supplicant
sv restart dhcpcd
ping -c3 repo-default.voidlinux.org
xbps-install -Sy xbps
```

iwd на base-образе нет, он появится в установленной системе.

## 2. Диск

В `cfdisk` создайте GPT и три раздела: `p1` 1 ГБ типа *EFI System*, `p2` под систему и игры, `p3` под данные Dev. Для SATA-дисков имена будут `/dev/sdaN`, поправьте команды. **XFS нельзя уменьшить**, поэтому оставьте в `vg0` свободное место.

```bash
DISK=/dev/nvme0n1
cfdisk -z "$DISK"

cryptsetup luksFormat --type luks2 "${DISK}p2"
cryptsetup luksFormat --type luks2 "${DISK}p3"   # другой пароль
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent "${DISK}p2" cryptroot
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent "${DISK}p3" cryptdev

pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 80G -n root vg0
lvcreate -L 400G -n gamer vg0

mkfs.vfat -F32 -n EFI "${DISK}p1"
mkfs.xfs -L root /dev/vg0/root
mkfs.xfs -L gamer /dev/vg0/gamer
mkfs.xfs -L devhome /dev/mapper/cryptdev

mount /dev/vg0/root /mnt
mkdir -p /mnt/boot /mnt/home/dev /mnt/home/gamer
mount "${DISK}p1" /mnt/boot
mount /dev/vg0/gamer /mnt/home/gamer
mount /dev/mapper/cryptdev /mnt/home/dev
```

`--allow-discards` ускоряет SSD, но позволяет увидеть, какие блоки заняты. Для большинства это приемлемо.

## 3. Базовая система

`base-minimal` теперь просто `base-container`, поэтому основа здесь `base-system`, из которого лишнее удаляется ниже.

```bash
REPO=https://repo-default.voidlinux.org/current
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64 xbps-install -S -r /mnt -R "$REPO" base-system cryptsetup lvm2 xfsprogs zstd limine efibootmgr iwd openresolv dbus elogind polkit rtkit chrony nftables zramen snooze run-parts opendoas xtools git pipewire wireplumber flatpak gamescope void-repo-nonfree
cp /etc/resolv.conf /mnt/etc/
xchroot /mnt /bin/bash
```

## 4. Настройка системы

Всё дальше до шага 11 выполняется **внутри chroot**. Часовой пояс поправьте под себя.

```bash
DISK=/dev/nvme0n1
echo voidbox > /etc/hostname
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
sed -i -e 's/^#en_US.UTF-8/en_US.UTF-8/' -e 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/default/libc-locales
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
xbps-reconfigure -f glibc-locales
passwd

mkdir -p /etc/xbps.d
printf 'ignorepkg=%s\n' wpa_supplicant sudo btrfs-progs f2fs-tools > /etc/xbps.d/10-ignore.conf
xbps-remove -Ry wpa_supplicant sudo btrfs-progs f2fs-tools
echo 'permit :wheel' > /etc/doas.conf
chmod 400 /etc/doas.conf
xbps-install -Sy
```

**Микрокод.** Для AMD он уже установлен (`linux-firmware-amd`). Для Intel:

```bash
xbps-install -y intel-ucode
```

**Драйвер GPU.** Выполните одну строку:

```bash
xbps-install -y mesa-dri vulkan-loader mesa-vulkan-radeon   # AMD
xbps-install -y mesa-dri vulkan-loader mesa-vulkan-intel    # Intel
xbps-install -y nvidia                                      # NVIDIA Turing (GTX 16xx, RTX 20xx) и новее
xbps-install -y nvidia580                                   # NVIDIA Maxwell, Pascal, Volta
```

Заголовки ядра для NVIDIA подтянутся сами, они в зависимостях `dkms`.

**`/etc/fstab`.** Подставьте UUID раздела EFI из `blkid "${DISK}p1"`.

```bash
cat > /etc/fstab <<'EOF'
/dev/vg0/root   /           xfs   defaults,noatime 0 0
/dev/vg0/gamer  /home/gamer xfs   defaults,noatime,nosuid,nodev,logbufs=8,logbsize=256k 0 0
LABEL=devhome   /home/dev   xfs   defaults,noatime,nosuid,nodev,logbufs=8,logbsize=256k,noauto 0 0
UUID=XXXX-XXXX  /boot       vfat  defaults,noatime,fmask=0077,dmask=0077 0 2
tmpfs           /tmp        tmpfs defaults,nosuid,nodev,mode=1777 0 0
EOF
```

- `noauto` у `/home/dev` обязателен. Ошибка `mount -a` при загрузке Void приводит в аварийную оболочку, а в Gaming этого раздела нет.
- `noexec` на `/home/gamer` и `/tmp` не ставьте, иначе не запустятся игры.

**Initramfs.** `hostonly_cmdline="no"` нужен, чтобы параметры брались только из Limine и Gaming не спрашивал пароль от `p3`.

```bash
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-local.conf <<'EOF'
hostonly="yes"
hostonly_cmdline="no"
add_dracutmodules+=" crypt lvm "
compress="zstd"
EOF
```

## 5. Limine

Хук пересобирает конфиг при каждом обновлении ядра. Он выполняется после сборки initramfs (`20-initramfs`) и сразу умеет Secure Boot из шага 12.

```bash
mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
cat > /etc/kernel.d/post-install/60-limine <<'HOOK'
#!/bin/sh
# Пересобирает limine.conf; при SECUREBOOT=1 добавляет хэши, вписывает хэш конфига в Limine и подписывает его
SECUREBOOT=0
ROOT_UUID=ROOT-UUID
DEV_UUID=DEV-UUID

COMMON="rd.luks.uuid=$ROOT_UUID rd.lvm.vg=vg0 root=/dev/vg0/root rootfstype=xfs rw quiet loglevel=3 slab_nomerge page_alloc.shuffle=1 zswap.enabled=0 lockdown=integrity"
DEV_CMD="rd.luks.uuid=$DEV_UUID $COMMON"
GAME_CMD="$COMMON gaming preempt=full split_lock_detect=off"

BOOT=/boot
OUT=$BOOT/limine.conf
EFI=$BOOT/EFI/BOOT/BOOTX64.EFI

file_ref() {
	if [ "$SECUREBOOT" = 1 ]; then
		printf 'boot():/%s#%s' "$1" "$(b2sum "$BOOT/$1" | cut -d' ' -f1)"
	else
		printf 'boot():/%s' "$1"
	fi
}

entry() {
	printf '/%s\n    protocol: linux\n    path: %s\n    cmdline: %s\n    module_path: %s\n\n' \
		"$1" "$(file_ref "vmlinuz-$2")" "$3" "$(file_ref "initramfs-$2.img")"
}

kernels=
for f in $(ls -1 "$BOOT"/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -rV); do
	if [ -e "$BOOT/initramfs-$f.img" ]; then
		kernels="$kernels $f"
	fi
done
[ -n "$kernels" ] || exit 0
newest=$(echo $kernels | cut -d' ' -f1)

{
	printf 'timeout: 3\neditor_enabled: no\n\n'
	entry "Void Dev" "$newest" "$DEV_CMD"
	entry "Void Gaming" "$newest" "$GAME_CMD"
	for v in $kernels; do
		entry "Void Dev $v" "$v" "$DEV_CMD"
	done
} > "$OUT.tmp" || exit 1

# Конфиг и Limine заменяются только вместе: при сбое подписи загрузка остаётся рабочей
mkdir -p "$BOOT/EFI/BOOT"
cp /usr/share/limine/BOOTX64.EFI "$EFI.new" || exit 1
if [ "$SECUREBOOT" = 1 ]; then
	limine enroll-config "$EFI.new" "$(b2sum "$OUT.tmp" | cut -d' ' -f1)" || exit 1
	sbctl sign "$EFI.new" || exit 1
fi
mv "$OUT.tmp" "$OUT"
mv "$EFI.new" "$EFI"
exit 0
HOOK
chmod +x /etc/kernel.d/post-install/60-limine
ln -sf ../post-install/60-limine /etc/kernel.d/post-remove/60-limine

sed -i -e "s/^ROOT_UUID=.*/ROOT_UUID=$(blkid -s UUID -o value "${DISK}p2")/" -e "s/^DEV_UUID=.*/DEV_UUID=$(blkid -s UUID -o value "${DISK}p3")/" /etc/kernel.d/post-install/60-limine

mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs none /sys/firmware/efi/efivars
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
efibootmgr --create --disk "$DISK" --part 1 --label "Limine" --loader '\EFI\BOOT\BOOTX64.EFI'
```

**Только для NVIDIA:** модули DKMS не подписаны, а `lockdown=integrity` их не загрузит. В строке `COMMON` замените `lockdown=integrity` на `nvidia_drm.modeset=1`.

После обновления пакета `limine` запускайте хук вручную: `/etc/kernel.d/post-install/60-limine`.

## 6. Сеть: iwd

```bash
mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF
```

iwd управляет только Wi-Fi. Если нужен кабель, сделайте сервис для конкретного интерфейса и добавьте `dhcpcd-$IF` в оба списка на шаге 8. Общий `dhcpcd` не включайте.

```bash
IF=enp3s0
cp -R /etc/sv/dhcpcd-eth0 "/etc/sv/dhcpcd-$IF"
rm -f "/etc/sv/dhcpcd-$IF/supervise" "/etc/sv/dhcpcd-$IF/log/supervise"
sed -i "s/eth0/$IF/g" "/etc/sv/dhcpcd-$IF/run"
```

## 7. Защита и производительность

Ядро и sysctl:

```bash
mkdir -p /etc/sysctl.d /etc/modules-load.d
cat > /etc/sysctl.d/90-local.conf <<'EOF'
# Защита
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
kernel.yama.ptrace_scope=1
kernel.kexec_load_disabled=1
kernel.sysrq=0
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
fs.suid_dumpable=0
net.core.bpf_jit_harden=2
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_redirects=0

# Производительность
vm.max_map_count=1048576
vm.swappiness=100
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
printf 'tcp_bbr\nsch_fq\n' > /etc/modules-load.d/bbr.conf
```

Не отключайте непривилегированные user namespaces: `bwrap` в Void без setuid, и без них Flatpak не работает.

Файрвол и монтирование `/home/dev` выполняются на этапе core-services, то есть **до запуска сети**. Штатный сервис `nftables` не включайте: при остановке он снимает все правила.

Входящие соединения закрыты, ответа на ping нет, исходящие открыты. Если в `/etc/nftables.conf` окажется ошибка, загрузятся встроенные правила с тем же смыслом, а при загрузке появится предупреждение. Сам `nft -c` проверяет только синтаксис.

```bash
cat > /etc/nftables.conf <<'EOF'
# Nothing comes in unless it answers something we started, nothing is forwarded,
# everything may go out. Open a port with a line in the input chain:
#   tcp dport 22 accept
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state vmap { established : accept, related : accept, invalid : drop }
    iif lo accept
    # IPv6 does not work without neighbor discovery and router advertisements
    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
    # DHCP replies
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
}
EOF
nft -c -f /etc/nftables.conf

cat > /etc/runit/core-services/85-firewall.sh <<'EOF'
# /etc/runit/core-services/85-firewall.sh: runs before any network comes up.
# This is not the nftables service on purpose: stopping that one flushes the rules.
# A broken /etc/nftables.conf must not leave the machine open, so the default
# rules are built in here too.
msg "Loading firewall..."
if ! nft -f /etc/nftables.conf; then
	msg_warn "/etc/nftables.conf did not load, using the built-in rules"
	nft -f - <<'RULES' || msg_error "NO FIREWALL: nft could not load any rules"
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state vmap { established : accept, related : accept, invalid : drop }
    iif lo accept
    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
}
RULES
fi
EOF

cat > /etc/runit/core-services/90-local.sh <<'EOF'
grep -qw gaming /proc/cmdline || mount /home/dev
EOF

cat >> /etc/sv/zramen/conf <<'EOF'
export ZRAM_COMP_ALGORITHM=zstd
export ZRAM_SIZE=50
export ZRAM_MAX_SIZE=16384
EOF

mkdir -p /etc/cron.weekly
printf '#!/bin/sh\nfstrim -a\n' > /etc/cron.weekly/fstrim
chmod +x /etc/cron.weekly/fstrim

mkdir -p /etc/pipewire/pipewire.conf.d
ln -s /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
```

## 8. Два режима: runlevel

```bash
mkdir -p /etc/sv/game-tune
cat > /etc/sv/game-tune/run <<'EOF'
#!/bin/sh
for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
	echo performance > "$g"
done
exec pause
EOF
chmod +x /etc/sv/game-tune/run

cp -R /etc/sv/agetty-tty1 /etc/sv/agetty-autologin-tty1
rm -f /etc/sv/agetty-autologin-tty1/supervise
cat >> /etc/sv/agetty-autologin-tty1/conf <<'EOF'
GETTY_ARGS="--autologin gamer --noclear"
EOF

mkdir -p /etc/runit/runsvdir/gaming
for s in udevd dbus elogind rtkit iwd chronyd zramen game-tune agetty-autologin-tty1 agetty-tty2; do
	ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/gaming/
done

for s in udevd dbus elogind rtkit iwd chronyd zramen snooze-weekly; do
	ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done
rm -f /etc/runit/runsvdir/default/agetty-tty4 /etc/runit/runsvdir/default/agetty-tty5 /etc/runit/runsvdir/default/agetty-tty6
ls -l /etc/runit/runsvdir/default /etc/runit/runsvdir/gaming
```

Автовход не ослабляет защиту диска: раньше него загрузка всё равно требует пароль LUKS. У `gamer` нет `wheel`.

## 9. Пользователи и сессии

**Не добавляйте `gamer` в группу `input`:** это даёт чтение всех нажатий клавиш. Доступ к устройствам активной сессии выдаёт elogind.

```bash
useradd -m -G wheel,audio,video dev
useradd -m -G audio,video gamer
passwd dev
passwd gamer

cat > /home/gamer/.bash_profile <<'EOF'
if [ "$(tty)" = /dev/tty1 ] && grep -qw gaming /proc/cmdline; then
	exec dbus-run-session "$HOME/game-session"
fi
EOF

cat > /home/gamer/game-session <<'EOF'
#!/bin/sh
pipewire &
exec gamescope -e -f -- flatpak run com.valvesoftware.Steam -gamepadui
EOF
chmod +x /home/gamer/game-session

chown -R dev:dev /home/dev
chown -R gamer:gamer /home/gamer
chmod 700 /home/dev /home/gamer
```

Сессию для `dev` настроит `install.sh` из kombain на шаге 11.

## 10. Сборка загрузки

```bash
xbps-reconfigure -fa
ls -l /boot /boot/EFI/BOOT
grep -E '^/|cmdline' /boot/limine.conf
```

Проверьте перед выходом:

- В `/boot` есть `vmlinuz-*`, `initramfs-*` и `limine.conf`, в `/boot/EFI/BOOT` есть `BOOTX64.EFI`.
- В `limine.conf` вместо `ROOT-UUID` и `DEV-UUID` стоят настоящие значения.
- В пунктах `Void Dev` два `rd.luks.uuid`, а в `Void Gaming` один.

## 11. Первая загрузка

```bash
exit
umount -R /mnt
reboot
```

В режиме **Dev** будет два запроса пароля LUKS, затем обычный вход в консоль.

```bash
cat /sys/kernel/security/lockdown
doas nft list ruleset
dmesg | grep -i microcode
swapon --show
iwctl station wlan0 scan
iwctl station wlan0 get-networks
iwctl station wlan0 connect "ИМЯ_СЕТИ"
```

Ожидается `[integrity]` в первом выводе (кроме NVIDIA), активная таблица файрвола и zram в `swapon`. Имя `wlan0` может быть другим, его покажет `iwctl device list`.

Установка графической среды и инструментов. `install.sh` описан в `README.md` репозитория:

```bash
git clone https://github.com/FalconBinary/kombain
cd kombain
doas ./install.sh --user dev
doas chsh -s /usr/local/bin/fdash dev
```

После выхода и нового входа на `tty1` запустится mango. Терминал открывается по `Alt+Return`, приложения по `Super+D`, Wi-Fi по `Super+W`.

Контроль температуры: `install.sh` ставит `zcool`, но не запускает его. На реальном железе он ещё не проверялся, поэтому сначала посмотрите, что он нашёл и что собирается делать:

```bash
zcool list
doas zcool run --dry-run
```

Лимиты задаются в `/etc/zcool.conf`, подробности в `zcool/README.md`. Если всё выглядит правильно, включите сервис в обоих режимах:

```bash
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/default/
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/gaming/
```

Undervolt через `zcool` не работает при `lockdown=integrity`: делайте его в BIOS.

Установка Steam:

```bash
doas -u gamer sh -c 'flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && flatpak install --user flathub com.valvesoftware.Steam'
```

Если `doas -u` не даст доступа к шине, войдите как `gamer` на `tty2` режима Gaming и выполните то же самое там.

В режиме **Gaming** должен быть **один** запрос пароля LUKS, затем автозапуск Steam. На `tty2` проверьте:

```bash
findmnt /home/dev
lsblk -f
cat /proc/cmdline
```

`findmnt` ничего не должен вывести, а `p3` в `lsblk` должен остаться закрытым. Выключение: `tty2` → `loginctl poweroff`.

## 12. Secure Boot (обязательно для заявленной защиты)

Без него LUKS защищает данные на выключенном ПК, но ядро на `/boot` можно незаметно подменить. Включайте только после того, как шаг 11 полностью заработал.

Цепочка такая: прошивка проверяет подпись Limine, Limine проверяет хэш конфига, конфиг содержит хэши ядра и initramfs. Параметры ядра тоже защищены, потому что они в конфиге.

1. В BIOS переведите Secure Boot в **Setup Mode** и задайте **пароль BIOS**, иначе Secure Boot можно просто выключить.
2. В Dev выполните:

```bash
doas xbps-install -Sy sbctl
doas sbctl status
doas sbctl create-keys
doas sbctl enroll-keys -m
doas sed -i 's/^SECUREBOOT=0/SECUREBOOT=1/' /etc/kernel.d/post-install/60-limine
doas /etc/kernel.d/post-install/60-limine
doas sbctl verify
```

3. Перезагрузитесь, включите Secure Boot в BIOS и проверьте: `doas sbctl status`.

⚠️ Предупреждения:

- **`-m` оставляет ключи Microsoft.** Без него на некоторых платах перестают работать Option ROM видеокарты, вплоть до чёрного экрана.
- **Любое несовпадение хэша останавливает загрузку без возврата в меню.** После ручного `dracut --force` или обновления `limine` сразу запускайте хук. `xbps` при обновлении ядра сделает это сам.
- **Ремонт:** выключите Secure Boot в BIOS и загрузите ISO, он не подписан вашим ключом. Сделайте это хотя бы раз заранее.

## 13. Обслуживание

```bash
doas xbps-install -Su
doas xcheckrestart
```

Обновляйтесь регулярно: на rolling-системе это важная часть безопасности. Старые ядра убирает `vkpurge`, хук Limine обновит меню сам.

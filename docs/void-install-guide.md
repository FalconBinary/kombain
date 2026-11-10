# Void Linux: Dev + Gaming на XFS, LUKS, Limine и iwd

Версия 3: графическая среда теперь ставится из репозитория kombain (`mangowc`, `netline`, `fdash`).

> ⚠️ Шаг 0 можно выполнить где угодно. Всё остальное выполняется **на целевом ПК из live ISO**. Шаг 2 стирает диск.
> Сначала прогоните установку в VM. На реальном железе вся схема ещё не проверялась.

## Автоматическая установка

`setup.sh` задаёт вопросы и выполняет команды этого гайда с вашими ответами: это те же шаги с 2 по 11, только не вручную. Шаг 0 (проверка ISO) и шаг 12 (Secure Boot) остаются за вами.

Загрузите ISO в режиме UEFI, войдите как `root` / `voidlinux` и выключите SSH: `sv down sshd`. По кабелю сеть поднимется сама, для Wi-Fi выполните команды из шага 1. Затем:

```bash
xbps-install -Syi -R https://repo-de.voidlinux.org/current xbps git
git clone https://github.com/FalconBinary/kombain
cd kombain
./setup.sh
```

Скрипт спросит:

- **диск** (занятые и флешка с ISO в списке не показываются);
- **имя пользователя**;
- **размеры** `/`, `/home/gamer` и `/home/ПОЛЬЗОВАТЕЛЬ`: `80G`, `500M` или `1.5T`, а Enter принимает значение, рассчитанное под ваш диск. Что осталось, остаётся свободным в `vg0`, чтобы потом увеличить `/` или `/home/gamer`: XFS нельзя уменьшить;
- **имя машины, часовой пояс, драйвер видеокарты** (карту он определит сам), **сеть** и **ставить ли рабочий стол**.

Заодно он убирает то, что этой машине не нужно: прошивки чужих производителей (NVIDIA, AMD или Intel, если их нет ни в процессоре, ни в видеокарте) `iwd`, если нет Wi-Fi, и `dhcpcd`, если вы отказались от кабеля. Если потом поставите такую видеокарту, удалите `/etc/xbps.d/11-firmware.conf` и выполните `xbps-install -Su linux-firmware`. Для Wi-Fi: `ln -s /etc/sv/iwd /etc/runit/runsvdir/default/`. Для кабеля: конец шага 6.

Зеркало он выбирает сам: скачивает список пакетов (около 2 МБ) с каждого зеркала Void первого уровня (Франкфурт, Хельсинки, Fastly, Чикаго) и берёт самое быстрое. Первый уровень получает пакеты прямо со сборочных серверов Void. Зеркало, которое не отдало список за 10 секунд, прислало вместо него страницу ошибки или не обновлялось неделю, пропускается. Если не ответило ни одно, он так же проверяет остальные зеркала из списка `xmirror.voidlinux.org`: их держат университеты и компании, и они бывают на день позади. Выбранное зеркало остаётся и для обновлений установленной системы. Выбрать своё:

```
./setup.sh --mirror https://mirror.yandex.ru/mirrors/voidlinux
```

Если установку прервать (`Ctrl+C`), повторный запуск сам закроет то, что осталось от прерванной.

До ввода имени диска ничего не меняется. Вопросы на английском: в консоли live ISO нет кириллического шрифта. Пароли LUKS и пароли пользователей вы вводите прямо в `cryptsetup` и `passwd`: скрипт их не видит. Только пароль Wi-Fi, если он его спросит, сохраняется для `iwd` на зашифрованном диске.

`./setup.sh --dry-run` задаст те же вопросы и покажет все команды, ничего не меняя.

Если установка прервалась, запустите скрипт снова: он закроет то, что осталось открытым, и начнёт заново, снова стерев выбранный диск.

Дальше ручная установка, то же самое по шагам.

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
minisign -V -p void-release-DATE.pub -x sha256sum.sig -m sha256sum.txt
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
wpa_passphrase "NETWORK_NAME" "PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant.conf
sv restart wpa_supplicant
sv restart dhcpcd
ping -c3 repo-de.voidlinux.org
xbps-install -Syi -R https://repo-de.voidlinux.org/current xbps
```

iwd на base-образе нет, он появится в установленной системе.

## 2. Диск

В `cfdisk` создайте GPT и три раздела: `p1` 1 ГБ типа *EFI System*, `p2` под систему и игры, `p3` под данные Dev. Для SATA-дисков имена будут `/dev/sdaN`, поправьте команды. **XFS нельзя уменьшить**, поэтому оставьте в `vg0` свободное место.

```bash
DISK=/dev/nvme0n1
cfdisk -z "$DISK"

cryptsetup luksFormat --type luks2 "${DISK}p2"
cryptsetup luksFormat --type luks2 "${DISK}p3"   # a different passphrase
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
REPO=https://repo-de.voidlinux.org/current
mkdir -p /mnt/var/db/xbps/keys /mnt/etc/xbps.d
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
printf 'noextract=%s\n' '/usr/share/locale/*' '!/usr/share/locale/ru/*' '!/usr/share/locale/en*' > /mnt/etc/xbps.d/20-noextract.conf
XBPS_ARCH=x86_64 xbps-install -S -r /mnt -R "$REPO" base-system cryptsetup lvm2 xfsprogs zstd limine efibootmgr iwd openresolv dbus elogind polkit chrony nftables zramen snooze run-parts opendoas xtools git pipewire wireplumber flatpak gamescope void-repo-nonfree
printf 'repository=%s\n' "$REPO" > /mnt/etc/xbps.d/00-repository-main.conf
printf 'repository=%s/nonfree\n' "$REPO" > /mnt/etc/xbps.d/10-repository-nonfree.conf
xchroot /mnt /bin/bash
```

`REPO` — зеркало Void во Франкфурте, его держит сам проект. Если пакеты качаются медленно или загрузка замирает, возьмите ближнее из списка на `xmirror.voidlinux.org`, например `REPO=https://mirror.yandex.ru/mirrors/voidlinux/current`, и его же в `-R` на шаге 1 (`-i` там значит: только это зеркало, не стандартное из ISO). Две строки `printf` оставляют это зеркало и для обновлений установленной системы.

`resolv.conf` в систему не копируется: внутри `xchroot` работают DNS-серверы live-системы, а установленная система получит свой файл от `resolvconf` при первом подключении. Скопированный файл `resolvconf` считал бы чужим и не обновлял, и DNS остался бы от сети, в которой шла установка.

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
xbps-install -y nvidia                                      # NVIDIA Turing (GTX 16xx, RTX 20xx) and newer
xbps-install -y nvidia580                                   # NVIDIA Maxwell, Pascal, Volta
```

Заголовки ядра для NVIDIA подтянутся сами, они в зависимостях `dkms`.

**NVIDIA, Turing и новее.** Карты Turing (GTX 16xx, RTX 20xx) засыпают, только если драйверу это разрешить. Без этого дискретная видеокарта в ноутбуке работает всё время, даже на рабочем столе:

```bash
echo 'options nvidia NVreg_DynamicPowerManagement=0x02' > /etc/modprobe.d/nvidia-sleep.conf
```

Саму карту отпускает спать `zcool` (шаг 11). Если что-то держит её включённой, это видно в `zcool list`. На настольном ПК, где NVIDIA показывает экран, строка ничего не меняет.

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

**Initramfs.** `hostonly_cmdline="no"` нужен, чтобы параметры брались только из Limine и Gaming не спрашивал пароль от `p3`. `hostonly_mode="strict"` кладёт в initramfs только драйверы этой машины. В обычном режиме dracut добавляет ещё все драйверы клавиатур, USB, дисков и сетевых карт с их прошивками. `omit_drivers` не пускает туда драйверы NVIDIA с их прошивками: экран загрузки и пароль LUKS показывает встроенная видеокарта или прошивка, а драйвер NVIDIA загружается уже с диска. Без этой строки на ноутбуке с GTX 1650 initramfs весил 209 МиБ вместо 20, и в `/boot` помещалось всего четыре ядра. После замены диска или его контроллера пересоберите initramfs с ISO: `xbps-reconfigure -f linux6.18` в `xchroot`.

```bash
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-local.conf <<'EOF'
hostonly="yes"
hostonly_mode="strict"
hostonly_cmdline="no"
add_dracutmodules+=" crypt lvm "
omit_drivers+=" nouveau nova_core nova_drm nvidia nvidia_drm nvidia_modeset nvidia_uvm "
compress="zstd"
EOF
```

## 5. Limine

Хук пересобирает конфиг при каждом обновлении ядра. Он выполняется после сборки initramfs (`20-initramfs`) и сразу умеет Secure Boot из шага 12.

```bash
mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
cat > /etc/kernel.d/post-install/60-limine <<'HOOK'
#!/bin/sh
# Rebuilds limine.conf. With SECUREBOOT=1 it adds file hashes, enrolls the config hash in Limine and signs it
SECUREBOOT=0
ROOT_UUID=ROOT-UUID
DEV_UUID=DEV-UUID

COMMON="rd.luks.uuid=$ROOT_UUID rd.lvm.vg=vg0 root=/dev/vg0/root rootfstype=xfs rw quiet loglevel=3 slab_nomerge page_alloc.shuffle=1 zswap.enabled=0 lockdown=integrity nowatchdog kfence.sample_interval=0 debugfs=off"
DEV_CMD="rd.luks.uuid=$DEV_UUID $COMMON init_on_free=1 ia32_emulation=0"
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
# The default entries boot Void's newest kernel. A kernel built from kombain's kernel/ has a dash
# in its name (6.18.62-kombain_1): it is never the default, and gets both modes by name below.
newest=$(echo $kernels | tr ' ' '\n' | grep -v -- - | head -1)
[ -n "$newest" ] || newest=$(echo $kernels | cut -d' ' -f1)

{
	printf 'timeout: 2\neditor_enabled: no\n\n'
	entry "Void Dev" "$newest" "$DEV_CMD"
	entry "Void Gaming" "$newest" "$GAME_CMD"
	for v in $kernels; do
		entry "Void Dev $v" "$v" "$DEV_CMD"
		case $v in *-*) entry "Void Gaming $v" "$v" "$GAME_CMD" ;; esac
	done
} > "$OUT.tmp" || exit 1

# The config and Limine are replaced together: if signing fails, booting still works
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

Параметры ядра: `nowatchdog` и `kfence.sample_interval=0` убирают регулярные пробуждения процессора, `debugfs=off` закрывает отладочную файловую систему. Только в Dev: `init_on_free=1` стирает освобождённую память (данные не остаются в RAM, это стоит немного скорости, поэтому в Gaming его нет) и `ia32_emulation=0` отключает 32-битный вход в ядро (Steam и игры работают в Gaming, где он остаётся). Для запуска 32-битных программ в Dev уберите этот параметр.

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

Без кабеля dhcpcd не нужен совсем: адрес для Wi-Fi iwd получает сам. Уберите его, как `wpa_supplicant` на шаге 4, чтобы обновления его не вернули:

```bash
printf 'ignorepkg=dhcpcd\n' > /etc/xbps.d/20-no-dhcpcd.conf
xbps-remove -Ry dhcpcd
```

Если кабель понадобится потом: `rm /etc/xbps.d/20-no-dhcpcd.conf`, `xbps-install -S dhcpcd` и сервис, как выше.

## 7. Защита и производительность

Ядро и sysctl:

```bash
mkdir -p /etc/sysctl.d /etc/modules-load.d
cat > /etc/sysctl.d/90-local.conf <<'EOF'
# Protection
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
net.ipv4.conf.*.rp_filter=1
net.ipv4.conf.*.accept_redirects=0
net.ipv4.conf.*.secure_redirects=0
net.ipv4.conf.*.send_redirects=0
net.ipv4.conf.*.accept_source_route=0
net.ipv6.conf.*.accept_redirects=0
net.ipv6.conf.*.accept_source_route=0
net.ipv4.tcp_rfc1337=1
dev.tty.ldisc_autoload=0
kernel.io_uring_disabled=2
vm.unprivileged_userfaultfd=0
vm.mmap_rnd_bits=32

# Performance
vm.max_map_count=1048576
vm.swappiness=100
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Fewer wakeups and disk writes while idle; zram needs no read-ahead
vm.dirty_writeback_centisecs=1500
vm.stat_interval=10
vm.compaction_proactiveness=0
vm.page-cluster=0
vm.watermark_boost_factor=0
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
# Only this table is replaced: rules of other programs stay. Containers with their own
# network still need a forward rule here, because this chain drops what is not allowed.
destroy table inet kombain
table inet kombain {
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
destroy table inet kombain
table inet kombain {
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
# Downloaded packages are never needed again, and they add up to gigabytes
printf '#!/bin/sh\nrm -f /var/cache/xbps/*\n' > /etc/cron.weekly/xbps-cache
chmod +x /etc/cron.weekly/fstrim /etc/cron.weekly/xbps-cache

mkdir -p /etc/pipewire/pipewire.conf.d
ln -s /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/

cat > /etc/pipewire/pipewire.conf.d/10-kombain.conf <<'EOF'
# Its X11 bell module would connect to Xwayland, which starts only for a client and stays for it.
context.properties = {
    module.x11.bell = false
}
EOF

mkdir -p /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/10-kombain.conf <<'EOF'
# Only sound: nothing here watches cameras or MIDI devices, which takes memory and wakeups.
# Programs can still use a camera directly.
wireplumber.profiles = {
  main = {
    monitor.libcamera = disabled
    monitor.v4l2 = disabled
    monitor.alsa-midi = disabled
    monitor.bluez-midi = disabled
  }
}
EOF

mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/90-audio.conf <<'EOF'
# Real-time scheduling for sound, without rtkit and the polkit it brings along.
@audio - rtprio 88
@audio - nice -11
@audio - memlock 4194304
EOF
```

Экономия энергии и лишние модули. Сервис работает один раз при загрузке и только в Dev: в Gaming всё остаётся на полной скорости. USB и видеокарта не трогаются, потому что с ними чаще всего бывают проблемы.

```bash
cat > /etc/modprobe.d/kombain.conf <<'EOF'
# The sound card sleeps after 10 s of silence
options snd_hda_intel power_save=10
# Beeps, and hardware watchdogs nobody is listening to
blacklist pcspkr
blacklist iTCO_wdt
blacklist sp5100_tco
# Rare network protocols: a known source of kernel holes, and nothing here uses them
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install n-hdlc /bin/false
install ax25 /bin/false
install netrom /bin/false
install x25 /bin/false
install rose /bin/false
install appletalk /bin/false
install atm /bin/false
# Void's stage 1 loads these at every boot only because each has a device file. Nothing here
# uses them: btrfs alone costs 0.2 s for its RAID6 benchmark and 2 MB. `modprobe btrfs` still works.
blacklist btrfs
blacklist hci_vhci
blacklist cuse
blacklist nvram
blacklist userio
EOF

cat > /etc/runit/core-services/91-power-save.sh <<'EOF'
# Lets idle devices sleep, once at boot. Dev mode only; not the GPU or USB, where this can misbehave.
if ! grep -qw gaming /proc/cmdline; then
	for dev in /sys/bus/pci/devices/*; do
		case $(cat "$dev/class") in
		0x03* | 0x0c03*) ;;
		*) echo auto > "$dev/power/control" 2>/dev/null || : ;;
		esac
	done
	for host in /sys/class/scsi_host/*/link_power_management_policy; do
		[ -e "$host" ] && { echo med_power_with_dipm > "$host" 2>/dev/null || : ; }
	done
fi
EOF
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
for s in udevd dbus elogind iwd chronyd zramen game-tune agetty-autologin-tty1 agetty-tty2; do
	ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/gaming/
done

for s in udevd dbus elogind iwd chronyd zramen snooze-weekly; do
	ln -sfn "/etc/sv/$s" /etc/runit/runsvdir/default/
done
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
pipewire >/dev/null 2>&1 &
started=$(date +%s)
gamescope -e -f -- flatpak run com.valvesoftware.Steam -gamepadui
status=$?
# Autologin would restart a session that cannot start, forever
if [ $(($(date +%s) - started)) -lt 30 ]; then
	echo "The game session ended right away, exit code $status."
	echo "Check the Vulkan driver and Steam: log in on tty2 with Ctrl+Alt+F2."
	echo "Press Enter to try again."
	read -r reply
fi
EOF
chmod +x /home/gamer/game-session

chown -R dev:dev /home/dev
chown -R gamer:gamer /home/gamer
chmod 700 /home/dev /home/gamer
```

Если сессия не смогла запуститься (нет драйвера Vulkan, Steam ещё не установлен), она покажет причину и будет ждать Enter, а не перезапускаться по кругу. Исправить причину можно на `tty2`.

Сессию для `dev` настроит `install.sh` из kombain на шаге 11.

## 10. Сборка загрузки

```bash
xbps-reconfigure -fa
# Spare consoles. Reconfiguring brings their links back, and so can an update: `down` keeps them off then.
for n in 3 4 5 6; do
	rm -f "/etc/runit/runsvdir/default/agetty-tty$n"
	touch "/etc/sv/agetty-tty$n/down"
done
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
# the empty resolv.conf xchroot leaves: resolvconf writes its own at the first connection
rm -f /mnt/etc/resolv.conf
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
iwctl station wlan0 connect "NETWORK_NAME"
```

Ожидается `[integrity]` в первом выводе (кроме NVIDIA), активная таблица файрвола и zram в `swapon`. Имя `wlan0` может быть другим, его покажет `iwctl device list`.

Установка графической среды и инструментов. `install.sh` описан в `README.md` репозитория:

```bash
git clone https://github.com/FalconBinary/kombain
cd kombain
doas ./install.sh --user dev
doas chsh -s /usr/local/bin/fdash dev
```

Кэш скачанных пакетов занимает больше гигабайта. Он не нужен, и дальше раз в неделю система очищает его сама:

```bash
doas sh -c 'rm -f /var/cache/xbps/*'
```

После выхода и нового входа на `tty1` запустится mango. Терминал открывается по `Alt+Return`, приложения по `Super+D`, Wi-Fi по `Super+W`.

Контроль температуры: `install.sh` ставит `zcool`, но не запускает его. Он работает на MSI GF63 Thin 10SC; на другом железе сначала посмотрите, что он нашёл и что собирается делать:

```bash
zcool list
doas zcool run --dry-run
```

Видеокарты он ведёт так же, как процессор: AMD и Intel через `/sys`, NVIDIA через `zcool-nvidia` и библиотеку её драйвера. Видеокарта, которая не показывает экран загрузки, засыпает, когда простаивает, и он её в это время не будит. Лимиты задаются в `/etc/zcool.conf`, подробности в `zcool/README.md`. Если всё выглядит правильно, включите сервис в обоих режимах:

```bash
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/default/
doas ln -s /etc/sv/zcool /etc/runit/runsvdir/gaming/
```

**Ноутбуки MSI.** Вентиляторами там управляет EC, и `zcool` умеет работать с ним сам: крутит вентиляторы ровно с той скоростью, какая нужна под нагрузку (через собственную кривую в EC), включает Cooler Boost раньше, чем урезать мощность, ставит порог зарядки (`battery.max = 80`) и переключает профили EC на батарее и от сети (`mode.battery = eco`). Это работает только для прошивок EC, которые он знает (GF63 и GF65 Thin), и нужны debugfs и отключённый lockdown (с NVIDIA он уже отключён). Уберите `debugfs=off` из строки `COMMON` в хуке Limine, запустите хук и перезагрузитесь:

```
doas sed -i 's/ debugfs=off//' /etc/kernel.d/post-install/60-limine
doas /etc/kernel.d/post-install/60-limine
```

Что он видит в EC и почему использует его или нет, показывает `zcool list`.

Сначала задайте предел температуры процессора в `/etc/zcool.conf`: `cpu0.max = 70` (в примере строка закомментирована; без неё предел равен критической температуре минус десять, у i5-10500H это 90 °C). Всё, что измеряет калибровка, она измеряет на пределе, так что после смены предела её нужно повторить. Затем один раз, от сети, запустите калибровку: `doas zcool calibrate`. За 3–8 минут он сам нагружает процессор и измеряет, сколько ватт уносит каждая скорость вентилятора на пределе, как быстро процессор работает на каждой мощности и на одном, половине и всех ядрах, сколько вентиляторов крутится и слушается ли EC его кривой. После этого вентиляторы сразу встают на нужную скорость, а тихий режим отдаёт ту мощность, которая стоит не больше 5% скорости. Сервис на это время останавливается и потом запускается снова; Ctrl-C прерывает калибровку и всё возвращает. Если прошивка разрешает процессору всплески намного больше, чем уносит охлаждение (на GF63 107 Вт против 32), калибровка подскажет предел всплеска: `burst.ac = 65` в меню или в `/etc/zcool.conf` убирает скачки температуры на старте нагрузки. Второй шаг, `doas zcool calibrate --long`, занимает до часа: zcool снимает ступенчатые отклики и строит тепловую модель ноутбука (насколько кристалл горячее радиатора на каждый ватт, сколько уносит каждая скорость вентилятора, инерция радиатора, температура в комнате). Каждое установившееся состояние он держит вчетверо дольше собственного времени радиатора, которое сам же и измеряет, поэтому длинная калибровка на ноутбуке идёт десятки минут. Обе калибровки сначала дают машине остыть (вентиляторы на полную, без нагрузки, до 50 °C), так что их можно запускать одну за другой. Модель записывается, только если сходится сама с собой и с тем, что вентиляторы унесли в короткой калибровке; иначе zcool так и говорит и ничего не сохраняет. С моделью предел всплеска становится динамическим: из холода полный, из тепла ровно такой, какой радиатор примет за три секунды, а прогноз для вентиляторов считается по модели, а не по наклону. Модель дальше учится сама. Регистры процессора, частоты, пределы мощности, видеокарты, EC и датчики показывает `doas zcool dump`, он ничего не меняет.

**kombain-bench** измеряет настоящие вещи до и после любого изменения: загрузку по этапам (прошивка, ядро, initramfs и LUKS, stage 1 runit, сервисы до рабочего стола), пробуждения, память и ватты в простое, насколько опаздывает задача на 144 Гц (`zjitter`), секунды и джоули сборки на C вместе с дрожанием рабочего стола под ней, время кадра игры из лога MangoHud, ватты от батареи. Строки копятся в `/var/tmp/kombain-bench/*.csv` с метками вариантов, `kombain-bench summary` показывает медианы и p95. Без этих чисел слова «быстрее» и «легче» ничего не значат: сначала снимите их на системе как она есть. На ядре с sched_ext (ядро kombain, раздел 15) `doas kombain-bench sched` гоняет планировщики по очереди, кругами: под каждым `jitter` и `build`, с остыванием ниже 50 °C перед каждым; планировщики scx ставит пакет `scx` из Void, метка строки — ядро и вариант, например `6.18.62-kombain_1/scx_lavd`.
```bash
doas kombain-bench boot
doas kombain-bench idle
kombain-bench build
```

**ztune** настраивает остальную систему под то, чем она занята, от сети и на батарее: сон PCIe-линий, энергосбережение Wi-Fi, отложенную запись на диск, огромные страницы, рабочий набор MGLRU, планировщики I/O. Игры (gamescope, Steam, Wine) и сборки (make, ninja, cc1, rustc, cargo, zig и другие) он находит по процессам: в игре всё работает на скорость и без задержек, а процессы сборки идут как SCHED_BATCH, чтобы рабочий стол не подтормаживал, пока компилируются все ядра. Процессор, видеокарту и вентиляторы он не трогает, это делает `zcool`. Всё, что он меняет, возвращается при остановке. Проверьте и включите:
```bash
ztune check
doas ztune run --dry-run
doas ztune calibrate
doas ln -s /etc/sv/ztune /etc/runit/runsvdir/default/
doas ln -s /etc/sv/ztune /etc/runit/runsvdir/gaming/
```
`ztune check` показывает каждую настройку: что стоит сейчас, что поставил бы ztune и почему. `ztune calibrate` за минуту находит, на скольких задачах сборка идёт быстрее всего, и записывает это в `/etc/profile.d/ztune.sh` (`MAKEFLAGS`, `CARGO_BUILD_JOBS`, `CMAKE_BUILD_PARALLEL_LEVEL`).

Под тяжёлой нагрузкой `zcool` не даёт системе встать: тяжёлые задачи (сборка, кодирование) уступают процессор рабочему столу, звуку и играм, а если память и swap почти кончились, он завершает самый прожорливый процесс, не трогая сеанс. На ноутбуках MSI, пока всё холодное, он включает тихую кривую вентиляторов прошивки. Все настройки `zcool` с пояснениями есть в меню: `doas zcool menu`. Чтобы предел стал потолком, который кристалл не пересекает, задайте `ceiling = hard`: тормоз самого процессора встаёт ровно на предел, zcool работает на градус ниже, а всплески мощности выше долгого предела прошивки разрешает только модель тепла из длинной калибровки; машина холоднее и немного медленнее, насколько — покажут строки `kombain-bench`. Пределы для режима Gaming можно сдвинуть отдельно: `limits.gaming = 10`. Там же три готовых набора (тихий, сбалансированный, быстрый) для того, что меняется вместе с источником питания: предпочтение энергии процессора, турбо, тихие вентиляторы и пределы на батарее. Сохранение (`s`) перезапускает сервис.

Undervolt через `zcool` не работает при `lockdown=integrity`: делайте его в BIOS. Без lockdown (например, с NVIDIA) `doas zcool undervolt probe` покажет, не закрыла ли его прошивка: он сдвигает напряжение на 1 мВ и сразу возвращает обратно. Если прошивка его не закрыла, `doas zcool undervolt find` примерно за час находит самое глубокое смещение, которое держит этот процессор: лестница от −50 до −125 мВ шагами по 10, ядро и кэш вместе; на каждой ступени пять минут счёта с известным ответом на всех ядрах у теплового предела и две минуты всплесков на одном ядре из простоя. Ступень заканчивают неверный ответ, machine check в журнале ядра или зависание машины, которое zcool прочитает из записи на диске при следующем старте. Результат, на две ступени выше первой провалившейся, показывает `zcool list`; сам он ничего не применяет: впишите его в BIOS или в `undervolt.core` и `undervolt.cache` в `/etc/zcool.conf`. Во время поиска не держите открытым ничего важного.

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

`sbctl verify` должен показать `✓` у `BOOTX64.EFI`. Строка `✗ /boot/vmlinuz-… is not signed` — это нормально: ядро не подписывается, его хэш проверяет Limine.

3. Перезагрузитесь, включите Secure Boot в BIOS и проверьте: `doas sbctl status`.

⚠️ Предупреждения:

- **`-m` оставляет ключи Microsoft.** Без него на некоторых платах перестают работать Option ROM видеокарты, вплоть до чёрного экрана.
- **Несовпадение хэша останавливает загрузку.** Limine пишет `PANIC: Blake2b hash for URI … does not match!` и по нажатию клавиши возвращается в меню. После ручного `dracut --force` или обновления `limine` сразу запускайте хук. `xbps` при обновлении ядра сделает это сам.
- **Ремонт:** выключите Secure Boot в BIOS и загрузите ISO, он не подписан вашим ключом. Сделайте это хотя бы раз заранее.

## 13. Обслуживание

```bash
doas xbps-install -Su
doas xcheckrestart
```

Обновляйтесь регулярно: на rolling-системе это важная часть безопасности. Старые ядра убирает `vkpurge`, хук Limine обновит меню сам.

## 14. Отчёт о машине

Всё выше проверено только в виртуальной машине. Что происходит на вашем железе, собирает `kombain-report`:
- на какой видеокарте рисуют экран и игры;
- что засыпает;
- сколько машина потребляет в покое и что будит процессор;
- температуры и вентиляторы;
- открыт ли undervolt;
- состояние Secure Boot.

Он ничего не меняет, кроме загрузки модуля `msr` и проверки undervolt на 1 мВ. Серийных номеров, MAC-адресов, UUID и имён сетей в файле нет.

В Dev, на рабочем столе, ничего не открывая, лучше от батареи. Займёт около минуты:

```bash
doas kombain-report
```

В Gaming запустите игру, перейдите на `tty2` (`Ctrl+Alt+F2`), войдите как `gamer` и выполните команду ниже. Затем вернитесь в игру (`Ctrl+Alt+F1`) минуты на три. У `gamer` нет root, поэтому части разделов не будет. Но главное, на какой видеокарте идёт игра, в отчёте будет.

```bash
kombain-report --after 60
```

Отчёт ложится в текущую папку, имя начинается с `kombain-report-`. Отчёт из Gaming останется у `gamer`, в Dev его можно забрать так: `doas cp /home/gamer/kombain-report-*.txt ~`. Прочитайте файлы перед отправкой.

## 15. Ядро kombain: sched_ext

Ядро Void собрано без sched_ext (`CONFIG_SCHED_CLASS_EXT` выключен), поэтому планировщики из пакета `scx` на нём не запускаются. В [`kernel/`](../kernel/) лежит шаблон `linux6.18-kombain`: то же ядро Void, тот же конфиг и те же патчи, с тремя изменениями, каждое с объяснением в `kernel/srcpkgs/linux6.18-kombain/files/kombain.config`: `CONFIG_SCHED_CLASS_EXT=y`, полная вытесняемость по умолчанию (`CONFIG_PREEMPT=y`; `preempt=` в параметрах ядра по-прежнему переключает её на лету при загрузке) и имя `-kombain`. Собирает его GitHub Actions (workflow `kernel`: по push в ветку `kernel*`, меняющему шаблон, или вручную с `main`; несколько часов), результат выкладывается релизом `kernel-<версия>-kombain-r<ревизия>`. Что проверяет CI, как собрать и обновить: [`kernel/README.md`](../kernel/README.md).

Стоковое ядро остаётся установленным и остаётся первым пунктом меню Limine. Новое добавляется рядом и убирается одной командой. Быстрее оно от этого не становится: быстрее то, что показали строки `kombain-bench` (шаг 14 и `bench/README.md`).

**Хук Limine.** Если хук из шага 5 ставился до появления этого раздела, в нём две строки надо обновить: пунктами по умолчанию становится новейшее ядро *без дефиса* в имени, то есть ядро Void, а ядро с дефисом (`6.18.62-kombain_1`) получает свои пункты в обоих режимах. Шаг 5 выше уже такой; на установленной системе:

```bash
doas sed -i "s/^newest=.*/newest=\$(echo \$kernels | tr ' ' '\\\\n' | grep -v -- - | head -1)\\n[ -n \"\$newest\" ] || &/" /etc/kernel.d/post-install/60-limine
doas sed -i 's/^\(\t\t\)entry "Void Dev \$v" "\$v" "\$DEV_CMD"$/&\n\1case $v in *-*) entry "Void Gaming $v" "$v" "$GAME_CMD" ;; esac/' /etc/kernel.d/post-install/60-limine
grep -n -A1 '^newest=' /etc/kernel.d/post-install/60-limine
```

Должно показать две строки `newest=` и `[ -n "$newest" ] || newest=…`. Если хук правился руками и `sed` ничего не нашёл, внесите обе правки сами по тексту шага 5.

**Установка.** Файлы релиза, их проверка и установка из каталога как из репозитория:

```bash
mkdir -p ~/kernel && cd ~/kernel
tag=kernel-6.18.62-kombain-r1
for f in linux6.18-kombain-6.18.62_1.x86_64.xbps linux6.18-kombain-headers-6.18.62_1.x86_64.xbps SHA256SUMS; do
  curl -fLO "https://github.com/FalconBinary/kombain/releases/download/$tag/$f"
done
sha256sum --ignore-missing -c SHA256SUMS
xbps-rindex -a ./*.xbps
doas xbps-install --repository="$PWD" linux6.18-kombain linux6.18-kombain-headers
```

`xbps-install` спросит про неподписанный репозиторий: это ваш каталог. Дальше хуки `/etc/kernel.d` отрабатывают для версии `6.18.62-kombain_1` так же, как для стокового ядра: `10-dkms` собирает модули NVIDIA под новый пакет `-headers` (оба пакета распаковываются до того, как любой из них настраивается, поэтому порядок в команде не важен), `20-dracut` собирает `initramfs-6.18.62-kombain_1.img` с теми же настройками из шага 4 (только драйверы этой машины, без NVIDIA), `60-limine` пересобирает меню и при Secure Boot подписывает его. В меню появятся `Void Dev 6.18.62-kombain_1` и `Void Gaming 6.18.62-kombain_1` ниже стоковых пунктов; `Void Dev` и `Void Gaming` без версии — стоковое ядро, как и было.

**Проверка**, после загрузки через новый пункт:

```bash
uname -r                             # 6.18.62-kombain_1
ls /sys/kernel/sched_ext             # каталог есть: класс планировщиков в ядре
cat /sys/kernel/sched_ext/state      # disabled: планировщик ещё не загружен
doas dmesg | grep 'Dynamic Preempt'  # Dynamic Preempt: full
dkms status                          # nvidia/…, 6.18.62-kombain_1, x86_64: installed
lsmod | grep '^nvidia'               # nvidia, nvidia_modeset, nvidia_drm
```

**Измерения.** Те же четыре, что уже есть для стокового ядра; метка строки берётся из `uname -r`, так что ядра в `kombain-bench summary` окажутся рядом:

```bash
doas kombain-bench boot
doas kombain-bench idle
kombain-bench jitter
kombain-bench build
kombain-bench summary
```

Для вывода нужны не меньше десяти загрузок и пяти длинных измерений на каждое ядро, чередуя их; метод в `bench/README.md`.

**Планировщик руками.** Пока `ztune` не переключает планировщики по режиму (это следующий шаг, после строк измерений):

```bash
doas xbps-install -S scx
doas scx_lavd                        # работает, пока открыт терминал; Ctrl-C возвращает EEVDF
cat /sys/kernel/sched_ext/root/ops   # lavd (в другом терминале)
kombain-bench jitter --label 6.18.62-kombain_1/scx_lavd
```

**Удаление.**

```bash
doas xbps-remove linux6.18-kombain linux6.18-kombain-headers
```

Хуки убирают модули DKMS, initramfs и пункты меню; `vkpurge` этого ядра не касается, пока пакет стоит, и ему нечего убирать после. Стоковое ядро не трогалось.

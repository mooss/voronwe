#!/usr/bin/env bash
echo 'In chroot script :)'

set -euo pipefail
function fatal() {
    echo "$@"
    exit 1
}

function verbose() {
    echo "$@"
}

function confirm() {
    prompt="$1"; error="$2"
    local yes; read -p "Confirm with uppercase 'yes' $prompt > " yes
    [[ $yes == YES ]] || fatal "$error"
}

function assert-absent() {
    [[ -e $1 ]] && fatal "$1 must not exist" || true
    verbose "$1 is indeed absent"
}

function assert-present() {
    [[ -e $1 ]] || fatal "$1 must exist"
    verbose "$1 is indeed present"
}

function extract-list() {
    local -r path="$1" re="$2"
    sed -n "s/^$re$/\1/p" "$path"\
        | sed -r 's/\s+/\n/g'
}
function replace-in() {
    local -r path="$1" re="$2"
    replacement=$(cat)
    # ${re/\\(.\*\\)/$replacement} is Bash-specific.
    sed -i "s/$re/${re/\\(.\*\\)/$replacement}/" "$path"
}
function process-list-in-place() {
    local -r filename="$1" re="$2"; shift; shift
    extract-list "$filename" "$re" | "$@" | paste -sd' ' | replace-in "$filename" "$re"
}

assert-present /removeme.bash

[[ -n $device ]] || fatal "\$device must be set."
echo
lsblk --output PATH,VENDOR,MODEL,SIZE --nodeps $device
confirm "that $device is the installation media" "Stopping chroot script."

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -ri 's/#(en_GB.UTF-8 UTF-8)/\1/' /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf

hostname=voronwe
echo $hostname > /etc/hostname
cat <<EOF
127.0.0.1  localhost
::1        localhost
127.0.1.1  $hostname.localdomain  $hostname
EOF

cat <<EOF > /etc/systemd/network/10-ethernet.network
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes

[DHCPv4]
RouteMetric=10

[IPv6AcceptRA]
RouteMetric=10
EOF

systemctl enable systemd-networkd.service

pacman --noconfirm -S iwd
systemctl enable iwd.service

cat <<EOF > /etc/systemd/network/20-wifi.network
[Match]
Name=wl*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes

[DHCPv4]
RouteMetric=20

[IPv6AcceptRA]
RouteMetric=20
EOF

systemctl enable systemd-resolved.service
# Garbage debug:
# echo
# echo
# df -h
# echo
# echo
# df -h /run
# df -h /etc
# echo
# echo

# Cannot execute:
#ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

systemctl enable systemd-timesyncd.service

echo -e "root\nroot" | passwd

useradd -m mooss
echo -e "mooss\nmooss" | passwd mooss

# groupadd wheel # wheel already exists.
usermod -aG wheel mooss
groupadd sudo
usermod -aG sudo mooss

pacman --noconfirm -S sudo
echo "%sudo ALL=(ALL) ALL" > /etc/sudoers.d/10-sudo

pacman --noconfirm -S polkit

pacman --noconfirm -S grub efibootmgr # TODO remove interaction
grub-install --target=i386-pc --recheck $device
grub-install --target=x86_64-efi --efi-directory /boot --recheck --removable

sed -r 's/relatime|atime/noatime/' /etc/fstab > /etc/fstab.new
echo 'Minimizing filesystem writes:'
diff -u /etc/fstab{,.new} || true
confirm 'that the new fstab is well-formed' 'Badly formed fstab'
mv /etc/fstab{.new,}

mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > /etc/systemd/journald.conf.d/10-volatile-storage.conf
Storage=volatile
SystemMaxUse=16M
EOF

process-list-in-place /etc/mkinitcpio.conf 'HOOKS=(\(.*\))' grep -v '^autodetect$'
grep '^HOOKS=' /etc/mkinitcpio.conf

process-list-in-place /etc/mkinitcpio.d/linux515.preset 'PRESETS=(\(.*\))' grep -v "'fallback'"
grep '^PRESETS=' /etc/mkinitcpio.d/linux515.preset

rm /boot/initramfs-5.15-x86_64-fallback.img
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg

pacman --noconfirm -S amd-ucode intel-ucode
grub-mkconfig -o /boot/grub/grub.cfg

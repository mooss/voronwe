#!/usr/bin/env bash
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

[[ $EUID == 0 ]] || fatal 'Root privileges required.'

assert-absent /mnt/removeme
assert-absent /removeme.bash

devices=$(lsblk --output PATH,VENDOR,MODEL,SIZE --nodeps --json | jq '.blockdevices')

echo Available devices:
echo "$devices"\
    | jq -r '["device", "vendor", "model", "size"], ["------", "------", "-----", "----"], (.[] | [.path, .vendor, .model, .size]) | @tsv'\
    | column -t -s $'\t'
echo

echo 'Select a device to overwrite (will destroy pre-existing data):'
select device in $(echo "$devices" | jq -r '.[] | .path'); do break; done
echo

echo "Selected device is:"
lsblk --output PATH,VENDOR,MODEL,SIZE --nodeps $device
echo
confirm "to overwrite $device" "Cancelling, will not overwrite."
echo

wipefs --all --force $device

sgdisk --clear\
       --new 1:0:+10M  --typecode 1:EF02 --change-name 1:"BIOS boot partition"\
       --new 2:0:+500M --typecode 2:EF00 --change-name 2:"EFI system"\
       --new 3:0:+4G  --typecode 3:0700 --change-name 3:"Shared data"\
       --new 4:0:0     --typecode 4:8300 --change-name 4:"Linux filesystem"\
       $device

wipefs -af ${device}1
wipefs -af ${device}2
wipefs -af ${device}3
wipefs -af ${device}4

mkfs.fat -F32 ${device}2
mkfs.exfat    ${device}3
mkfs.ext4     ${device}4

mkdir /mnt/removeme
mount ${device}4 /mnt/removeme
mkdir /mnt/removeme/boot
mount ${device}2 /mnt/removeme/boot

pacstrap /mnt/removeme linux515 linux-firmware base vim
sync

genfstab -U /mnt/removeme | grep -v '^/swapfile' > /mnt/removeme/etc/fstab

# Skip fstab verification.
# echo Generated fstab; echo
# cat /mnt/removeme/etc/fstab
# confirm "that fstab was correctly generated" "Stopping installation"

assert-absent /removeme.bash
verbose

cp chroot.bash /mnt/removeme/removeme.bash
chmod +x /mnt/removeme/removeme.bash
export device=$device
echo "Entering chroot"; echo
arch-chroot /mnt/removeme /removeme.bash || echo CHROOT FAILED

echo
echo
echo
echo umount /mnt/removeme/boot
echo umount /mnt/removeme
echo rmdir /mnt/removeme

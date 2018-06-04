#!/bin/bash

############### SCRIPT PARAMETERS ###############

# Set your USERNAME and HOSTNAME 
MYHOSTNAME="yourHostnameHere"
USERNAME="yourUsernameHere"
LANG="en_US.UTF-8"
diskpass=""
diskpassconfirm="1"
rootpass=""
rootpassconfirm="1"
userpass=""
userpassconfirm="1"

# Set your target drive and partition sizes here
DRIVE="/dev/sda" # Determine your drive by using 'lsblk' cmd and set accordingly
EFI_SIZE="+104MB" # 
BOOT_SIZE="+262MB"
CRYPT_SIZE="" # By default, crypt partition is set to 100% of FREESPACE

# Set your encryption parameters
CIPHER="aes-xts-plain64"
KEY_SIZE="512"
HASH="sha512"
ITER_TIME="20000" # Number of milliseconds to spend w/PBKDF2 passphrase processing
SECURE_WIPE=false
# Security parameters
SANDBOX=true;

# Set mkinitcpio parameters here
MODULES="";

# Package manager (pacman)  parameters
ADDLPKGS="file-roller acpi compton obs-studio sudo vlc intel-ucode dmidecode thunar i3-wm i3status i3lock rxvt-unicode pulseaudio pavucontrol xorg-server xorg-xinit bluez bluez-utils pulseaudio-bluetooth pulseaudio-alsa bluez-libs ttf-liberation ttf-roboto noto-fonts ttf-ubuntu-font-family adobe-source-code-pro-fonts chromium firefox rofi thunderbird xbindkeys xf86-video-intel wget p7zip unzip unrar tmux lxappearance openssh nodejs npm ntfs-3g okular dnsutils i3blocks python-pip python audacity lsof iptables firejail"

#################################################

# Prompt user for encryption password
while [[ "$diskpass" != "$diskpassconfirm" || "$diskpass" == "" ]]; do
	echo -n "Specify your disk password: ";
	read -s diskpass; echo;
	echo -n "Please retype password to verify: ";
	read -s diskpassconfirm; echo
done

# Prompt user for ROOT account password
while [[ "$rootpass" != "$rootpassconfirm" || "$rootpass" == "" ]]; do
	echo -n "Specify your root password: ";
	read -s rootpass; echo;
	echo -n "Please retype root password to verify: ";
	read -s rootpassconfirm; echo
done

# Prompt user for USER account password
while [[ "$userpass" != "$userpassconfirm" || "$userpass" == "" ]]; do
	echo -n "Specify your user account password for $USERNAME: ";
	read -s userpass; echo "";
	echo -n "Please retype password to confirm: "
	read -s userpassconfirm; echo
done

# Check for internet connectivity
if ! ping -c 3 archlinux.org; then
	echo "Unable to establish connection to arch servers. Check your settings";
	exit 1;
fi

# Update system clock
timedatectl set-ntp true;

# Secure wipe ensures that drive is initialized with a random array of 0's and 1's,
# making free space indistinguishable from future encrypted sections. 
if $SECURE_WIPE; then
	if cryptsetup open --type plain -d /dev/urandom $DRIVE to_be_wiped; then
		dd if=/dev/zero of=/dev/mapper/to_be_wiped status=progress;
		cryptsetup close /dev/mapper/to_be_wiped;
	else
		echo "Target device $DRIVE could not be opened. Exiting...";
		exit 1;
	fi
fi

# Create partitions
# to create the partitions programatically (rather than manually)
# we're going to simulate the manual input to fdisk
# The sed script strips off all the comments so that we can 
# document what we're doing in-line with the actual commands
# Note that a blank line (commented as "defualt" will send a empty
# line terminated with a newline to take the fdisk default.
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk ${DRIVE}
  g # clear the in memory partition table
  n # new partition
  1 # partition number 1
    # default - start at beginning of disk 
  $EFI_SIZE# EFI parttion, default is 150MB
  t # change partition type
  1 # Make sure partition is efi
  n # new partition
  2 # partion number 2
    # default, start immediately after preceding partition
  $BOOT_SIZE  # BOOT partition, default size is 200MB 
  t # change partition type
  2 # select second partition
  20 # set type to Linux filesystem
  n # new partition
  3 # partition number 3
    # default, start immediately after preceding partition
  $CRYPT_SIZE # Encryption partition, default size is 100% of remaining freespace 
  t # change partition type
  3 # select 3rd partition
  20 # set type to Linux filesystem
  p # print the in-memory partition table
  w # write changes to disk
  q # and we're done
EOF

# Create filesystems for partitions
mkfs.vfat -F32 "$DRIVE"1;
mkfs.ext2 -F "$DRIVE"2;

# Setup encryption of the system
echo -n "$diskpass" | cryptsetup -v -c $CIPHER -s $KEY_SIZE -h $HASH -i $ITER_TIME --use-random luksFormat "$DRIVE"3 -;
echo -n "$diskpass" | cryptsetup luksOpen "$DRIVE"3 luks;

# Create encrypted partitions via Logical Volume Manager (LVM)
pvcreate /dev/mapper/luks;
vgcreate vg0 /dev/mapper/luks;
lvcreate --size 8G vg0 --name swap;
lvcreate -l +100%FREE vg0 --name root;

# Create filesystem on encrypted partitions and setup swapspace
mkfs.ext4 -F /dev/mapper/vg0-root;
mkswap /dev/mapper/vg0-swap;

# Get UUID of encrypted drive (will be used as mount instructions for grub)
UUID="$(blkid | grep $DRIVE | $grep crypto | awk '{print $2}'| sed 's/\"//g')"

# Mount the new system
mount /dev/mapper/vg0-root /mnt;
swapon /dev/mapper/vg0-swap;
mkdir /mnt/boot;
mount "$DRIVE"2 /mnt/boot;
mkdir /mnt/boot/efi;
mount "$DRIVE"1 /mnt/boot/efi;

# Fetch a new mirrorlist and ensure that all sections are uncommented
curl -o /etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=US&protocol=http&protocol=https&ip_version=4';
sed -i 's/^#Server/Server/g' /etc/pacman.d/mirrorlist

# Begin installing Arch Linux
pacstrap /mnt base base-devel grub vim git efibootmgr dialog wpa_supplicant;

# Copy mirrorlist to installation 
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist;

# Generate and configure fstab (file used to mount devices @ boot-time)
genfstab -pU /mnt > /mnt/etc/fstab;
echo -n "tmpfs	/tmp	tmpfs	defaults,noatime,mode=1777	0	0" >> /mnt/etc/fstab; # Sets /tmp to be a ramdisk

# Generate arch-chroot script on the fly 
echo '#!/bin/bash' > /mnt/install-cont.sh;
echo "UUID=\"$UUID\"; # Pass variables to 2nd script
DRIVE=\"$DRIVE\";
MODULES=\"$MODULES\";
HOSTNAME=\"$MYHOSTNAME\";
USERNAME=\"$USERNAME\";
LANG=\"$LANG\";
SANDBOX=\"$SANDBOX\";
ADDLPKGS=\"$ADDLPKGS\";" >> /mnt/install-cont.sh;

# Copy config-backup to chroot directory
if [ -f home_backup.zip ]; then
	cp home_backup.zip /mnt;
fi

cat <<'EOF' >> /mnt/install-cont.sh 

# Set hostname and configure hosts fire
echo "$HOSTNAME" > /etc/hostname;
echo -n "127.0.0.1	$HOSTNAME
::1	localhost
127.0.1.1 $HOSTNAME.localdomain	$HOSTNAME" >> /etc/hosts;

# Create user account
useradd -m -g users -G wheel -s /bin/bash "$USERNAME"

# Give wheel group sudo permissions
sed -i '0,/^# %wheel/s// %wheel/' /etc/sudoers;

# Setup system clock
if [ -f /etc/localtime ]; then
	rm /etc/localtime;
fi
ln -s /usr/share/zoneinfo/America/Los_Angeles /etc/localtime;
hwclock --systohc;

# Update Locale
echo "LANG=$LANG" > /etc/locale.conf;
sed -i 's/^#en_US\.UTF-8/en_US\.UTF-8/' /etc/locale.gen
locale-gen;


# Configure mkinitcpio, add ext4 to MODULES, add 'encrypt' and 'lvm2' to HOOKS before filesystems
sed -ri 's/^MODULES=\(/&ext4 thinkpad_acpi intel_agp i915/' /etc/mkinitcpio.conf
sed -ri 's/^HOOKS=\([a-zA-Z ]*block/& encrypt lvm2/' /etc/mkinitcpio.conf

# Add cryptdevice identifier to /etc/default/grub
sed -ri "s/^GRUB_CMDLINE_LINUX=\"/&cryptdevice=$UUID:luks/" /etc/default/grub

# Install supplementary software
pacman --noconfirm -S $ADDLPKGS;

# Regenerate initrd image 
mkinitcpio -p linux

# Install grub and generate config
grub-install "$DRIVE"
grub-mkconfig -o /boot/grub/grub.cfg;

# Make fonts look pretty
ln -s /etc/fonts/conf.avail/70-no-bitmaps.conf	/etc/fonts/conf.d;
ln -s /etc/fonts/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d;
ln -s /etc/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d;

# Implement security hardening via app sandboxing and additional file controls
if [ $SANDBOX ]; then
	# Internet Sandboxing
	groupadd no-internet;
	usermod -a -G no-internet $USERNAME;
	mkdir /home/$USERNAME/.local/bin
	echo -ne \#\!/bin/bash\\nsg no-internet \"\$@\" > /home/$USERNAME/bin/no-internet;
	chown -R "$USERNAME":users /home/$USERNAME/bin;
	chmod 755 /home/$USERNAME/bin/no-internet;
	# Set associated firewall rules for no-internet group
	iptables -I OUTPUT 1 -m owner --gid-owner no-internet -j DROP;
	iptables-save > /etc/iptables/iptables.rules;
	systemctl enable iptables;
	
	# General permissions Sandboxing
	####Custom configuration for firejail will go here####	
fi

if [ -f /home_backup.zip ]; then
	unzip home_backup.zip -d /home/$USERNAME/;
	rm home_backup.zip;
fi

# Set ownership of everything in $HOME to $USER
chown -R "$USERNAME":users /home/$USERNAME/;

EOF

# Set 'install-cont.sh' to be executable and run it
chmod 700 /mnt/install-cont.sh;
arch-chroot /mnt ./install-cont.sh;

# Set $USERNAME and root passwords 
arch-chroot /mnt bash -c "echo -ne "root:$rootpass" | chpasswd"
arch-chroot /mnt bash -c "echo -ne "$USERNAME:$userpass" | chpasswd" 
#Clean things up
rm /mnt/install-cont.sh
#rm -- "$0"

# Unmount all partitions
#umount -R /mnt
#swapoff -a

# Reboot into new system
#reboot


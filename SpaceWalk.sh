#!/bin/bash

# Validate input
if [ -z "$1" ]; then
    echo "Usage: ASync -installBase <path_to_mount>"
    exit 1
fi

MOUNT_DIR="$1"

# Validate the mount directory exists
if [ ! -d "$MOUNT_DIR" ]; then
    echo "Error: The specified directory $MOUNT_DIR does not exist."
    exit 1
fi

# Mount the directory if not mounted already
echo "Mounting the $MOUNT_DIR..."
mount --bind / $MOUNT_DIR

# Set up essential directories
echo "Setting up system directories..."
mkdir -p $MOUNT_DIR/{etc,bin,lib,usr,var,home}

# Install essential packages using ASynk
echo "Installing essential packages..."
ASYNK_BOOTSTRAP_FILE="/etc/ASynk/bootstrap.json"

# Check if bootstrap.json exists
if [ ! -f "$ASYNK_BOOTSTRAP_FILE" ]; then
    echo "Error: bootstrap.json does not exist."
    exit 1
fi

# Install Linux, glibc, AShell, coreutils, etc.
install_base_packages() {
    # Install essential packages (Linux, glibc, coreutils, AShell)
    for package in "Linux" "glibc" "coreutils" "AShell"; do
        echo "Installing $package..."
        install_package $package
    done
}

# Function to install package
install_package() {
    PACKAGE_NAME=$1
    PACKAGE_DATA=$(jq -r ".\"$PACKAGE_NAME\"" < $ASYNK_BOOTSTRAP_FILE)
    
    if [ "$PACKAGE_DATA" == "null" ]; then
        echo "Error: Package $PACKAGE_NAME not found in bootstrap.json."
        return 1
    fi

    TARURL=$(echo $PACKAGE_DATA | jq -r '.url')
    TARNAME=$(echo $PACKAGE_DATA | jq -r '.tarball')
    DEPENDENCIES=$(echo $PACKAGE_DATA | jq -r '.depindincs | join(" ")')
    BUILD_COMMANDS=$(echo $PACKAGE_DATA | jq -r '.build | join(" && ")')

    # Install dependencies first
    if [ -n "$DEPENDENCIES" ]; then
        for dep in $DEPENDENCIES; do
            install_package $dep
        done
    fi

    # Download the tarball
    wget $TARURL -O /tmp/$TARNAME
    
    # Extract and install
    tar -xf /tmp/$TARNAME -C /tmp/
    PACKAGE_DIR=$(echo $TARNAME | sed 's/\.[^.]*$//') 
    cd /tmp/$PACKAGE_DIR
    
    # Run the build commands
    eval $BUILD_COMMANDS
    
    # Install package to target system
    make DESTDIR=$MOUNT_DIR install
}

# Install base packages
install_base_packages

# Chroot into the new system for additional configurations
echo "Chrooting into the new system at $MOUNT_DIR..."
mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc
mount --bind /sys $MOUNT_DIR/sys
chroot $MOUNT_DIR /bin/bash <<EOF

# Sync the repository
echo "Syncing the ASynk repository..."
ASync -I sync repo

# Install packages using ASync -Is after sync
echo "Installing NVIDIA drivers if needed..."
if grep -q "nvidia" /etc/ASynk/config.json; then
    ASync -Is nvidia
fi

# Install elogan
echo "Installing elogan..."
ASync -Is elogan

# Create a user account
echo "Creating user account..."
useradd -m -G wheel user
echo "user:password" | chpasswd  # Replace with a secure password

# Install GRUB
echo "Installing GRUB..."
grub-install --target=i386-pc --boot-directory=$MOUNT_DIR/boot /dev/sda

# Create the GRUB configuration
echo "Creating GRUB config..."
grub-mkconfig -o $MOUNT_DIR/boot/grub/grub.cfg

# Exit chroot
exit
EOF

# Unmount after finishing chroot tasks
umount $MOUNT_DIR/{dev,proc,sys}

# Final message
echo "Installation complete. Please reboot the system."

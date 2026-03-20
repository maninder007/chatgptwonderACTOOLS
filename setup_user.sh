cat <<EOF > ~/setup_user.sh
#!/bin/bash

# Load variables from the absolute path
source ~/install.env

# 1. Create User & Set Password
useradd -m -s /bin/bash "\$SUDO_USER_NAME"
echo "\$SUDO_USER_NAME:\$SUDO_USER_PASSWORD" | chpasswd

# 2. Grant Passwordless Sudo (Escapes all prompts for software installs)
echo "\$SUDO_USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/\$SUDO_USER_NAME"
chmod 0440 "/etc/sudoers.d/\$SUDO_USER_NAME"

# 3. Setup SSH Keys
USER_HOME="/home/\$SUDO_USER_NAME"
mkdir -p "\$USER_HOME/.ssh"
echo "\$SUDO_USER_AUTHORIZED_KEYS" > "\$USER_HOME/.ssh/authorized_keys"
chown -R "\$SUDO_USER_NAME:\$SUDO_USER_NAME" "\$USER_HOME/.ssh"
chmod 700 "\$USER_HOME/.ssh"
chmod 600 "\$USER_HOME/.ssh/authorized_keys"

# 4. Harden SSH Config (Locking out root/password login)
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH to apply hardening
systemctl restart ssh

# 5. Security Cleanup: Securely delete the environment file
# 'shred' overwrites the data before deleting so it can't be recovered easily
shred -u ~/install.env

echo "-------------------------------------------------------"
echo "SETUP COMPLETE: User '\$SUDO_USER_NAME' is ready."
echo "SECURITY: ~/install.env has been shredded and deleted."
echo "-------------------------------------------------------"
EOF

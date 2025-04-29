#!/bin/bash
set -euo pipefail

###############################################################################
# Preliminary: Ensure we’re running as root and determine real (non-root) user.
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root. Use sudo." >&2
    exit 1
fi

###############################################################################
# Step 1: Install the primary workaround script.
# This script makes the following modifications:
#   • In /usr/share/alsa-card-profile/mixer/paths/analog-output.conf.common,
#     it removes any existing [Element Master] block then inserts one (with
#     'switch = mute' and 'volume = ignore') before the first occurrence of
#     [Element PCM].
#
#   • In /usr/share/alsa-card-profile/mixer/paths/analog-output-headphones.conf,
#     if a [Element Master] block exists, it updates any line starting with
#     "volume =" so that its value is "ignore".
#
#   • Finally, it restarts the user’s Wireplumber service.
###############################################################################
TARGET_SCRIPT="/usr/local/bin/alsa_workaround.sh"
cat << "EOF" > "$TARGET_SCRIPT"
#!/bin/bash
set -uo pipefail

# === Configuration File Paths ===
CONF_COMMON="/usr/share/alsa-card-profile/mixer/paths/analog-output.conf.common"
CONF_HEADPHONES="/usr/share/alsa-card-profile/mixer/paths/analog-output-headphones.conf"

# === Create Timestamped Backups ===
timestamp=$(date +%Y%m%d%H%M%S)
backup_common="${CONF_COMMON}.bak.${timestamp}"
backup_headphones="${CONF_HEADPHONES}.bak.${timestamp}"
cp "$CONF_COMMON" "$backup_common"
cp "$CONF_HEADPHONES" "$backup_headphones"
echo "Backups created:"
echo "  $backup_common"
echo "  $backup_headphones"

###########################################################################
# STEP 1:
# If [Element Master] does not exist in CONF_COMMON, insert the following block
# immediately before the first occurrence of [Element PCM].
# The block to insert is exactly:
#
#   [Element Master]
#   switch = mute
#   volume = ignore
#
###########################################################################
if ! grep -Fxq "[Element Master]" "$CONF_COMMON"; then
    echo "Inserting [Element Master] block into $CONF_COMMON before [Element PCM]."
    awk 'BEGIN { inserted = 0 }
         {
             if ($0 == "[Element PCM]" && inserted == 0) {
                 # Print the block precisely with exactly three lines.
                 printf "[Element Master]\nswitch = mute\nvolume = ignore\n\n";
                 inserted = 1;
             }
             print $0;
         }' "$CONF_COMMON" > "${CONF_COMMON}.tmp" && mv "${CONF_COMMON}.tmp" "$CONF_COMMON"
fi

###########################################################################
# STEP 2:
# If [Element Master] exists in CONF_COMMON (which it should now), then in the
# CONF_HEADPHONES file, override any line within the [Element Master] block that
# begins with "volume =" to read exactly "volume = ignore".
###########################################################################
if grep -Fxq "[Element Master]" "$CONF_COMMON"; then
    echo "[Element Master] exists in $CONF_COMMON; modifying HEADPHONES config accordingly."
    if grep -Fxq "[Element Master]" "$CONF_HEADPHONES"; then
        awk 'BEGIN { inMaster = 0 }
             {
                 if ($0 == "[Element Master]") {
                     inMaster = 1;
                     print $0;
                     next;
                 }
                 # If a new block starts (the first character is “[”) reset the flag.
                 if (inMaster && substr($0, 1, 1) == "[") { inMaster = 0 }
                 # While inside the [Element Master] block, if the line begins with "volume =", override it.
                 if (inMaster && index($0, "volume =") == 1) {
                     print "volume = ignore";
                     next;
                 }
                 print $0;
             }' "$CONF_HEADPHONES" > "${CONF_HEADPHONES}.tmp" && mv "${CONF_HEADPHONES}.tmp" "$CONF_HEADPHONES"
    else
        echo "[Element Master] block not found in $CONF_HEADPHONES; skipping modification of that file."
    fi
fi

###########################################################################
# STEP 3:
# Only restart the wireplumber service if either configuration file differs
# from its original backup.
###########################################################################
restart_service=false

if ! cmp -s "$CONF_COMMON" "$backup_common" || ! cmp -s "$CONF_HEADPHONES" "$backup_headphones"; then
    restart_service=true
fi


if [ "$restart_service" = true ]; then
    echo "Configuration differences detected; restarting wireplumber service..."

    logged_in_users=$(who | awk '{print $1}' | sort -u)
    for user in $logged_in_users; do
        XDG_RUNTIME_DIR="/run/user/$(id -u $user)"
        if command -v su >/dev/null 2>&1; then
            su "$user" -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user restart wireplumber.service"
        else
            printf "Warning: 'su' command not found. Skipping user %s.\n" "$user"
        fi
    done
fi

###########################################################################
# STEP 4:
# Cleanup.
###########################################################################
rm -f "$backup_common" "$backup_headphones"
EOF

echo "Workaround script installed at ${TARGET_SCRIPT}"

###############################################################################
# Step 2: For Pacman systems, install hook to reapply the patch
# when alsa-card-profiles is upgraded
###############################################################################
if command -v pacman &> /dev/null; then
    echo "Pacman system detected. Installing pacman hook..."
    HOOK_DIR="/etc/pacman.d/hooks"
    mkdir -p "$HOOK_DIR"
    HOOK_FILE="${HOOK_DIR}/alsa-workaround.hook"
    cat << EOF > "$HOOK_FILE"
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = alsa-card-profiles

[Action]
Description = Reapplying ALSA workaround after upgrade of one or more key packages...
When = PostTransaction
Exec = /usr/local/bin/alsa_workaround.sh
EOF
    echo "Pacman hook installed at ${HOOK_FILE}"
fi

###############################################################################
# Step 3: For APT systems, install a helper hook that runs only if any of the
#         target packages are upgraded.
###############################################################################
if command -v apt-get &> /dev/null; then
    echo "APT system detected. Installing APT hook..."

    # Create a helper hook script that checks package versions.
    APT_HOOK_SCRIPT="/usr/local/bin/alsa_workaround_apt_hook.sh"
    cat << 'EOF' > "$APT_HOOK_SCRIPT"
#!/bin/bash
set -euo pipefail

# Location to store last seen package versions.
STATUS_FILE="/var/lib/alsa_workaround_status"
# List of packages to monitor.
PACKAGES=("alsa-card-profiles" "wireplumber" "pipewire-alsa" "alsa-firmware")

declare -A current_versions

# Gather current installed versions (or "none" if not installed).
for pkg in "${PACKAGES[@]}"; do
    version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "none")
    current_versions["$pkg"]="$version"
done

# Determine whether we need to run the workaround.
run_update=0
if [ ! -f "$STATUS_FILE" ]; then
    run_update=1
else
    while IFS= read -r line; do
        pkg=$(echo "$line" | cut -d' ' -f1)
        stored_ver=$(echo "$line" | cut -d' ' -f2-)
        if [ "${current_versions[$pkg]}" != "$stored_ver" ]; then
            run_update=1
            break
        fi
    done < "$STATUS_FILE"
fi

if [ "$run_update" -eq 1 ]; then
    /usr/local/bin/alsa_workaround.sh
    # Overwrite the status file with current versions.
    > "$STATUS_FILE"
    for pkg in "${PACKAGES[@]}"; do
        echo "$pkg ${current_versions[$pkg]}" >> "$STATUS_FILE"
    done
fi

exit 0
EOF
    chmod +x "$APT_HOOK_SCRIPT"
    echo "APT hook helper installed at ${APT_HOOK_SCRIPT}"

    # Install the APT configuration hook so that the helper runs after each dpkg transaction.
    APT_CONFIG_FILE="/etc/apt/apt.conf.d/99alsa-workaround"
    cat << 'EOF' > "$APT_CONFIG_FILE"
DPkg::Post-Invoke {
    "if [ -x /usr/local/bin/alsa_workaround_apt_hook.sh ]; then /usr/local/bin/alsa_workaround_apt_hook.sh; fi";
};
EOF
    echo "APT DPkg::Post-Invoke hook installed at ${APT_CONFIG_FILE}"
fi

echo "Installation complete."

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
# set -euo pipefail

###############################################################################
# Step 1: Ensure we’re running as root.
###############################################################################

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root. Use sudo." >&2
    exit 1
fi

###############################################################################
# Step 2: Define WirePlumber restart function.
###############################################################################

restart_wireplumber() {
    echo "Restarting WirePlumber service..."

    logged_in_users=$(ps -eo user= | sort -u)

    for user in $logged_in_users; do
        # Skip invalid, unavailable, or expired users
        if [[ ! "$user" =~ ^[a-zA-Z0-9._-]+$ ]] || ! passwd -S "$user" &>/dev/null || [[ "$(passwd -S "$user" | awk '{print $2}')" =~ ^(L|E)$ ]]; then
            continue
        fi

        XDG_RUNTIME_DIR="/run/user/$(id -u $user 2>/dev/null)"
        if [[ -d "$XDG_RUNTIME_DIR" ]]; then
            if command -v su >/dev/null 2>&1; then
                su "$user" -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} systemctl --user restart wireplumber.service"
            else
                printf "Warning: 'su' command not found. Skipping user %s.\n" "$user"
            fi
        else
            printf "Warning: XDG_RUNTIME_DIR not found for %s. Skipping.\n" "$user"
        fi
    done
}

###############################################################################
# Step 3: Check ALSA configuration files for patch application.
###############################################################################

CONF_COMMON="/usr/share/alsa-card-profile/mixer/paths/analog-output.conf.common"
CONF_HEADPHONES="/usr/share/alsa-card-profile/mixer/paths/analog-output-headphones.conf"

if [[ ! -r "$CONF_COMMON" || ! -r "$CONF_HEADPHONES" ]]; then
    echo "Unable to read ALSA configuration files. Assuming first patch is not present."
    USE_SOFTMIXER=true
else
    echo "ALSA configuration files are readable. Proceeding with verification..."
    USE_SOFTMIXER=false
fi

###############################################################################
# Step 4: Copy ALSA configuration files to a writable location.
###############################################################################

TMP_COMMON="/tmp/analog-output.conf.common.tmp"
TMP_HEADPHONES="/tmp/analog-output-headphones.conf.tmp"

cp "$CONF_COMMON" "$TMP_COMMON"
cp "$CONF_HEADPHONES" "$TMP_HEADPHONES"

###############################################################################
# Step 5: Apply patch to temporary files.
###############################################################################

if ! grep -Fxq "[Element Master]" "$TMP_COMMON"; then
    echo "Inserting [Element Master] block into $TMP_COMMON before [Element PCM]."
    awk 'BEGIN { inserted = 0 }
         {
             if ($0 == "[Element PCM]" && inserted == 0) {
                 printf "[Element Master]\nswitch = mute\nvolume = ignore\n\n";
                 inserted = 1;
             }
             print $0;
         }' "$TMP_COMMON" > "${TMP_COMMON}.patched"
else
    cp "$TMP_COMMON" "${TMP_COMMON}.patched"  # Ensure the file exists
fi

if grep -Fxq "[Element Master]" "$TMP_HEADPHONES"; then
    awk 'BEGIN { inMaster = 0 }
         {
             if ($0 == "[Element Master]") {
                 inMaster = 1;
                 print $0;
                 next;
             }
             if (inMaster && substr($0, 1, 1) == "[") { inMaster = 0 }
             if (inMaster && index($0, "volume =") == 1) {
                 print "volume = ignore";
                 next;
             }
             print $0;
         }' "$TMP_HEADPHONES" > "${TMP_HEADPHONES}.patched"
else
    cp "$TMP_HEADPHONES" "${TMP_HEADPHONES}.patched"  # Ensure file exists even if unchanged
fi


###############################################################################
# Step 6: Compare patched temporary files with originals.
###############################################################################

if cmp -s "$TMP_COMMON" "${TMP_COMMON}.patched" && cmp -s "$TMP_HEADPHONES" "${TMP_HEADPHONES}.patched"; then
    echo "First patch was already applied. No further action needed."
    rm -f "$TMP_COMMON" "$TMP_HEADPHONES" "${TMP_COMMON}.patched" "${TMP_HEADPHONES}.patched"
else
    echo "First patch is missing and needs to be applied."
    echo "Differences detected:"
    diff "$TMP_COMMON" "${TMP_COMMON}.patched"
    diff "$TMP_HEADPHONES" "${TMP_HEADPHONES}.patched"

    ###############################################################################
    # Step 6.5: Attempt to apply first patch to original files.
    ###############################################################################

    if [[ -w "$CONF_COMMON" && -w "$CONF_HEADPHONES" ]]; then
        echo "Applying first patch to ALSA profile files..."
        cp "${TMP_COMMON}.patched" "$CONF_COMMON"
        cp "${TMP_HEADPHONES}.patched" "$CONF_HEADPHONES"

        # Ensure patch files exist before comparing
        if [[ ! -f "${TMP_COMMON}.patched" || ! -f "${TMP_HEADPHONES}.patched" ]]; then
            echo "Error: Expected patch files were not created!"
            ls -l "${TMP_COMMON}.patched" "${TMP_HEADPHONES}.patched"  # Print file details
            exit 1
        fi

        # Verify changes were applied successfully
        if cmp -s "$CONF_COMMON" "${TMP_COMMON}.patched" && cmp -s "$CONF_HEADPHONES" "${TMP_HEADPHONES}.patched"; then
            echo "First patch successfully applied."
            rm -f "$TMP_COMMON" "$TMP_HEADPHONES"
            restart_wireplumber
            exit 0
        else
            echo "Warning: Patch attempt made, but files were not updated correctly!"

            # Additional debugging output
            echo "Checking if files were modified..."
            diff "$CONF_COMMON" "${TMP_COMMON}.patched" || echo "No differences found in $CONF_COMMON"
            diff "$CONF_HEADPHONES" "${TMP_HEADPHONES}.patched" || echo "No differences found in $CONF_HEADPHONES"

            echo "Checking write permissions..."
            ls -ld "$(dirname "$CONF_COMMON")" "$(dirname "$CONF_HEADPHONES")"

            exit 1
        fi

    else
        echo "First patch location is not writable. Falling back to soft mixer patch."
        USE_SOFTMIXER=true
    fi
fi

###############################################################################
# Step 7: Apply soft mixer patch if necessary.
###############################################################################

if [[ "$USE_SOFTMIXER" = true ]]; then
    SOFTMIXER_CONFIG='
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*pci-0000_c4_00.6.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  },
  {
    matches = [
      {
        device.name = "~alsa_card.*"
        node.name = "~alsa_input.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = false
      }
    }
  }
]
'

    GLOBAL_CONF="/etc/wireplumber/wireplumber.conf.d/alsa-soft-mixer.conf"
    USER_CONF="$HOME/.config/wireplumber/wireplumber.conf.d/alsa-soft-mixer.conf"

    # Check if either configuration file already exists
    if [[ -f "$GLOBAL_CONF" || -f "$USER_CONF" ]]; then
        echo "Soft mixer patch already exists—no changes needed."
        exit 0
    fi

    # Function to recursively check and create writable directories
    ensure_writable_path() {
        local target_dir="$1"

        while [[ -n "$target_dir" ]]; do
            if [[ -w "$target_dir" ]]; then
                echo "Writable directory found: $target_dir"
                mkdir -p "$1"  # Create missing directories
                return 0
            fi
            target_dir=$(dirname "$target_dir")  # Move up one level
        done

        echo "No writable directory found for $1. Manual intervention required."
        return 1
    }

    # Attempt to apply the soft mixer patch globally **first**
    if ensure_writable_path "/etc/wireplumber/wireplumber.conf.d"; then
        echo "Applying soft mixer patch globally..."
        echo "$SOFTMIXER_CONFIG" > "$GLOBAL_CONF"
        restart_wireplumber
        exit 0  # **Exit immediately if successful**
    fi

    # If global path failed, attempt user-specific path
    if ensure_writable_path "$HOME/.config/wireplumber/wireplumber.conf.d"; then
        echo "Applying soft mixer patch for current user..."
        echo "$SOFTMIXER_CONFIG" > "$USER_CONF"
        restart_wireplumber
        exit 0
    fi

    # If neither path worked, require manual intervention
    echo "Neither configuration path is writable. Manual intervention required."
    exit 1


fi
EOF

chmod +x "$TARGET_SCRIPT"

"$TARGET_SCRIPT"

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

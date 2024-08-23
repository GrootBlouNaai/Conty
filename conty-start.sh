#!/usr/bin/env bash
LD_PRELOAD_ORIG="${LD_PRELOAD}"
LD_LIBRARY_PATH_ORIG="${LD_LIBRARY_PATH}"
unset LD_PRELOAD LD_LIBRARY_PATH
LC_ALL_ORIG="${LC_ALL}"
export LC_ALL=C
if (( EUID == 0 )) && [ -z "$ALLOW_ROOT" ]; then
    echo "${msg_root}"
    exit 1
fi
script_version="1.26.1"
init_size=50000
bash_size=1490760
script_size=37478
busybox_size=1161112
utils_size=4327795
if [ -n "${BASH_SOURCE[0]}" ]; then
	script_literal="${BASH_SOURCE[0]}"
else
	script_literal="${0}"
	if [ "${script_literal}" = "$(basename "${script_literal}")" ]; then
		script_literal="$(command -v "${0}")"
	fi
fi
script_name="$(basename "${script_literal}")"
script="$(readlink -f "${script_literal}")"
script_md5="$(head -c 4000000 "${script}" | md5sum | head -c 7)"_"$(tail -c 1000000 "${script}" | md5sum | head -c 7)"
script_id="$$"
conty_dir_name=conty_"${USER}"_"${script_md5}"
if  [ -z "${BASE_DIR}" ]; then
	export working_dir=/tmp/"${conty_dir_name}"
else
	export working_dir="${BASE_DIR}"/"${conty_dir_name}"
fi
if [ "${USE_SYS_UTILS}" != 1 ] && [ "${busybox_size}" -gt 0 ]; then
	busybox_bin_dir="${working_dir}"/busybox_bins
	busybox_path="${busybox_bin_dir}"/busybox
	if [ ! -f "${busybox_bin_dir}"/echo ]; then
		mkdir -p "${busybox_bin_dir}"
		tail -c +$((init_size+bash_size+script_size+1)) "${script}" | head -c "${busybox_size}" > "${busybox_path}"
		chmod +x "${busybox_path}" 2>/dev/null
		"${busybox_path}" --install -s "${busybox_bin_dir}" &>/dev/null
	fi
	if "${busybox_bin_dir}"/echo &>/dev/null; then
		export PATH="${busybox_bin_dir}:${PATH}"
	fi
fi
if [ -n "${CUSTOM_MNT}" ] && [ -d "${CUSTOM_MNT}" ]; then
	mount_point="${CUSTOM_MNT}"
else
	mount_point="${working_dir}"/mnt
fi
export overlayfs_dir="${HOME}"/.local/share/Conty/overlayfs_"${script_md5}"
export nvidia_drivers_dir="${overlayfs_dir}"/nvidia
export overlayfs_shared_dir="${HOME}"/.local/share/Conty/overlayfs_shared
export nvidia_drivers_shared_dir="${overlayfs_shared_dir}"/nvidia
offset=$((init_size+bash_size+script_size+busybox_size+utils_size))
if [ "$(tail -c +$((offset+1)) "${script}" | head -c 6)" = "DWARFS" ]; then
	dwarfs_image=1
fi
squashfs_comp_arguments=(-b 1M -comp zstd -Xcompression-level 19)
dwarfs_comp_arguments=(-l7 -C zstd:level=19 --metadata-compression null \
                            -S 21 -B 1 --order nilsimsa \
                            -W 12 -w 4 --no-create-timestamp)
NVIDIA_HANDLER="${NVIDIA_HANDLER:-1}"
unset script_is_symlink
if [ -L "${script_literal}" ]; then
    script_is_symlink=1
fi
if [ -z "${script_is_symlink}" ]; then
    if [ -t 0 ] && ([ "$1" = "-h" ] || [ -z "$1" ]); then
        echo "${msg_help}"
        exit
    elif [ "$1" = "-v" ]; then
        echo "${script_version}"
        exit
    elif [ "$1" = "-o" ]; then
        echo "${offset}"
        exit
    fi
fi
show_msg () {
	if [ "${QUIET_MODE}" != 1 ]; then
		echo "$@"
	fi
}
exec_test () {
	mkdir -p "${working_dir}"
	exec_test_file="${working_dir}"/exec_test
	rm -f "${exec_test_file}"
	touch "${exec_test_file}"
	chmod +x "${exec_test_file}"
	[ -x "${exec_test_file}" ]
}
launch_wrapper () {
	if [ "${USE_SYS_UTILS}" = 1 ]; then
		"$@"
	else
		"${working_dir}"/utils/ld-linux-x86-64.so.2 --library-path "${working_dir}"/utils "$@"
	fi
}

# Checks if zenity is installed on the system.
check_zenity_installed () {
    if ! command -v zenity &> /dev/null; then
        exit 1
    fi
}

# This function provides a GUI interface for users to run commands or select files.
# Handles user response based on exit code and selected options.
gui () {
    check_zenity_installed

    local gui_response=$(zenity --title="Conty" \
        --entry \
        --text="Enter a command or select a file you want to run" \
        --ok-label="Run" \
        --cancel-label="Quit" \
        --extra-button="Select a file" \
        --extra-button="Open a terminal")
    local gui_exit_code=$?

    if [ "${gui_response}" = "Select a file" ]; then
        handle_file_selection
    elif [ "${gui_response}" = "Open a terminal" ]; then
        open_terminal
    elif [ "${gui_exit_code}" = 0 ]; then
        execute_command "${gui_response}"
    fi
}

# Selects a file using zenity file selection dialog.
select_file () {
    zenity --title="A file to run" --file-selection
}

# Handles the selection and execution of a file by the user.
handle_file_selection () {
    local filepath=$(select_file)
    if [ -f "${filepath}" ]; then
        # Checks if the selected file is executable and makes it executable if not.
        [ -x "${filepath}" ] || chmod +x "${filepath}"
        "${filepath}"
    else
        zenity --error --text="You did not select a file"
    fi
}

# Checks if a compatible terminal emulator is installed.
check_terminal_emulator () {
    command -v lxterminal &> /dev/null
}

# Opens a terminal for the user to execute commands.
open_terminal () {
    # Opens a terminal if a compatible terminal emulator is found.
    if check_terminal_emulator; then
        lxterminal -T "Conty terminal" --command="bash -c 'echo Welcome to Conty; echo Enter any commands you want to execute; bash'"
    else
        zenity --error --text="A terminal emulator is not installed in this instance of Conty"
    fi
}

# Parses the command input and handles argument combining.
parse_command () {
    local gui_response="$1"
    local combined_args=""
    local -a launch_command=()
    for a in ${gui_response}; do
        if [ "${a:0:1}" = "\"" ] || [ "${a:0:1}" = "'" ] || [ -n "${combined_args}" ]; then
            combined_args="${combined_args} ${a}"
            if [ "${a: -1}" = "\"" ] || [ "${a: -1}" = "'" ]; then
                combined_args="${combined_args:2}"
                combined_args="${combined_args%?}"
                launch_command+=("${combined_args}")
                unset combined_args
            fi
            continue
        fi
        launch_command+=("${a}")
    done
    echo "${launch_command[@]}"
}

# Executes the command entered by the user.
execute_command () {
    local gui_response="$1"
    if [ -z "${gui_response}" ]; then
        zenity --error --text="You need to enter a command to execute"
    else
        # Parses the command input and handles argument combining.
        local launch_command=($(parse_command "${gui_response}"))
        # Executes the parsed command.
        "${launch_command[@]}"
    fi
}

# Helper function to check if NVIDIA should be shared
should_share_nvidia() {
    [ "${1}" = "share_nvidia" ]
}

# Function to get NVIDIA driver URL
get_nvidia_driver_url() {
    echo "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
}

# Function to install NVIDIA driver
install_nvidia_driver() {
    chmod +x nvidia.run
    ./nvidia.run --target nvidia-driver -x &>/dev/null
    if [ -f nvidia-driver/nvidia-installer ]; then
        cd nvidia-driver || exit 1
        chmod +x nvidia-installer
        fakeroot ./nvidia-installer --silent --no-x-check --no-kernel-module &>/dev/null
        rm -rf "${NVIDIA_DRIVERS_DIR}"/nvidia.run "${NVIDIA_DRIVERS_DIR}"/nvidia-driver
        if [ -s /usr/lib/libGLX_nvidia.so."${NVIDIA_DRIVER_VERSION}" ] || \
           [ -s /usr/lib/libGL.so."${NVIDIA_DRIVER_VERSION}" ]; then
            echo "${NVIDIA_DRIVER_VERSION}" > "${NVIDIA_DRIVERS_DIR}"/current-nvidia-version
            echo "The driver installed successfully"
        else
            echo "Failed to install the driver"
        fi
    else
        echo "Failed to extract the driver"
    fi
}

# Function to update system packages
update_system_packages() {
    reflector --protocol https --score 5 --sort rate --save /etc/pacman.d/mirrorlist
    fakeroot -- pacman -Syy 2>/dev/null
    date -u +"%d-%m-%Y %H:%M (DMY UTC)" > /version
    fakeroot -- pacman --noconfirm -S archlinux-keyring 2>/dev/null
    fakeroot -- pacman --noconfirm -S chaotic-keyring 2>/dev/null
    rm -rf /etc/pacman.d/gnupg/*
    fakeroot -- pacman-key --init
    echo "keyserver hkps://keyserver.ubuntu.com" >> /etc/pacman.d/gnupg/gpg.conf
    fakeroot -- pacman-key --populate archlinux
    fakeroot -- pacman-key --populate chaotic
    fakeroot -- pacman --noconfirm --overwrite "*" -Su 2>/dev/null
}

# Function to install required packages
install_required_packages() {
    fakeroot -- pacman --noconfirm -Runs ${pkgsremove} 2>/dev/null
    fakeroot -- pacman --noconfirm -S ${pkgsinstall} 2>/dev/null
    ldconfig -C /etc/ld.so.cache
    rm -f /var/cache/pacman/pkg/*
}

mount_overlayfs () {
    mkdir -p "${OVERLAYFS_DIR}"/up
    mkdir -p "${OVERLAYFS_DIR}"/work
    mkdir -p "${OVERLAYFS_DIR}"/merged
    mkdir -p "${NVIDIA_DRIVERS_DIR}"

    # Checks if the merged directory is empty before mounting
    if [ ! "$(ls "${OVERLAYFS_DIR}"/merged 2>/dev/null)" ]; then
        if command -v "${unionfs_fuse}" 1>/dev/null; then
            if should_share_nvidia "${1}"; then
                launch_wrapper "${unionfs_fuse}" -o relaxed_permissions,cow,noatime "${OVERLAYFS_DIR}"/up=RW:"${overlayfs_shared_dir}"/up=RO:"${mount_point}"=RO "${OVERLAYFS_DIR}"/merged
            else
                launch_wrapper "${unionfs_fuse}" -o relaxed_permissions,cow,noatime "${OVERLAYFS_DIR}"/up=RW:"${mount_point}"=RO "${OVERLAYFS_DIR}"/merged
            fi
        else
            echo "unionfs-fuse not found"
            return 1
        fi
    fi
}

nvidia_driver_handler () {
    OLD_PWD="${PWD}"
    rm -rf "${NVIDIA_DRIVERS_DIR}"/nvidia.run "${NVIDIA_DRIVERS_DIR}"/nvidia-driver
    mkdir -p "${NVIDIA_DRIVERS_DIR}"
    cd "${NVIDIA_DRIVERS_DIR}"

    echo "Found Nvidia driver ${NVIDIA_DRIVER_VERSION}"

    # Downloads the Nvidia driver from the official source
    echo "Downloading the Nvidia driver ${NVIDIA_DRIVER_VERSION}..."
    driver_url=$(get_nvidia_driver_url)
    curl -#Lo nvidia.run "${driver_url}"

    # Checks if the downloaded driver file is valid
    if [ ! -s nvidia.run ] || [ "$(stat -c%s nvidia.run)" -lt 30000000 ]; then
        rm -f nvidia.run
        driver_url="https:$(curl -#Lo - "https://raw.githubusercontent.com/flathub/org.freedesktop.Platform.GL.nvidia/master/data/nvidia-${NVIDIA_DRIVER_VERSION}-x86_64.data" | cut -d ':' -f 6)"
        curl -#Lo nvidia.run "${driver_url}"
    fi

    if [ -s nvidia.run ]; then
        echo "Installing the Nvidia driver, please wait..."
        install_nvidia_driver
    else
        echo "Failed to download the driver"
    fi

    cd "${OLD_PWD}"
}

update_conty () {
    # Updates the system packages and configurations
    if [ "$(ls /var/cache/pacman/pkg_host 2>/dev/null)" ]; then
        mkdir -p /var/cache/pacman/pkg
        ln -s /var/cache/pacman/pkg_host/* /var/cache/pacman/pkg 2>/dev/null
    fi

    update_system_packages
    install_required_packages

    # Generates the package list after updates
    pacman -Q > /pkglist.x86_64.txt
    update-ca-trust
    locale-gen
}
# Setup and execution of a containerized environment using FUSE and Dwarfs/Squashfuse.

# Function to calculate optimal Dwarfs settings based on system resources
calculate_dwarfs_settings() {
    if getconf _PHYS_PAGES &>/dev/null && getconf PAGE_SIZE &>/dev/null; then
        memory_size="$(($(getconf _PHYS_PAGES) * $(getconf PAGE_SIZE) / (1024 * 1024)))"
        if [ "${memory_size}" -ge 45000 ]; then
            dwarfs_cache_size="4096M"
        elif [ "${memory_size}" -ge 23000 ]; then
            dwarfs_cache_size="2048M"
        elif [ "${memory_size}" -ge 15000 ]; then
            dwarfs_cache_size="1024M"
        elif [ "${memory_size}" -ge 7000 ]; then
            dwarfs_cache_size="512M"
        elif [ "${memory_size}" -ge 3000 ]; then
            dwarfs_cache_size="256M"
        elif [ "${memory_size}" -ge 1500 ]; then
            dwarfs_cache_size="128M"
        else
            dwarfs_cache_size="64M"
        fi
    fi

    if getconf _NPROCESSORS_ONLN &>/dev/null; then
        dwarfs_num_workers="$(getconf _NPROCESSORS_ONLN)"
        if [ "${dwarfs_num_workers}" -ge 8 ]; then
            dwarfs_num_workers=8
        fi
    fi
}

# Function to determine which tools to use based on the image type and system utilities availability
set_tools() {
    if [ "${dwarfs_image}" = 1 ]; then
        mount_tool="${working_dir}/utils/dwarfs${fuse_version}"
        extraction_tool="${working_dir}/utils/dwarfsextract"
        compression_tool="${working_dir}/utils/mkdwarfs"
    else
        mount_tool="${working_dir}/utils/squashfuse${fuse_version}"
        extraction_tool="${working_dir}/utils/unsquashfs"
        compression_tool="${working_dir}/utils/mksquashfs"
    fi
    bwrap="${working_dir}/utils/bwrap"
    unionfs_fuse="${working_dir}/utils/unionfs${fuse_version}"
}

# Function to check if /tmp is mounted with noexec
check_tmp_noexec() {
    if ! exec_test; then
        echo "Seems like /tmp is mounted with noexec or you don't have write access!"
        echo "Please remount it without noexec or set BASE_DIR to a different location."
        exit 1
    fi
}

# Function to extract the image if the -e flag is provided
extract_image() {
    if command -v "${extraction_tool}" 1>/dev/null; then
        if [ "${dwarfs_image}" = 1 ]; then
            echo "Extracting the image..."
            mkdir "$(basename "${script}")_files"
            launch_wrapper "${extraction_tool}" -i "${script}" -o "$(basename "${script}")_files" -O "${offset}"
            echo "Done"
        else
            launch_wrapper "${extraction_tool}" -o "${offset}" -user-xattrs -d "$(basename "${script}")_files" "${script}"
        fi
    else
        echo "Extraction tool not found"
        exit 1
    fi
}

# Function to display Bubblewrap help if the -H flag is provided
show_bwrap_help() {
    launch_wrapper "${bwrap}" --help
}

# Main script logic
if ! command -v fusermount3 1>/dev/null && ! command -v fusermount 1>/dev/null; then
    echo "Please install fuse2 or fuse3 and run the script again."
    exit 1
fi

if command -v fusermount3 1>/dev/null; then
    fuse_version=3
fi

dwarfs_cache_size="128M"
dwarfs_num_workers="2"

if [ "${dwarfs_image}" = 1 ]; then
    calculate_dwarfs_settings
fi

mkdir -p "${working_dir}"

if ([ "${USE_SYS_UTILS}" != 1 ] && [ "${utils_size}" -gt 0 ]) || [ "$1" = "-u" ]; then
    if ! exec_test; then
        if [ -z "${BASE_DIR}" ]; then
            export working_dir="${HOME}/.local/share/Conty/${conty_dir_name}"
            if [ -z "${CUSTOM_MNT}" ]; then
                mount_point="${working_dir}/mnt"
            fi
        fi
        check_tmp_noexec
    fi

    if ! command -v tar 1>/dev/null || ! command -v gzip 1>/dev/null; then
        echo "Please install tar and gzip and run the script again."
        exit 1
    fi

    set_tools

    if [ ! -f "${mount_tool}" ] || [ ! -f "${bwrap}" ]; then
        tail -c +$((init_size+bash_size+script_size+busybox_size+1)) "${script}" | head -c "${utils_size}" | tar -C "${working_dir}" -zxf -
        if [ ! -f "${mount_tool}" ] || [ ! -f "${bwrap}" ]; then
            clear
            echo "The integrated utils were not extracted!"
            echo "Perhaps something is wrong with the integrated utils.tar.gz."
            exit 1
        fi
        chmod +x "${mount_tool}" 2>/dev/null
        chmod +x "${bwrap}" 2>/dev/null
        chmod +x "${extraction_tool}" 2>/dev/null
        chmod +x "${unionfs_fuse}" 2>/dev/null
        chmod +x "${compression_tool}" 2>/dev/null
    fi
else
    if ! command -v bwrap 1>/dev/null; then
        echo "USE_SYS_UTILS is enabled, but bubblewrap is not installed!"
        echo "Please install it and run the script again."
        exit 1
    fi

    bwrap=bwrap
    unionfs_fuse=unionfs

    if [ "${dwarfs_image}" = 1 ]; then
        if ! command -v dwarfs 1>/dev/null && ! command -v dwarfs2 1>/dev/null; then
            echo "USE_SYS_UTILS is enabled, but dwarfs is not installed!"
            echo "Please install it and run the script again."
            exit 1
        fi
        if command -v dwarfs2 1>/dev/null; then
            mount_tool=dwarfs2
        else
            mount_tool=dwarfs
        fi
        extraction_tool=dwarfsextract
    else
        if ! command -v squashfuse 1>/dev/null; then
            echo "USE_SYS_UTILS is enabled, but squashfuse is not installed!"
            echo "Please install it and run the script again."
            exit 1
        fi
        mount_tool=squashfuse
        extraction_tool=unsquashfs
    fi

    show_msg "Using system-wide ${mount_tool} and bwrap"
fi

if [ "$1" = "-e" ] && [ -z "${script_is_symlink}" ]; then
    extract_image
    exit
fi

if [ "$1" = "-H" ] && [ -z "${script_is_symlink}" ]; then
    show_bwrap_help
    exit
fi

# This function sets up and runs a sandboxed environment using bwrap.
run_bwrap () {
    # Initialize variables
    unset sandbox_params
    unset unshare_net
    unset custom_home
    unset non_standard_home
    unset xsockets
    unset mount_opt
    unset command_line
    command_line=("${@}")

    # Handles the case where WAYLAND_DISPLAY is set or defaults to 'wayland-0'.
    set_wayland_socket

    # Ensures XDG_RUNTIME_DIR is set to a valid path if not already set.
    set_xdg_runtime_dir

    # Checks if HOME is non-standard and adjusts accordingly.
    handle_non_standard_home

    # Sets up parameters for sandboxing based on SANDBOX and SANDBOX_LEVEL.
    set_sandbox_params

    # Disables network if DISABLE_NET is set to 1.
    disable_network

    # Sets a custom home directory if HOME_DIR is set.
    set_custom_home

    # Configures XAUTHORITY and xsockets based on various conditions.
    set_xauthority_and_xsockets

    # Binds root and other necessary mounts based on conditions.
    bind_root_and_mounts

    # Sets various environment variables based on conditions.
    set_environment_variables

    # Display message and launch the wrapper
    show_msg
    launch_wrapper "${bwrap}" \
        "${bind_root[@]}" \
        --dev-bind /dev /dev \
        --ro-bind /sys /sys \
        --bind-try /tmp /tmp \
        --proc /proc \
        --bind-try /home /home \
        --bind-try /mnt /mnt \
        --bind-try /media /media \
        --bind-try /run /run \
        --bind-try /var /var \
        --ro-bind-try /usr/share/steam/compatibilitytools.d /usr/share/steam/compatibilitytools.d \
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/hosts /etc/hosts \
        --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
        --ro-bind-try /etc/passwd /etc/passwd \
        --ro-bind-try /etc/group /etc/group \
        --ro-bind-try /etc/machine-id /etc/machine-id \
        --ro-bind-try /etc/asound.conf /etc/asound.conf \
        --ro-bind-try /etc/localtime /etc/localtime \
        "${non_standard_home[@]}" \
        "${sandbox_params[@]}" \
        "${custom_home[@]}" \
        "${mount_opt[@]}" \
        "${xsockets[@]}" \
        "${unshare_net[@]}" \
        "${set_vars[@]}" \
        --setenv PATH "${CUSTOM_PATH}" \
        "${command_line[@]}"
}

# Extracts the logic for setting WAYLAND_DISPLAY into a new function.
set_wayland_socket () {
    if [ -n "${WAYLAND_DISPLAY}" ]; then
        wayland_socket="${WAYLAND_DISPLAY}"
    else
        wayland_socket="wayland-0"
    fi
}

# Extracts the logic for setting XDG_RUNTIME_DIR into a new function.
set_xdg_runtime_dir () {
    if [ -z "${XDG_RUNTIME_DIR}" ]; then
        XDG_RUNTIME_DIR="/run/user/${EUID}"
    fi
}

# Extracts the logic for handling non-standard home directories into a new function.
handle_non_standard_home () {
    if [ -n "${HOME}" ] && [ "$(echo "${HOME}" | head -c 6)" != "/home/" ]; then
        HOME_BASE_DIR="$(echo "${HOME}" | cut -d '/' -f2)"
        case "${HOME_BASE_DIR}" in
            tmp|mnt|media|run|var)
                ;;
            *)
                NEW_HOME=/home/"${USER}"
                non_standard_home+=(--tmpfs /home \
                                    --bind "${HOME}" "${NEW_HOME}" \
                                    --setenv "HOME" "${NEW_HOME}" \
                                    --setenv "XDG_CONFIG_HOME" "${NEW_HOME}"/.config \
                                    --setenv "XDG_DATA_HOME" "${NEW_HOME}"/.local/share)
                unset command_line
                for arg in "$@"; do
                    if [[ "${arg}" == *"${HOME}"* ]]; then
                        arg="$(echo "${arg/"$HOME"/"$NEW_HOME"}")"
                    fi
                    command_line+=("${arg}")
                done
                ;;
        esac
    fi
}

# Extracts the logic for setting sandbox parameters into a new function.
set_sandbox_params () {
    if [ "${SANDBOX}" = 1 ]; then
        sandbox_params+=(--tmpfs /home \
                         --tmpfs /mnt \
                         --tmpfs /media \
                         --tmpfs /var \
                         --tmpfs /run \
                         --symlink /run /var/run \
                         --tmpfs /tmp \
                         --new-session)
        if [ -n "${non_standard_home[*]}" ]; then
            sandbox_params+=(--dir "${NEW_HOME}")
        else
            sandbox_params+=(--dir "${HOME}")
        fi
        if [ -n "${SANDBOX_LEVEL}" ] && [ "${SANDBOX_LEVEL}" -ge 2 ]; then
            sandbox_level_msg="(level 2)"
            sandbox_params+=(--dir "${XDG_RUNTIME_DIR}" \
                             --ro-bind-try "${XDG_RUNTIME_DIR}"/"${wayland_socket}" "${XDG_RUNTIME_DIR}"/"${wayland_socket}" \
                             --ro-bind-try "${XDG_RUNTIME_DIR}"/pulse "${XDG_RUNTIME_DIR}"/pulse \
                             --ro-bind-try "${XDG_RUNTIME_DIR}"/pipewire-0 "${XDG_RUNTIME_DIR}"/pipewire-0 \
                             --unshare-pid \
                             --unshare-user-try \
                             --unsetenv "DBUS_SESSION_BUS_ADDRESS")
        else
            sandbox_level_msg="(level 1)"
            sandbox_params+=(--bind-try "${XDG_RUNTIME_DIR}" "${XDG_RUNTIME_DIR}" \
                             --bind-try /run/dbus /run/dbus)
        fi
        if [ -n "${SANDBOX_LEVEL}" ] && [ "${SANDBOX_LEVEL}" -ge 3 ]; then
            sandbox_level_msg="(level 3)"
            DISABLE_NET=1
        fi
        show_msg "Sandbox is enabled ${sandbox_level_msg}"
    fi
}

# Extracts the logic for disabling network into a new function.
disable_network () {
    if [ "${DISABLE_NET}" = 1 ]; then
        show_msg "Network is disabled"
        unshare_net=(--unshare-net)
    fi
}

# Extracts the logic for setting custom home directory into a new function.
set_custom_home () {
    if [ -n "${HOME_DIR}" ]; then
        show_msg "Home directory is set to ${HOME_DIR}"
        if [ -n "${non_standard_home[*]}" ]; then
            custom_home+=(--bind "${HOME_DIR}" "${NEW_HOME}")
        else
            custom_home+=(--bind "${HOME_DIR}" "${HOME}")
        fi
        [ ! -d "${HOME_DIR}" ] && mkdir -p "${HOME_DIR}"
    fi
}

# Extracts the logic for setting XAUTHORITY and xsockets into a new function.
set_xauthority_and_xsockets () {
    if [ -z "${XAUTHORITY}" ]; then
        XAUTHORITY="${HOME}"/.Xauthority
    fi
    xsockets+=(--tmpfs /tmp/.X11-unix)
    if [ -n "${non_standard_home[*]}" ] && [ "${XAUTHORITY}" = "${HOME}"/.Xauthority ]; then
        xsockets+=(--ro-bind-try "${XAUTHORITY}" "${NEW_HOME}"/.Xauthority \
                   --setenv "XAUTHORITY" "${NEW_HOME}"/.Xauthority)
    else
        xsockets+=(--ro-bind-try "${XAUTHORITY}" "${XAUTHORITY}")
    fi
    if [ "${DISABLE_X11}" != 1 ]; then
        if [ "$(ls /tmp/.X11-unix 2>/dev/null)" ]; then
            if [ -n "${SANDBOX_LEVEL}" ] && [ "${SANDBOX_LEVEL}" -ge 3 ]; then
                xsockets+=(--ro-bind-try /tmp/.X11-unix/X"${xephyr_display}" /tmp/.X11-unix/X"${xephyr_display}" \
                           --setenv "DISPLAY" :"${xephyr_display}")
            else
                for s in /tmp/.X11-unix/*; do
                    xsockets+=(--bind-try "${s}" "${s}")
                done
            fi
        fi
    else
        show_msg "Access to X server is disabled"
        xsockets+=(--ro-bind-try "${working_dir}"/running_"${script_id}" "${XAUTHORITY}" \
                   --unsetenv "DISPLAY" \
                   --unsetenv "XAUTHORITY")
    fi
}

# Extracts the logic for binding root and other mounts into a new function.
bind_root_and_mounts () {
    if [ ! "$(ls "${mount_point}"/opt 2>/dev/null)" ] && [ -z "${SANDBOX}" ]; then
        mount_opt=(--bind-try /opt /opt)
    fi
    if ([ "${NVIDIA_HANDLER}" = 1 ] || [ "${USE_OVERLAYFS}" = 1 ]) && \
        [ "$(ls "${overlayfs_dir}"/merged 2>/dev/null)" ]; then
        newroot_path="${overlayfs_dir}"/merged
    else
        newroot_path="${mount_point}"
    fi
    if [ "${RW_ROOT}" = 1 ]; then
        bind_root=(--bind "${newroot_path}" /)
    else
        bind_root=(--ro-bind "${newroot_path}" /)
    fi
}

# Extracts the logic for setting environment variables into a new function.
set_environment_variables () {
    conty_variables="BASE_DIR DISABLE_NET DISABLE_X11 HOME_DIR QUIET_MODE \
                     SANDBOX SANDBOX_LEVEL USE_OVERLAYFS NVIDIA_HANDLER \
                     USE_SYS_UTILS XEPHYR_SIZE CUSTOM_MNT"
    for v in ${conty_variables}; do
        set_vars+=(--unsetenv "${v}")
    done
    [ -n "${LD_PRELOAD_ORIG}" ] && set_vars+=(--setenv LD_PRELOAD "${LD_PRELOAD_ORIG}")
    [ -n "${LD_LIBRARY_PATH_ORIG}" ] && set_vars+=(--setenv LD_LIBRARY_PATH "${LD_LIBRARY_PATH_ORIG}")
    if [ -n "${LC_ALL_ORIG}" ]; then
        set_vars+=(--setenv LC_ALL "${LC_ALL_ORIG}")
    else
        set_vars+=(--unsetenv LC_ALL)
    fi
}
exit_function () {
	sleep 3
	rm -f "${working_dir}"/running_"${script_id}"
	if [ ! "$(ls "${working_dir}"/running_* 2>/dev/null)" ]; then
		if [ -d "${overlayfs_dir}"/merged ]; then
			fusermount"${fuse_version}" -uz "${overlayfs_dir}"/merged 2>/dev/null || \
			umount --lazy "${overlayfs_dir}"/merged 2>/dev/null
		fi
		if [ -z "${CUSTOM_MNT}" ]; then
			fusermount"${fuse_version}" -uz "${mount_point}" 2>/dev/null || \
			umount --lazy "${mount_point}" 2>/dev/null
		fi
		if [ ! "$(ls "${mount_point}" 2>/dev/null)" ] || [ -n "${CUSTOM_MNT}" ]; then
			rm -rf "${working_dir}"
		fi
	fi
	exit
}
trap_exit () {
	exit_function &
}
trap 'trap_exit' EXIT
if [ "$(ls "${working_dir}"/running_* 2>/dev/null)" ] && [ ! "$(ls "${mount_point}" 2>/dev/null)" ]; then
	rm -f "${working_dir}"/running_*
fi
if [ -f "${nvidia_drivers_dir}"/lock ] && [ ! "$(ls "${working_dir}"/running_* 2>/dev/null)" ]; then
	rm -f "${nvidia_drivers_dir}"/lock
fi
if [ "${dwarfs_image}" = 1 ]; then
	mount_command=("${mount_tool}" \
	               "${script}" "${mount_point}" \
	               -o offset="${offset}" \
	               -o debuglevel=error \
	               -o workers="${dwarfs_num_workers}" \
	               -o mlock=try \
	               -o no_cache_image \
	               -o cache_files \
	               -o cachesize="${dwarfs_cache_size}" \
	               -o decratio=0.6 \
	               -o tidy_strategy=swap \
	               -o tidy_interval=5m)
else
	mount_command=("${mount_tool}" \
	               -o offset="${offset}",ro \
	               "${script}" "${mount_point}")
fi
ulimit -n $(ulimit -Hn) &>/dev/null
mkdir -p "${mount_point}"
if [ "$(ls "${mount_point}" 2>/dev/null)" ] || launch_wrapper "${mount_command[@]}"; then
	if [ "$1" = "-m" ] && [ -z "${script_is_symlink}" ]; then
		if [ ! -f "${working_dir}"/running_mount ]; then
			echo 1 > "${working_dir}"/running_mount
			echo "The image has been mounted to ${mount_point}"
		else
			rm -f "${working_dir}"/running_mount
			echo "The image has been unmounted"
		fi
		exit
	fi
	if [ "$1" = "-V" ] && [ -z "${script_is_symlink}" ]; then
		if [ -f "${mount_point}"/version ]; then
			cat "${mount_point}"/version
		else
			echo "Unknown version"
		fi
		exit
	fi
	if [ "$1" = "-d" ] && [ -z "${script_is_symlink}" ]; then
		applications_dir="${HOME}"/.local/share/applications/Conty
		if [ -d "${applications_dir}" ]; then
			rm -rf "${applications_dir}"
			echo "Desktop files have been removed"
			exit
		fi
		mkdir -p "${applications_dir}"
		cp -r "${mount_point}"/usr/share/applications "${applications_dir}"_temp
		cd "${applications_dir}"_temp || exit 1
		unset variables
		vars="BASE_DIR DISABLE_NET DISABLE_X11 HOME_DIR SANDBOX SANDBOX_LEVEL USE_SYS_UTILS CUSTOM_MNT"
		for v in ${vars}; do
			if [ -n "${!v}" ]; then
				variables="${v}=\"${!v}\" ${variables}"
			fi
		done
		if [ -n "${variables}" ]; then
			variables="env ${variables} "
		fi
		echo "Exporting..."
		shift
		for f in *.desktop */ */*.desktop; do
			if [ "${f}" != "*.desktop" ] && [ "${f}" != "*/*.desktop" ] && [ "${f}" != "*/" ]; then
				if [ -d "${f}" ]; then
					mkdir -p "${applications_dir}"/"${f}"
					continue
				fi
				if [ -L "${f}" ]; then
					cp --remove-destination "${mount_point}"/"$(readlink "${f}")" "${f}"
				fi
				while read -r line; do
					line_function="$(echo "${line}" | head -c 4)"
					if [ "${line_function}" = "Name" ]; then
						line="${line} (Conty)"
					elif [ "${line_function}" = "Exec" ]; then
						line="Exec=${variables}\"${script}\" $@ $(echo "${line}" | tail -c +6)"
					elif [ "${line_function}" = "TryE" ]; then
						continue
					fi
					echo $line >> "${applications_dir}"/"${f%.desktop}"-conty.desktop
				done < "${f}"
			fi
		done
		mkdir -p "${HOME}"/.local/share
		cp -nr "${mount_point}"/usr/share/icons "${HOME}"/.local/share 2>/dev/null
		rm -rf "${applications_dir}"_temp
		echo "Desktop files have been exported"
		exit
	fi
	echo 1 > "${working_dir}"/running_"${script_id}"
	show_msg "Running Conty"
	export CUSTOM_PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/jvm/default/bin:/usr/local/bin:/usr/local/sbin:${PATH}"
	if [ "$1" = "-l" ] && [ -z "${script_is_symlink}" ]; then
		run_bwrap --ro-bind "${mount_point}"/var /var pacman -Q
		exit
	fi
	if [ "$1" = "-u" ] && [ -z "${script_is_symlink}" ] && [ -z "${CUSTOM_MNT}" ]; then
		export overlayfs_dir="${HOME}"/.local/share/Conty/update_overlayfs_"${script_md5}"
		rm -rf "${overlayfs_dir}"
		if mount_overlayfs; then
			USE_OVERLAYFS=1
			QUIET_MODE=1
			RW_ROOT=1
			unset DISABLE_NET
			unset HOME_DIR
			unset SANDBOX_LEVEL
			unset SANDBOX
			unset DISABLE_X11
			if ! touch test_rw 2>/dev/null; then
				cd "${HOME}" || exit 1
			fi
			rm -f test_rw
			OLD_PWD="${PWD}"
			conty_update_temp_dir="${PWD}"/conty_update_temp_"${script_md5}"
			mkdir "${conty_update_temp_dir}"
			cd "${conty_update_temp_dir}" || exit 1
			if command -v awk 1>/dev/null; then
				current_file_size="$(stat -c "%s" "${script}")"
				available_disk_space="$(df -P -B1 "${PWD}" | awk 'END {print $4}')"
				required_disk_space="$((current_file_size*7))"
				if [ "${available_disk_space}" -lt "${required_disk_space}" ]; then
					echo "Not enough free disk space"
					echo "You need at least $((required_disk_space/1024/1024)) MB of free space"
					exit 1
				fi
			fi
			shift
			if [ -n "$1" ]; then
				packagelist=("$@")
				for i in "${packagelist[@]}"; do
					if [ "$(echo "${i}" | head -c 1)" = "-" ]; then
						pkgsremove+=" ${i:1}"
					else
						pkgsinstall+=" ${i}"
					fi
				done
				export pkgsremove
				export pkgsinstall
			fi
			clear
			echo "Updating and installing packages..."
			cp -r "${mount_point}"/etc/pacman.d/gnupg "${overlayfs_dir}"/gnupg
			export -f update_conty
			run_bwrap \
			    --bind "${overlayfs_dir}"/gnupg /etc/pacman.d/gnupg \
				--bind "${overlayfs_dir}"/merged/var /var \
				--bind-try /var/cache/pacman/pkg /var/cache/pacman/pkg_host \
				bash -c update_conty
			if [ "${dwarfs_image}" = 1 ]; then
				compression_command=("${compression_tool}" -i "${overlayfs_dir}"/merged -o image "${dwarfs_comp_arguments[@]}")
			else
				compression_command=("${compression_tool}" "${overlayfs_dir}"/merged image "${squashfs_comp_arguments[@]}")
			fi
			clear
			echo "Creating an image..."
			launch_wrapper "${compression_command[@]}"
			if [ "${init_size}" -gt 0 ]; then
				tail -c +$((init_size+bash_size+1)) "${script}" | head -c "${script_size}" > conty-start.sh
			else
				head -c "${script_size}" "${script}" > conty-start.sh
			fi
			tail -c +$((init_size+bash_size+script_size+busybox_size+1)) "${script}" | head -c "${utils_size}" > utils.tar.gz
			clear
			echo "Combining everything into a single executable..."
			cat "${working_dir}"/utils/init "${working_dir}"/utils/bash \
				conty-start.sh "${working_dir}"/utils/busybox utils.tar.gz \
				image > conty_updated.sh
			chmod +x conty_updated.sh
			mv -f "${script}" "${script}".old."${script_md5}" 2>/dev/null
			mv -f conty_updated.sh "${script}" 2>/dev/null || move_failed=1
			fusermount"${fuse_version}" -uz "${overlayfs_dir}"/merged 2>/dev/null || \
			umount --lazy "${overlayfs_dir}"/merged 2>/dev/null
			chmod -R 700 "${overlayfs_dir}"
			rm -rf "${overlayfs_dir}" "${conty_update_temp_dir}"
			clear
			echo "Conty has been updated!"
			if [ "${move_failed}" = 1 ]; then
				echo
				echo "Replacing ${script} with the new one failed!"
				echo
				echo "You can find conty_updated.sh in the current working"
				echo "directory or in your HOME."
			fi
		else
			echo "Failed to mount unionfs"
			echo "Cannot update Conty"
		fi
		exit
	fi
	if [ "${NVIDIA_HANDLER}" = 1 ]; then
		if [ -f /sys/module/nvidia/version ]; then
			unset NVIDIA_SHARED
			if [ ! "$(ls "${mount_point}"/usr/lib/libGLX_nvidia.so.*.* 2>/dev/null)" ]; then
				export overlayfs_dir="${overlayfs_shared_dir}"
				export nvidia_drivers_dir="${nvidia_drivers_shared_dir}"
				export NVIDIA_SHARED=1
			fi
			if [ -f "${nvidia_drivers_dir}"/lock ]; then
				echo "Nvidia driver is currently installing"
				echo "Please wait a moment and run Conty again"
				exit 1
			fi
			if mount_overlayfs; then
				show_msg "Nvidia driver handler is enabled"
				unset nvidia_skip_install
				unset nvidia_driver_version
				nvidia_driver_version="$(cat /sys/module/nvidia/version)"
				if [ "$(ls "${mount_point}"/usr/lib/libGLX_nvidia.so.*.* 2>/dev/null)" ]; then
					container_nvidia_version="$(basename "${mount_point}"/usr/lib/libGLX_nvidia.so.*.* | tail -c +18)"
				fi
				if [ -f "${nvidia_drivers_dir}"/current-nvidia-version ] && \
					[ ! "$(ls "${overlayfs_dir}"/up 2>/dev/null)" ]; then
					rm -f "${nvidia_drivers_dir}"/current-nvidia-version
				fi
				if [ -z "${nvidia_driver_version}" ] || [ "${nvidia_driver_version}" = "" ]; then
					echo "Unable to determine Nvidia driver version"
					rm -f "${nvidia_drivers_dir}"/current-nvidia-version
					nvidia_skip_install=1
				fi
				if [ "${nvidia_driver_version}" = "${container_nvidia_version}" ]; then
					rm -f "${nvidia_drivers_dir}"/current-nvidia-version
					nvidia_skip_install=1
				fi
				if [ "$(cat "${nvidia_drivers_dir}"/current-nvidia-version 2>/dev/null)" = "${nvidia_driver_version}" ]; then
					nvidia_skip_install=1
				fi
				if [ -z "${nvidia_skip_install}" ]; then
					mkdir -p "${nvidia_drivers_dir}"
					echo > "${nvidia_drivers_dir}"/lock
					export nvidia_driver_version
					export -f nvidia_driver_handler
					DISABLE_NET=0 QUIET_MODE=1 RW_ROOT=1 run_bwrap --tmpfs /tmp --tmpfs /var --tmpfs /run \
					--bind "${nvidia_drivers_dir}" "${nvidia_drivers_dir}" \
					bash -c nvidia_driver_handler
					rm -f "${nvidia_drivers_dir}"/lock
				fi
				if [ -n "${NVIDIA_SHARED}" ]; then
					fusermount"${fuse_version}" -uz "${overlayfs_dir}"/merged 2>/dev/null || \
					umount --lazy "${overlayfs_dir}"/merged 2>/dev/null
					rm -f "${overlayfs_shared_dir}"/up/etc/ld.so.cache
					export overlayfs_dir="${HOME}"/.local/share/Conty/overlayfs_"${script_md5}"
					export nvidia_drivers_dir="${overlayfs_dir}"/nvidia
					mount_overlayfs share_nvidia
					if [ "$(cat "${nvidia_drivers_dir}"/ld.so.cache.nvidia 2>/dev/null)" != "${nvidia_driver_version}" ]; then
						QUIET_MODE=1 RW_ROOT=1 run_bwrap ldconfig
						echo "${nvidia_driver_version}" > "${nvidia_drivers_dir}"/ld.so.cache.nvidia
					fi
				fi
			else
				echo "Nvidia driver handler disabled due to unionfs errors"
				unset NVIDIA_HANDLER
			fi
		else
			unset NVIDIA_HANDLER
		fi
		if [ -z "${NVIDIA_SHARED}" ] && [ ! -f "${nvidia_drivers_dir}"/current-nvidia-version ]; then
			unset NVIDIA_HANDLER
		fi
	fi
	if [ "${USE_OVERLAYFS}" = 1 ]; then
		if mount_overlayfs; then
			show_msg "Using unionfs"
			RW_ROOT=1
		else
			echo "Failed to mount unionfs"
			unset USE_OVERLAYFS
		fi
	fi
	if [ "${SANDBOX}" = 1 ] && [ -n "${SANDBOX_LEVEL}" ] && [ "${SANDBOX_LEVEL}" -ge 3 ]; then
		if [ -f "${mount_point}"/usr/bin/Xephyr ]; then
			if [ -z "${XEPHYR_SIZE}" ]; then
				XEPHYR_SIZE="800x600"
			fi
			xephyr_display="$((script_id+2))"
			if [ -S /tmp/.X11-unix/X"${xephyr_display}" ]; then
				xephyr_display="$((script_id+10))"
			fi
			QUIET_MODE=1 DISABLE_NET=1 SANDBOX_LEVEL=2 run_bwrap \
			--bind-try /tmp/.X11-unix /tmp/.X11-unix \
			Xephyr -noreset -ac -br -screen "${XEPHYR_SIZE}" :"${xephyr_display}" &>/dev/null & sleep 1
			xephyr_pid=$!
			QUIET_MODE=1 run_bwrap openbox & sleep 1
		else
			echo "SANDBOX_LEVEL is set to 3, but Xephyr is not present inside the container."
			echo "Xephyr is required for this SANDBOX_LEVEL."
			exit 1
		fi
	fi
	if [ -n "${script_is_symlink}" ] && [ -f "${mount_point}"/usr/bin/"${script_name}" ]; then
		export CUSTOM_PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/jvm/default/bin"
		show_msg "Autostarting ${script_name}"
		run_bwrap "${script_name}" "$@"
	elif [ "$1" = "-g" ] || ([ ! -t 0 ] && [ -z "${1}" ] && [ -z "${script_is_symlink}" ]); then
		export -f gui
		run_bwrap bash -c gui
	else
		run_bwrap "$@"
	fi
	if [ -n "${xephyr_pid}" ]; then
		wait "${xephyr_pid}"
	fi
else
	echo "Mounting the image failed!"
	exit 1
fi
exit

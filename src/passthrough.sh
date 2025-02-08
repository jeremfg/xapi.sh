# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Configures PCI passthrough for peripherals that will be passed through VMs

# Configure PCI passthrough. PCI devices must be of the "XX:YY.ZZ" format
#
# Parameters:
#   $@: PCI devices to passthrough
# Returns:
#   0: Success
#   1: Failure
#   2: Reboot required
passthrough_pci_configure() {
  local pciback_arg

  for pci in "${@}"; do
    local desc
    desc=$(lspci -s "${pci}")
    logInfo "Configuring PCI passthrough for ${desc}"
    pciback_arg+="(0000:${pci})"
  done
  logTrace "Boot config: ${pciback_arg}"

  local cur
  if ! cur=$("/opt/xensource/libexec/xen-cmdline" --get-dom0 "xen-pciback.hide"); then
    logError "Failed to get current grub configuration"
    return 1
  elif [[ -z "${cur}" ]]; then
    logInfo "No current configuration found"
  elif [[ "${cur}" == "xen-pciback.hide=${pciback_arg}" ]]; then
    logInfo "Configuration already set"
    return 0
  fi

  # If we reach here, configuration is necessary
  if ! sudo "/opt/xensource/libexec/xen-cmdline" --set-dom0 "xen-pciback.hide=${pciback_arg}"; then
    logError "Failed to set configuration"
    return 1
  else
    logInfo "Pci passthrough configuration set"
    return 2
  fi
}

# Configure USB devices to they can be passed though to a VM
#
# Parameters:
#   $@: USB device names to passthrough
# Returns:
#   0: Success
#   1: Failure
passthrough_usb_configure() {
  local usb var_usb_vid var_usb_pid var_usb_sn scan_performed
  scan_performed=0

  # Make sure we have all the data we need
  for usb in "${@}"; do
    var_usb_vid="UDEV_VID_${usb}"
    var_usb_pid="UDEV_PID_${usb}"
    var_usb_sn="UDEV_SN_${usb}"

    if [[ -z "${!var_usb_vid}" ]]; then
      logError "Missing VID for ${usb}"
      return 1
    elif [[ -z "${!var_usb_pid}" ]]; then
      logError "Missing PID for ${usb}"
      return 1
    elif [[ -z "${!var_usb_sn}" ]]; then
      logError "Missing SN for ${usb}"
      return 1
    fi
  done

  # Load XE utilities
  # shellcheck disable=SC1091
  if ! source "${PI_ROOT}/src/xe_host.sh"; then
    logError "Failed to load xe_host.sh"
    return 1
  fi

  local vid pid sn usb_output
  for usb in "${@}"; do
    var_usb_vid="UDEV_VID_${usb}"
    var_usb_pid="UDEV_PID_${usb}"
    var_usb_sn="UDEV_SN_${usb}"
    vid="${!var_usb_vid}"
    pid="${!var_usb_pid}"
    sn="${!var_usb_sn}"

    # Find out if the USB device is plugged in
    if ! usb_output=$(lsusb -d "${vid}:${pid}"); then
      logError "Failed to list USB devices with VID:PID ${vid}:${pid}"
      return 1
    elif [[ -z "${usb_output}" ]]; then
      logError "USB device not found: ${usb}"
      return 1
    fi

    # Iterate over each line of lsusb to find the correct device
    local line bus device udevadm_output cur_sn res
    cur_sn=""
    while IFS= read -r line; do
      # Extract bus and device number
      bus=$(echo "${line}" | cut -d' ' -f2)
      device=$(echo "${line}" | cut -d' ' -f4 | cut -d':' -f1 || true)
      if [[ -z "${bus}" ]] || [[ -z "${device}" ]]; then
        logError "Failed to extract bus and device number"
        return 1
      fi

      # Get the serial number
      if ! udevadm_output=$(udevadm info --query=all "--name=/dev/bus/usb/${bus}/${device}"); then
        logError "Failed to get udevadm info for ${bus}:${device}"
        return 1
      elif [[ -z "${udevadm_output}" ]]; then
        logError "udevadm info not found for ${bus}:${device}"
        return 1
      fi

      cur_sn=$(echo "${udevadm_output}" | grep "ID_SERIAL_SHORT=" | cut -d'=' -f2 || true)
      if [[ -z "${cur_sn}" ]]; then
        logError "Failed to extract serial number for ${bus}:${device}"
        return 1
      fi

      if [[ "${cur_sn}" == "${sn}" ]]; then
        logInfo "Found USB device: ${usb}"
        break
      else
        logWarn "Found a similar USB device to ${usb}, but with serial number ${cur_sn}"
        cur_sn=""
      fi
    done <<<"${usb_output}"

    if [[ -z "${cur_sn}" ]]; then
      logError "Failed to find USB device: ${usb}"
      return 1
    fi

    logInfo <<EOF
USB device ${usb} found:
  VID   : ${vid}
  PID   : ${pid}
  SN    : ${sn}
  Bus   : ${bus}
  Device: ${device}
EOF

    # Check if Xen sees the USB device
    while true; do
      local xen_usb_output
      if ! xe_exec xen_usb_output pusb-list "vendor-id=${vid}" "product-id=${pid}" "serial=${sn}"; then
        logError "Failed to list USB devices in Xen"
        return 1
      elif [[ -n "${xen_usb_output}" ]]; then
        logInfo "USB device is visible to Xen: ${usb}"
        break
      else
        logWarn "USB device is not visible to Xen: ${usb}"
      fi

      # If we reach here, the USB device is not visible to Xen.
      # Try to configure USB policies if not already configured
      local policy
      policy="ALLOW:vid=${vid} pid=${pid} # Edited by scripts"
      if ! grep -q "${policy}" "${USB_POLICY_FILE}"; then
        logInfo "USB policy not found for ${usb}, adding it"
        # Add policy as the first line that is not a comment
        if ! sed -i "/^[^#]/i ${policy}" "${USB_POLICY_FILE}"; then
          logError "Failed to add USB policy for ${usb}"
          return 1
        else
          scan_performed=0
          logTrace "USB policy added for ${usb}"
        fi
      else
        logInfo "USB policy found for ${usb}"
        if [[ ${scan_performed} -eq 1 ]]; then
          logError "Unable to list USB device in xen: ${usb}"
          return 1
        else
          logInfo "Scanning for USB devices in Xen"
          if ! xe_host_current res; then
            logError "Failed to get current host"
            return 1
          elif ! xe_exec res pusb-scan "host-uuid=${res}"; then
            logError "Failed to scan for USB devices in Xen"
            return 1
          else
            scan_performed=1
          fi
        fi
      fi
    done

    # If we reach here, the USB device is visible to Xen
    # Make sure passthrough is enabled for it
    local usb_uuid p_enabled
    if ! xe_exec usb_uuid pusb-list "vendor-id=${vid}" "product-id=${pid}" "serial=${sn}" --minimal; then
      logError "Failed to get USB UUID"
      return 1
    elif [[ -z "${usb_uuid}" ]]; then
      logError "USB not found: ${usb}"
      return 1
    fi

    if ! xe_exec p_enabled pusb-param-get "uuid=${usb_uuid}" "param-name=passthrough-enabled"; then
      logError "Failed to get passthrough-enabled"
      return 1
    elif [[ "${p_enabled}" == "true" ]]; then
      logInfo "Passthrough already enabled for ${usb}"
    elif [[ "${p_enabled}" == "false" ]]; then
      logInfo "Enabling passthrough for ${usb}"

      if ! xe_exec res pusb-param-set "uuid=${usb_uuid}" "passthrough-enabled=true"; then
        logError "Failed to enable passthrough for ${usb}"
        return 1
      fi
    else
      logError "Unknown value for passthrough-enabled: ${p_enabled}"
      return 1
    fi
    # If we reach here, all is good for our device, move on to the next one
  done

  # If we reach here, it means all USB devices are configured properly
  return 0
}

# Constants
USB_POLICY_FILE="/etc/xensource/usb-policy.conf"

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
PI_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${PI_SOURCE}" ]]; do # resolve $PI_SOURCE until the file is no longer a symlink
  PI_ROOT=$(cd -P "$(dirname "${PI_SOURCE}")" >/dev/null 2>&1 && pwd)
  PI_SOURCE=$(readlink "${PI_SOURCE}")
  [[ ${PI_SOURCE} != /* ]] && PI_SOURCE=${PI_ROOT}/${PI_SOURCE} # if $PI_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
PI_ROOT=$(cd -P "$(dirname "${PI_SOURCE}")" >/dev/null 2>&1 && pwd)
PI_ROOT=$(realpath "${PI_ROOT}/../..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  logFatal "This script cannot be piped"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  logFatal "This script cannot be executed"
fi

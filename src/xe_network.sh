# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng network configuration

if [[ -z ${GUARD_XE_NETWORK_SH} ]]; then
  GUARD_XE_NETWORK_SH=1
else
  return 0
fi

# Checks if the provided NICs exists
#
# Parameters:
#   $@[in]: NICs to validate
# Returns:
#   0: If all NICs are valid
#   1: If any NIC is invalid
xe_validate_nic() {
  local _macs=("$@")

  local HOST_ID
  if ! xe_current_host HOST_ID; then
    logError "Failed to get host"
    return 1
  fi

  # Force a rescan of interfaces
  local res
  if ! xe_exec res pif-scan host-uuid="${HOST_ID}"; then
    logError "Failed to scan for PIFs: ${res}"
    return 1
  fi

  local mac
  for mac in "${_macs[@]}"; do
    logTrace "Checking if a NIC with MAC address ${mac} exists"
    if ! xe_identify_nic "${mac}"; then
      logError "NIC with MAC ${mac} not found"
      return 1
    else
      local details
      xe_join_params details
      logInfo <<EOF
==== NIC ${xe_params_array['device']} found ====${details}
EOF
    fi
  done

  return 0
}

# Perform lookup of a NIC from it's MAC address
#
# Parameters:
#   $1[in]: MAC address to lookup
xe_identify_nic() {
  local _mac="$1"

  local res
  if ! xe_exec res pif-list MAC="${_mac}"; then
    logError "Failed to execute search"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "NIC not found"
    return 1
  else
    xe_parse_params "${res}"
    return 0
  fi
}

# Constants
if [[ -z ${XE_LOGIN} ]]; then
  XE_LOGIN=""
fi

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
XN_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XN_SOURCE}" ]]; do # resolve $XN_SOURCE until the file is no longer a symlink
  XN_ROOT=$(cd -P "$(dirname "${XN_SOURCE}")" >/dev/null 2>&1 && pwd)
  XN_SOURCE=$(readlink "${XN_SOURCE}")
  [[ ${XN_SOURCE} != /* ]] && XN_SOURCE=${XN_ROOT}/${XN_SOURCE} # if $XN_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XN_ROOT=$(cd -P "$(dirname "${XN_SOURCE}")" >/dev/null 2>&1 && pwd)
XN_ROOT=$(realpath "${XN_ROOT}/..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
# shellcheck disable=SC1091 # Ignore non-constant source
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "ERROR: Failed to load slf4.sh"
  exit 1
fi
# shellcheck source=src/xe_host.sh
if ! source "${XN_ROOT}/src/xe_host.sh"; then
  logFatal "Failed to load xe_host.sh"
fi
# shellcheck source=src/xe_utils.sh
if ! source "${XN_ROOT}/src/xe_utils.sh"; then
  logFatal "Failed to load xe_utils.sh"
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

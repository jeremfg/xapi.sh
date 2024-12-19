# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script handles SR management on a XCP-ng host

if [[ -z ${GUARD_XE_STORAGE_SH} ]]; then
  GUARD_XE_STORAGE_SH=1
else
  return 0
fi

# Retrive the UUID of the SR by name
#
# Parameters:
#   $1[out]: The UUID of the SR
#   $2[in]: The name of the SR
# Returns:
#   0: If the SR was found
#   1: If an error occured
#   2: If the SR wasn't found
xe_stor_uuid_by_name() {
  local __sr_uuid="$1"
  local __sr_name="$2"
  local __res

  if ! xe_exec __res sr-list name-label="${__sr_name}" params=uuid --minimal; then
    logError "Failed to list SRs: ${__res}"
    return 1
  elif [[ -n "${__res}" ]]; then
    logInfo "SR ${__sr_name} found"
    eval "${__sr_uuid}='${__res}'"
    return 0
  fi

  logInfo "SR ${__sr_name} not found"
  return 2
}

# Create a new LVM SR, if one of the same name doesn't exists
#
# Parameters:
#   $1[out]: The UUID of the created SR
#   $2[in]: The name of the SR
#   $3[in]: The device to use for the SR
# Returns:
#   0: If the SR was created or already exists
#   1: If the SR couldn't be created
xe_stor_create_lvm() {
  local _sr_uuid="$1"
  local _sr_name="$2"
  local _device="$3"
  local _res

  local _host_id
  if ! xe_current_host _host_id; then
    logError "Failed to get host"
    return 1
  fi

  xe_stor_uuid_by_name "${_sr_uuid}" "${_sr_name}"
  _res=$?
  case ${_res} in
  0)
    return 0
    ;;
  1)
    return 1
    ;;
  2)
    : # Continue, will be created
    ;;
  *)
    logError "Unexpected return code: ${_res}"
    return 1
    ;;
  esac

  if ! xe_exec _res sr-create content-type=user device-config:device="/dev/${_device}" host-uuid="${_host_id}" name-label="${_sr_name}" shared=false type=lvm; then
    logError "Failed to create SR ${_sr_name}: ${_res}"
    return 1
  else
    logInfo "SR ${_sr_name} created: ${_res}"
  fi

  xe_stor_uuid_by_name "${_sr_uuid}" "${_sr_name}"
  _res=$?
  case ${_res} in
  0)
    return 0
    ;;
  1)
    :
    ;;
  2)
    logError "SR ${_sr_name} should have been found after creation"
    ;;
  *)
    logError "Unexpected return code: ${_res}"
    ;;
  esac

  return 1
}

# Create a new ISO SR, if one of the same name doesn't exists
#
# Parameters:
#   $1[out]: The UUID of the created SR
#   $2[in]: The name of the SR
#   $3[in]: The path to the ISOs
# Returns:
#   0: If the SR was created or already exists
#   1: If the SR couldn't be created
xe_stor_create_iso() {
  local _sr_uuid="$1"
  local _sr_name="$2"
  local _path="$3"
  local _res

  local _host_id
  if ! xe_current_host _host_id; then
    logError "Failed to get host"
    return 1
  fi

  xe_stor_uuid_by_name "${_sr_uuid}" "${_sr_name}"
  _res=$?
  case ${_res} in
  0)
    return 0
    ;;
  1)
    return 1
    ;;
  2)
    : # Continue, will be created
    ;;
  *)
    logError "Unexpected return code: ${_res}"
    return 1
    ;;
  esac

  if ! xe_exec _res sr-create content-type=iso device-config:location="${_path}" device-config:legacy_mode=true host-uuid="${_host_id}" name-label="${_sr_name}" shared=true type=iso; then
    logError "Failed to create SR ${_sr_name}: ${_res}"
    return 1
  else
    logInfo "SR ${_sr_name} created: ${_res}"
  fi

  xe_stor_uuid_by_name "${_sr_uuid}" "${_sr_name}"
  _res=$?
  case ${_res} in
  0)
    return 0
    ;;
  1)
    :
    ;;
  2)
    logError "SR ${_sr_name} should have been found after creation"
    ;;
  *)
    logError "Unexpected return code: ${_res}"
    ;;
  esac

  return 1
}

# Plug an existing SR by name
#
# Parameters:
#   $1[in]: The name of the SR
# Returns:
#   0: If the SR was plugged
#   1: If the SR couldn't be plugged
xe_stor_plug() {
  local _sr_name="$1"
  local _sr_uuid
  local _pbd_uuid
  local _res

  if ! xe_stor_uuid_by_name _sr_uuid "${_sr_name}"; then
    logError "Failed to get UUID of SR ${_sr_name}"
    return 1
  elif [[ -z "${_sr_uuid}" ]]; then
    logError "No SR found with name ${_sr_name}"
    return 1
  elif ! xe_exec _pbd_uuid pbd-list sr-uuid="${_sr_uuid}" --minimal; then
    logError "Failed to get PBD of SR ${_sr_name}: ${_pbd_uuid}"
    return 1
  elif [[ -z "${_pbd_uuid}" ]]; then
    logError "No PBD found for SR ${_sr_name}"
    return 1
  elif ! xe_exec _res pbd-param-get uuid="${_pbd_uuid}" param-name=currently-attached --minimal; then
    logError "Failed to get state of SR ${_sr_name}: ${_res}"
    return 1
  elif [[ "${_res}" == "true" ]]; then
    logInfo "SR ${_sr_name} already plugged"
    return 0
  fi

  if ! xe_exec _res pbd-plug uuid="${_pbd_uuid}"; then
    logError "Failed to plug SR ${_sr_name}: ${_res}"
    return 1
  elif ! xe_exec _res pbd-param-get uuid="${_pbd_uuid}" param-name=currently-attached --minimal; then
    logError "Failed to get state of SR ${_sr_name}: ${_res}"
    return 1
  elif [[ "${_res}" == "true" ]]; then
    logInfo "SR ${_sr_name} plugged successfully"
    return 0
  else
    logInfo "Could not plug SR ${_sr_name}: ${_res}"
  fi

  return 1
}

# Unplug an existing SR by name
#
# Parameters:
#   $1[in]: The name of the SR
# Returns:
#   0: If the SR was unplugged
#   1: If the SR couldn't be unplugged
xe_stor_unplug() {
  local _sr_name="$1"
  local _sr_uuid
  local _pbd_uuid
  local _res

  if ! xe_stor_uuid_by_name _sr_uuid "${_sr_name}"; then
    logError "Failed to get UUID of SR ${_sr_name}"
    return 1
  elif [[ -z "${_sr_uuid}" ]]; then
    logError "No SR found with name ${_sr_name}"
    return 1
  elif ! xe_exec _pbd_uuid pbd-list sr-uuid="${_sr_uuid}" --minimal; then
    logError "Failed to get PBD of SR ${_sr_name}: ${_pbd_uuid}"
    return 1
  elif [[ -z "${_pbd_uuid}" ]]; then
    logError "No PBD found for SR ${_sr_name}"
    return 1
  elif ! xe_exec _res pbd-param-get uuid="${_pbd_uuid}" param-name=currently-attached --minimal; then
    logError "Failed to get state of SR ${_sr_name}: ${_res}"
    return 1
  elif [[ "${_res}" == "true" ]]; then
    logInfo "SR ${_sr_name} needs to be unplugged"
  else
    logInfo "SR ${_sr_name} already unplugged"
    return 0
  fi

  if ! xe_exec _res pbd-unplug uuid="${_pbd_uuid}"; then
    logError "Failed to unplug SR ${_sr_name}: ${_res}"
    return 1
  else
    logInfo "SR ${_sr_name} unplugged: ${_res}"
  fi

  return 0
}

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
XS_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XS_SOURCE}" ]]; do # resolve $XS_SOURCE until the file is no longer a symlink
  XS_ROOT=$(cd -P "$(dirname "${XS_SOURCE}")" >/dev/null 2>&1 && pwd)
  XS_SOURCE=$(readlink "${XS_SOURCE}")
  [[ ${XS_SOURCE} != /* ]] && XS_SOURCE=${XS_ROOT}/${XS_SOURCE} # if $XS_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XS_ROOT=$(cd -P "$(dirname "${XS_SOURCE}")" >/dev/null 2>&1 && pwd)
XS_ROOT=$(realpath "${XS_ROOT}/..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck source=src/xe_host.sh
if ! source "${XS_ROOT}/src/xe_host.sh"; then
  logFatal "Failed to load xe_host.sh"
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

# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script handles SR management on a XCP-ng host

if [[ -z ${GUARD_XE_STORAGE_SH} ]]; then
  GUARD_XE_STORAGE_SH=1
else
  return 0
fi

# Find a local SR matching the provided characteristics
#
# Parameters:
#   $1[out]: The UUID of the found SR
#   $2[in]: The type of the SR to search for
#   $3[in]: The content-type of the SR to search for
# Returns:
#   0: If the SR was found
#   1: If an error occured
#   2: If the SR wasn't found
xe_stor_local_find() {
  local __result_sr_uuid="${1}"
  local _type="${2}"
  local _content_type="${3}"

  local _res _cmd host_uuid host_name
  if ! xe_host_current host_uuid; then
    logError "Failed to get host"
    return 1
  elif [[ -z "${host_uuid}" ]]; then
    logError "No host found"
    return 1
  elif ! xe_exec host_name host-list uuid="${host_uuid}" params=name-label --minimal; then
    logError "Failed to get host name: ${host_name}"
    return 1
  elif [[ -z "${host_name}" ]]; then
    logError "No host name found"
    return 1
  elif ! xe_exec _res sr-list host="${host_name}" type="${_type}" content-type="${_content_type}" --minimal; then
    logError "Failed to list SRs: ${_res}"
    return 1
  elif [[ -z "${_res}" ]]; then
    logWarn "No SR found"
    return 2
  elif [[ "${_res}" == *","* ]]; then
    logWarn "Multiple SRs found"
    return 1
  else
    eval "${__result_sr_uuid}='${_res}'"
    logInfo "SR ${_res} found"
    return 0
  fi  
}

# Rename the specified SR
#
# Parameters:
#   $1[in]: The UUID of the SR
#   $2[in]: The new name of the SR
# Returns:
#   0: If the SR now bears the desired name
#   1: If an error occured
xe_stor_rename() {
  local _sr_uuid="${1}"
  local _new_name="${2}"
  local _res

  if [[ -z "${_new_name}" ]]; then
    logError "New name not specified"
    return 1
  elif [[ -z "${_sr_uuid}" ]]; then
    logError "SR not specified"
    return 1
  fi

  # Get the current name, changing it only if it's different
  if ! xe_exec _res sr-param-get uuid="${_sr_uuid}" param-name=name-label --minimal; then
    logError "Failed to get name of SR ${_sr_uuid}: ${_res}"
    return 1
  elif [[ "${_res}" == "${_new_name}" ]]; then
    logInfo "SR ${_sr_uuid} already named ${_new_name}"
    return 0
  elif ! xe_exec _res sr-param-set uuid="${_sr_uuid}" name-label="${_new_name}"; then
    logError "Failed to rename SR ${_sr_uuid} to ${_new_name}: ${_res}"
    return 1
  else
    logInfo "SR ${_sr_uuid} renamed to ${_new_name}"
  fi

  return 0  
}

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
  local __result_sr_uuid="$1"
  local __sr_name="$2"
  local __res

  if ! xe_exec __res sr-list name-label="${__sr_name}" params=uuid --minimal; then
    logError "Failed to list SRs: ${__res}"
    return 1
  elif [[ -n "${__res}" ]]; then
    logInfo "SR ${__sr_name} found"
    eval "${__result_sr_uuid}='${__res}'"
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
  if ! xe_host_current _host_id; then
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
  if ! xe_host_current _host_id; then
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

# Create a new udev SR, if one of the same name doesn't exists
#
# Parameters:
#   $1[out]: The UUID of the created SR
#   $2[in]: The name of the SR
#   $3[in]: The directory where the SR will find device simlinks
# Returns:
#   0: If the SR was created or already exists
#   1: If the SR couldn't be created
xe_stor_create_udev() {
  local __result_sr_uuid="${1}"
  local __sr_name="${2}"
  local __path="${3}"

  if [[ -z "${__sr_name}" ]]; then
    logError "SR not specified"
    return 1
  elif [[ -z "${__path}" ]]; then
    logError "Path not specified"
    return 1
  elif [[ ! -d "${__path}" ]]; then
    logError "Path does not exist: ${__path}"
    return 1
  fi

  local _host_id _res _cmd
  if ! xe_host_current _host_id; then
    logError "Failed to get host"
    return 1
  fi
  xe_stor_uuid_by_name "${__result_sr_uuid}" "${__sr_name}"
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

  _cmd=(sr-create name-label="${__sr_name}" "type=udev")
  _cmd+=("content-type=disk" "device-config:location=${__path}")
  _cmd+=("host-uuid=${_host_id}")
  if ! xe_exec _res "${_cmd[@]}"; then
    logError "Failed to create SR ${__sr_name}: ${_res}"
    return 1
  else
    logInfo "SR ${__sr_name} created: ${_res}"
  fi

  xe_stor_uuid_by_name "${__result_sr_uuid}" "${__sr_name}"
  _res=$?
  case ${_res} in
  0)
    return 0
    ;;
  1)
    :
    ;;
  2)
    logError "SR ${__sr_name} should have been found after creation"
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
    if ! xe_stor_refresh "${_sr_name}"; then
      logError "Failed to refresh SR ${_sr_name}"
      return 1
    fi
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

# Rescan the content of the SR
#
# Parameters:
#   $1[in]: The name of the SR
# Returns:
#   0: If the SR was refreshed
#   1: If the SR couldn't be refreshed
xe_stor_refresh() {
  local _sr_name="$1"
  local _sr_uuid _res

  if ! xe_stor_uuid_by_name _sr_uuid "${_sr_name}"; then
    logError "Failed to get UUID of SR ${_sr_name}"
    return 1
  elif [[ -z "${_sr_uuid}" ]]; then
    logError "No SR found with name ${_sr_name}"
    return 1
  fi

  if ! xe_exec _res sr-scan uuid="${_sr_uuid}"; then
    logError "Failed to refresh SR ${_sr_name}: ${_res}"
    return 1
  else
    logInfo "SR ${_sr_name} refreshed: ${_res}"
  fi

  return 0
}

# Retrieve the list of VDI UUIDs for a given store
#
# Parameters:
#   $1[out]: The list of VDI UUIDs
#   $2[in]: The name of the store
# Returns:
#   0: If the list was found
#   1: If the list couldn't be found
xe_stor_vdis() {
  local __result_vdis="$1"
  local _sr_name="$2"

  local _sr_uuid _res _vdis
  if ! xe_stor_uuid_by_name _sr_uuid "${_sr_name}"; then
    logError "Failed to get UUID of SR ${_sr_name}"
    return 1
  elif [[ -z "${_sr_uuid}" ]]; then
    logError "No SR found with name ${_sr_name}"
    return 1
  fi

  if ! xe_exec _vdis vdi-list sr-uuid="${_sr_uuid}" --minimal; then
    logError "Failed to list VDIs of SR ${_sr_name}: ${_vdis}"
    return 1
  elif [[ -z "${_vdis}" ]]; then
    logWarn "No VDIs found in SR ${_sr_name}"
    eval "${__result_vdis}=()"
    return 0
  fi
  IFS=',' read -r -a _vdis <<<"${_vdis}"
  eval "${__result_vdis}=(\"\${_vdis[@]}\")"
  return 0
}

# Rename an existing disk
#
# Parameters:
#   $1[in]: The UUID of the disk
#   $2[in]: The new name of the disk
# Returns:
#   0: If the disk was renamed or its name was already the same
#   1: If the disk couldn't be renamed
xe_disk_rename() {
  local _disk_uuid="$1"
  local _new_name="$2"
  local _res

  if ! xe_exec _res vdi-param-get uuid="${_disk_uuid}" param-name=name-label --minimal; then
    logError "Failed to get name of disk ${_disk_uuid}: ${_res}"
    return 1
  elif [[ "${_res}" == "${_new_name}" ]]; then
    logInfo "Disk ${_disk_uuid} already named ${_new_name}"
    return 0
  fi

  if ! xe_exec _res vdi-param-set uuid="${_disk_uuid}" name-label="${_new_name}"; then
    logError "Failed to rename disk ${_disk_uuid} to ${_new_name}: ${_res}"
    return 1
  else
    logInfo "Disk ${_disk_uuid} renamed to ${_new_name}"
  fi

  return 0
}

# Create a new disk
#
# Parameters:
#   $1[out]: The UUID of the created disk
#   $2[in]: The name of the disk
#   $3[in]: The size of the disk (in Bytes)
#   $4[in]: The SR UUID to store the disk
# Returns:
#   0: If the disk was created
#   1: If the disk couldn't be created
xe_disk_create() {
  local __result_disk_uuid="$1"
  local _disk_name="$2"
  local _disk_size="$3"
  local _sr_uuid="$4"

  local _res _cmd vdis vdi vdbs vdb
  # First, check if we have a disk of that name already
  if ! xe_exec vdis vdi-list sr-uuid="${_sr_uuid}" name-label="${_disk_name}" --minimal; then
    logError "Failed to list disks: ${vdis}"
    return 1
  elif [[ -n "${vdis}" ]]; then
    # Check if this disk is already attached to a VM or orphaned
    IFS=',' read -r -a vdis <<<"${vdis}"
    for vdi in "${vdis[@]}"; do
      if ! xe_exec vdbs vbd-list vdi-uuid="${vdi}" --minimal; then
        logError "Failed to list VBDs: ${vdbs}"
        return 1
      elif [[ -n "${vdbs}" ]]; then
        IFS=',' read -r -a vdbs <<<"${vdbs}"
        for vdb in "${vdbs[@]}"; do
          if ! xe_exec _res vbd-param-get uuid="${vdb}" param-name=currently-attached --minimal; then
            logError "Failed to get VBD state: ${_res}"
            return 1
          elif [[ "${_res}" == "true" ]]; then
            logWarn "Disk ${_disk_name} is already attached to a VM. Ignoring..."
          else
            logError <<EOF
We found a drive that is associated with a VDB, but not attached to a VM.
This is a situation where we might be able to do something clever to re-use
that disk. To be explored in the future if this corner case ever presents itself.
If only to handle it better than with an error like today. Here is the output received:
${_res}
EOF
            return 1
          fi
        done
      else
        logWarn "Disk ${_disk_name} is orphaned. We found what we wanted"
        eval "${__result_disk_uuid}='${vdi}'"
        return 0
      fi
    done
  else
    logInfo "Disk ${_disk_name} does not exist. Creating..."
  fi

  # If we reached here, we need to create a disk
  _cmd=("vdi-create" "name-label=${_disk_name}" "sr-uuid=${_sr_uuid}")
  _cmd+=("virtual-size=${_disk_size}" "--minimal")
  if ! xe_exec _res "${_cmd[@]}"; then
    logError "Failed to create disk ${_disk_name}: ${_res}"
    return 1
  elif [[ -z "${_res}" ]]; then
    logError "Disk ${_disk_name} not returned creation"
    return 1
  else
    logInfo "Disk ${_disk_name} created: ${_res}"
  fi

  eval "${__result_disk_uuid}='${_res}'"
  return 0
}

# Find the UUID of a ISO by its name
#
# Parameters:
#   $1[out]: The UUID of the ISO
#   $2[in]: The name of the ISO
# Returns:
#   0: If the ISO was found
#   1: If an error occured
#   2; The ISO does not exist
xe_iso_uuid_by_name() {
  local __result_iso_uuid="$1"
  local _iso_name="$2"

  local _res _cmd cd_uuid cd_name line
  if ! xe_exec _res cd-list; then
    logError "Failed to list ISOs: ${_res}"
    return 1
  elif [[ -z "${_res}" ]]; then
    logError "No ISO found"
    return 1
  fi

  while IFS= read -r line; do
    local _key _value
    if ! xe_read_param _key _value "${line}"; then
      logTrace "Failed to parse line: ${line}"
      continue
    elif [[ "${_key}" == "uuid" ]]; then
      cd_uuid="${_value}"
    elif [[ "${_key}" == "name-label" ]]; then
      cd_name="${_value}"
      # We rely on the fact that the UUID will be set before the name
      if [[ "${cd_name}" == "${_iso_name}" ]]; then
        eval "${__result_iso_uuid}='${cd_uuid}'"
        logInfo "ISO ${_iso_name} found"
        return 0
      else
        logTrace "ISO ${cd_name} skipped"
      fi
    else
      logWarn "Unknown key: ${_key}"
      continue
    fi
  done <<<"${_res}"

  logError "ISO ${_iso_name} not found"
  return 2
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

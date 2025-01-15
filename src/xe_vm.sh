# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng virtual machine configuration

if [[ -z ${GUARD_XE_VM_SH} ]]; then
  GUARD_XE_VM_SH=1
else
  logWarn "Re-sourcing xe_vm.sh"
  return 0
fi

# Prepare a virtual machine for execution
#
# Parameters:
#   $1: VM name
#   $2: VM memory size in MiB
#   $3: VM VCPUs
#   $4: VM disk size in GiB
# Returns:
#   0: Success
#   1: Failure
#   2: VM already exists
xe_vm_prepare() {
  local vm_name="${1}"
  local vm_mem="${2}"
  local vm_vcpus="${3}"
  local vm_disk="${4}"

  local cmd res tmpl_uuid sr_uuid vm_uuid vdi_uuid is_new_vm
  is_new_vm=0

  # Validate provided values
  if [[ -z "${vm_name}" ]] || [[ -z "${vm_mem}" ]] || [[ -z "${vm_vcpus}" ]] || [[ -z "${vm_disk}" ]]; then
    logError "Invalid parameters"
    return 1
  elif [[ "${vm_mem}" -lt 256 ]] || [[ "${vm_mem}" -gt 65536 ]]; then
    logError "Invalid memory size: ${vm_mem}"
    return 1
  elif [[ "${vm_vcpus}" -lt 1 ]] || [[ "${vm_vcpus}" -gt 16 ]]; then
    logError "Invalid VCPUs count: ${vm_vcpus}"
    return 1
  elif [[ "${vm_disk}" -lt 1 ]] || [[ "${vm_disk}" -gt 1024 ]]; then
    logError "Invalid disk size: ${vm_disk}"
    return 1
  fi

  # Validate assumed values
  if [[ -z "${VM_SR}" ]]; then
    logError "Invalid parameters"
    return 1
  fi

  if ! xe_vm_template tmpl_uuid; then
    return 1
  elif ! xe_stor_uuid_by_name sr_uuid "${VM_SR}"; then
    return 1
  fi

  # Find or create the VM
  cmd=("vm-install" "new-name-label=${vm_name}" "params=uuid" "--minimal")
  cmd+=("template-uuid=${tmpl_uuid}" "sr-uuid=${sr_uuid}")
  if ! xe_exec vm_uuid vm_list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -n "${vm_uuid}" ]]; then
    logInfo "VM ${vm_name} already exists"
  elif ! xe_exec vm_uuid "${cmd[@]}"; then
    logError "VM ${vm_name} creation failed"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found after creation"
    return 1
  else
    is_new_vm=2
    logInfo "VM ${vm_name} created"
  fi

  # Check if that VM already has a disk
  local disks cur_uuid disk_id disk_name
  disk_id=0
  cmd=("vm-disk-list" "uuid=${vm_uuid}")
  cmd+=("vdi-params=uuid" "vbd-params=none" "--minimal")
  if ! xe_exec res "${cmd[@]}"; then
    logError "Failed to list disks for VM ${vm_name}"
    return 1
  elif [[ -n "${res}" ]]; then
    IFS=',' read -r -a disks <<<"${res}"
    logInfo "VM ${vm_name} already has ${#disks[@]} disk(s)"
    for cur_uuid in "${disks[@]}"; do
      disk_name="${vm_name}-disk-${disk_id}"
      if ! xe_disk_rename "${cur_uuid}" "${disk_name}"; then
        logError "Failed to rename disk ${disk_id}"
        return 1
      fi
      if ! xe_exec res vdi_list uuid="${cur_uuid}" params=virtual-size --minimal; then
        logError "Failed to get disk size for disk ${disk_id}"
        return 1
      elif [[ $((res / 1024 / 1024 / 1024)) -eq "${vm_disk}" ]]; then
        if [[ -z "${vdi_uuid}" ]]; then
          vdi_uuid="${cur_uuid}"
          logInfo "Disk found for VM ${vm_name}"
        else
          logWarn "Multiple disks with the same size detected. Ignoring ${cur_uuid}"
        fi
      else
        logInfo "Disk of size ${res} Bytes found attached to VM ${vm_name}"
      fi
      disk_id=$((disk_id + 1))
    done
    if [[ -z "${vdi_uuid}" ]]; then
      # Didn't find a match
      if [[ "${is_new_vm}" -eq 2 ]]; then
        if [[ ${#disks[@]} -eq 1 ]] && [[ -n "${cur_uuid}" ]]; then
          vdi_uuid="${cur_uuid}"
          logInfo "Disk found for new VM ${vm_name}"
        else
          # This condition should not happen
          logWarn "New VM ${vm_name} did not create a disk. We will create one"
        fi
      else
        if [[ ${#disks[@]} -eq 1 ]] && [[ -n "${cur_uuid}" ]]; then
          vdi_uuid="${cur_uuid}"
          logInfo "Only one disk found for existing VM ${vm_name}. Using it and change size"
        else
          logError "No suitable disk found for existing VM ${vm_name}"
          return 1
        fi
      fi
    fi
  else
    logInfo "No disks found for VM ${vm_name}. We will create one"
  fi

  # If we reach here and we don't have a disk, create it
  if [[ -z "${vdi_uuid}" ]]; then
    local vbd_id
    disk_name="${vm_name}-disk-${disk_id}"
    if ! xe_vm_vbd_next vbd_id "${vm_uuid}"; then
      return 1
    fi
    cmd=(vbd-create "vm-uuid=${vm_uuid}" "device=${vbd_id}")
    cmd+=("vdi-uuid=${vdi_uuid}" "type=Disk" "mode=RW" "--minimal")
    if ! xe_disk_create vdi_uuid "${disk_name}" "$((vm_disk * 1024 * 1024 * 1024))" "${sr_uuid}"; then
      logError "Failed to create disk for VM ${vm_name}"
      return 1
    elif ! xe_exec "${cmd[@]}"; then
      logError "Failed to attach disk to VM ${vm_name}"
      return 1
    else
      logInfo "Disk created and attached to VM ${vm_name}"
    fi
  fi

  # Handle disk size
  if ! xe_exec res vdi-param-get uuid="${vdi_uuid}" param-name=virtual-size --minimal; then
    logError "Failed to get disk size for disk ${vdi_uuid}"
    return 1
  elif [[ $((res / 1024 / 1024 / 1024)) -ne "${vm_disk}" ]]; then
    logInfo "Disk ${vdi_uuid} has size $((res / 1024 / 1024 / 1024)) GiB. Resizing"
    if ! xe_vm_shutdown "${vm_uuid}"; then
      logError "Failed to shutdown VM ${vm_name}"
      return 1
    elif ! xe_exec res vdi-resize uuid="${vdi_uuid}" disk-size="${vm_disk}GiB --minimal"; then
      logError "Failed to resize disk ${vdi_uuid} to ${vm_disk} GiB"
      return 1
    else
      logInfo "Disk ${vdi_uuid} resized to ${vm_disk} GiB"
    fi
  else
    logInfo "Disk ${vdi_uuid} already has size ${vm_disk} GiB"
  fi

  # Handle RAM
  local cur_min cur_max
  if ! xe_exec cur_max vm-param-get uuid="${vm_uuid}" param-name=memory-dynamic-max --minimal; then
    logError "Failed to get memory-dynamic-max for VM ${vm_name}"
    return 1
  elif ! xe_exec cur_min vm-param-get uuid="${vm_uuid}" param-name=memory-dynamic-min --minimal; then
    logError "Failed to get memory-dynamic-min for VM ${vm_name}"
    return 1
  fi
  if [[ $((cur_max / 1024 / 1024)) -ne "${vm_mem}" ]] || [[ $((cur_min / 1024 / 1024)) -ne "${vm_mem}" ]]; then
    logInfo "VM ${vm_name} has ${cur_max/ 1024 / 1024} MiB of RAM. Resizing"
    if ! xe_vm_shutdown "${vm_uuid}"; then
      logError "Failed to shutdown VM ${vm_name}"
      return 1
    elif ! xe_exec res vm-memory-set "memory=${vm_mem}MiB" "uuid=${vm_uuid}" --minimal; then
      logError "Failed to resize RAM for VM ${vm_name} to ${vm_mem} MiB"
      return 1
    else
      logInfo "RAM for VM ${vm_name} resized to ${vm_mem} MiB"
    fi
  else
    logInfo "RAM for VM ${vm_name} already has size ${vm_mem} MiB"
  fi

  # Handle CPU count
  local cur_cpu_count
  if ! xe_exec cur_cpu_count vm-param-get uuid="${vm_uuid}" param-name=VCPUs-max --minimal; then
    logError "Failed to get VCPUs-max for VM ${vm_name}"
    return 1
  elif [[ "${cur_cpu_count}" -ne "${vm_vcpus}" ]]; then
    logInfo "VM ${vm_name} has ${cur_cpu_count} VCPUs. Resizing"
    if ! xe_vm_shutdown "${vm_uuid}"; then
      logError "Failed to shutdown VM ${vm_name}"
      return 1
    elif ! xe_exec res vm-param-set "VCPUs-max=${vm_vcpus}" "uuid=${vm_uuid}" --minimal; then
      logError "Failed to resize VCPUs for VM ${vm_name} to ${vm_vcpus}"
      return 1
    else
      logInfo "VCPUs for VM ${vm_name} resized to ${vm_vcpus}"
    fi
  else
    logInfo "VCPUs for VM ${vm_name} already has count ${vm_vcpus}"
  fi

  # shellcheck disable=SC2248
  return ${is_new_vm}
}

# Attach a network to a VM
#
# Parameters:
#   $1[in]: The VM name
#   $2[in]: The network name
# Returns:
#   0: If the network was attached
#   1: If the network couldn't be attached
xe_vm_net_attach() {
  local vm_name="${1}"
  local net_name="${2}"

  if [[ -z "${vm_name}" ]] || [[ -z "${net_name}" ]]; then
    logError "Invalid parameters"
    return 1
  fi

  local vm_uuid net_uuid vifs vif vif_id res cmd
  if ! xe_exec vm_uuid vm_list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi
  if ! xe_net_uuid_by_name net_uuid "${net_name}"; then
    return 1
  fi

  if ! xe_exec vifs vm-vif-list uuid="${vm_uuid}" params=uuid --minimal; then
    logError "Failed to list VIFs for VM ${vm_name}"
    return 1
  fi
  IFS=',' read -r -a vifs <<<"${vifs}"
  for vif in "${vifs[@]}"; do
    if ! xe_exec res vif-param-get uuid="${vif}" param-name=network-uuid --minimal; then
      logError "Failed to get network-uuid for VIF ${vif}"
      return 1
    elif [[ "${res}" == "${net_uuid}" ]]; then
      logInfo "Network ${net_name} already attached to VM ${vm_name}"
      return 0
    else
      logTrace "Ignoring network ${res}"
    fi
  done

  # If we reach here, we need to attach the network
  if ! xe_vm_vif_next vif_id "${vm_uuid}"; then
    return 1
  fi
  cmd=("vif-create" "network-uuid=${net_uuid}" "vm-uuid=${vm_uuid}")
  cmd+=("device=${vif_id}" "mac=random" "--minimal")
  if ! xe_vm_shutdown "${vm_uuid}"; then
    logError "Failed to shutdown VM ${vm_name}"
    return 1
  elif ! xe_exec vif "${cmd[@]}"; then
    logError "Failed to attach network ${net_name} to VM ${vm_name}"
    return 1
  else
    logInfo "Network ${net_name} attached to VM ${vm_name} by: vif ${vif}"
  fi

  return 0
}

# Attach an ISO to a VM
#
# Parameters:
#   $1[in]: The VM name
#   $2[in]: The ISO name
# Returns:
#   0: If the ISO was attached
#   1: If the ISO couldn't be attached
xe_vm_iso_attach() {
  local vm_name="${1}"
  local iso_name="${2}"

  if [[ -z "${vm_name}" ]] || [[ -z "${iso_name}" ]]; then
    logError "Invalid parameters"
    return 1
  fi

  local vm_uuid iso_uuid vbds vbd vbd_id res cmd
  if [[ -z "${vm_name}" ]]; then
    logError "Invalid parameters"
    return 1
  elif ! xe_exec vm_uuid vm_list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi

  # TODO: Find ISO UUID

  # Get a list of already attached ISOs
  cmd=("vm-cd-list" "uuid=${vm_uuid}" "vbd-params=none" "vdi-params=uuid")
  cmd+=(--multiple --minimal)
  if ! xe_exec res "${cmd[@]}"; then
    logError "Failed to list attached ISOs for VM ${vm_name}"
    return 1
  elif [[ -n "${res}" ]]; then
    IFS=',' read -r -a vbds <<<"${res}"
    for vbd in "${vbds[@]}"; do
      if [[ -z "${vbd}" ]]; then
        logError "Invalid VDI"
        return 1
      elif [[ "${iso_uuid}" == "${vbd}" ]]; then
        logInfo "ISO ${iso_uuid} already attached to VM ${vm_name}"
        return 0
      else
        logTrace "Ignoring ISO ${vbd}"
      fi
    done

    logWarn "One or more different ISOs are already attached. Ejecting..."
    if ! xe_vm_iso_eject "${vm_name}"; then
      return 1
    fi
  else
    logInfo "No ISOs attached to VM ${vm_name}"
  fi

  # If we reach here, we need to attach the ISO
  if ! xe_exec vm-cd-insert "cd-name=${iso_name}" "uuid=${vm_uuid}" --minimal; then
    logError "Failed to insert ISO ${iso_name} to VM ${vm_name}"
    return 1
  elif [[ -n "${res}" ]]; then
    # This should mean we have no drive at all on this VM, on which to insert a CD
    logWarn "No CD drive found for VM ${vm_name}: ${res}"
    cmd=("vm-cd-add" "cd-name=${iso_name}" "device=${vbd_id}")
    cmd+=("uuid=${vm_uuid}" "--minimal")
    if ! xe_vm_vbd_next vbd_id "${vm_uuid}"; then
      return 1
    elif ! xe_exec res "${cmd[@]}"; then
      logError "Failed to attach ISO ${iso_name} to VM ${vm_name}"
      return 1
    elif [[ -n "${res}" ]]; then
      logError <<EOF
Failed to attach ISO ${iso_name} to VM ${vm_name}.
Unexpected response:
${res}
EOF
      return 1
    else
      logInfo "ISO ${iso_name} attached to VM ${vm_name}"
    fi
  else
    logInfo "ISO ${iso_name} succesfully inserted to VM ${vm_name}"
    return 0
  fi
}

# Eject ISO from a VM
#
# Parameters:
#   $1[in]: The VM name
# Returns:
#   0: If the ISO was ejected
#   1: If the ISO couldn't be ejected
xe_vm_iso_eject() {
  local vm_name="${1}"

  local vm_uuid
  if [[ -z "${vm_name}" ]]; then
    logError "Invalid parameters"
    return 1
  elif ! xe_exec vm_uuid vm_list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi

  if ! xe_exec res vm-cd-eject "uuid=${vm_uuid}" --minimal; then
    logError "Failed to eject ISO from VM ${vm_name}"
    return 1
  elif [[ -n "${res}" ]]; then
    logError <<EOF
Failed to eject ISO from VM ${vm_name}. Unexpected response:
${res}
EOF
    return 1
  else
    logInfo "ISO ejected from VM ${vm_name}"
    return 0
  fi
}

# Find an available VBD slot
#
# Parameters:
#   $1[out]: The available slot
#   $2[in]: The VM UUID
# Returns:
#   0: If a slot was found
#   1: If no slot was found
xe_vm_vbd_next() {
  local __result_SLOT="${1}"
  local vm_uuid="${2}"

  local __res slots slot
  if ! xe_exec __res vm-param-get "uuid=${vm_uuid}" param-name=allowed-VBD-devices --minimal; then
    logError "Failed to get allowed-VBD-devices for VM ${vm_uuid}"
    return 1
  fi

  IFS=';' read -r -a slots <<<"${__res}"
  if [[ ${#slots[@]} -le 0 ]]; then
    logError "No slots found for VM ${vm_uuid}"
    return 1
  fi

  # Take fhe first available slot
  slot=${slots[0]}
  if [[ ! ${slot} =~ ^[0-9]+$ ]]; then
    logError "Invalid slot number: ${slot}"
    return 1
  fi

  eval "${__result_SLOT}='${slot}'"
  return 0
}

# Find an available VIF slot
#
# Parameters:
#   $1[out]: The available slot
#   $2[in]: The VM UUID
# Returns:
#   0: If a slot was found
#   1: If no slot was found
xe_vm_vif_next() {
  local __result_SLOT="${1}"
  local vm_uuid="${2}"

  local __res slots slot
  if ! xe_exec __res vm-param-get "uuid=${vm_uuid}" param-name=allowed-VIF-devices --minimal; then
    logError "Failed to get allowed-VIF-devices for VM ${vm_uuid}"
    return 1
  fi

  IFS=';' read -r -a slots <<<"${__res}"
  if [[ ${#slots[@]} -le 0 ]]; then
    logError "No slots found for VM ${vm_uuid}"
    return 1
  fi

  # Take fhe first available slot
  slot=${slots[0]}
  if [[ ! ${slot} =~ ^[0-9]+$ ]]; then
    logError "Invalid slot number: ${slot}"
    return 1
  fi

  eval "${__result_SLOT}='${slot}'"
  return 0
}

# Find template UUID
#
# Parameters:
#   $1[out]: Template uuid
#   $2[in]: Template name
# Returns:
#   0: Success
#   1: Failure
xe_vm_template() {
  local __result_TEMPLATE_UUID="${1}"
  local template_name="${2}"

  if [[ -z "${template_name}" ]]; then
    template_name="${VM_TEMPLATE_DEFAULT}"
    logWarn "No template given. Using default: ${template_name}"
  fi

  local __res
  if ! xe_exec __res template_list name-label="${template_name} params=uuid --minimal"; then
    logError "Failed to list templates"
    return 1
  fi

  if [[ -z "${__res}" ]]; then
    logError "Template not found"
    return 1
  fi

  eval "${__result_TEMPLATE_UUID}='${__res}'"

  return 0
}

# Add a tag to a VM
#
# Parameters:
#   $1[in]: The VM UUID
#   $2[in]: The tag names, comma separated
# Returns:
#   0: If the tag was added
#   1: If the tag couldn't be added
xe_vm_tag_add() {
  local vm_uuid="$1"
  local tag_names="$2"

  if [[ -z "${vm_uuid}" ]]; then
    logError "Invalid VM"
    return 1
  elif [[ -z "${tag_names}" ]]; then
    logWarn "No tags to set"
    return 0
  fi

  # Desired tags
  local __res tags tag tag2 cur_tags found
  IFS=',' read -r -a tags <<<"${tag_names}"

  # Current tags
  if ! xe_exec __res vm-param-get "uuid=${vm_uuid}" param-name=tags --minimal; then
    logError "Failed to get tags for VM ${vm_uuid}"
    return 1
  fi
  IFS=',' read -r -a cur_tags <<<"${__res}"

  for tag in "${tags[@]}"; do
    found=0
    for tag2 in "${cur_tags[@]}"; do
      if [[ "${tag}" == "${tag2}" ]]; then
        found=1
        logInfo "Tag ${tag} already set"
        break
      else
        logTrace "Tag ${tag} != ${tag2}. Ignoring"
      fi
    done
    if [[ "${found}" -eq 0 ]]; then
      if ! xe_exec __res vm-param-add "uuid=${vm_uuid}" param-name=tags param-key="${tag}" --minimal; then
        logError "Failed to add tag ${tag} to VM ${vm_uuid}: ${__res}"
        return 1
      else
        logInfo "Tag ${tag} added to VM ${vm_uuid}"
      fi
    fi
  done

  return 0
}

# Start a VM
#
# Parameters:
#   $1[in]: The VM UUID
# Returns:
#   0: If the VM was started
#   1: If the VM couldn't be started
xe_vm_start() {
  local vm_uuid="${1}"

  if [[ -z "${vm_uuid}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  local cur_state
  if ! xe_exec cur_state vm-param-get "uuid=${vm_uuid}" param-name=power-state --minimal; then
    logError "Failed to get power-state for VM ${vm_uuid}"
    return 1
  fi

  if [[ "${cur_state}" == "running" ]]; then
    logInfo "VM ${vm_uuid} already running"
    return 0
  elif ! xe_exec res vm-start "uuid=${vm_uuid}" --minimal; then
    logError "Failed to start VM ${vm_uuid}: ${res}"
    return 1
  else
    logInfo "VM ${vm_uuid} start commanded"
  fi

  # Wait for the VM to start (max 10 minutes)
  local end_time
  end_time=$(($(date +%s) + (10 * 60)))
  while true; do
    sleep 1

    if ! xe_exec cur_state vm-param-get "uuid=${vm_uuid}" param-name=power-state --minimal; then
      logError "Failed to get power-state for VM ${vm_uuid}"
      return 1
    fi

    if [[ "${cur_state}" == "running" ]]; then
      logInfo "VM ${vm_uuid} running"
      break
    elif [[ $(date +%s || true) -ge ${end_time} ]]; then
      logError "Timeout reached while waiting for VM ${vm_uuid} to start"
      return 1
    fi
  done

  return 0
}

# Shutdown a VM
#
# Parameters:
#   $1[in]: The VM UUID
# Returns:
#   0: If the VM was shutdown
#   1: If the VM couldn't be shutdown
xe_vm_shutdown() {
  local vm_uuid="${1}"

  if [[ -z "${vm_uuid}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  local cur_state
  if ! xe_exec cur_state vm-param-get "uuid=${vm_uuid}" param-name=power-state --minimal; then
    logError "Failed to get power-state for VM ${vm_uuid}"
    return 1
  fi

  if [[ "${cur_state}" == "halted" ]]; then
    logInfo "VM ${vm_uuid} already halted"
    return 0
  elif ! xe_exec res vm-shutdown "uuid=${vm_uuid}" --minimal; then
    logError "Failed to shutdown VM ${vm_uuid}: ${res}"
    return 1
  else
    logInfo "VM ${vm_uuid} shutdown commanded"
  fi

  # Wait for the VM to shutdown (max 10 minutes)
  local end_time
  end_time=$(($(date +%s) + (10 * 60)))
  while true; do
    sleep 1

    if ! xe_exec cur_state vm-param-get "uuid=${vm_uuid}" param-name=power-state --minimal; then
      logError "Failed to get power-state for VM ${vm_uuid}"
      return 1
    fi

    if [[ "${cur_state}" == "halted" ]]; then
      logInfo "VM ${vm_uuid} halted"
      break
    elif [[ $(date +%s || true) -ge ${end_time} ]]; then
      logError "Timeout reached while waiting for VM ${vm_uuid} to shutdown"
      return 1
    fi
  done

  return 0
}

# External variables

# Constants
VM_TEMPLATE_DEFAULT="Other install media"

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
XV_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XV_SOURCE}" ]]; do # resolve $XV_SOURCE until the file is no longer a symlink
  XV_ROOT=$(cd -P "$(dirname "${XV_SOURCE}")" >/dev/null 2>&1 && pwd)
  XV_SOURCE=$(readlink "${XV_SOURCE}")
  [[ ${XV_SOURCE} != /* ]] && XV_SOURCE=${XV_ROOT}/${XV_SOURCE} # if $XV_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XV_ROOT=$(cd -P "$(dirname "${XV_SOURCE}")" >/dev/null 2>&1 && pwd)
XV_ROOT=$(realpath "${XV_ROOT}/..")

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
if ! source "${XV_ROOT}/src/xe_host.sh"; then
  logFatal "Failed to load xe_host.sh"
fi
# shellcheck source=src/xe_storage.sh
if ! source "${XV_ROOT}/src/xe_storage.sh"; then
  logFatal "Failed to load xe_storage.sh"
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

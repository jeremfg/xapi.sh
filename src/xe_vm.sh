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

# Get all the VMs matching at least one of the given tags
#
# Parameters:
#   $1[out]: The variable to store the list of VM UUIDs
#   $2[in]: Set to "local" if the scrope should be limited to the current host
#   $@[in]: The list of tags to search for
# Returns:
#   0: If the VMs were successfully retrieved
#   1: If an error occurred
xe_vm_list_tagged() {
  local __result_tagged_vms="${1}"
  local __scope="${2}"
  shift 2

  if [[ -z "${__result_tagged_vms}" ]]; then
    logError "Result variable not specified"
    return 1
  elif [[ -z "${__scope}" ]]; then
    logWarn "Scope not specified. Assuming all"
    __scope="all"
  fi

  # Build the command
  local __cmd __res
  __cmd=("vm-list" "is-control-domain=false" "params=uuid,name-label,tags")
  if [[ "${__scope}" == "local" ]]; then
    if ! xe_host_current __res; then
      logError "Failed to get current host"
      return 1
    else
      __cmd+=("resident-on=${__res}")
    fi
  elif [[ "${__scope}" != "all" ]]; then
    if xe_exec __res host-list "name-label=${__scope}" --minimal; then
      logError "Failed to get host UUID for ${__scope}"
      return 1
    elif [[ -z "${__res}" ]]; then
      logError "Host ${__scope} not found"
      return 1
    elif [[ "${res}" == *","* ]]; then
      logError "Multiple hosts found for ${__scope}"
      return 1
    else
      __cmd+=("resident-on=${__res}")
    fi
  fi

  if ! xe_exec __res "${__cmd[@]}"; then
    logError "Failed to list VMs"
    return 1
  fi

  local __tag _line _key _value _cur_uuid _cur_name found
  local __vm_uuids=()
  local __tags=()
  while IFS= read -r _line; do
    if xe_read_param _key _value "${_line}"; then
      if [[ "${_key}" == "uuid" ]]; then
        found=0
        _cur_uuid="${_value}"
      elif [[ "${_key}" == "name-label" ]]; then
        _cur_name="${_value}"
      elif [[ "${_key}" == "tags" ]]; then
        IFS=',' read -r -a __tags <<<"${_value}"
        for __tag in "${__tags[@]}"; do
          if [[ " ${*} " =~ [[:space:]]${__tag}[[:space:]] ]]; then
            logTrace "VM ${_cur_name} has tag ${__tag}"
            found=1
            __vm_uuids+=("${_cur_uuid}")
            break
          fi
        done
        if [[ "${found}" -eq 0 ]]; then
          logTrace "VM ${_cur_name} does not have any of the specified tags"
        fi
      else
        logWarn "Unknown key ${_key} for VM ${_cur_uuid}"
      fi
    fi
  done <<<"${__res}"

  eval "${__result_tagged_vms}=(\"\${__vm_uuids[@]}\")"
  return 0
}

# Get all the VMs for which none of the given tags match
#
# Parameters:
#   $1[out]: The variable to store the list of VM UUIDs
#   $2[in]: Set to "local", "all" or a specific hostname if the scrope should be limited
#   $@: The list of tags to search for
# Returns:
#   0: If the VMs were successfully retrieved
#   1: If an error occurred
xe_vm_list_not_tagged() {
  local __result_tagged_vms="${1}"
  local __scope="${2}"
  shift 2

  if [[ -z "${__result_tagged_vms}" ]]; then
    logError "Result variable not specified"
    return 1
  elif [[ -z "${__scope}" ]]; then
    logWarn "Scope not specified. Assuming all"
    __scope="all"
  fi

  # Build the command
  local __cmd __res
  __cmd=("vm-list" "is-control-domain=false" "params=uuid,name-label,tags")
  if [[ "${__scope}" == "local" ]]; then
    if ! xe_host_current __res; then
      logError "Failed to get current host"
      return 1
    else
      __cmd+=("resident-on=${__res}")
    fi
  elif [[ "${__scope}" != "all" ]]; then
    if xe_exec __res host-list "name-label=${__scope}" --minimal; then
      logError "Failed to get host UUID for ${__scope}"
      return 1
    elif [[ -z "${__res}" ]]; then
      logError "Host ${__scope} not found"
      return 1
    elif [[ "${res}" == *","* ]]; then
      logError "Multiple hosts found for ${__scope}"
      return 1
    else
      __cmd+=("resident-on=${__res}")
    fi
  fi

  if ! xe_exec __res "${__cmd[@]}"; then
    logError "Failed to list VMs"
    return 1
  fi

  local __tag _line _key _value _cur_uuid _cur_name found
  local __vm_uuids=()
  local __tags=()
  while IFS= read -r _line; do
    if xe_read_param _key _value "${_line}"; then
      if [[ "${_key}" == "uuid" ]]; then
        found=0
        _cur_uuid="${_value}"
      elif [[ "${_key}" == "name-label" ]]; then
        _cur_name="${_value}"
      elif [[ "${_key}" == "tags" ]]; then
        IFS=',' read -r -a __tags <<<"${_value}"
        for __tag in "${__tags[@]}"; do
          if [[ " ${*} " =~ [[:space:]]${__tag}[[:space:]] ]]; then
            logTrace "VM ${_cur_name} has tag ${__tag}"
            found=1
            break
          fi
        done
        if [[ "${found}" -eq 0 ]]; then
          __vm_uuids+=("${_cur_uuid}")
          logTrace "VM ${_cur_name} does not have any of the specified tags"
        fi
      else
        logWarn "Unknown key ${_key} for VM ${_cur_uuid}"
      fi
    fi
  done <<<"${__res}"

  eval "${__result_tagged_vms}=(\"\${__vm_uuids[@]}\")"
  return 0
}

# Retrieve a list of every VM UUID that has a drive part of the specified SR
#
# Parameters:
#   $1[out]: The variable to store the list of VM UUIDs
#   $2[in] : The SR name to search for
# Returns:
#   0: If the VMs were successfully retrieved
#   1: If an error occurred
xe_vm_list_by_sr() {
  local __result_vms="${1}"
  local __sr="${2}"

  if [[ -z "${__sr}" ]]; then
    logError "SR not specified"
    return 1
  fi

  # Get the UUID of the Storage Repository (SR)
  local sr_uuid
  if ! xe_exec sr_uuid sr-list name-label="${__sr}" --minimal; then
    logError "Storage Repository ${__sr} not found"
    return 1
  fi

  # Get the list of VDIs in the SR
  local vdi_uuids
  if ! xe_exec vdi_uuids vdi-list sr-uuid="${sr_uuid}" --minimal; then
    logError "Failed to list VDIs in SR ${__sr}"
    return 1
  elif [[ -z "${vdi_uuids}" ]]; then
    logInfo "No VDIs found in SR ${__sr}"
    eval "${__result_vms}=()"
    return 0
  fi
  IFS=',' read -r -a vdi_uuids <<<"${vdi_uuids}"

  local vm_uuids vm_uuid vdi_uuid vbd_uuids
  vm_uuids=()
  for vdi_uuid in "${vdi_uuids[@]}"; do
    if ! xe_exec vbd_uuids vbd-list vdi-uuid="${vdi_uuid}" --minimal; then
      logError "Failed to list VBDs for VDI ${vdi_uuid}"
      return 1
    elif [[ -z "${vbd_uuids}" ]]; then
      logInfo "No VBD found for VDI ${vdi_uuid}"
    else
      IFS=',' read -r -a vbd_uuids <<<"${vbd_uuids}"
      for vbd_uuid in "${vbd_uuids[@]}"; do
        if ! xe_exec vm_uuid vbd-param-get uuid="${vbd_uuid}" param-name=vm-uuid --minimal; then
          logError "Failed to get VM for VBD ${vbd_uuid}"
          return 1
        elif [[ -n "${vm_uuid}" ]]; then
          vm_uuids+=("${vm_uuid}")
        fi
      done
    fi
  done

  if [[ ${#vm_uuids[@]} -eq 0 ]]; then
    logInfo "No VMs found with VDIs in SR ${__sr}"
    eval "${__result_vms}=()"
    return 0
  else
    eval "${__result_vms}=(\"\${vm_uuids[@]}\")"
    return 0
  fi
}

# Check if VM UUID does NOT have the specified tag
#
# Parameters:
#   $1[in]: The VM UUID
#   $2[in]: The tag to search for
# Returns:
#   0: If the VM does not have the tag
#   1: If the VM has the tag
xe_vm_not_tagged() {
  local __vm_uuid="${1}"
  local __tag="${2}"

  if [[ -z "${__vm_uuid}" ]] || [[ -z "${__tag}" ]]; then
    logError "VM UUID or tag not specified"
    return 1
  fi

  local res
  if ! xe_exec res vm-param-get uuid="${__vm_uuid}" param-name=tags --minimal; then
    logError "Failed to get tags for VM ${__vm_uuid}"
    return 1
  fi
  IFS=',' read -r -a res <<<"${res}"
  if [[ " ${res[*]} " =~ [[:space:]]${__tag}[[:space:]] ]]; then
    logInfo "VM ${__vm_uuid} has tag ${__tag}"
    return 1
  else
    logInfo "VM ${__vm_uuid} does not have tag ${__tag}"
    return 0
  fi
}

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
    logError "Invalid parameters in xe_vm_prepare"
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
  if [[ -z "${XCP_VM_SR_NAME}" ]]; then
    logError "Invalid environment: XCP_VM_SR_NAME not set"
    return 1
  fi

  if ! xe_vm_template tmpl_uuid; then
    return 1
  elif ! xe_stor_uuid_by_name sr_uuid "${XCP_VM_SR_NAME}"; then
    return 1
  fi

  # Find or create the VM
  cmd=("vm-install" "new-name-label=${vm_name}" "params=uuid" "--minimal")
  cmd+=("template-uuid=${tmpl_uuid}" "sr-uuid=${sr_uuid}")
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
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
      if ! xe_exec res vdi-list uuid="${cur_uuid}" params=virtual-size --minimal; then
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
    if ! xe_disk_create vdi_uuid "${disk_name}" "$((vm_disk * 1024 * 1024 * 1024))" "${sr_uuid}"; then
      logError "Failed to create disk for VM ${vm_name}"
      return 1
    fi
    cmd=("vbd-create" "vm-uuid=${vm_uuid}" "device=${vbd_id}")
    cmd+=("vdi-uuid=${vdi_uuid}" "type=Disk" "mode=RW" "--minimal")
    if ! xe_exec res "${cmd[@]}"; then
      logError "Failed to attach disk to VM ${vm_name}: ${res}"
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
    if ! xe_vm_shutdown "${vm_name}"; then
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
    logInfo "VM ${vm_name} has $((cur_max / 1024 / 1024)) MiB of RAM. Resizing"
    if ! xe_vm_shutdown "${vm_name}"; then
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
  elif [[ "${cur_cpu_count}" -lt "${vm_vcpus}" ]]; then
    logInfo "VM ${vm_name} has ${cur_cpu_count} VCPUs MAX. Resizing"
    if ! xe_vm_shutdown "${vm_name}"; then
      logError "Failed to shutdown VM ${vm_name}"
      return 1
    elif ! xe_exec res vm-param-set "VCPUs-max=${vm_vcpus}" "uuid=${vm_uuid}" --minimal; then
      logError "Failed to resize VCPUs MAX for VM ${vm_name} to ${vm_vcpus}"
      return 1
    else
      logInfo "VCPUs MAX for VM ${vm_name} resized to ${vm_vcpus}"
    fi
  else
    logInfo "VCPUs MAX for VM ${vm_name} already has count ${vm_vcpus}"
  fi
  if ! xe_exec cur_cpu_count vm-param-get uuid="${vm_uuid}" param-name=VCPUs-at-startup --minimal; then
    logError "Failed to get VCPUs-at-startup for VM ${vm_name}"
    return 1
  elif [[ "${cur_cpu_count}" -ne "${vm_vcpus}" ]]; then
    logInfo "VM ${vm_name} has ${cur_cpu_count} VCPUs on startup. Resizing"
    if ! xe_vm_shutdown "${vm_name}"; then
      logError "Failed to shutdown VM ${vm_name}"
      return 1
    elif ! xe_exec res vm-param-set "VCPUs-at-startup=${vm_vcpus}" "uuid=${vm_uuid}" --minimal; then
      logError "Failed to resize VCPUs at startup for VM ${vm_name} to ${vm_vcpus}"
      return 1
    else
      logInfo "VCPUs for VM ${vm_name} resized to ${vm_vcpus} at startup"
    fi
  else
    logInfo "VCPUs for VM ${vm_name} already has count ${vm_vcpus} at startup"
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
    logError "Invalid parameters in xe_vm_net_attach"
    return 1
  fi

  local vm_uuid net_uuid vifs vif vif_id res cmd
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
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
  if ! xe_vm_shutdown "${vm_name}"; then
    logError "Failed to shutdown VM ${vm_name}"
    return 1
  elif ! xe_exec vif "${cmd[@]}"; then
    logError "Failed to attach network ${net_name} to VM ${vm_name}"
    return 1
  else
    logInfo "Network ${net_name} attached to VM ${vm_name} by vif ${vif}"
  fi

  return 0
}

# Attach PCI devices to a VM
#
# Parameters:
#   $1[in]: VM name
#   $2[in]: List of PCI devices
# Returns:
#   0: If PCI devices were attached
#   1: If any error occurred
xe_vm_pci_attach() {
  local _vm="${1}"
  local _devices="${2}"

  local cmd res res2 vm_uuid availables device configured to_configure
  if ! xe_exec vm_uuid vm-list "name-label=${_vm}" --minimal; then
    logError "Failed to get VM"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM not found"
    return 1
  fi

  # Retrieve the list of configured devices
  # xe vm-param-remove param-name=other-config param-key=pci uuid=<vm uuid>
  cmd=(vm-param-get "uuid=${vm_uuid}" "param-name=other-config")
  cmd+=("param-key=pci" "--minimal")
  if ! xe_exec configured "${cmd[@]}"; then
    # It's possible that zero PCI entry exists
    if [[ "${configured}" == *"Key pci not found in map"* ]]; then
      cmd=(vm-param-get "uuid=${vm_uuid}" "param-name=other-config")
      cmd+=("--minimal")
      if ! xe_exec configured "${cmd[@]}"; then
        logError "Failed to get configured PCI devices: ${configured}"
        return 1
      elif [[ "${configured}" == *"pci"* ]]; then
        logError "Failed to get configured PCI devices: ${configured}"
        return 1
      else
        logInfo "No PCI devices configured: ${configured}"
        configured=""
      fi
    fi
  else
    # FIXME: Try to understand why there are extra backslashes in this answer.
    # Executing the same command locally yields clean output
    logTrace "Response before cleanup: \"${configured}\""
    configured="${configured//\\/}"
    logTrace "Response after cleanup : \"${configured}\""
  fi

  # Retrieve the list of available devices
  if ! xe_host_exec availables xl pci-assignable-list; then
    logError "Failed to get available PCI devices: ${availables}"
    return 1
  fi

  # Parse all the data into arrays
  IFS=',' read -r -a configured <<<"${configured}"
  IFS=',' read -r -a _devices <<<"${_devices}"
  readarray -t availables <<<"${availables}"

  # Trim all 3 arrays, we don't double-quote on purpose
  # shellcheck disable=SC2206
  configured=(${configured[@]})
  # shellcheck disable=SC2206
  _devices=(${_devices[@]})
  # shellcheck disable=SC2206
  availables=(${availables[@]})

  logTrace <<EOF
This is the information gathered:
  Configured: ${configured[*]}
  Availables: ${availables[*]}
  Devices:    ${_devices[*]}
EOF

  # Find devices that are already configured
  to_configure=()
  for res in "${_devices[@]}"; do
    if [[ " ${configured[*]} " =~ [[:space:]]0/0000:${res}[[:space:]] ]]; then
      logTrace "Device ${res} already configured"
      continue
    else
      logTrace "Device ${res} not configured"
      to_configure+=("0/0000:${res}")
    fi
  done

  if [[ ${#to_configure[@]} -eq 0 ]]; then
    logInfo "No devices to configure"
    return 0
  fi

  # For each one we need to configure, check if they are available
  for device in "${to_configure[@]}"; do
    res=0
    for available in "${availables[@]}"; do
      if [[ "${device}" == "0/${available}" ]]; then
        logTrace "Device ${device} available"
        res=1
        break
      fi
    done
    if [[ ${res} -eq 0 ]]; then
      logError "Device ${device} not available"
      return 1
    fi
  done

  # For each device already configured, remember the extra ones
  to_configure=()
  for device in "${configured[@]}"; do
    res2=0
    for res in "${_devices[@]}"; do
      if [[ "${device}" == "0/0000:${res}" ]]; then
        res2=1
        break
      fi
    done
    if [[ ${res2} -eq 0 ]]; then
      if [[ " ${to_configure[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
        logWarn "Device ${device} already in list. Ignoring duplicate."
      else
        logTrace "Keeping existing device ${device}"
        to_configure+=("${device}")
      fi
    fi
  done

  # Add all our devices
  for device in "${_devices[@]}"; do
    device="0/0000:${device}"
    if [[ " ${to_configure[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
      logWarn "Device ${device} already in list. Ignoring duplicate."
    else
      logTrace "Keeping existing device ${device}"
      to_configure+=("${device}")
    fi
  done

  # Build a comma separated list of devices to configure
  res2=""
  for device in "${to_configure[@]}"; do
    res2+="${device},"
  done
  res2="${res2%,}"

  if ! xe_vm_shutdown "${_vm}"; then
    logError "Failed to shutdown VM ${_vm}"
    return 1
  elif ! xe_exec res vm-param-set "uuid=${vm_uuid}" "other-config:pci=${res2}"; then
    logError "Failed to attach PCI devices"
    return 1
  else
    logInfo "Attached PCI devices to VM ${_vm}"
  fi

  return 0
}

# Attach a USB device to a VM
#
# Parameters:
#   $1[in]: The VM name
#   $2[in]: The USB VID
#   $3[in]: The USB PID
#   $4[in]: The USB SN
# Returns:
#   0: If the USB device was attached
#   1: If the USB device couldn't be attached
xe_vm_usb_attach() {
  local vm_name="${1}"
  local usb_vid="${2}"
  local usb_pid="${3}"
  local usb_sn="${4}"

  # Validate input
  if [[ -z "${vm_name}" ]]; then
    logError "VM name not specified"
    return 1
  elif [[ -z "${usb_vid}" ]]; then
    logError "USB VID not specified"
    return 1
  elif [[ -z "${usb_pid}" ]]; then
    logError "USB PID not specified"
    return 1
  elif [[ -z "${usb_sn}" ]]; then
    logError "USB SN not specified"
    return 1
  fi

  # Obtain the UUIDs
  local vm_uuid usb_uuid cmd res
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" --minimal; then
    logError "Failed to get VM ${vm_name}"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  elif [[ "${vm_uuid}" == *","* ]]; then
    logError "Multiple VMs found with name ${vm_name}"
    return 1
  elif ! xe_exec usb_uuid pusb-list "vendor-id=${usb_vid}" "product-id=${usb_pid}" "serial=${usb_sn}" --minimal; then
    logError "Failed to get USB device"
    return 1
  elif [[ -z "${usb_uuid}" ]]; then
    logError "USB device not found"
    return 1
  elif [[ "${usb_uuid}" == *","* ]]; then
    logError "Multiple USB devices found with VID ${usb_vid}, PID ${usb_pid}, SN ${usb_sn}"
    return 1
  fi

  # Check if VM already has the USB device attached
  local vusb_device group_uuid
  vusb_devices=()
  if ! xe_exec res vusb-list "vm-uuid=${vm_uuid}" --minimal; then
    logError "Failed to list USB devices for VM ${vm_name}"
    return 1
  elif [[ -n "${res}" ]]; then
    IFS=',' read -r -a vusb_devices <<<"${res}"
  fi
  for vusb_device in "${vusb_devices[@]}"; do
    if ! xe_exec res usb-group-list "PUSB-uuids:contains=${usb_uuid}" "VUSB-uuids:contains=${vusb_device}" --minimal; then
      logError "Failed to list USB group devices"
      return 1
    elif [[ -n "${res}" ]]; then
      logInfo "USB device ${usb_uuid} already attached to VM ${vm_name}"
      return 0
    fi
  done

  # If we reach here, we need to attach the USB device
  if ! xe_vm_shutdown "${vm_name}"; then
    logError "Failed to shutdown VM ${vm_name} before attaching USB device"
    return 1
  elif ! xe_exec group_uuid usb-group-list "PUSB-uuids=${usb_uuid}" --minimal; then
    logError "Failed to create USB group"
    return 1
  elif [[ -z "${group_uuid}" ]]; then
    logError "USB group not found"
    return 1
  elif ! xe_exec res vusb-create "vm-uuid=${vm_uuid}" "usb-group-uuid=${group_uuid}" --minimal; then
    logError "Failed to attach USB device to VM ${vm_name}"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Failed to attach USB device to VM ${vm_name}"
    return 1
  else
    logInfo "USB device ${usb_uuid} attached to VM ${vm_name}: ${res}"
    return 0
  fi
}

# Attach all the given VDIs to a VM, and only them from the specified SR
#
# Parameters:
#   $1[in]: The VM name
#   $2[in]: The SR name
#   $@[in]: The list of VDI uuids
# Returns:
#   0: If the VDIs were attached
#   1: If the VDIs couldn't be attached
xe_vm_attach_all_but_only_from_sr() {
  local __vm_name="${1}"
  local __sr_name="${2}"
  shift 2

  local __vm_uuid __sr_uuid __vdi_uuids __vdi_uuid __vdi_id __vdi_ids __cmd __res
  if ! xe_exec __vm_uuid vm-list name-label="${__vm_name}" --minimal; then
    logError "Failed to get VM ${__vm_name}"
    return 1
  elif [[ -z "${__vm_uuid}" ]]; then
    logError "VM ${__vm_name} not found"
    return 1
  elif ! xe_stor_uuid_by_name __sr_uuid "${__sr_name}"; then
    return 1
  fi

  # Get the list of VDIs in the SR
  if ! xe_exec __vdi_uuids vdi-list sr-uuid="${__sr_uuid}" --minimal; then
    logError "Failed to list VDIs in SR ${__sr_name}"
    return 1
  fi
  IFS=',' read -r -a __vdi_uuids <<<"${__vdi_uuids}"

  # Get the list of VBDs for the VM
  if ! xe_exec __vdi_ids vm-disk-list uuid="${__vm_uuid}" --minimal; then
    logError "Failed to list VBDs for VM ${__vm_name}"
    return 1
  fi
  IFS=',' read -r -a __vdi_ids <<<"${__vdi_ids}"

  # For each VBD, check if the VID is part of the SR and desired
  local vdbs_to_eject=()
  for __vdi_uuid in "${__vdi_ids[@]}"; do
    if [[ " ${__vdi_uuids[*]} " =~ [[:space:]]${__vdi_uuid}[[:space:]] ]]; then
      logTrace "VDI ${__vdi_uuid} is part of SR ${__sr_name}"
      # Is this a desired VDI?
      if [[ " $* " =~ [[:space:]]${__vdi_uuid}[[:space:]] ]]; then
        logTrace "VDI ${__vdi_uuid} is desired. Ignoring."
      else
        logTrace "VDI ${__vdi_uuid} is not desired. Marking for ejection"
        vdbs_to_eject+=("${__vdi_uuid}")
      fi
    else
      logTrace "VDI ${__vdi_uuid} is not part of SR ${__sr_name}. Ignoring..."
      continue
    fi
  done

  # Fpr each desired VDI, list the missing ones on the VM
  local vdis_to_attach=()
  local found=0
  for __vdi_uuid in "$@"; do
    if [[ " ${__vdi_uuids[*]} " =~ [[:space:]]${__vdi_uuid}[[:space:]] ]]; then
      logTrace "VDI ${__vdi_uuid} is part of SR ${__sr_name}"
      # Is this VDI already attached?
      if [[ " ${__vdi_ids[*]} " =~ [[:space:]]${__vdi_uuid}[[:space:]] ]]; then
        logTrace "VDI ${__vdi_uuid} already attached to VM ${__vm_name}. Ignoring"
      else
        logTrace "VDI ${__vdi_uuid} is not attached to VM ${__vm_name}. Marking for attachment"
        vdis_to_attach+=("${__vdi_uuid}")
      fi
    else
      logTrace "VDI ${__vdi_uuid} is not part of SR ${__sr_name}. This is unexpected"
      return 1
    fi
  done

  # Do we have anything to eject or attach?
  if [[ ${#vdbs_to_eject[@]} -eq 0 ]] && [[ ${#vdis_to_attach[@]} -eq 0 ]]; then
    logInfo "No VDIs to eject or attach"
    return 0
  fi

  # We have to modify the VM. First. Ensure shutdown
  if ! xe_vm_shutdown "${__vm_name}"; then
    logError "Failed to shutdown VM ${__vm_name}"
    return 1
  fi

  # Do the ejections
  for __vbd_id in "${vdbs_to_eject[@]}"; do
    if ! xe_exec __res vbd-destroy uuid="${__vbd_id}"; then
      logError "Failed to eject VDI ${__vbd_id}: ${__res}"
      return 1
    fi
    logInfo "VDI ${__vbd_id} ejected from VM ${__vm_name}"
  done

  # Do the attachments
  for __vdi_uuid in "${vdis_to_attach[@]}"; do
    if ! xe_vm_vbd_next __vbd_id "${__vm_uuid}"; then
      return 1
    fi
    __cmd=("vbd-create" "vm-uuid=${__vm_uuid}" "device=${__vbd_id}")
    __cmd+=("vdi-uuid=${__vdi_uuid}" "type=Disk" "mode=RW" "--minimal")
    if ! xe_exec __res "${__cmd[@]}"; then
      logError "Failed to attach VDI ${__vdi_uuid} to VM ${__vm_name}: ${__res}"
      return 1
    fi
    logInfo "VDI ${__vdi_uuid} attached to VM ${__vm_name}"
  done

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
    logError "Invalid parameters in xe_vm_iso_attach"
    return 1
  fi

  local vm_uuid iso_uuid vbds vbd vbd_id res cmd
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi

  # Get ISO UUID
  if ! xe_iso_uuid_by_name iso_uuid "${iso_name}"; then
    return 1
  fi

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
  if xe_exec res vm-cd-insert "cd-name=${iso_name}" "uuid=${vm_uuid}" --minimal; then
    logInfo "ISO ${iso_name} succesfully inserted to VM ${vm_name}"
    return 0
  elif [[ "${res}" == *"The VM has no empty CD drive"* ]]; then
    # This should mean we have no drive at all on this VM, on which to insert a CD
    logWarn "No CD drive found for VM ${vm_name}: ${res}"
    if ! xe_vm_vbd_next vbd_id "${vm_uuid}"; then
      return 1
    fi
    cmd=("vm-cd-add" "cd-name=${iso_name}" "device=${vbd_id}")
    cmd+=("uuid=${vm_uuid}" "--minimal")
    if ! xe_exec res "${cmd[@]}"; then
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
    logError "Failed to insert ISO ${iso_name} to VM ${vm_name}: ${res}"
    return 1
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
    logError "Invalid parameters in xe_vm_iso_eject"
    return 1
  elif ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
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
  if ! xe_exec __res template-list name-label="${template_name}" "params=uuid" --minimal; then
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
#   $1[in]: The VM name
#   $2[in]: The tag names, comma separated
# Returns:
#   0: If the tag was added
#   1: If the tag couldn't be added
xe_vm_tag_add() {
  local __vm_name="$1"
  local tag_names="$2"

  if [[ -z "${__vm_name}" ]]; then
    logError "Invalid VM"
    return 1
  elif [[ -z "${tag_names}" ]]; then
    logWarn "No tags to set"
    return 0
  fi

  # Desired tags
  local __res tags tag tag2 cur_tags found vm_uuid
  IFS=',' read -r -a tags <<<"${tag_names}"

  # Current tags
  if ! xe_exec vm_uuid vm-list name-label="${__vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${__vm_name} not found"
    return 1
  elif ! xe_exec __res vm-param-get "uuid=${vm_uuid}" param-name=tags --minimal; then
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
#   $1[in]: The VM name
# Returns:
#   0: If the VM was started
#   1: If the VM couldn't be started
xe_vm_start() {
  local vm_name="${1}"

  if [[ -z "${vm_name}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  local vm_uuid
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi

  if ! xe_vm_start_by_id "${vm_uuid}"; then
    logError "Failed to start VM ${vm_name}"
    return 1
  fi

  return 0
}

# Start one or multiple VMs by their UUID
#
# Parameters:
#   $@[in]: The VM UUIDs
# Returns:
#   0: If the VMs were all started
#   1: If one or more VMs couldn't be started
xe_vm_start_by_id() {
  local __vm_start_res=0

  if [[ -z "${*}" ]]; then
    logError "Invalid VMs"
    return 1
  fi

  local __cmd __res __vm __vm_name
  for __vm in "${@}"; do
    __vm_name=""
    __cmd=("vm-list" "uuid=${__vm}" "is-control-domain=false")
    __cmd+=("params=name-label")

    # Make sure the VM exists
    if ! xe_exec __res "${__cmd[@]}"; then
      logError "Failed to list VM: ${__vm}"
      return 1
    elif [[ -z "${__res}" ]]; then
      logError "VM ${__vm} not found"
      return 1
    fi
    while IFS= read -r _line; do
      if xe_read_param _key _value "${_line}"; then
        if [[ "${_key}" == "name-label" ]]; then
          if [[ -n "${__vm_name}" ]]; then
            logError "Multiple VMs for ${__vm}"
            return 1
          fi
          __vm_name="${_value}"
        else
          logError "Unexpected key: ${_key}"
          return 1
        fi
      fi
    done <<<"${__res}"

    local cur_state
    if ! xe_vm_state_by_id cur_state "${__vm}"; then
      logError "Failed to get state for VM ${__vm_name}"
      return 1
    elif [[ "${cur_state}" == "running" ]]; then
      logInfo "VM ${__vm_name} already running"
      continue
    elif [[ "${cur_state}" != "halted" ]]; then
      logWarn "VM ${__vm_name} is in an unexpected state: ${cur_state}"
    fi

    logTrace "Starting VM: ${__vm_name}"
    if ! xe_exec __res vm-start "uuid=${__vm}" --minimal; then
      logError "Failed to start VM: ${__vm_name}"
      __vm_start_res=1
    else
      logInfo "Start of VM ${__vm} successful"
    fi

    # Wait for VM to be running
    while true; do
      if ! xe_exec cur_state vm-param-get "uuid=${vm_uuid}" param-name=power-state --minimal; then
        logError "Failed to get power-state for VM ${__vm_name}"
        return 1
      fi
      if [[ "${cur_state}" == "running" ]]; then
        logInfo "VM ${__vm_name} running"
        break
      elif [[ "${cur_state}" == "halted" ]]; then
        logError "VM ${__vm_name} returned to halted"
        return 1
      else
        logInfo "VM ${__vm_name} not running yet"
      fi
    done
  done

  return "${__vm_start_res}"
}

# Shutdown a VM
#
# Parameters:
#   $1[in]: The VM name
#   $2[in]: If set to "force", the VM will be shutdown regardless of XCP_CRITICAL_TAG
# Returns:
#   0: If the VM was shutdown
#   1: If the VM couldn't be shutdown
xe_vm_shutdown() {
  local vm_name="${1}"
  local __force="${2}"

  if [[ -z "${vm_name}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  local cur_state vm_uuid
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logError "VM ${vm_name} not found"
    return 1
  fi

  xe_vm_shutdown_by_id "${__force}" "${vm_uuid}"
  return $?
}

# Shutdown one or multiple VMs by their UUID
#
# Parameters:
#   $1[in]: If set to "force", the VM will be shutdown regardless of XCP_CRITICAL_TAG
#   $@[in]: The VM UUIDs
# Returns:
#   0: If the VM was shutdown
#   1: If the VM couldn't be shutdown
xe_vm_shutdown_by_id() {
  local __vmsh_force="${1}"
  shift

  if [[ -z "${*}" ]]; then
    logError "Invalid VMs"
    return 1
  elif [[ -z "${XCP_CRITICAL_TAG}" ]]; then
    logError "Critical tag not set. Cannot verify if we are allowed to shutdown"
    return 1
  fi

  # Validate each VM
  local __res __cmd __vm _line _key _value __vm_name __vm_tags
  for __vm in "${@}"; do
    __cmd=("vm-list" "uuid=${__vm}" "is-control-domain=false")
    __cmd+=("params=name-label,tags")
    if ! xe_exec __res "${__cmd[@]}"; then
      logError "Failed to list VM: ${__vm}"
      return 1
    elif [[ -z "${__res}" ]]; then
      logError "VM ${__vm} not found"
      return 1
    fi
    __vm_name=""
    while IFS= read -r _line; do
      if xe_read_param _key _value "${_line}"; then
        if [[ "${_key}" == "name-label" ]]; then
          if [[ -n "${__vm_name}" ]]; then
            logError "Multiple VMs for ${__vm}"
            return 1
          fi
          __vm_name="${_value}"
        elif [[ "${_key}" == "tags" ]]; then
          __vm_tags=()
          IFS=',' read -r -a __vm_tags <<<"${_value}"
          if [[ " ${__vm_tags[*]} " =~ [[:space:]]${XCP_CRITICAL_TAG}[[:space:]] ]]; then
            if [[ "${__vmsh_force}" != "force" ]]; then
              logError "VM ${__vm_name} has tag ${XCP_CRITICAL_TAG}. Not allowed to shutdown"
              return 1
            else
              logWarn "VM ${__vm_name} has tag ${XCP_CRITICAL_TAG}. Forced shutdown"
            fi
          else
            logTrace "VM ${__vm_name} does not have tag ${XCP_CRITICAL_TAG}"
          fi
        fi
      fi
    done <<<"${__res}"
  done

  # If we reach here, we can shut down all these VMs
  for __vm in "${@}"; do
    {
      local state
      if ! xe_vm_state_by_id state "${__vm}"; then
        logError "Failed to get state for VM ${__vm}"
      elif [[ "${state}" != "halted" ]]; then
        logTrace "Shutting down VM: ${__vm} currently in state ${state}"
        if ! xe_exec __res vm-shutdown "uuid=${__vm}" --minimal; then
          logError "Failed to shutdown VM: ${__vm}"
        else
          logInfo "Shutdown of VM ${__vm} successful"
        fi
      else
        logInfo "VM ${__vm} already halted"
      fi
    } &
  done
  logInfo "Shutdown of VMs commanded"

  return 0
}

# Wait for one or more VMs to be halted
#
# Parameters:
#   $@[in]: The VM UUIDs to wait for
# Returns:
#   0: If all VMs were halted
#   1: If one or more VMs couldn't be halted
xe_vm_wait_halted_by_id() {
  local __res __cmd __vm _line _key _value __vm_name __started_wait
  __started_wait=$(date +%s)
  for __vm in "${@}"; do
    __cmd=("vm-list" "uuid=${__vm}" "is-control-domain=false")
    __cmd+=("params=name-label,power-state")
    if ! xe_exec __res "${__cmd[@]}"; then
      logError "Failed to list VM: ${__vm}"
      return 1
    elif [[ -z "${__res}" ]]; then
      logError "VM ${__vm} not found"
      return 1
    fi
    __vm_name=""
    while IFS= read -r _line; do
      if xe_read_param _key _value "${_line}"; then
        if [[ "${_key}" == "name-label" ]]; then
          if [[ -n "${__vm_name}" ]]; then
            logError "Multiple VMs for ${__vm}"
            return 1
          fi
          __vm_name="${_value}"
        elif [[ "${_key}" == "power-state" ]]; then
          if [[ "${_value}" == "halted" ]]; then
            logInfo "VM ${__vm_name} is halted"
            break
          elif [[ "${_value}" == "shutting-down" ]] || [[ "${_value}" == "running" ]]; then
            logTrace "VM ${__vm_name} is still shutting down"
            while true; do
              sleep 1
              if ! xe_exec _value vm-param-get "uuid=${__vm}" param-name=power-state --minimal; then
                logError "Failed to get power-state for VM ${__vm}"
                return 1
              elif [[ "${_value}" == "halted" ]]; then
                logInfo "VM ${__vm_name} is finally halted"
                break
              elif [[ "${_value}" == "shutting-down" ]]; then
                logTrace "VM ${__vm_name} is still shutting down"
              elif [[ "${_value}" == "running" ]]; then
                local elapsed
                elapsed=$(($(date +%s) - __started_wait))
                if [[ ${elapsed} -gt 15 ]]; then
                  logError "VM ${__vm_name} was stucked in the running state for more than 15 seconds"
                  return 1
                else
                  logWarn "VM ${__vm_name} is still running after ${elapsed} seconds"
                fi
              else
                logError "Unexpected state ${_value} for VM ${__vm_name}"
                return 1
              fi
            done
          else
            logError "Unexpected state: ${_value} for VM ${__vm_name}"
            return 1
          fi
        else
          logWarn "Unknown key ${_key} for VM ${__vm_name}"
        fi
      fi
    done <<<"${__res}"
  done

  return 0
}

# Retrieve the current state of a VM
#
# Parameters:
#   $1[out]: The state of the VM (see xe_vm_state_by_id for possible values)
#   $1[in]: The VM name
# Returns:
#   0: If the state was retrieved
#   1: If the state couldn't be retrieved
xe_vm_state() {
  local __result_STATE="${1}"
  local __vm_name="${2}"

  if [[ -z "${__vm_name}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  local cur_state vm_uuid
  if ! xe_exec vm_uuid vm-list name-label="${vm_name}" params=uuid --minimal; then
    logError "Failed to list VMs"
    return 1
  elif [[ -z "${vm_uuid}" ]]; then
    logWarn "VM ${vm_name} not found"
    eval "${__result_STATE}='not_exist'"
    return 0
  fi

  xe_vm_state_by_id "${__result_STATE}" "${vm_uuid}"
  return $?
}

# Retrieve the current state of a VM by ID
#
# Parameters:
#   $1[out]: The state of the VM (running, halted, not_exist)
#   $1[in]: The VM UUID
# Returns:
#   0: If the state was retrieved
#   1: If the state couldn't be retrieved
xe_vm_state_by_id() {
  local __result_STATE_UUID="${1}"
  local __vm_uuid="${2}"

  if [[ -z "${__vm_uuid}" ]]; then
    logError "Invalid VM"
    return 1
  fi

  if ! xe_exec cur_state vm-param-get "uuid=${__vm_uuid}" param-name=power-state --minimal; then
    logError "Failed to get power-state for VM ${vm_uuid}"
    return 1
  elif [[ -z "${cur_state}" ]]; then
    logWarn "VM ${vm_uuid} not found"
    eval "${__result_STATE_UUID}='not_exist'"
    return 0
  fi

  case "${cur_state}" in
  running)
    eval "${__result_STATE_UUID}='running'"
    ;;
  halted)
    eval "${__result_STATE_UUID}='halted'"
    ;;
  *)
    logError "Unknown state: ${cur_state}"
    return 1
    ;;
  esac

  return 0
}

# Variables loaded externally

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
elif ! source "${XV_ROOT}/src/xe_host.sh"; then
  logFatal "Failed to load xe_host.sh"
elif ! source "${XV_ROOT}/src/xe_storage.sh"; then
  logFatal "Failed to load xe_storage.sh"
elif ! source "${XV_ROOT}/src/xe_network.sh"; then
  logFatal "Failed to load xe_network.sh"
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

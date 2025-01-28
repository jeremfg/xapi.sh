# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng network configuration

if [[ -z ${GUARD_XE_NETWORK_SH} ]]; then
  GUARD_XE_NETWORK_SH=1
else
  logWarn "Re-sourcing xe_network.sh"
  return 0
fi

# Utility function that cleans up garbage after a clean install.
# Mainly interested in deleting PIFs and Networks with "side" interfaces,
# which are remnants from interface renamer logic
#
# Returns:
#   0: Success
#   1: Failure
xe_cleanup_network() {
  local _res _res2 good_nics suspicious_nics bad_nics del_pif del_nets nic line key value host_id

  good_nics=()
  suspicious_nics=()
  bad_nics=()
  del_pif=()
  del_nets=()

  # Get host ID
  if ! xe_host_current host_id; then
    logError "Failed to get host"
    return 1
  fi

  # Get all PIFs
  if ! xe_exec _res pif-list --minimal; then
    logError "Failed to list PIFs"
    return 1
  fi

  IFS=',' read -r -a _res2 <<<"${_res}"
  for nic in "${_res2[@]}"; do
    if ! xe_exec _res pif-param-list uuid="${nic}"; then
      logError "Failed to get details for PIF ${nic}"
      return 1
    elif ! xe_parse_params "${_res}"; then
      logError "Failed to parse PIF ${nic}"
      return 1
    fi
    local device vlan
    device="${xe_params_array['device']}"
    vlan="${xe_params_array['VLAN']}"
    if [[ -z "${vlan}" ]] || [[ "${vlan}" == "-1" ]]; then
      if [[ "${device}" =~ ^eth[0-9]+$ ]]; then
        # Check if we already have the NIC in the good_nics array
        if [[ " ${good_nics[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
          logError "Duplicate NIC found: ${device}"
          return 1
        else
          logTrace "Remembering good NIC: ${device}"
          good_nics+=("${device}")
        fi
      else
        if [[ " ${suspicious_nics[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
          logError "Duplicate suspicious NIC found: ${device}"
          return 1
        else
          logTrace "Remembering suspicious NIC: ${device}"
          suspicious_nics+=("${device}")
        fi
      fi
    else
      logTrace "Skipping VLAN ${vlan} interface on ${device}"
    fi
  done

  # Perform a scan
  if ! xe_exec _res pif-scan host-uuid="${host_id}"; then
    logError "Failed to scan for PIFs"
    return 1
  fi

  # Get all PIFs
  if ! xe_exec _res pif-list --minimal; then
    logError "Failed to list PIFs"
    return 1
  fi

  # Check if new NICs have appeared
  IFS=',' read -r -a _res2 <<<"${_res}"
  for nic in "${_res2[@]}"; do
    if ! xe_exec _res pif-param-list uuid="${nic}"; then
      logError "Failed to get details for PIF ${nic}"
      return 1
    elif ! xe_parse_params "${_res}"; then
      logError "Failed to parse PIF ${nic}"
      return 1
    fi
    local device vlan
    device="${xe_params_array['device']}"
    vlan="${xe_params_array['VLAN']}"
    if [[ -z "${vlan}" ]] || [[ "${vlan}" == "-1" ]]; then
      if [[ " ${good_nics[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
        continue
      elif [[ " ${suspicious_nics[*]} " =~ [[:space:]]${device}[[:space:]] ]]; then
        continue
      else
        logInfo "New NIC found: ${device}"
        if [[ "${device}" =~ ^eth[0-9]+$ ]]; then
          good_nics+=("${device}")
        else
          suspicious_nics+=("${device}")
        fi
      fi
    else
      logTrace "Skipping VLAN ${vlan} interface on ${device}"
    fi
  done

  # Report on all suspicious NICs
  for nic in "${suspicious_nics[@]}"; do
    # If NIC contains "side", consider it bad
    if [[ "${nic}" == *"side"* ]]; then
      bad_nics+=("${nic}")
      logWarn "Bad NIC detected: ${nic}"
    else
      logWarn "Suspicious NIC detected: ${nic}"
    fi
  done

  local pif_uuid
  # Try to find matching bad networks
  for nic in "${bad_nics[@]}"; do
    # Get uuid of the NIC
    if ! xe_exec _res pif-list device="${nic}"; then
      logError "Failed to list PIFs for NIC ${nic}"
      return 1
    fi
    if ! xe_parse_params "${_res}"; then
      logError "Failed to parse PIFs for NIC ${nic}"
      return 1
    fi
    pif_uuid=${xe_params_array['uuid']}
    del_pif+=("${pif_uuid}")

    # Get the network associated with the NIC
    if xe_exec _res network-list PIF-uuids="${pif_uuid}"; then
      if ! xe_parse_params "${_res}"; then
        logError "Failed to parse network parameters ${nic}"
        return 1
      fi
      # To be safe, confirm it contains "side" in bridge name too
      if [[ "${xe_params_array['bridge']}" == *"side"* ]]; then
        logWarn "Bad network detected: ${xe_params_array['name-label']}"
        del_nets+=("${xe_params_array['uuid']}")
      else
        logWarn <<EOF
Not fully satisfied with the assosdciated network: ${xe_params_array['name-label']}
It does not contain "side" in the bridge name, so unsure if it would be OK to
delete it. Please investigate further.
EOF
      fi
    else
      logWarn "No corresponding network for: ${nic}"
    fi
  done

  # Perform deletions
  for pif_uuid in "${del_pif[@]}"; do
    if ! xe_exec _res pif-forget uuid="${pif_uuid}"; then
      logError "Failed to forget PIF ${pif_uuid}"
    else
      logInfo "PIF ${pif_uuid} forgotten"
    fi
  done
  for net_uuid in "${del_nets[@]}"; do
    if ! xe_exec _res network-destroy uuid="${net_uuid}"; then
      logError "Failed to destroy network ${net_uuid}"
    else
      logInfo "Network ${net_uuid} destroyed"
    fi
  done

  # Perform a scan again
  if ! xe_exec _res pif-scan host-uuid="${host_id}"; then
    logError "Failed to scan for PIFs"
    return 1
  fi

  # Make sure no "side" has reappeared
  if ! xe_exec _res pif-list; then
    logError "Failed to list PIFs"
    return 1
  fi
  while read -r line; do
    if xe_read_param key value "${line}"; then
      if [[ "${key}" == "device" ]]; then
        if [[ "${value}" == *"side"* ]]; then
          logError "Bad NIC detected: ${value}"
          return 1
        fi
      fi
    fi
  done <<<"${_res}"

  return 0
}

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
  if ! xe_host_current HOST_ID; then
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

# Configure a network with DHCP and multiple VLANs
#
# Parameters:
#   $1[in]: NIC to configure
#   $2[in]: Network nets
# Returns:
#   0: Success
#   1: Failure
xe_vlan_config() {
  local _nic="${1}"
  local _net_list="${2}"

  if [[ -z "${_nic}" ]]; then
    logError "NIC not provided"
    return 1
  elif [[ -z "${_net_list}" ]]; then
    logError "Networks not provided"
    return 1
  fi

  local cur_host
  if ! xe_host_current cur_host; then
    logError "Failed to get current host"
    return 1
  fi

  local nets res vlan vlan_var
  nets=()
  IFS=',' read -r -a nets <<<"${_net_list}"
  # Build an associative array of all nets
  local net
  local net_map
  net_map=()
  for net in "${nets[@]}"; do
    vlan_var="NET_${net}"
    vlan="${!vlan_var}"
    if [[ -z "${vlan}" ]]; then
      logError "VLAN not provided for ${net}"
      return 1
    fi
    net_map["${vlan}"]="${net}"
  done

  logTrace <<EOF
Configuring NIC ${_nic} with the following networks:
$(for vlan in "${!net_map[@]}"; do echo "  ${net_map[${vlan}]}: ${vlan}"; done)
EOF

  # 1. Find the PIF uuid
  local pif_uuid net_uuid
  if ! xe_identify_nic "${_nic}"; then
    logError "Failed to identify NIC ${_nic}"
    return 1
  fi
  pif_uuid="${xe_params_array['uuid']}"
  if [[ -z "${pif_uuid}" ]]; then
    logError "Failed to get PIF UUID for NIC ${_nic}"
    return 1
  fi

  # 2. Try to identify the main network
  if ! xe_exec res network-list PIF-uuids="${pif_uuid}" --minimal; then
    logError "Failed to list networks for NIC ${_nic}"
    return 1
  fi
  IFS=',' read -r -a nets <<<"${res}"
  if [[ ${#nets[@]} -eq 0 ]]; then
    logError "Failed to get networks for NIC ${_nic}"
    return 1
  else
    logWarn "NIC ${_nic} is part of multiple(s) network(s)"
    local qty
    qty=0
    for net in "${nets[@]}"; do
      qty=$((qty + 1))
      if ! xe_exec res network-param-get uuid="${net}" param-name=name-label; then
        logError "Failed to get network name for ${net}"
        return 1
      fi
      if [[ ${qty} -gt 1 ]]; then
        logWarn "Too many networks with ${res}. TODO: Find a way to filter"
        return 1
      else
        net_uuid="${net}"
      fi
    done
  fi
  logInfo "Identified main network: ${net_uuid}"

  # 3. Configure the MTU on this network
  if [[ -z "${NET_MTU}" ]]; then
    logWarn "MTU not provided, setting default to 1504"
    NET_MTU=1504
  fi

  # Check current MTU first
  if ! xe_exec res network-param-get uuid="${net_uuid}" param-name=MTU; then
    logError "Failed to get MTU for network ${net_uuid}"
    return 1
  elif [[ "${res}" -eq "${NET_MTU}" ]]; then
    logInfo "MTU already set to ${NET_MTU} for network ${net_uuid}"
  else
    logInfo "Setting MTU to ${NET_MTU} for network ${net_uuid}"
    if ! xe_exec res network-param-set uuid="${net_uuid}" MTU="${NET_MTU}"; then
      logError "Failed to set MTU for network ${net_uuid}"
      return 1
    else
      logInfo "MTU set to ${NET_MTU} for network ${net_uuid}"
    fi
  fi

  # 4. Name that interface "Trunk"
  if ! xe_exec res network-param-get uuid="${net_uuid}" param-name=name-label; then
    logError "Failed to get name for network ${net_uuid}"
    return 1
  elif [[ "${res}" == "Trunk" ]]; then
    logInfo "Name already set to Trunk for network ${net_uuid}"
  else
    logInfo "Setting name to Trunk for network ${net_uuid}"
    if ! xe_exec res network-param-set uuid="${net_uuid}" name-label=Trunk; then
      logError "Failed to set name for network ${net_uuid}"
      return 1
    else
      logInfo "Name set to Trunk for network ${net_uuid}"
    fi
  fi

  # 5. Configure VLANs
  local vlan_mtu vlan_uuid vlan_pif
  vlan_mtu=$((NET_MTU - 4))
  for vlan in "${!net_map[@]}"; do
    net="${net_map[${vlan}]}"
    # First check if such a network already exists
    if ! xe_exec vlan_uuid network-list name-label="${net}" --minimal; then
      logError "Failed to list networks while searching for ${net}"
      return 1
    elif [[ -n "${vlan_uuid}" ]]; then
      logInfo "Network ${net} already exists"
    elif ! xe_exec vlan_uuid network-create name-label="${net}" MTU="${vlan_mtu}"; then
      logError "Failed to create network ${net} for VLAN ${vlan}"
      return 1
    else
      logInfo "Network ${net} created for VLAN ${vlan}: ${vlan_uuid}"
    fi

    # Check if we already have a vlan for this network
    if ! xe_exec vlan_pif vlan-list tag="${vlan}" --minimal; then
      logError "Failed to list VLAN ${vlan}"
      return 1
    elif [[ -n "${vlan_pif}" ]]; then
      logInfo "VLAN ${vlan} already exists"
    elif ! xe_exec vlan_pif pool-vlan-create network-uuid="${vlan_uuid}" vlan="${vlan}" pif-uuid="${pif_uuid}"; then
      logError "Failed to create VLAN ${vlan}"
      return 1
    else
      logInfo "VLAN ${vlan} created: ${res}"
    fi
  done

  if [[ -n "${pif_uuid}" ]]; then
    logInfo "Configuring management IF on: ${pif_uuid}"
    # Chek if we already have DHCP turned on for it
    if ! xe_exec res pif-param-get uuid="${pif_uuid}" param-name=IP-configuration-mode; then
      logError "Failed to get IP configuration mode"
      return 1
    elif [[ "${res}" == "DHCP" ]]; then
      logInfo "Management IF already configured with DHCP"
    elif ! xe_exec res pif-reconfigure-ip uuid="${pif_uuid}" mode=dhcp; then
      logError "Failed to configure management IP"
      return 1
    else
      logInfo "Management IP configured"
    fi
  fi

  return 0
}

# Configure the management interface
#
# Parameters:
#   $1[in]: NIC to configure
# Returns:
#   0: Success
#   1: Failure
xe_mgt_config() {
  local _nic="${1}"

  if [[ -z "${_nic}" ]]; then
    logError "NIC not provided"
    return 1
  fi

  # 1. Find the PIF uuid
  local res nets pif_uuid net_uuid
  if ! xe_identify_nic "${_nic}"; then
    logError "Failed to identify NIC ${_nic}"
    return 1
  fi
  pif_uuid="${xe_params_array['uuid']}"
  if [[ -z "${pif_uuid}" ]]; then
    logError "Failed to get PIF UUID for NIC ${_nic}"
    return 1
  fi

  # 2. Try to identify the main network associated with it
  if ! xe_exec res network-list PIF-uuids="${pif_uuid}" --minimal; then
    logError "Failed to list networks for NIC ${_nic}"
    return 1
  fi
  IFS=',' read -r -a nets <<<"${res}"
  if [[ ${#nets[@]} -eq 0 ]]; then
    logError "Failed to get networks for NIC ${_nic}"
    return 1
  else
    logWarn "NIC ${_nic} is part of multiple(s) network(s)"
    local qty net
    qty=0
    for net in "${nets[@]}"; do
      qty=$((qty + 1))
      if ! xe_exec res network-param-get uuid="${net}" param-name=name-label; then
        logError "Failed to get network name for ${net}"
        return 1
      fi
      if [[ ${qty} -gt 1 ]]; then
        logWarn "Too many networks with ${res}. TODO: Find a way to filter"
        return 1
      else
        net_uuid="${net}"
      fi
    done
  fi
  logInfo "Identified main network: ${net_uuid}"

  # 3. Name that interface "Mgmt"
  if ! xe_exec res network-param-get uuid="${net_uuid}" param-name=name-label; then
    logError "Failed to get name for network ${net_uuid}"
    return 1
  elif [[ "${res}" == "Mgmt" ]]; then
    logInfo "Name already set to Mgmt for network ${net_uuid}"
  else
    logInfo "Setting name to Mgmt for network ${net_uuid}"
    if ! xe_exec res network-param-set uuid="${net_uuid}" name-label=Mgmt; then
      logError "Failed to set name for network ${net_uuid}"
      return 1
    else
      logInfo "Name set to Mgmt for network ${net_uuid}"
    fi
  fi

  # 4. Check the pif is using the proper static configuration
  if ! xe_exec res pif-param-get uuid="${pif_uuid}" param-name=IP-configuration-mode; then
    logError "Failed to get IP configuration mode for management IF"
    return 1
  elif [[ "${res}" != "Static" ]]; then
    logInfo "Management IF not configured statically"
  elif ! xe_exec res pif-param-get uuid="${pif_uuid}" param-name=IP; then
    logError "Failed to get IP for management IF"
    return 1
  elif [[ "${res}" != "${XEN_MGT}" ]]; then
    logInfo "Management IF has wrong IP: ${res}"
  elif ! xe_exec res pif-param-get uuid="${pif_uuid}" param-name=netmask; then
    logError "Failed to get netmask for management IF"
    return 1
  elif [[ "${res}" != "${XEN_MASK}" ]]; then
    logInfo "Management IF has wrong netmask: ${res}"
  elif ! xe_exec res pif-param-get uuid="${pif_uuid}" param-name=gateway; then
    logError "Failed to get gateway for management IF"
    return 1
  elif [[ "${res}" != "${XEN_GW}" ]]; then
    logInfo "Management IF has wrong gateway: ${res}"
  else
    logInfo "Management IF already configured"
    # TODO Set network name to Mgmt
    return 0
  fi

  # If we reach here, we need to reconfigure the management IF
  local my_cmd
  my_cmd=("pif-reconfigure-ip" "uuid=${pif_uuid}" "mode=Static")
  my_cmd+=("IP=${XEN_MGT}")
  my_cmd+=("netmask=${XEN_MASK}")
  my_cmd+=("gateway=${XEN_GW}")
  if ! xe_exec res "${my_cmd[@]}"; then
    logError "Failed to reconfigure management IF"
    return 1
  else
    logInfo "Management IF reconfigured"
  fi

  return 0
}

# Get the UUID of a network by name
#
# Parameters:
#   $1[out]: The UUID of the network
#   $2[in]: The name of the network
# Returns:
#   0: If the network was found
#   1: If the network couldn't be found
xe_net_uuid_by_name() {
  local __result_net_uuid="${1}"
  local _net_name="${2}"

  local res
  if ! xe_exec res network-list name-label="${_net_name}" --minimal; then
    logError "Failed to list networks"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "No network found with name ${_net_name}"
    return 1
  else
    eval "${__result_net_uuid}='${res}'"
    logInfo "Network ${_net_name} found: ${res}"
    return 0
  fi
}

# Variables loaded externally
if [[ -z "${XEN_MGT}" ]]; then XEN_MGT=""; fi
if [[ -z "${XEN_MASK}" ]]; then XEN_MASK=""; fi
if [[ -z "${XEN_GW}" ]]; then XEN_GW=""; fi

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

# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng host configuration

if [[ -z ${GUARD_XE_HOST_SH} ]]; then
  GUARD_XE_HOST_SH=1
else
  return 0
fi

# Get the current host
#
# Parameters:
#   $1[out]: ID of the host
# Returns:
#   0: If host was found
#   1: If host was not found
xe_current_host() {
  local _id="$1"

  local res
  if ! xe_exec res host-list --minimal; then
    logError "Failed to get host"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Host not found"
    return 1
  elif [[ "${res}" == *","* ]]; then
    logError "Multiple hosts found"
    return 1
  else
    eval "${_id}='${res}'"
    logInfo "Host: ${res} found"
    return 0
  fi
}

# Create a pool and join it once it exists
# NOTE: This is a missnomer, a pool always exists.
# We will just be setting the label
#
# Parameters:
#   $1[in]: Pool name
# Returns:
#   0: If pool was created and joined
#   1: If any error occurred
xe_pool_create() {
  local _name="$1"

  local cur_host
  if ! xe_current_host cur_host; then
    logError "Failed to get current host"
    return 1
  fi

  local res pool_uuid
  # Get the pool
  if ! xe_exec pool_uuid pool-list --minimal; then
    logError "Failed to get pool"
    return 1
  elif [[ -z "${pool_uuid}" ]]; then
    logError "Pool not found"
    return 1
  elif ! xe_exec res pool-param-get uuid="${pool_uuid}" param-name=name-label --minimal; then
    logError "Failed to get pool name"
    return 1
  elif [[ "${res}" == "${_name}" ]]; then
    logInfo "Pool already configured"
    return 0
  else
    logInfo "Pool found: ${res}"
    if ! xe_exec res pool-param-set uuid="${pool_uuid}" name-label="${_name}"; then
      logError "Failed to set pool name"
      return 1
    else
      logInfo "Pool name set to ${_name}"
    fi
  fi
}

# Get the current pool
#
# Parameters:
#   $1[out]: ID of the pool
# Returns:
#   0: If pool was found
#   1: If pool was not found
xe_current_pool() {
  local _id="$1"

  local res
  if ! xe_exec res pool-list --minimal; then
    logError "Failed to get pool"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Pool not found"
    return 1
  elif [[ "${res}" == *","* ]]; then
    logError "Multiple pools found"
    return 1
  else
    eval "${_id}='${res}'"
    logInfo "Pool: ${res} found"
    return 0
  fi
}

# Check if the current host is the pool master
#
# Returns:
#   0: If host is the pool master
#   1: If any error occurred
#   2: If host is not the pool master
xe_is_pool_masater() {
  local cur_host cur_pool cur_master res

  if ! xe_current_host cur_host; then
    logError "Failed to get current host"
    return 1
  fi
  if ! xe_current_pool cur_pool; then
    logError "Failed to get current pool"
    return 1
  fi

  if ! xe_exec res pool-param-get uuid="${cur_pool}" param-name=master --minimal; then
    logError "Failed to get pool master"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Pool master not found"
    return 1
  else
    cur_master="${res}"
    logInfo "Pool master: ${cur_master}"
  fi

  if [[ "${cur_host}" == "${cur_master}" ]]; then
    logInfo "Host is the pool master"
    return 0
  else
    logInfo "Host is not the pool master"
    return 2
  fi
}

# Configure email notifications
#
# Parameters:
#   $1[in]: sendemail.conf file
xe_configure_email() {
  local _config="$1"

  if [[ -z "${BIN_DIR}" ]]; then
    logError "BIN_DIR is not set"
    return 1
  fi
  if ! xe_is_pool_masater; then
    logError "Host is not the pool master. Do not configure email"
    return 0
  fi
  if [[ -f "${_config}" ]]; then
    logInfo "Mail configuration found"
    if ! config_load "${_config}"; then
      logError "Failed to load mail configuration"
      return 1
    fi
  else
    logError "Mail configuration not found"
    return 1
  fi

  # Ok, we need to configure emails
  local cur_pool
  if ! xe_current_pool cur_pool; then
    logError "Failed to get current pool"
    return 1
  fi

  local res
  if ! xe_exec res pool-param-set uuid="${cur_pool}" other-config:mail-destination="${SYSADMIN}"; then
    logError "Failed to set email destination"
    return 1
  else
    logInfo "XCP-ng's smail destination set to ${SYSADMIN}"
  fi

  if ! xe_exec res pool-param-set uuid="${cur_pool}" other-config:ssmtp-mailhub="${SMTP}"; then
    logError "Failed to set SMTP server"
    return 1
  else
    logInfo "XCP-ng's SMTP server set to ${SMTP}"
  fi

  # Configure SMTP parameters
  local cfg_file_dst="/etc/mail-alarm.conf"
  local cfg_file_src="/etc/ssmtp/ssmtp.conf"
  if [[ ! -f "${cfg_file_src}" ]]; then
    logError "ssmtp does not exist"
    return 1
  fi

  # Check if simlink already exists and points to the right location
  if [[ -L "${cfg_file_dst}" ]]; then
    if [[ "$(readlink "${cfg_file_dst}" || true)" == "${cfg_file_src}" ]]; then
      logInfo "ssmtp.conf already symlinked"
    else
      logError "ssmtp.conf is not symlinked to mail-alarm.conf"
      return 1
    fi
  elif [[ -f "${cfg_file_dst}" ]]; then
    logError "mail-alarm.conf already exists"
    return 1
  else
    if ! ln -s "${cfg_file_src}" "${cfg_file_dst}"; then
      logError "Failed to create symlink to ssmtp.conf for XCP-ng"
      return 1
    else
      logInfo "Created symlink to ssmtp.conf for XCP-ng"
    fi
  fi

  # Install the XCP-ng notification test script
  file=$(
    cat <<EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test XCP-ng notifications
# (This file was automatically generated during installation)

# Determine BPKG's global prefix
if [[ -z "\${PREFIX}" ]]; then
  if [[ \$(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="\${HOME}/.local"
  fi
fi

if ! source "\${PREFIX}/lib/slf4.sh"; then
  echo "ERROR: Failed to load slf4.sh"
  exit 1
fi
if ! source "${XH_ROOT}/src/xe_utils.sh"; then
  logError "Failed to load xe_utils.sh"
  exit 1
fi

# XCP-ng message levels
LVL_ERROR=1
LVL_WARN=2
LVL_INFO=3
LVL_DEBUG=4
LVL_TRACE=5

if ! xe_exec res host-list name-label=\$(hostname) --minimal; then
  logError "Failed to get host: \$(res)"
  exit 1
elif [[ -z "\${res}" ]]; then
  logError "Host not found"
  exit 1
elif [[ "\${res}" == *","* ]]; then
  logError "Multiple hosts found"
  exit 1
else
  HOST_ID=\${res}
fi

if ! xe_exec message-create name="Test" body="This is a test notification" priority=\${LVL_INFO} host-uuid=\${HOST_ID}; then
  logError "Failed to send notification to XCP-ng"
  exit 1
else
  logInfo "Test notification sent succesfully"
fi

EOF
  )

  logInfo "Installing notification test script"
  if ! echo "${file}" >"${BIN_DIR}/notification_test.sh"; then
    logWarn "Failed to install notification test script"
  fi
  if ! chmod +x "${BIN_DIR}/notification_test.sh"; then
    logWarn "Failed to make notification test script executable"
  fi

  return 0
}

# Constants to please shellcheck
if [[ -z ${SYSADMIN} ]]; then
  SYSADMIN=""
fi
if [[ -z ${SMTP} ]]; then
  SMTP=""
fi

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
XH_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XH_SOURCE}" ]]; do # resolve $XH_SOURCE until the file is no longer a symlink
  XH_ROOT=$(cd -P "$(dirname "${XH_SOURCE}")" >/dev/null 2>&1 && pwd)
  XH_SOURCE=$(readlink "${XH_SOURCE}")
  [[ ${XH_SOURCE} != /* ]] && XH_SOURCE=${XH_ROOT}/${XH_SOURCE} # if $XH_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XH_ROOT=$(cd -P "$(dirname "${XH_SOURCE}")" >/dev/null 2>&1 && pwd)
XH_ROOT=$(realpath "${XH_ROOT}/..")

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
# shellcheck disable=SC1091 # Ignore non-constant source
if ! source "${PREFIX}/lib/config.sh"; then
  logFatal "Failed to load config.sh"
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

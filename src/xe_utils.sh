# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Utility functions for XenAPI usage

if [[ -z ${GUARD_XE_UTILS_SH} ]]; then
  GUARD_XE_UTILS_SH=1
else
  logWarn "Re-sourcing xe_utils.sh"
  return 0
fi

# Create a remote connection to the XAPI
#
# Parameters:
#   $1[in]    : The XAPI FQDN/IP address to use
#   $XEN_PORT : TCP port to conect (environment variable)
#   $XEN_PWD  : Password to use for the connection (environment variable)
#   $XEN_USER : User to use for the connection (environment variable)
# Returns:
#   0: If the connection was successfully tested
#   1: If an error occurred
xe_create_connection() {
  local __host="$1"
  if [[ -z ${__host} ]]; then
    logError "Host not specified"
    return 1
  elif [[ -z ${XEN_USER} ]]; then
    logError "User not specified"
    return 1
  elif [[ -z ${XEN_PWD} ]]; then
    logError "Password not specified"
    return 1
  elif [[ -z ${XEN_PORT} ]]; then
    logError "Port not specified"
    return 1
  fi

  if ! command -v xe &>/dev/null; then
    logError "xe tool not found"
    return 1
  fi

  # Make sure the previous login is cleared
  XE_LOGIN=()

  local tmp_login
  tmp_login=("-s" "${__host}")
  tmp_login+=("-p" "${XEN_PORT}")
  tmp_login+=("-u" "${XEN_USER}")
  tmp_login+=("-pw" "${XEN_PWD}")

  local __xe
  if ! xe_exec __xe "${tmp_login[@]}" "help"; then
    logError "Failed to connect to XAPI"
    return 1
  else
    XE_LOGIN=("${tmp_login[@]}")
    XE_BACKUP_HOST="${__host}"
    XE_BACKUP_USR="${XEN_USER}"
    XE_BACKUP_PWD="${XEN_PWD}"
    XE_BACKUP_PORT="${XEN_PORT}"
  fi
}

# Execute a xe command
#
# Parameters:
#   $1[out]: The command output
#   $@[in]: The command to execute
# Returns:
#   0: If the command was successfully executed
#   1: If an error occurred (actual result code returned)
xe_exec() {
  local __result_stdout="$1"
  shift

  # Check tool is available
  if ! command -v xe &>/dev/null; then
    logError "xe tool not found"
    return 1
  fi

  local __actual_cmd __printable_cmd __result __return_code
  if [[ -z "${XE_LOGIN[*]}" ]]; then
    __actual_cmd=("xe" "$@")
    __printable_cmd=("xe" "$@")
  else
    __actual_cmd=("xe" "$@" "${XE_LOGIN[@]}")
    __printable_cmd=("${XE_LOGIN[@]}")
    __printable_cmd[7]="********"
    __printable_cmd=("xe" "$@" "${__printable_cmd[*]}")
  fi

  logTrace "Executing command: ${__printable_cmd[*]}"
  __result=$("${__actual_cmd[@]}" 2>&1)
  __return_code=$?

  if [[ ${__return_code} -ne 0 ]]; then
    logError <<EOF
Failed to Execute command: ${__printable_cmd[*]}

Return Code: ${__return_code}
Output:
${__result}
EOF
  else
    logTrace "Command executed successfully\n${__result}"
  fi

  eval "${__result_stdout}='${__result}'"

  # shellcheck disable=SC2248
  return ${__return_code}
}

# Execute a command on a XCP-ng host
#
# Parameters:
#   $1[out]: The command output
#   $@[in]: The command to execute
# Returns:
#   0: If the command was successfully executed
#   1: If an error occurred (actual result code returned)
xe_host_exec() {
  local __stdout_xe_host_exec="${1}"
  shift

  local __host_exec_ret_code

  if [[ -n "${XE_LOGIN[*]}" ]]; then
    # We need to execute remotely
    xe_ssh_exec "${__stdout_xe_host_exec}" "${@}"
    return $?
  fi

  # If we reach here, it means we need to execute the command locally
  local __host_exec_ret_code __host_exec_output
  logTrace "Executing host command: ${*}"
  __host_exec_output=$("${@}" 2>&1)
  __host_exec_ret_code=$?

  if [[ ${__host_exec_ret_code} -ne 0 ]]; then
    logError <<EOF
Failed to execute host command: ${*}

Return Code: ${__host_exec_ret_code}
Output:
${__host_exec_output}
EOF
  else
    logTrace "Command executed successfully${IFS}${__host_exec_output}"
  fi

  printf -v "${__stdout_xe_host_exec}" '%s' "${__host_exec_output}"

  # shellcheck disable=SC2248
  return ${__host_exec_ret_code}
}

# Execute a command on a XCP-ng host via SSH
#
# Parameters:
#   $1[out]: The command output
#   $@[in]: The command to execute
# Returns:
#   0: If the command was successfully executed
#   1: If an error occurred (actual result code returned)
xe_ssh_exec() {
  local __result_stdout="${1}"
  shift

  if ! command -v ssh &>/dev/null; then
    logError "ssh tool not found"
    return 1
  elif ! command -v sshpass &>/dev/null; then
    logError "sshpass tool not found"
    return 1
  elif [[ -z "${XE_LOGIN}" ]]; then
    logError "No XAPI connection available"
    return 1
  fi

  # Since we have XE_LOGIN, we can assume we have the credentials for SSH as well
  local __actual_cmd __printable_cmd __result __return_code
  __actual_cmd=("sshpass" "-p" "${XE_BACKUP_PWD}")
  __actual_cmd+=("ssh" "-o" "StrictHostKeyChecking=no")
  __actual_cmd+=("${XE_BACKUP_USR}@${XE_BACKUP_HOST}")
  __actual_cmd+=("$@")

  # Make a printable version of the command that obfuscates the password
  __printable_cmd=("${__actual_cmd[@]}")
  __printable_cmd[2]="********"

  logTrace "Executing remote command: ${__printable_cmd[*]}"
  __result=$("${__actual_cmd[@]}" 2>&1)
  __return_code=$?

  if [[ ${__return_code} -ne 0 ]]; then
    logError <<EOF
Failed to execute remote command: ${__printable_cmd[*]}

Return Code: ${__return_code}
Output:
${__result}
EOF
  else
    logTrace "Command executed successfully\n${__result}"
  fi

  printf -v "${__result_stdout}" '%s' "${__result}"

  # shellcheck disable=SC2248
  return ${__return_code}
}

# Parse a list of parameters
#
# Parameters:
#   $1[in]: Actual command response to parse
# Returns:
#   0: If successfully parsed
#   1: If an error occurred
xe_parse_params() {
  local __result_response="$1"

  if [[ -z "${__result_response}" ]]; then
    logError "Parameters undefined"
    return 1
  fi

  # Ensure the associative array is cleared
  for key in "${!xe_params_array[@]}"; do
    unset "xe_params_array[${key}]"
  done

  local line key value
  while IFS= read -r line; do
    if xe_read_param key value "${line}"; then
      # Assign the key-value pair to the associative array
      xe_params_array["${key}"]="${value}"
    fi
  done <<<"${__result_response}"

  return 0
}

# Parse a key=value pair
#
# Parameters:
#   $1[out]: key read
#   $2[out]: value read
#   $3[in] : line to parse
# Returns:
#   0: If successfully parsed
#   1: If the line did not contain relevant data
xe_read_param() {
  local __result_key="$1"
  local __result_value="$2"
  local __line="$3"

  # Remove leading and trailing whitespace
  __line=$(echo "${__line}" | sed 's/^[ \t]*//;s/[ \t]*$//')

  # Skip empty lines
  if [[ -z "${__line}" ]]; then
    return 1
  fi

  # Split the line into key and value
  local _key_ _value_
  _key_=$(echo "${__line}" | cut -d ':' -f 1 | sed 's/[ \t]*$//' || true)
  _value_=$(echo "${__line}" | cut -d ':' -f 2- | sed 's/^[ \t]*//' || true)

  # Make sure key and value are not empty
  if [[ -z "${_key_}" ]]; then
    logWarn "Skipping invalid line: ${__line}"
    return 1
  fi

  # Remove " ( RO)" from the key if present
  # shellcheck disable=SC2001 # I prefer using sed to variable expansion
  _key_=$(echo "${_key_}" | sed 's/ \(.*\)$//')

  # Assign the key-value pair to the output variables
  eval "${__result_key}='${_key_}'"
  eval "${__result_value}='${_value_}'"

  return 0
}

# Stringify the array variable so it can be used in other inputs
#
# Parameters:
#   $1[out]: Resulting string
xe_join_params() {
  local __result_string="$1"

  local key res
  # Iterate over the associative array and build the result string
  for key in "${!xe_params_array[@]}"; do
    res="${res}\n${key}=${xe_params_array[${key}]}"
  done

  eval "${__result_string}='${res}'"
}

# Store login parameters (Used when working remotely)
if [[ -z ${XE_LOGIN} ]]; then XE_LOGIN=""; fi

# Variables
XE_BACKUP_HOST=""
XE_BACKUP_USR=""
XE_BACKUP_PWD=""
# shellcheck disable=SC2034
XE_BACKUP_PORT=""

# Associative array used for parameter parsing
declare -gA xe_params_array

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
XE_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XE_SOURCE}" ]]; do # resolve $XE_SOURCE until the file is no longer a symlink
  XE_ROOT=$(cd -P "$(dirname "${XE_SOURCE}")" >/dev/null 2>&1 && pwd)
  XE_SOURCE=$(readlink "${XE_SOURCE}")
  [[ ${XE_SOURCE} != /* ]] && XE_SOURCE=${XE_ROOT}/${XE_SOURCE} # if $XE_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XE_ROOT=$(cd -P "$(dirname "${XE_SOURCE}")" >/dev/null 2>&1 && pwd)
XE_ROOT=$(realpath "${XE_ROOT}/..")

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

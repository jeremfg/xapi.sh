# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# Utility functions for XenAPI usage

if [[ -z ${GUARD_XE_UTILS_SH} ]]; then
  GUARD_XE_UTILS_SH=1
else
  return 0
fi

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

  local __result __return_code
  if [[ -z ${XE_LOGIN} ]]; then
    __result=$(xe "$@" 2>&1)
    __return_code=$?
  else
    __result=$(xe "${XE_LOGIN}" "$@" 2>&1)
    __return_code=$?
  fi

  if [[ ${__return_code} -ne 0 ]]; then
    logError <<EOF
Failed to Execute command: xe ${XE_LOGIN} $*

Return Code: ${__return_code}
Output:
${__result}
EOF
  fi

  eval "${__result_stdout}='${__result}'"

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
    # Remove leading and trailing whitespace
    line=$(echo "${line}" | sed 's/^[ \t]*//;s/[ \t]*$//')

    # Skip empty lines
    if [[ -z "${line}" ]]; then
      continue
    fi

    # Split the line into key and value
    key=$(echo "${line}" | cut -d ':' -f 1 | sed 's/[ \t]*$//' || true)
    value=$(echo "${line}" | cut -d ':' -f 2- | sed 's/^[ \t]*//' || true)

    # Make sure key and value are not empty
    if [[ -z "${key}" ]] || [[ -z "${value}" ]]; then
      logWarn "Skipping invalid line: ${line}"
      continue
    fi

    # Remove " ( RO)" from the key if present
    # shellcheck disable=SC2001 # I prefer using sed to variable expansion
    key=$(echo "${key}" | sed 's/ \(.*\)//')

    # Assign the key-value pair to the associative array
    xe_params_array["${key}"]="${value}"

  done <<<"${__result_response}"

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

# Associative array used for parameter parsing
declare -gA xe_params_array

# Store login parameters (Used when working remotely)
if [[ -z ${XE_LOGIN} ]]; then
  XE_LOGIN=""
fi

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

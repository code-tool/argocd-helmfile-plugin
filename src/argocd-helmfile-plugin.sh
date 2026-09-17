#!/bin/bash

## specially handled ENV vars
# HELM_BINARY - custom path to helm binary
# HELM_TEMPLATE_OPTIONS - helm template --help
# HELMFILE_BINARY - custom path to helmfile binary
# HELMFILE_GLOBAL_OPTIONS - helmfile --help
# HELMFILE_TEMPLATE_OPTIONS - helmfile template --help
# HELMFILE_HELMFILE - a complete helmfile.yaml (ignores standard helmfile.yaml and helmfile.d if present based on strategy)
# HELMFILE_HELMFILE_STRATEGY - REPLACE or INCLUDE
# HELMFILE_INIT_SCRIPT_FILE - path to script to execute during the init phase
# HELMFILE_ENV_FILE - path to env file (or anything) to source
# HELMFILE_CACHE_CLEANUP - run helmfile cache cleanup on init
# HELMFILE_REPO_CACHE_TIMEOUT - seconds to cache the repo update process
# HELMFILE_USE_CONTEXT_NAMESPACE - do not set helmfile namespace to ARGOCD_APP_NAMESPACE (for multi-namespace apps)
# HELMFILE_DISCOVERY_RESPONSE - truthy value for forced response
# PLUGIN_APP_HOME - per-application HOME directory, perform variable expansion
# HELM_HOME - deprecated alias for PLUGIN_APP_HOME
# HELM_CACHE_HOME - perform variable expansion
# HELM_CONFIG_HOME - perform variable expansion
# HELM_DATA_HOME - perform variable expansion

# NOTE: only 1 -f value/file/dir is used by helmfile, while you can specific -f multiple times
# only the last one matters and all previous -f arguments are irrelevant

# NOTE: helmfile pukes if both helmfile.yaml and helmfile.d are present (and -f isn't explicity used)

## standard build environment
## https://argoproj.github.io/argo-cd/user-guide/build-environment/
# ARGOCD_APP_NAME - name of application
# ARGOCD_APP_NAMESPACE - destination application namespace.
# ARGOCD_APP_REVISION - the resolved revision, e.g. f913b6cbf58aa5ae5ca1f8a2b149477aebcbd9d8
# ARGOCD_APP_SOURCE_PATH - the path of the app within the repo
# ARGOCD_APP_SOURCE_REPO_URL the repo's URL
# ARGOCD_APP_SOURCE_TARGET_REVISION - the target revision from the spec, e.g. master.

## cmp
# - https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/
# - https://github.com/argoproj/argo-cd/blob/master/docs/proposals/parameterized-config-management-plugins.md
# - https://github.com/argoproj/argo-cd/blob/master/docs/proposals/parameterized-config-management-plugins.md#how-will-the-cmp-know-what-parameter-values-are-set
#
# if parameter is absent in the application spec (not present), ENV var is not set at all
# boolean params are currently (2.6) still free-form strings to the user

# each manifest generation cycle calls git reset/clean before (between init and generate it is NOT ran)
# init is called before every manifest generation
# it can be used to download dependencies, etc, etc

# set by Argo CD from the destination cluster, see normalize_kube_version()
# KUBE_VERSION="<major>.<minor>[.<patch>]" (may carry a "v" prefix or vendor suffix)
# KUBE_API_VERSIONS="v1,apps/v1,..."

# exit on errors, unset variables and failures inside pipelines
set -Eeuo pipefail

# debugging execution
#
# Enable this only if you are debugging an issue.
# Leaving this on causes excessive space consumption on etcd database.
if [[ "${DEBUG:-}" == "1" ]]; then
  set -x
fi

echoerr() { printf "%s\n" "$*" >&2; }

# report where a failure happened, the failing tool prints its own error
trap 'echoerr "${SCRIPT_NAME:-plugin}: ${phase:-startup} failed (exit $?) at line ${LINENO}"' ERR

# https://unix.stackexchange.com/questions/294835/replace-environment-variables-in-a-file-with-their-actual-values
variable_expansion() {
  # prefer envsubst if available, fallback to perl
  if command -v envsubst >/dev/null; then
    printf "%s" "$*" | envsubst
  else
    printf "%s" "$*" | perl -pe 's/\$(\{)?([a-zA-Z_]\w*)(?(1)\})/$ENV{$2}/g'
  fi
}

# truthy_test "${FOO:-false}" && echo "yes \$FOO"
# true, 1 and yes (any case) are truthy, everything else is not
truthy_test() {
  case "${1,,}" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# split a free-form options string into words (no glob expansion)
# usage: split_words <array name> <string>
split_words() {
  local -n _split_words_out="${1}"
  read -r -d '' -a _split_words_out <<<"${2}" || true
}

# export <prefix>NAME=value as NAME=value
# https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/2.3-2.4/
export_prefixed_env() {
  local prefix="${1}" n v name
  while IFS='=' read -r -d '' n v; do
    [[ "${n}" == "${prefix}"* ]] || continue
    name="${n#"${prefix}"}"
    if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echoerr "WARNING: ignoring ${n}, '${name}' is not a valid variable name"
      continue
    fi
    export "${name}=${v}"
  done < <(env -0)
}

# Argo CD passes the cluster version as reported by the API server, which may
# carry a leading "v", a trailing "+" or a vendor suffix:
#   1.29, 1.29+, v1.29.3, 1.29.0+k3s1, 1.29.0-eks-5e0fdde
# https://github.com/argoproj/argo-cd/issues/8249
# Prints "<major>.<minor>[.<patch>]", or nothing if the value is not usable.
normalize_kube_version() {
  local version="${1#v}"
  version="${version%%[+-]*}"
  if [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "${version}"
  fi
}

cache_set_time() {
  local key="${1}"
  touch "${HOME}/${key}"
}

cache_get_time() {
  local key="${1}"
  if [[ -f "${HOME}/${key}" ]]; then
    stat -c %Y "${HOME}/${key}"
  fi
}

cache_is_valid() {
  local key="${1}"
  local timeout="${2}"
  local cache_time current_time

  if [[ -z "${key}" ]]; then
    return 1
  fi

  if [[ ! "${timeout}" =~ ^[0-9]+$ || "${timeout}" -lt 1 ]]; then
    return 1
  fi

  cache_time=$(cache_get_time "${key}")
  if [[ -z "${cache_time}" ]]; then
    return 1
  fi

  current_time=$(date +%s)
  if ((current_time - cache_time > timeout)); then
    return 1
  fi
}

cache_is_expired() {
  ! cache_is_valid "${1}" "${2}"
}

# detect and validate tool versions, only needed for phases that run them
check_tool_versions() {
  local helm_version helmfile_version
  local helm_major helm_minor helmfile_major helmfile_minor

  if ! helm_version=$("${helm}" version --template '{{.Version}}' 2>/dev/null); then
    echoerr "failed to run '${helm} version', helm >= 3.6 is required"
    exit 1
  fi
  echoerr "helm version ${helm_version}"

  if [[ ! "${helm_version}" =~ ^v([0-9]+)\.([0-9]+)\. ]]; then
    echoerr "unable to parse helm version '${helm_version}', helm >= 3.6 is required"
    exit 1
  fi
  helm_major="${BASH_REMATCH[1]}"
  helm_minor="${BASH_REMATCH[2]}"

  # 3.6 added "helm template --kube-version"
  if ((helm_major < 3 || (helm_major == 3 && helm_minor < 6))); then
    echoerr "helm ${helm_version} is not supported, helm >= 3.6 is required"
    exit 1
  fi

  if ! helmfile_version=$("${helmfile}" --version 2>/dev/null); then
    echoerr "failed to run '${helmfile} --version', helmfile >= 1 is required"
    exit 1
  fi
  echoerr "${helmfile_version}"

  if [[ ! "${helmfile_version}" =~ version\ v?([0-9]+)\.([0-9]+)\. ]]; then
    echoerr "unable to parse helmfile version '${helmfile_version}', helmfile >= 1 is required"
    exit 1
  fi
  helmfile_major="${BASH_REMATCH[1]}"
  helmfile_minor="${BASH_REMATCH[2]}"

  if ((helmfile_major < 1)); then
    echoerr "${helmfile_version} is not supported, helmfile >= 1 is required"
    exit 1
  fi

  # older helmfile runs "helm version --client", which Helm 4 removed
  # https://github.com/helmfile/helmfile/issues/2268
  if ((helm_major >= 4 && helmfile_major == 1 && helmfile_minor < 2)); then
    echoerr "${helmfile_version} does not support helm ${helm_version}, helmfile >= 1.2 is required for helm 4"
    exit 1
  fi
}

# resolve a binary from an explicit path or PATH
resolve_binary() {
  local name="${1}" custom="${2}"
  if [[ "${custom}" ]]; then
    echo "${custom}"
  elif ! command -v "${name}"; then
    echoerr "${name} not found in PATH"
    return 1
  fi
}

# exit immediately if no phase is passed in
if [[ -z "${1:-}" ]]; then
  echoerr "invalid invocation"
  exit 1
fi

phase="${1}"
SCRIPT_NAME=$(basename "${0}")

# export vars unprefixed, params (PARAM_) take precedence over ENV vars (ARGOCD_ENV_)
# https://github.com/argoproj/argo-cd/blob/master/docs/proposals/parameterized-config-management-plugins.md#how-will-the-cmp-know-what-parameter-values-are-set
export_prefixed_env "ARGOCD_ENV_"
export_prefixed_env "PARAM_"

# immediately correct PATH if necessary
PATH=$(variable_expansion "${PATH}")
export PATH

# expand nested variables
for var in HELMFILE_GLOBAL_OPTIONS HELMFILE_TEMPLATE_OPTIONS HELM_TEMPLATE_OPTIONS HELMFILE_INIT_SCRIPT_FILE; do
  if [[ "${!var:-}" ]]; then
    printf -v "${var}" "%s" "$(variable_expansion "${!var}")"
  fi
done

HELMFILE_ENV_FILE=$(variable_expansion "${HELMFILE_ENV_FILE:-.argo-cd-helmfile-env}")
if [[ -f "${HELMFILE_ENV_FILE}" ]]; then
  echoerr "sourcing env file: ${HELMFILE_ENV_FILE}"
  # env files are user content and may reference unset variables
  set +u
  # shellcheck disable=SC1090
  source "${HELMFILE_ENV_FILE}"
  set -u
fi

for var in HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME; do
  if [[ "${!var:-}" ]]; then
    export "${var}=$(variable_expansion "${!var}")"
  fi
done

# per-application home directory, later used as HOME so apps do NOT share
# helm repositories, registry logins, caches, etc.
# HELM_HOME is accepted as a deprecated alias (helm ignores it since v3).
PLUGIN_APP_HOME="${PLUGIN_APP_HOME:-}"
if [[ -z "${PLUGIN_APP_HOME}" && "${HELM_HOME:-}" ]]; then
  echoerr "WARNING: HELM_HOME is deprecated, use PLUGIN_APP_HOME instead"
  PLUGIN_APP_HOME="${HELM_HOME}"
fi

if [[ "${PLUGIN_APP_HOME}" ]]; then
  PLUGIN_APP_HOME=$(variable_expansion "${PLUGIN_APP_HOME}")
else
  PLUGIN_APP_HOME="/tmp/__${SCRIPT_NAME}__/apps/${ARGOCD_APP_NAME:-}"
fi

# HELM_HOME is kept in sync for init scripts that still reference it
export PLUGIN_APP_HOME
export HELM_HOME="${PLUGIN_APP_HOME}"

mkdir -p "${PLUGIN_APP_HOME}"

export HELMFILE_HELMFILE_HELMFILED="${PWD}/.__${SCRIPT_NAME}__helmfile.d"

# set binary paths and base options
case "${phase}" in
  "init" | "generate")
    helm=$(resolve_binary helm "${HELM_BINARY:-}")
    helmfile=$(resolve_binary helmfile "${HELMFILE_BINARY:-}")
    check_tool_versions
    ;;
esac

helmfile_cmd=("${helmfile:-helmfile}" --helm-binary "${helm:-helm}" --no-color --allow-no-matching-release)

if [[ "${ARGOCD_APP_NAMESPACE:-}" ]] && ! truthy_test "${HELMFILE_USE_CONTEXT_NAMESPACE:-false}"; then
  helmfile_cmd+=(--namespace "${ARGOCD_APP_NAMESPACE}")
fi

if [[ "${HELMFILE_GLOBAL_OPTIONS:-}" ]]; then
  global_options=()
  split_words global_options "${HELMFILE_GLOBAL_OPTIONS}"
  helmfile_cmd+=("${global_options[@]}")
fi

if [[ -v HELMFILE_HELMFILE ]]; then
  helmfile_cmd+=(--file "${HELMFILE_HELMFILE_HELMFILED}")
fi

# TODO: parse helmfile here to detect the operative -f or --file

# set home variable to ensure apps do NOT overlap settings/repos/etc
export HOME="${PLUGIN_APP_HOME}"

echoerr "starting ${phase}"

case "${phase}" in
  "init")
    if truthy_test "${HELMFILE_CACHE_CLEANUP:-false}"; then
      "${helmfile_cmd[@]}" cache cleanup
    fi

    if [[ -v HELMFILE_HELMFILE ]]; then
      rm -rf "${HELMFILE_HELMFILE_HELMFILED}"
      mkdir -p "${HELMFILE_HELMFILE_HELMFILED}"

      case "${HELMFILE_HELMFILE_STRATEGY:-REPLACE}" in
        "INCLUDE")
          count=0

          [[ -f "helmfile.yaml" ]] && count=$((count + 1))
          [[ -f "helmfile.yaml.gotmpl" ]] && count=$((count + 1))
          [[ -d "helmfile.d" ]] && count=$((count + 1))

          if [[ "${count}" -gt 1 ]]; then
            echoerr "You can have either helmfile.yaml, helmfile.yaml.gotmpl, or helmfile.d, but not more than one"
          fi

          if [[ -f "helmfile.yaml" ]]; then
            cp -a "helmfile.yaml" "${HELMFILE_HELMFILE_HELMFILED}/"
          fi

          if [[ -f "helmfile.yaml.gotmpl" ]]; then
            cp -a "helmfile.yaml.gotmpl" "${HELMFILE_HELMFILE_HELMFILED}/"
          fi

          if [[ -d "helmfile.d" ]]; then
            cp -ar "helmfile.d/"* "${HELMFILE_HELMFILE_HELMFILED}/"
          fi
          ;;
        "REPLACE") ;;

        *)
          echoerr "invalid \$HELMFILE_HELMFILE_STRATEGY: ${HELMFILE_HELMFILE_STRATEGY}"
          exit 1
          ;;
      esac

      # ensure custom file is processed last
      echo "${HELMFILE_HELMFILE}" >"${HELMFILE_HELMFILE_HELMFILED}/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ__argocd__helmfile__.yaml"
    fi

    if [[ "${HELMFILE_INIT_SCRIPT_FILE:-}" ]]; then
      bash "$(realpath "${HELMFILE_INIT_SCRIPT_FILE}")"
    fi

    # using app revision here to ensure if the git repo is updated the cache is busted
    cache_key="plugin-${phase}-repos-${ARGOCD_APP_REVISION:-}"

    if cache_is_expired "${cache_key}" "${HELMFILE_REPO_CACHE_TIMEOUT:-}"; then
      # https://github.com/roboll/helmfile/issues/1064
      "${helmfile_cmd[@]}" repos
      cache_set_time "${cache_key}"
    else
      echoerr "skipping repos update due to cache"
    fi
    ;;

  "generate")
    # helmfile args
    # --environment default, -e default       specify the environment name. defaults to default
    # --namespace value, -n value             Set namespace. Uses the namespace set in the context by default, and is available in templates as {{ .Namespace }}
    # --selector value, -l value              Only run using the releases that match labels. Labels can take the form of foo=bar or foo!=bar.
    #                                         A release must match all labels in a group in order to be used. Multiple groups can be specified at once.
    #                                         --selector tier=frontend,tier!=proxy --selector tier=backend. Will match all frontend, non-proxy releases AND all backend releases.
    #                                         The name of a release can be used as a label. --selector name=myrelease
    # --allow-no-matching-release             Do not exit with an error code if the provided selector has no matching releases.

    # options for "helmfile template"
    helmfile_template_args=(--skip-deps)
    # options passed by helmfile to "helm template" (--args, split on spaces)
    helm_template_args=()

    # Capabilities.KubeVersion
    kube_version=$(normalize_kube_version "${KUBE_VERSION:-}")
    if [[ "${kube_version}" ]]; then
      helmfile_template_args+=(--kube-version "${kube_version}")
    elif [[ "${KUBE_VERSION:-}" ]]; then
      echoerr "WARNING: ignoring invalid KUBE_VERSION '${KUBE_VERSION}'"
    fi

    # Capabilities.APIVersions, helm accepts a comma-separated list
    if [[ "${KUBE_API_VERSIONS:-}" ]]; then
      helm_template_args+=("--api-versions=${KUBE_API_VERSIONS}")
    fi

    if [[ "${HELM_TEMPLATE_OPTIONS:-}" ]]; then
      helm_template_args+=("${HELM_TEMPLATE_OPTIONS}")
    fi

    if [[ ${#helm_template_args[@]} -gt 0 ]]; then
      helmfile_template_args+=(--args "${helm_template_args[*]}")
    fi

    if [[ "${HELMFILE_TEMPLATE_OPTIONS:-}" ]]; then
      template_options=()
      split_words template_options "${HELMFILE_TEMPLATE_OPTIONS}"
      helmfile_template_args+=("${template_options[@]}")
    fi

    # TODO: support post process pipeline here
    "${helmfile_cmd[@]}" template "${helmfile_template_args[@]}"
    ;;

  "discover")
    # https://github.com/argoproj/argo-cd/issues/4831
    # discovery by default is not executed in the ARGOCD_APP_SOURCE_PATH
    # stdout plus exit code 0 means "use this plugin", diagnostics go to stderr
    if [[ "${HELMFILE_DISCOVERY_RESPONSE:-}" ]]; then
      if truthy_test "${HELMFILE_DISCOVERY_RESPONSE}"; then
        echo "forced discovery response: enabled"
        exit 0
      fi
      echoerr "forced discovery response: disabled"
      exit 1
    fi

    if [[ "${HELMFILE_GLOBAL_OPTIONS:-}" == *--file* || "${HELMFILE_GLOBAL_OPTIONS:-}" == *-f* ]]; then
      echo "custom file path provided, assumed proper"
      exit 0
    fi

    if [[ -v HELMFILE_HELMFILE ]]; then
      echo "complete helmfile provided, assumed proper"
      exit 0
    fi

    if [[ -f "helmfile.yaml" || -f "helmfile.yaml.gotmpl" || -d "helmfile.d" ]]; then
      echo "valid helmfile content discovered"
      exit 0
    fi

    echoerr "no valid helmfile content discovered"
    exit 1
    ;;

  "parameters")
    cat <<"EOF"
[
  {
    "name": "HELM_TEMPLATE_OPTIONS",
    "title": "HELM_TEMPLATE_OPTIONS",
    "tooltip": "helm template --help"
  },
  {
    "name": "HELMFILE_TEMPLATE_OPTIONS",
    "title": "HELMFILE_TEMPLATE_OPTIONS",
    "tooltip": "helmfile template --help"
  },
  {
    "name": "HELMFILE_GLOBAL_OPTIONS",
    "title": "HELMFILE_GLOBAL_OPTIONS",
    "tooltip": "helmfile --help"
  },
  {
    "name": "HELMFILE_HELMFILE",
    "title": "HELMFILE_HELMFILE",
    "tooltip": "a complete helmfile.yaml (ignores standard helmfile.yaml and helmfile.d if present based on strategy)"
  },
  {
    "name": "HELMFILE_HELMFILE_STRATEGY",
    "title": "HELMFILE_HELMFILE_STRATEGY",
    "tooltip": "REPLACE or INCLUDE"
  },
  {
    "name": "HELMFILE_INIT_SCRIPT_FILE",
    "title": "HELMFILE_INIT_SCRIPT_FILE",
    "tooltip": "path to script to execute during the init phase"
  },
  {
    "name": "HELMFILE_CACHE_CLEANUP",
    "title": "HELMFILE_CACHE_CLEANUP",
    "tooltip": "run helmfile cache cleanup on init",
    "itemType": "boolean"
  },
  {
    "name": "HELMFILE_USE_CONTEXT_NAMESPACE",
    "title": "HELMFILE_USE_CONTEXT_NAMESPACE",
    "tooltip": "do not set helmfile namespace to ARGOCD_APP_NAMESPACE (for multi-namespace apps)",
    "itemType": "boolean"
  }
]
EOF

    exit 0
    ;;

  *)
    echoerr "invalid invocation"
    exit 1
    ;;
esac

echoerr "finishing ${phase}"

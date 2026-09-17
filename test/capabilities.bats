#!/usr/bin/env bats
# Kubernetes capabilities: KUBE_VERSION and KUBE_API_VERSIONS from Argo CD
# must reach helm template (.Capabilities.KubeVersion / .APIVersions).

setup() {
  load helpers
  common_setup
  write_helmfile helmfile.yaml
  HELM_MAJOR="$(helm version --template '{{.Version}}' | sed -E 's/^v([0-9]+).*/\1/')"
}

skip_if_helm4_bug() {
  if [[ "${HELM_MAJOR}" -ge 4 ]]; then
    true "known bug: capabilities flags are only passed for Helm 3 (fix planned)"
  fi
}

@test "capabilities: helm and helmfile versions are logged to stderr" {
  run_plugin init
  assert_success
  assert_regex "${stderr}" "helm version v[0-9]+\."
  assert_regex "${stderr}" "helmfile version"
}

@test "capabilities: renders without KUBE_VERSION and KUBE_API_VERSIONS" {
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "false"
}

@test "capabilities: KUBE_VERSION is passed to helm" {
  skip_if_helm4_bug
  export KUBE_VERSION="1.29"
  plugin_init
  run_plugin generate
  assert_success
  # helm keeps the two-part form: --kube-version 1.29 renders as v1.29
  assert_equal "$(probe_value kubeVersion)" "v1.29"
}

@test "capabilities: KUBE_API_VERSIONS is passed to helm" {
  skip_if_helm4_bug
  export KUBE_API_VERSIONS="v1,apps/v1,probe.example.com/v1"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "true"
}

@test "capabilities: KUBE_API_VERSIONS without the probe API is honoured" {
  skip_if_helm4_bug
  export KUBE_API_VERSIONS="v1,apps/v1"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "false"
}

# KUBE_VERSION normalization. Argo CD passes the cluster's version, which may
# carry a leading "v" or vendor suffixes (argoproj/argo-cd#8249).
kube_version_case() {
  local input="$1" expected="$2"
  export KUBE_VERSION="${input}"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value kubeVersion)" "${expected}"
}

@test "capabilities: KUBE_VERSION 1.29.3 -> v1.29.3" {
  skip_if_helm4_bug
  kube_version_case "1.29.3" "v1.29.3"
}

@test "capabilities: KUBE_VERSION v1.29.3 -> v1.29.3" {
  skip_if_helm4_bug
  kube_version_case "v1.29.3" "v1.29.3"
}

@test "capabilities: KUBE_VERSION 1.29.0+k3s1 -> v1.29.0" {
  true "known bug: sanitizer produces 1.29.031 (fix planned)"
  kube_version_case "1.29.0+k3s1" "v1.29.0"
}

@test "capabilities: KUBE_VERSION 1.29.0-eks-5e0fdde -> v1.29.0" {
  true "known bug: sanitizer produces 1.29.050 (fix planned)"
  kube_version_case "1.29.0-eks-5e0fdde" "v1.29.0"
}

@test "capabilities: KUBE_VERSION 1.29+ -> v1.29" {
  skip_if_helm4_bug
  kube_version_case "1.29+" "v1.29"
}

#!/usr/bin/env bats
# Kubernetes capabilities: KUBE_VERSION and KUBE_API_VERSIONS from Argo CD
# must reach helm template (.Capabilities.KubeVersion / .APIVersions).

setup() {
  load helpers
  common_setup
  write_helmfile helmfile.yaml
}

@test "capabilities: renders without KUBE_VERSION and KUBE_API_VERSIONS" {
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "false"
  refute_regex "${stderr}" "WARNING"
}

@test "capabilities: KUBE_VERSION is passed to helm" {
  export KUBE_VERSION="1.29"
  plugin_init
  run_plugin generate
  assert_success
  # helm keeps the two-part form: --kube-version 1.29 renders as v1.29
  assert_equal "$(probe_value kubeVersion)" "v1.29"
}

@test "capabilities: KUBE_VERSION is passed with the native helmfile flag" {
  HELMFILE_BINARY="$(make_call_logger helmfile)"
  export HELMFILE_BINARY KUBE_VERSION="1.29.3"
  plugin_init
  run_plugin generate
  assert_success
  run grep -- ' template --skip-deps --kube-version 1.29.3' "${BATS_TEST_TMPDIR}/helmfile-calls.log"
  assert_success
}

@test "capabilities: KUBE_API_VERSIONS is passed to helm" {
  export KUBE_API_VERSIONS="v1,apps/v1,probe.example.com/v1"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "true"
}

@test "capabilities: single KUBE_API_VERSIONS entry is passed to helm" {
  export KUBE_API_VERSIONS="probe.example.com/v1"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "true"
}

@test "capabilities: KUBE_API_VERSIONS without the probe API is honoured" {
  export KUBE_API_VERSIONS="v1,apps/v1"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value hasProbeApi)" "false"
}

@test "capabilities: KUBE_VERSION, KUBE_API_VERSIONS and HELM_TEMPLATE_OPTIONS together" {
  export KUBE_VERSION="v1.30.2+k3s1"
  export KUBE_API_VERSIONS="v1,probe.example.com/v1"
  export ARGOCD_ENV_HELM_TEMPLATE_OPTIONS="--set marker=combined"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value kubeVersion)" "v1.30.2"
  assert_equal "$(probe_value hasProbeApi)" "true"
  assert_equal "$(probe_value marker)" "combined"
}

@test "capabilities: --args is not passed when there is nothing to pass" {
  HELMFILE_BINARY="$(make_call_logger helmfile)"
  export HELMFILE_BINARY
  plugin_init
  run_plugin generate
  assert_success
  run grep -- '--args' "${BATS_TEST_TMPDIR}/helmfile-calls.log"
  assert_failure
}

@test "capabilities: --args has no leading or double spaces" {
  HELMFILE_BINARY="$(make_call_logger helmfile)"
  export HELMFILE_BINARY KUBE_API_VERSIONS="v1"
  export ARGOCD_ENV_HELM_TEMPLATE_OPTIONS="--set marker=x"
  plugin_init
  run_plugin generate
  assert_success
  run grep -- '--args --api-versions=v1 --set marker=x' "${BATS_TEST_TMPDIR}/helmfile-calls.log"
  assert_success
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
  refute_regex "${stderr}" "WARNING"
}

@test "capabilities: KUBE_VERSION 1.29.3 -> v1.29.3" {
  kube_version_case "1.29.3" "v1.29.3"
}

@test "capabilities: KUBE_VERSION v1.29.3 -> v1.29.3" {
  kube_version_case "v1.29.3" "v1.29.3"
}

@test "capabilities: KUBE_VERSION 1.29+ -> v1.29" {
  kube_version_case "1.29+" "v1.29"
}

@test "capabilities: KUBE_VERSION 1.29.0+k3s1 -> v1.29.0" {
  kube_version_case "1.29.0+k3s1" "v1.29.0"
}

@test "capabilities: KUBE_VERSION 1.29.0-eks-5e0fdde -> v1.29.0" {
  kube_version_case "1.29.0-eks-5e0fdde" "v1.29.0"
}

@test "capabilities: KUBE_VERSION v1.31.1-gke.1678000 -> v1.31.1" {
  kube_version_case "v1.31.1-gke.1678000" "v1.31.1"
}

@test "capabilities: KUBE_VERSION 1.30.4+rke2r1 -> v1.30.4" {
  kube_version_case "1.30.4+rke2r1" "v1.30.4"
}

@test "capabilities: invalid KUBE_VERSION is ignored with a warning" {
  local v default
  plugin_init
  run_plugin generate
  default="$(probe_value kubeVersion)"

  for v in "latest" "1" "v" "1.x" "one.two"; do
    export KUBE_VERSION="${v}"
    run_plugin generate
    assert_success
    assert_regex "${stderr}" "WARNING: ignoring invalid KUBE_VERSION '${v}'"
    assert_equal "$(probe_value kubeVersion)" "${default}"
  done
}

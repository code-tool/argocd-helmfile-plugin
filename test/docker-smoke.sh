#!/bin/bash
# Smoke test executed inside the built image (make test-docker).
# Checks that the shipped binaries and the plugin work together.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp -r /test/fixtures/chart-probe "${work}/chart"
cd "${work}"

cat >helmfile.yaml <<YAML
releases:
  - name: probe
    chart: ${work}/chart
YAML

export ARGOCD_APP_NAME="smoke" ARGOCD_APP_NAMESPACE="smoke-ns" ARGOCD_APP_REVISION="smoke"
export PLUGIN_APP_HOME="${work}/home"

plugin="argocd-helmfile-plugin.sh"
command -v "${plugin}" >/dev/null || fail "${plugin} not on PATH"

"${plugin}" discover >/dev/null || fail "discover did not match helmfile.yaml"
"${plugin}" parameters | jq -e 'length > 0' >/dev/null || fail "parameters is not valid JSON"
"${plugin}" init >/dev/null || fail "init failed"
out="$("${plugin}" generate)" || fail "generate failed"
grep -q 'releaseNamespace: "smoke-ns"' <<<"${out}" || fail "unexpected generate output: ${out}"

# Plugins shipped in the image must be visible to helm.
plugins="$(helm plugin list)"
for p in diff helm-git secrets; do
  grep -q "^${p}\b" <<<"${plugins}" || fail "helm plugin ${p} missing"
done

echo "OK: docker smoke test passed"

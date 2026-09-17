# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/)
and this project adheres to Semantic Versioning (https://semver.org/).
---

## [Unreleased]
### Removed
- Dead code: `if [[ true ]]` wrappers, duplicate `PATH` expansion, unused `print_env_vars`, unused `/tmp/__<script>__/bin` directory, unreachable block after `exit 0` in `parameters`, commented-out `find` blocks.
- Remaining Helm 2 code: `helm init --client-only`, Helm 2 `--kube-version` handling and comments.
- `HELMFILE_HELM3` export (no-op since helmfile v1).

### Changed
- Helm version is detected with `helm version --template '{{.Version}}'` instead of parsing `--short` output.
- `init` and `generate` fail with a clear error for Helm < 3, helmfile < 1 or unparsable versions.
- `discover` and `parameters` no longer run `helm`/`helmfile`.
- Minimum versions: helm >= 3.6, helmfile >= 1 (>= 1.2 with Helm 4).
- Script runs with `set -Eeuo pipefail` and reports the failing phase and line on errors.
- `discover` writes "no match" and "forced response: disabled" messages to stderr; stdout is only used for a match.
- Options in `HELMFILE_GLOBAL_OPTIONS` / `HELMFILE_TEMPLATE_OPTIONS` are split into words without glob expansion; multi-line values are supported.
- `ARGOCD_ENV_*` / `PARAM_*` with names that are not valid shell variables are skipped with a warning instead of failing.
- Missing `helm` / `helmfile` binaries fail with a clear message.
- `KUBE_VERSION` is passed with helmfile's `--kube-version` flag; `KUBE_API_VERSIONS` as one comma-separated `--api-versions`. `--args` is only passed when needed.

### Deprecated
- `HELM_HOME`: use `PLUGIN_APP_HOME`. `HELM_HOME` is still accepted with a warning and is exported with the same value.

### Fixed
- `truthy_test` evaluated values as arithmetic expressions, which could run command substitutions from parameter values; it now compares strings only (`true`, `1`, `yes`, any case).
- Non-numeric `HELMFILE_REPO_CACHE_TIMEOUT` no longer causes errors; it disables the cache.
- Helm 4: `KUBE_VERSION` and `KUBE_API_VERSIONS` were ignored, so charts rendered with Helm's default capabilities instead of the destination cluster's.
- `KUBE_VERSION` with vendor suffixes was corrupted (`1.29.0+k3s1` became `1.29.031`); it is now normalized, invalid values are ignored with a warning.
- `HELMFILE_HELMFILE_STRATEGY=INCLUDE` aborted `init` silently when any helmfile source existed (`((count++))` under `set -e`).

### Added
- `PLUGIN_APP_HOME` environment variable.
- bats test suite (`test/`) covering the `discover`, `parameters`, `init` and `generate` phases, environment handling and Kubernetes capabilities.
- Docker image smoke test (`test/docker-smoke.sh`).
- `Makefile` with `tools`, `lint`, `test` and `test-docker` targets.
- GitHub Actions workflow `Test` running shellcheck, bats and the Docker smoke test on pushes to `main` and pull requests.

## [1.3.1] - 2026-05-27
### Fixed 
 - Fixed plugin installation and compatibility issues for Helm v4, ensuring proper support for CLI plugins including helm-secrets as described in the updated installation guide: https://github.com/jkroepke/helm-secrets/wiki/Installation

## [1.3.0] - 2026-05-26
### Changed
- Supported Kubernetes Versions 1.35.x - 1.33.x
- kubectl v1.34.8; helm 4.2.0; helmfile 1.5.2

## [1.2.0] - 2026-01-08
### Changed
- Supported Kubernetes Versions 1.34.x - 1.32.x
- kubectl v1.33.4; helm v3.19.4; helmfile 1.1.9

## [1.1.1] - 2025-11-05
### Changed
- Supported Kubernetes Versions 1.34.x - 1.32.x
- kubectl v1.33.4; helm v3.18.6; helmfile 1.1.9

## [1.1.0] - 2025-09-02
### Changed
- Supported Kubernetes Versions 1.34.x - 1.32.x
- kubectl v1.33.4; helm v3.18.6; helmfile 1.1.5

## [v1.0.0] - Released 2025-08-20 (initial release)
### Changed
- Supported Kubernetes Versions 1.32.x - 1.31.x
- kubectl v1.32.8; helm v3.17.4; helmfile v1.1.5 
- GitHub Actions workflow
### Removed
- Helm2 support removed.


---

## Legend

### Types of changes
- **Added** – new features
- **Changed** – changes in existing functionality
- **Deprecated** – soon-to-be removed features
- **Removed** – removed features
- **Fixed** – bug fixes
- **Security** – vulnerability fixes
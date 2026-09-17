# argocd-helmfile-plugin

![Image](https://img.shields.io/docker/pulls/code-tool/argocd-helmfile-plugin.svg)
![Image](https://img.shields.io/github/actions/workflow/status/code-tool/argocd-helmfile-plugin/ci.yml?branch=main&style=flat-square)

# Intro

Support for `helmfile` with `argo-cd`.

`argo-cd` already supports `helm` in 2 distinct ways, why is this useful?

- It helps decouple configuration from chart development
- It's similar to using a repo type of `helm` but you can still manage
  configuration with git.
- Because I like the power afforded using `helmfile`'s features such as
  `environments`, `selectors`, templates, and being able to use `ENV` vars as
  conditionals **AND** values.
- https://github.com/helmfile/helmfile/blob/main/docs/writing-helmfile.md
- https://github.com/helmfile/helmfile/blob/main/docs/shared-configuration-across-teams.md

# Security

Please make note that `helmfile` itself allows execution of arbitrary scripts.
Due to this feature, execution of arbitrary scripts are allowed by this plugin,
both explicitly (see `HELMFILE_INIT_SCRIPT_FILE` env below) and implicity.

Consider these implications for your environment and act appropriately.

- https://github.com/roboll/helmfile#templating (`exec` description)
- https://github.com/helmfile/helmfile/pull/1 (can disable `exec` using env vars)
- the execution pod/context is the `argocd-repo-server`

# Requirements

- `helm` >= 3.6 (Helm 4 recommended; Helm 2 is not supported)
- `helmfile` >= 1, and >= 1.2 when used with Helm 4

The plugin checks both versions in the `init` and `generate` phases and fails
with a clear message if they are not supported.

## Kubernetes capabilities

Argo CD passes the destination cluster's version and APIs as `KUBE_VERSION` and
`KUBE_API_VERSIONS`. The plugin passes them to `helm template`, so charts can use
`.Capabilities.KubeVersion` and `.Capabilities.APIVersions.Has`:

- `KUBE_VERSION` is normalized first: a leading `v` and anything after the first
  `+` or `-` are removed (`v1.29.0+k3s1` → `1.29.0`, `1.29.0-eks-5e0fdde` → `1.29.0`).
  Values that are still not `<major>.<minor>[.<patch>]` are ignored with a warning.
- `KUBE_API_VERSIONS` is passed as `--api-versions`.

## Helm 4 notes

- Post-renderers are Helm plugins in Helm 4. `--post-renderer` in
  `HELM_TEMPLATE_OPTIONS` or `postRenderer:` in helmfile must name an installed
  plugin, not an executable path.
- `helm registry login` takes a domain name only (no path). Check
  `HELMFILE_INIT_SCRIPT_FILE` scripts that log in to OCI registries.
- Plugins installed via `HELMFILE_INIT_SCRIPT_FILE` need `--verify=false` unless
  they are signed and their key is available.

# Installation

- https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/

## Sidecar

This shows optional use of sops/age integration. You may add/remove others as necessary.

```yaml
repoServer:
  volumes:
  ...
  - name: age-secret-keys
    secret:
      secretName: argocd-age-secret-keys
  - emptyDir: {}
    name: helmfile-cmp-tmp

  extraContainers:
  - name: helmfile-plugin
    image: code-tool/argocd-helmfile-plugin:latest
    command: [/var/run/argocd/argocd-cmp-server]
    env:
    ...
    - name: SOPS_AGE_KEY_FILE
      value: /sops/age/keys.txt
    securityContext:
      runAsNonRoot: true
      runAsUser: 999
    volumeMounts:
      ...
      - mountPath: /sops/age
        name: age-secret-keys
      - mountPath: /var/run/argocd
        name: var-files
      - mountPath: /home/argocd/cmp-server/plugins
        name: plugins
      - mountPath: /tmp
        name: helmfile-cmp-tmp
```

# Usage

Configure your `argo-cd` app to use a repo/directory which holds a valid
`helmfile` configuration. This can be a directory which contains a
`helmfile.yaml` **OR** `helmfile.yaml.gotmpl` file **OR** a `helmfile.d` directory containing any number of
`*.yaml` or `*.yaml.gotmpl` files. You cannot have both configurations.

There are a number of specially handled `ENV` variables which can be set (all
optional):

- `HELM_BINARY` - custom path to `helm` binary
- `HELM_TEMPLATE_OPTIONS` - pass-through options for the templating operation
  `helm template --help`
- `HELMFILE_BINARY` - custom path to `helmfile` binary
- `HELMFILE_USE_CONTEXT_NAMESPACE` - do not set helmfile namespace to `ARGOCD_APP_NAMESPACE`,
  for use with multi-namespace apps
- `HELMFILE_GLOBAL_OPTIONS` - pass-through options for all `helmfile`
  operations `helmfile --help`
- `HELMFILE_TEMPLATE_OPTIONS` - pass-through options for the templating
  operation `helmfile template --help`
- `HELMFILE_INIT_SCRIPT_FILE` - path to script to execute during init phase
- `HELMFILE_HELMFILE` - a complete `helmfile.yaml` or `helmfile.yaml.gotmpl` content
- `HELMFILE_HELMFILE_STRATEGY` - one of `REPLACE` or `INCLUDE`
  - `REPLACE` - the default option, only the content of `HELMFILE_HELMFILE` is
    rendered, if any valid files exist in the repo they are ignored
  - `INCLUDE` - any valid files in the repo **AND** the content of
    `HELMFILE_HELMFILE` are rendered, precedence is given to
    `HELMFILE_HELMFILE` should the same release name be declared in multiple
    files
- `HELMFILE_CACHE_CLEANUP` - run helmfile cache cleanup on init
- `PLUGIN_APP_HOME` - per-application directory used as `HOME` while running
  `helm`/`helmfile`, so applications do not share repositories, registry
  logins or caches. Defaults to `/tmp/__argocd-helmfile-plugin.sh__/apps/${ARGOCD_APP_NAME}`
- `HELM_HOME` - **deprecated** alias for `PLUGIN_APP_HOME` (Helm itself ignores
  it since v3). Still accepted with a warning; `PLUGIN_APP_HOME` wins if both are set

Of the above `ENV` variables, the following do variable expansion on the value:

- `HELMFILE_GLOBAL_OPTIONS`
- `HELMFILE_TEMPLATE_OPTIONS`
- `HELM_TEMPLATE_OPTIONS`
- `HELMFILE_INIT_SCRIPT_FILE`
- `PLUGIN_APP_HOME` (and deprecated `HELM_HOME`)
- `HELM_CACHE_HOME`
- `HELM_CONFIG_HOME`
- `HELM_DATA_HOME`

Meaning, you can do things like:

- `HELMFILE_GLOBAL_OPTIONS="--environment ${ARGOCD_APP_NAME} --selector cluster=${CLUSTER_ID}`

Any of the standard `Build Environment` variables can be used as well as
variables declared in the application spec.

- https://argoproj.github.io/argo-cd/user-guide/config-management-plugins/#environment
- https://argoproj.github.io/argo-cd/user-guide/build-environment/

## Helm Plugins

To use the various helm plugins the recommended approach is the install the
plugins using the/an `initContainers` (explicitly set the `HELM_DATA_HOME` env
var during the `helm plugin add` command) and simply set the `HELM_DATA_HOME`
environment variable in your application spec (or globally in the pod). This
prevents the plugin(s) from being downloaded over and over each run.

```yaml
# repo server deployment
  volumes:
  ...
  - name: helm-data-home
    emptyDir: {}

# repo-server container
  volumeMounts:
  ...
  - mountPath: /home/argocd/.local/share/helm
    name: helm-data-home

# init container
  volumeMounts:
  ...
  - mountPath: /helm/data
    name: helm-data-home

    [[ ! -d "${HELM_DATA_HOME}/plugins/helm-secrets" ]] && /custom-tools/helm plugin install https://github.com/jkroepke/helm-secrets --version ${HELM_SECRETS_VERSION} --verify=false
    chown -R 999:999 "${HELM_DATA_HOME}"

# lastly, in your app definition
...
plugin:
  env:
  - name: HELM_DATA_HOME
    value: /home/argocd/.local/share/helm
```

If the above is not possible/desired, the recommended approach would be to use
`HELMFILE_INIT_SCRIPT_FILE` to execute an arbitrary script during the `init`
phase. Within the script it's desireable to run `helm plugin list` and only
install the plugin only if it's not already installed.

## Custom Init

You can use the `HELMFILE_INIT_SCRIPT_FILE` feature to do any kind of _init_
logic required including installing helm plugins, downloading external files,
etc. The value can be a relative or absolute path and the file itself can be
injected using an `initContainers` or stored in the application git repository.

## Development

### Tests

Tests use [bats-core](https://github.com/bats-core/bats-core) and run the plugin
against the real `helm` and `helmfile` binaries, using the versions pinned in
`docker/Dockerfile`. No cluster or network access to chart repositories is needed.

```bash
make test         # downloads helm, helmfile and bats into .tools/, then runs test/*.bats
make lint         # shellcheck
make test-docker  # builds the image and runs test/docker-smoke.sh inside it
```

Requirements: `bash`, `git`, `wget`, `jq`, `make`, `shellcheck` (and `docker` for `test-docker`).
Override tool versions with e.g. `make test HELM_VERSION=v3.19.4`.

Tests for known bugs are marked with `skip "known bug: ..."`. Remove the skip
together with the fix.

### Contributing
```declarative
# Create fork.
# Add the original repository as a new remote called "upstream" (only once, if not done before)
git remote add upstream https://github.com/code-tool/argocd-helmfile-plugin.git

# List all remotes to verify that "upstream" exists
git remote -v

# 1. Fetch the latest changes from the original repository
git fetch upstream

# 2. Switch to your main branch (your fork’s main branch, usually `master` or `main`)
git checkout main

# 3. Merge the latest changes from the original repository into your `main`
git merge upstream/main

# 4. Push the updated `main` branch to your fork on GitHub
git push origin main

# 5. Create a new feature branch from the updated `main` for your next changes
git checkout -b new-feature-branch

# (Now you can edit files, commit changes, and push this branch, then open a new pull request)
```
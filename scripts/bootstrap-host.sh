#!/usr/bin/env bash
# bootstrap-host.sh — idempotent Arch Linux host toolchain provisioning for the
# Athena local estate (Plan 01, Task 1).
#
# Provisions exactly five things, in this order, and verifies each before
# moving to the next:
#   1. Docker Engine   (host daemon — NOT Podman/DinD; see athena-infra README
#                        and 01-RESEARCH.md Pitfall 2 / CONTEXT.md D-17)
#   2. k3d v5.9.0
#   3. mkcert v1.4.4   (installs the root CA into the system + NSS/browser
#                        trust stores via `mkcert -install`)
#   4. Helm v4.2.3     (replaces any existing Helm v3 on PATH)
#   5. act v0.2.89     (Plan 06, Task 1; FOUND-05 — fast local inner loop for
#                        the workflows the self-hosted runner also executes)
#
# Safe to run twice: every step checks the desired end state first and no-ops
# when already met. Requires an interactive terminal with sudo privileges for
# the Docker install step (package install, service enable, group membership)
# and for any tool this script installs system-wide (mkcert, k3d if no distro
# package exists). Helm v4 is installed to a user-writable location and needs
# no privilege escalation.
#
# Usage: bash scripts/bootstrap-host.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
_c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
_c_yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
_c_red() { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '[bootstrap-host] %s\n' "$1"; }
ok()    { _c_green "[bootstrap-host] OK: $1"; }
warn()  { _c_yellow "[bootstrap-host] WARN: $1"; }
fail()  { _c_red "[bootstrap-host] FAIL: $1"; }

K3D_VERSION="v5.9.0"
MKCERT_VERSION="v1.4.4"
HELM_VERSION="v4.2.3"
ACT_VERSION="v0.2.89"

NEEDS_RELOGIN=0
PROVISION_FAILED=0

# ---------------------------------------------------------------------------
# Pinned upstream artifact checksums / sources — RESEARCH.md T-01-04:
# every download is pinned to an explicit version tag and verified post-install
# by version probe. Distro packages (pacman) are preferred over piped
# installers wherever available.
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_available() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! require_cmd sudo; then
    return 1
  fi
  # -v refreshes/validates the sudo timestamp; will prompt interactively if
  # this shell has a controlling terminal, or fail fast if it does not.
  sudo -v 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Docker Engine
# ---------------------------------------------------------------------------
install_docker() {
  info "Step 1/5: Docker Engine"

  if require_cmd docker && systemctl is-active --quiet docker 2>/dev/null; then
    ok "Docker already installed and daemon active ($(docker --version))"
  else
    if ! sudo_available; then
      fail "Docker install requires sudo privileges in an interactive terminal. Run this script yourself (not via an automated agent) so sudo can prompt for your password."
      PROVISION_FAILED=1
      return 1
    fi

    if ! require_cmd docker; then
      info "Installing docker package from the Arch extra repo..."
      sudo pacman -S --needed --noconfirm docker
    fi

    info "Enabling and starting the docker service..."
    sudo systemctl enable --now docker

    if ! docker info >/dev/null 2>&1; then
      fail "docker info did not succeed after enabling the service."
      PROVISION_FAILED=1
      return 1
    fi
  fi

  # docker-buildx (Plan 06, Task 2 — live finding): unlike Docker's official
  # convenience installer, Arch's `docker` package does NOT bundle the
  # buildx CLI plugin — `DOCKER_BUILDKIT=1 docker build` hard-fails with
  # "buildx component is missing" until this plugin is present. CLAUDE.md's
  # "BuildKit is Docker's default builder since Docker 23+" holds for
  # Docker's own installer, not for this distro's packaging, so this step
  # closes that gap explicitly rather than leaving CI's BuildKit build
  # (heavy-selfhosted.yml) to discover it cold.
  if require_cmd docker && docker buildx version >/dev/null 2>&1; then
    ok "docker-buildx already installed ($(docker buildx version))"
  else
    if ! sudo_available; then
      fail "docker-buildx install requires sudo."
      PROVISION_FAILED=1
      return 1
    fi
    info "Installing docker-buildx from the Arch extra repo..."
    sudo pacman -S --needed --noconfirm docker-buildx
    if ! docker buildx version >/dev/null 2>&1; then
      fail "docker buildx version did not succeed after installing docker-buildx."
      PROVISION_FAILED=1
      return 1
    fi
    ok "docker-buildx installed: $(docker buildx version)"
  fi

  # Group membership: idempotent check before usermod.
  if id -nG "$USER" 2>/dev/null | grep -qw docker; then
    ok "User '$USER' is already in the docker group"
  else
    if ! sudo_available; then
      fail "Adding '$USER' to the docker group requires sudo."
      PROVISION_FAILED=1
      return 1
    fi
    info "Adding '$USER' to the docker group..."
    sudo usermod -aG docker "$USER"
    NEEDS_RELOGIN=1
    warn "Group membership change requires a NEW LOGIN SESSION (log out and back in, or 'newgrp docker') before 'docker' works without sudo in this shell."
  fi

  if ! docker info >/dev/null 2>&1; then
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      warn "docker info still fails in this shell — expected until you start a new login session."
    else
      fail "docker info failed."
      PROVISION_FAILED=1
      return 1
    fi
  else
    ok "docker info succeeds"
  fi
}

# ---------------------------------------------------------------------------
# 2. k3d
# ---------------------------------------------------------------------------
install_k3d() {
  info "Step 2/5: k3d ${K3D_VERSION}"

  if require_cmd k3d; then
    ok "k3d already installed ($(k3d version | head -1))"
    return 0
  fi

  # Probe the distro package first (RESEARCH.md T-01-04: prefer pacman over a
  # piped installer wherever available). As of this plan's research, k3d has
  # no Arch `extra` package, so this is expected to fall through.
  if pacman -Ss '^k3d$' 2>/dev/null | grep -q '^extra/k3d\|^community/k3d'; then
    if ! sudo_available; then
      fail "k3d install requires sudo."
      PROVISION_FAILED=1
      return 1
    fi
    info "Installing k3d from the distro package..."
    sudo pacman -S --needed --noconfirm k3d
  else
    info "No distro package for k3d found — installing pinned ${K3D_VERSION} via upstream installer."
    if ! sudo_available; then
      fail "k3d's upstream installer needs sudo to write to /usr/local/bin. Run this script yourself in an interactive terminal."
      PROVISION_FAILED=1
      return 1
    fi
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
      | TAG="${K3D_VERSION}" bash
  fi

  if ! require_cmd k3d; then
    fail "k3d install did not put 'k3d' on PATH."
    PROVISION_FAILED=1
    return 1
  fi
  ok "k3d installed: $(k3d version | head -1)"
}

# ---------------------------------------------------------------------------
# 3. mkcert
# ---------------------------------------------------------------------------
install_mkcert() {
  info "Step 3/5: mkcert ${MKCERT_VERSION}"

  if ! require_cmd mkcert; then
    if pacman -Ss '^mkcert$' 2>/dev/null | grep -q '^extra/mkcert\|^community/mkcert'; then
      if ! sudo_available; then
        fail "mkcert install requires sudo."
        PROVISION_FAILED=1
        return 1
      fi
      info "Installing mkcert from the distro package..."
      sudo pacman -S --needed --noconfirm mkcert
    else
      info "No distro package for mkcert found — installing pinned ${MKCERT_VERSION} release binary."
      if ! sudo_available; then
        fail "Installing mkcert to /usr/local/bin needs sudo."
        PROVISION_FAILED=1
        return 1
      fi
      local tmp_bin
      tmp_bin="$(mktemp)"
      curl -fsSL -o "$tmp_bin" \
        "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-amd64"
      chmod +x "$tmp_bin"
      sudo mv "$tmp_bin" /usr/local/bin/mkcert
    fi
  else
    ok "mkcert already installed ($(mkcert -version 2>&1 || true))"
  fi

  if ! require_cmd mkcert; then
    fail "mkcert install did not put 'mkcert' on PATH."
    PROVISION_FAILED=1
    return 1
  fi

  local caroot
  caroot="$(mkcert -CAROOT)"
  if [ -f "${caroot}/rootCA.pem" ] && [ -f "${caroot}/rootCA-key.pem" ]; then
    ok "mkcert root CA already installed at ${caroot}"
  else
    info "Running 'mkcert -install' to create and trust the local root CA..."
    mkcert -install
    caroot="$(mkcert -CAROOT)"
    if [ ! -f "${caroot}/rootCA.pem" ] || [ ! -f "${caroot}/rootCA-key.pem" ]; then
      fail "mkcert -install did not produce rootCA.pem/rootCA-key.pem in ${caroot}."
      PROVISION_FAILED=1
      return 1
    fi
    ok "mkcert root CA installed and trusted at ${caroot}"
  fi
}

# ---------------------------------------------------------------------------
# 4. Helm v4
# ---------------------------------------------------------------------------
# Helm v4 notes (carried into this script's comments per the plan):
#   - Server-Side Apply replaces the v3 three-way merge; --wait may need
#     extra `watch` RBAC as a result.
#   - --atomic/--force are renamed to --rollback-on-failure/--force-replace
#     (old flags still work with deprecation warnings).
#   - HELM_EXPERIMENTAL_OCI is obsolete — OCI support is on by default.
install_helm() {
  info "Step 4/5: Helm ${HELM_VERSION}"

  if require_cmd helm && helm version --short 2>/dev/null | grep -q '^v4\.'; then
    ok "Helm v4 already installed ($(helm version --short))"
    return 0
  fi

  local install_dir
  if require_cmd helm; then
    install_dir="$(dirname "$(command -v helm)")"
  else
    install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
  fi

  info "Installing Helm ${HELM_VERSION} into ${install_dir}..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" RETURN

  local tarball="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "${tmp_dir}/${tarball}" \
    "https://get.helm.sh/${tarball}"
  tar -xzf "${tmp_dir}/${tarball}" -C "${tmp_dir}"

  if [ -w "$install_dir" ]; then
    install -m 0755 "${tmp_dir}/linux-amd64/helm" "${install_dir}/helm"
  elif sudo_available; then
    sudo install -m 0755 "${tmp_dir}/linux-amd64/helm" "${install_dir}/helm"
  else
    fail "Cannot write to ${install_dir} and sudo is unavailable."
    PROVISION_FAILED=1
    return 1
  fi

  if ! helm version --short 2>/dev/null | grep -q '^v4\.'; then
    fail "helm version --short does not report a v4.x prefix after install."
    PROVISION_FAILED=1
    return 1
  fi
  ok "Helm v4 installed: $(helm version --short)"
}

# ---------------------------------------------------------------------------
# 5. act (Plan 06, Task 1 — FOUND-05)
# ---------------------------------------------------------------------------
# act runs the estate's GitHub Actions workflows locally against the host
# Docker daemon for fast inner-loop iteration before anything is pushed —
# see estate/athena-infra/.actrc for the committed runtime configuration and
# docs/runbooks/runner-ops.md for what a green act run does and does not
# prove relative to a real self-hosted-runner run.
install_act() {
  info "Step 5/5: act ${ACT_VERSION}"

  if require_cmd act; then
    ok "act already installed ($(act --version 2>&1))"
    return 0
  fi

  # Probe the distro package first (RESEARCH.md T-01-04: prefer pacman over
  # a piped installer wherever available). As of this plan's research, act
  # ships in Arch's `extra` repo at exactly the pinned version.
  if pacman -Ss '^act$' 2>/dev/null | grep -q '^extra/act\|^community/act'; then
    if ! sudo_available; then
      fail "act install requires sudo."
      PROVISION_FAILED=1
      return 1
    fi
    info "Installing act from the distro package..."
    sudo pacman -S --needed --noconfirm act
  else
    info "No distro package for act found — installing pinned ${ACT_VERSION} via upstream installer."
    if ! sudo_available; then
      fail "act's upstream installer needs sudo to write to /usr/local/bin. Run this script yourself in an interactive terminal."
      PROVISION_FAILED=1
      return 1
    fi
    curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh \
      | sudo bash -s -- -b /usr/local/bin "${ACT_VERSION}"
  fi

  if ! require_cmd act; then
    fail "act install did not put 'act' on PATH."
    PROVISION_FAILED=1
    return 1
  fi
  ok "act installed: $(act --version 2>&1)"
}

# ---------------------------------------------------------------------------
# Version summary
# ---------------------------------------------------------------------------
_version_of() {
  # Prints a tool's version line, or "NOT FOUND" without leaking the shell's
  # own "command not found" noise when the binary is absent.
  local bin="$1"
  shift
  if ! require_cmd "$bin"; then
    echo "NOT FOUND"
    return
  fi
  "$bin" "$@" 2>&1 | head -1
}

print_summary() {
  echo
  info "Toolchain version summary:"
  printf '  %-10s %s\n' "docker"    "$(_version_of docker --version)"
  printf '  %-10s %s\n' "buildx"    "$(_version_of docker buildx version)"
  printf '  %-10s %s\n' "k3d"       "$(_version_of k3d version)"
  printf '  %-10s %s\n' "mkcert"    "$(_version_of mkcert -version)"
  printf '  %-10s %s\n' "helm"      "$(_version_of helm version --short)"
  printf '  %-10s %s\n' "act"       "$(_version_of act --version)"
  printf '  %-10s %s\n' "kubectl"   "$(_version_of kubectl version --client)"
  printf '  %-10s %s\n' "terraform" "$(_version_of terraform version)"
  printf '  %-10s %s\n' "ansible"   "$(_version_of ansible --version)"
  printf '  %-10s %s\n' "gh"        "$(_version_of gh --version)"
  printf '  %-10s %s\n' "dnsmasq"   "$(_version_of dnsmasq --version)"
  echo
}

main() {
  install_docker || true
  install_k3d || true
  install_mkcert || true
  install_helm || true
  install_act || true

  print_summary

  if [ "$PROVISION_FAILED" -ne 0 ]; then
    fail "One or more of the five provisioned tools (docker, k3d, mkcert, helm v4, act) is not fully provisioned. See FAIL lines above."
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      warn "If the only remaining gap is 'docker info' in THIS shell, start a new login session (log out/in, or run 'newgrp docker') and re-run this script to confirm."
    fi
    exit 1
  fi

  ok "Host toolchain baseline complete: docker, k3d, mkcert (root CA trusted), Helm v4, act."
  if [ "$NEEDS_RELOGIN" -eq 1 ]; then
    warn "Docker group membership was just added — start a new login session before relying on docker without sudo."
  fi
}

main "$@"

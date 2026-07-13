#!/usr/bin/env bash
############################################################
# bootstrap-host.sh
#
# Fresh Ubuntu -> Fully ready K3s master host.
#
# Usage:
#   git clone https://github.com/fadyadel2010/Kubernetes_Vps_Deploy.git
#   cd Kubernetes_Vps_Deploy
#   sudo ./bootstrap-host.sh
#
# Re-running this script is safe (idempotent). Every step
# checks current state before changing anything.
#
# NOTE: any active firewall (ufw/firewalld) is detected and disabled
# before packages are installed/updated. This host is meant to be
# followed by a master bootstrap.sh that applies the real firewall
# rules once provisioning is done.
############################################################

set -Eeuo pipefail

############################################################
# Locate ourselves first (needed before anything else)
############################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################################
# Config (override via environment variables if needed)
############################################################
REPO_URL="${REPO_URL:-https://github.com/fadyadel2010/Kubernetes_Vps_Deploy.git}"

# If the script is already running from inside a git repo, treat that
# repo as the project root instead of cloning into a nested subfolder.
# Using `git rev-parse --is-inside-work-tree` instead of a hardcoded
# `[[ -d .git ]]` check means this still works even if this script is
# later moved into a subfolder (e.g. scripts/bootstrap-host.sh).
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
else
  REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/Kubernetes_Vps_Deploy}"
fi
PROJECT_ROOT="$REPO_DIR"

TIMEZONE="${TIMEZONE:-UTC}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"          # stable | latest | vX.Y.Z+k3s1
K3S_EXTRA_ARGS="${K3S_EXTRA_ARGS:---disable=servicelb}"   # MetalLB replaces ServiceLB
HELM_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"

# apt behavior toggles - upgrading can change the kernel, so it's opt-in
DO_APT_UPGRADE="${DO_APT_UPGRADE:-false}"
DO_DIST_UPGRADE="${DO_DIST_UPGRADE:-false}"

MIN_RAM_GB=2
MIN_DISK_GB=10
RECOMMENDED_RAM_GB=8
RECOMMENDED_DISK_GB=100

LOG_FILE="${LOG_FILE:-/var/log/bootstrap-host.log}"

############################################################
# Logging helpers
############################################################
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"
COLOR_OK="\033[1;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERR="\033[1;31m"

info()  { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
ok()    { echo -e "${COLOR_OK}[OK]${COLOR_RESET}   $*"; }
warn()  { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
err()   { echo -e "${COLOR_ERR}[ERROR]${COLOR_RESET} $*"; }
section(){ echo; echo "============================================================"; echo " $1"; echo "============================================================"; }

on_error() {
  local exit_code=$?
  err "Script failed at line $1 (exit code $exit_code). See $LOG_FILE for details."
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root. Try: sudo $0"
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

############################################################
# Global summary variables (filled in as steps run, printed
# in the final Host Summary section)
############################################################
G_UBUNTU="unknown"
G_ARCH="unknown"
G_CPU="unknown"
G_RAM="unknown"
G_DISK="unknown"
G_K3S="not installed"
G_HELM="not installed"
G_KUBECTL="not working"
G_SC="none"
G_METRICS="not verified"
G_SWAP="unknown"
G_PROJECT="not ready"
G_FIREWALL="unknown"

############################################################
# 1) Environment Validation
############################################################
step_environment_validation() {
  section "1) Environment Validation"

  local ubuntu_pretty arch cpu_cores ram_gb disk_gb internet_ok=false root_ok=false sudo_ok=false

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    ubuntu_pretty="${PRETTY_NAME:-unknown}"
  else
    ubuntu_pretty="unknown"
  fi

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This does not look like Ubuntu (ID=${ID:-unknown}). Continuing anyway, but this script is only tested on Ubuntu."
  fi

  arch="$(uname -m)"
  cpu_cores="$(nproc)"
  ram_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  disk_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"

  if curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1 || curl -fsS --max-time 5 https://8.8.8.8 >/dev/null 2>&1; then
    internet_ok=true
  fi

  [[ "${EUID}" -eq 0 ]] && root_ok=true
  command_exists sudo && sudo_ok=true

  G_UBUNTU="$ubuntu_pretty"
  G_ARCH="$arch"
  G_CPU="$cpu_cores"
  G_RAM="${ram_gb} GB"
  G_DISK="${disk_gb} GB free"

  echo
  printf "  %-16s %s\n" "Ubuntu:"        "$ubuntu_pretty"
  printf "  %-16s %s\n" "Architecture:"  "$arch"
  printf "  %-16s %s\n" "CPU cores:"     "$cpu_cores"
  printf "  %-16s %s GB\n" "RAM:"        "$ram_gb"
  printf "  %-16s %s GB free\n" "Disk:"  "$disk_gb"
  printf "  %-16s %s\n" "Internet:"      "$([[ $internet_ok == true ]] && echo OK || echo FAILED)"
  printf "  %-16s %s\n" "Root:"          "$([[ $root_ok == true ]] && echo OK || echo NO)"
  printf "  %-16s %s\n" "sudo:"          "$([[ $sudo_ok == true ]] && echo OK || echo "NOT FOUND")"
  echo

  require_root

  if [[ "$internet_ok" != true ]]; then
    err "No internet connectivity detected. Cannot continue."
    exit 1
  fi

  if (( ram_gb < MIN_RAM_GB )); then
    err "RAM (${ram_gb}GB) is below the required minimum (${MIN_RAM_GB}GB). K3s may fail to run reliably on this host."
  elif (( ram_gb < RECOMMENDED_RAM_GB )); then
    warn "RAM (${ram_gb}GB) is below the recommended amount for production (${RECOMMENDED_RAM_GB}GB). This host will work, but isn't sized for production."
  fi

  if (( disk_gb < MIN_DISK_GB )); then
    err "Free disk (${disk_gb}GB) is below the required minimum (${MIN_DISK_GB}GB). Installation may fail partway through."
  elif (( disk_gb < RECOMMENDED_DISK_GB )); then
    warn "Free disk (${disk_gb}GB) is below the recommended amount for production (${RECOMMENDED_DISK_GB}GB). This host will work, but isn't sized for production."
  fi

  ok "Environment validation passed."
}

############################################################
# 2) Firewall Check
############################################################
# This host is provisioned to run BEHIND a master bootstrap.sh that
# configures the real firewall rules afterwards. Any firewall left
# enabled here can silently block apt, curl, k3s node traffic, or the
# helm/kubectl calls that follow, so we disable it up front. It is the
# master bootstrap.sh's job to turn firewalling back on with the
# correct rules once this host is otherwise ready.
step_firewall_check() {
  section "2) Firewall Check"

  G_FIREWALL="none detected"

  # UFW (Ubuntu's default firewall front-end)
  if command_exists ufw; then
    if ufw status | head -1 | grep -qi "active"; then
      warn "UFW is currently ACTIVE. Disabling it before install/update (a later bootstrap.sh will manage firewall rules)."
      ufw disable
      G_FIREWALL="ufw: was active, now disabled"
    else
      info "UFW is installed but already inactive."
      G_FIREWALL="ufw: inactive"
    fi
  fi

  # firewalld (uncommon on Ubuntu, but check in case it was installed manually)
  if command_exists firewall-cmd; then
    if systemctl is-active --quiet firewalld; then
      warn "firewalld is currently ACTIVE. Stopping and disabling it before install/update."
      systemctl stop firewalld
      systemctl disable firewalld
      G_FIREWALL="firewalld: was active, now disabled"
    else
      info "firewalld is installed but already inactive."
      [[ "$G_FIREWALL" == "none detected" ]] && G_FIREWALL="firewalld: inactive"
    fi
  fi

  if [[ "$G_FIREWALL" == "none detected" ]]; then
    info "No known firewall manager (ufw/firewalld) detected on this host."
  fi

  ok "Firewall check complete: $G_FIREWALL"
}

############################################################
# 3) System Update
############################################################
step_system_update() {
  section "3) System Update"
  export DEBIAN_FRONTEND=noninteractive

  info "Running apt update..."
  apt-get update -y

  if [[ "$DO_DIST_UPGRADE" == "true" ]]; then
    info "Running apt dist-upgrade (DO_DIST_UPGRADE=true)..."
    apt-get dist-upgrade -y
  elif [[ "$DO_APT_UPGRADE" == "true" ]]; then
    info "Running apt upgrade (DO_APT_UPGRADE=true)..."
    apt-get upgrade -y
  else
    info "Skipping apt upgrade/dist-upgrade (can change the kernel)."
    info "Set DO_APT_UPGRADE=true or DO_DIST_UPGRADE=true to enable it."
  fi

  info "Running apt autoremove..."
  apt-get autoremove -y

  ok "System is up to date."
}

############################################################
# 4) Required Packages
############################################################
step_required_packages() {
  section "4) Required Packages"
  export DEBIAN_FRONTEND=noninteractive

  local packages=(
    curl
    wget
    git
    jq
    vim
    nano
    ca-certificates
    gnupg
    software-properties-common
    apt-transport-https
    unzip
    zip
    bash-completion
    make
    gcc
    g++
    build-essential
    net-tools
    lsof
    tree
    rsync
    openssl
    dnsutils
    iputils-ping
    telnet
    nfs-common
  )

  info "Installing: ${packages[*]}"
  apt-get install -y "${packages[@]}"

  # yq is not in default Ubuntu repos in a reliable version -> install binary
  if ! command_exists yq; then
    info "Installing yq (binary release)..."
    local yq_arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && yq_arch="arm64"
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  fi
  ok "yq version: $(yq --version)"

  ok "Required packages installed."
}

############################################################
# 5) System Tuning
############################################################
step_system_tuning() {
  section "5) System Tuning"

  info "Loading required kernel modules..."
  cat >/etc/modules-load.d/k3s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay || true
  modprobe br_netfilter || true

  info "Writing sysctl tuning parameters..."
  cat >/etc/sysctl.d/99-k3s-bootstrap.conf <<'EOF'
# --- k3s / kubernetes required tuning ---
vm.max_map_count = 262144
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152
fs.aio-max-nr = 1048576
net.core.somaxconn = 32768
vm.swappiness = 0
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

  sysctl --system >/dev/null

  ok "System tuning applied (includes DB-friendly aio/dirty-ratio settings for Postgres/Mongo)."
}

############################################################
# 6) Disable Swap
############################################################
step_disable_swap() {
  section "6) Disable Swap"

  if swapon --show | grep -q .; then
    info "Disabling active swap..."
    swapoff -a
  else
    info "No active swap found."
  fi

  if grep -Eq '^\s*[^#].*\sswap\s' /etc/fstab; then
    info "Commenting out swap entry in /etc/fstab..."
    sed -i.bak -E '/^\s*[^#].*\sswap\s/ s/^/#/' /etc/fstab
  fi

  G_SWAP="Disabled"
  ok "Swap disabled."
}

############################################################
# 7) Time Sync
############################################################
step_time_sync() {
  section "7) Time Sync"
  export DEBIAN_FRONTEND=noninteractive

  if ! command_exists chronyd; then
    info "Installing chrony..."
    apt-get install -y chrony
  fi

  info "Setting timezone to ${TIMEZONE}..."
  timedatectl set-timezone "$TIMEZONE" || warn "Could not set timezone to ${TIMEZONE}."

  systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true

  timedatectl set-ntp true || true

  ok "Time sync configured ($(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown))."
}

############################################################
# 8) Install K3s
############################################################
step_install_k3s() {
  section "8) Install K3s"

  if command_exists k3s; then
    ok "K3s already installed ($(k3s --version | head -1))."
  else
    info "Installing K3s (channel: ${K3S_CHANNEL}, extra args: ${K3S_EXTRA_ARGS})..."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
      INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 ${K3S_EXTRA_ARGS}" \
      sh -
  fi

  info "Waiting for K3s to become ready..."
  local tries=0
  until k3s kubectl get nodes >/dev/null 2>&1; do
    ((tries++))
    if (( tries > 30 )); then
      err "K3s did not become ready in time."
      exit 1
    fi
    sleep 2
  done

  G_K3S="$(k3s --version | head -1)"
  ok "K3s is up: $G_K3S"
}

############################################################
# 9) kubectl
############################################################
step_kubectl() {
  section "9) kubectl"

  mkdir -p /root/.kube
  cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
  chmod 600 /root/.kube/config

  if ! command_exists kubectl; then
    info "Symlinking k3s kubectl -> /usr/local/bin/kubectl..."
    ln -sf "$(command -v k3s)" /usr/local/bin/kubectl
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  grep -q "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" /root/.bashrc 2>/dev/null || \
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc

  if kubectl get nodes >/dev/null 2>&1; then
    G_KUBECTL="OK"
    ok "kubectl works:"
    kubectl get nodes
  else
    err "kubectl is not working."
    exit 1
  fi
}

############################################################
# 10) Helm
############################################################
step_helm() {
  section "10) Helm"

  if command_exists helm; then
    ok "Helm already installed ($(helm version --short))."
  else
    info "Installing Helm..."
    curl -fsSL "$HELM_INSTALL_SCRIPT_URL" -o /tmp/get-helm-3
    chmod +x /tmp/get-helm-3
    /tmp/get-helm-3
    rm -f /tmp/get-helm-3
  fi
  G_HELM="$(helm version --short)"
  ok "Helm: $G_HELM"

  info "Registering commonly used Helm repositories..."
  local repos=(
    "prometheus-community https://prometheus-community.github.io/helm-charts"
    "jetstack https://charts.jetstack.io"
    "bitnami https://charts.bitnami.com/bitnami"
    "opensearch https://opensearch-project.github.io/helm-charts/"
    "cnpg https://cloudnative-pg.github.io/charts"
    "ot-helm https://ot-container-kit.github.io/helm-charts/"
  )
  for entry in "${repos[@]}"; do
    local name url
    name="$(echo "$entry" | awk '{print $1}')"
    url="$(echo "$entry" | awk '{print $2}')"
    helm repo add "$name" "$url" >/dev/null 2>&1 || warn "Could not add helm repo '$name' (already added or unreachable)."
  done
  helm repo update >/dev/null 2>&1 || warn "helm repo update failed."
  ok "Helm repositories ready: prometheus-community, jetstack, bitnami, opensearch, cnpg, ot-helm."
}

############################################################
# 11) Storage
############################################################
step_storage() {
  section "11) Storage"

  info "Waiting for local-path-provisioner..."
  local tries=0
  until kubectl -n kube-system get deploy local-path-provisioner >/dev/null 2>&1; do
    ((tries++))
    if (( tries > 30 )); then
      warn "local-path-provisioner deployment not found after waiting. Check K3s installation."
      break
    fi
    sleep 2
  done

  if kubectl get storageclass local-path >/dev/null 2>&1; then
    G_SC="local-path"
    ok "StorageClass 'local-path' is present:"
    kubectl get storageclass
  else
    warn "StorageClass 'local-path' not found."
  fi
}

############################################################
# 12) Metrics Server
############################################################
step_metrics_server() {
  section "12) Metrics Server"

  if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
    ok "metrics-server already present (bundled with K3s)."
  else
    warn "metrics-server not found, installing via Helm..."
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    helm upgrade --install metrics-server metrics-server/metrics-server \
      -n kube-system \
      --set args="{--kubelet-insecure-tls}"
    ok "metrics-server installed."
  fi

  info "Waiting for metrics to become available (kubectl top nodes)..."
  local tries=0
  until kubectl top nodes >/dev/null 2>&1; do
    ((tries++))
    if (( tries > 20 )); then
      warn "metrics-server is installed but 'kubectl top nodes' has no data yet. It may need a few more minutes."
      G_METRICS="installed (no data yet)"
      return
    fi
    sleep 5
  done

  G_METRICS="OK"
  ok "metrics-server is returning data:"
  kubectl top nodes
}

############################################################
# 13) Git (clone once, never overwrite local changes)
############################################################
step_git_sync() {
  section "13) Git"

  if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    info "Repository already exists at $REPO_DIR."
    info "Fetching remote refs (no local changes will be touched)..."
    git -C "$REPO_DIR" fetch --all --quiet || warn "git fetch failed (offline remote?)."
    echo
    git -C "$REPO_DIR" status
    echo
    ok "Repository already exists. Bootstrap does not modify your working tree."
  else
    info "Cloning $REPO_URL -> $REPO_DIR ..."
    git clone "$REPO_URL" "$REPO_DIR"

    if [[ ! -d "$REPO_DIR/.git" ]]; then
      err "Repository clone failed (check disk space, network connectivity, and permissions on $REPO_DIR)."
      exit 1
    fi

    ok "Repository cloned."
  fi

  PROJECT_ROOT="$REPO_DIR"
  G_PROJECT="Ready ($PROJECT_ROOT)"
}

############################################################
# 14) Permissions (make all project scripts executable)
############################################################
step_permissions() {
  section "14) Permissions"

  if [[ ! -d "$PROJECT_ROOT" ]]; then
    warn "Project root $PROJECT_ROOT does not exist yet, skipping."
    return
  fi

  info "Making all shell scripts executable under $PROJECT_ROOT ..."
  find "$PROJECT_ROOT" -type f -name "*.sh" -exec chmod +x {} \;

  info "Making Python scripts executable (if any)..."
  find "$PROJECT_ROOT" -type f -name "*.py" -exec chmod +x {} \; 2>/dev/null || true

  info "Ensuring systemd unit files have correct read permissions (if any)..."
  find "$PROJECT_ROOT" -type f \( -name "*.service" -o -name "*.timer" \) -exec chmod 644 {} \; 2>/dev/null || true

  ok "Project scripts verified executable (bootstrap.sh, validate.sh, cleanup.sh, *.py, *.service, *.timer)."
}

############################################################
# 15) Final Validation
############################################################
step_final_validation() {
  section "15) Final Validation"

  local all_ok=true
  local checks=(kubectl helm git jq yq systemctl)

  for c in "${checks[@]}"; do
    if command_exists "$c"; then
      ok "$c: found"
    else
      err "$c: MISSING"
      all_ok=false
    fi
  done

  if command_exists k3s; then
    ok "k3s: found ($(k3s --version | head -1))"
  else
    err "k3s: MISSING"
    all_ok=false
  fi

  if systemctl is-active --quiet k3s; then
    ok "k3s service: active"
  else
    err "k3s service: NOT active"
    all_ok=false
  fi

  if curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
    ok "network: OK"
  else
    err "network: FAILED"
    all_ok=false
  fi

  echo
  info "Cluster state:"
  kubectl get nodes -o wide || all_ok=false
  echo
  kubectl get storageclass || all_ok=false
  echo
  kubectl get ns || all_ok=false

  echo
  if [[ "$all_ok" == true ]]; then
    ok "ALL CHECKS PASSED. Host is ready."
  else
    err "One or more checks failed. Review the log at $LOG_FILE."
    exit 1
  fi
}

############################################################
# 16) Host Summary
############################################################
step_host_summary() {
  section "16) Host Summary"

  cat <<SUMMARY
====================================================
 Host Summary
====================================================
Ubuntu ............... ${G_UBUNTU}
Architecture ......... ${G_ARCH}
CPU .................. ${G_CPU}
RAM .................. ${G_RAM}
Disk ................. ${G_DISK}
K3s .................. ${G_K3S}
Helm ................. ${G_HELM}
kubectl .............. ${G_KUBECTL}
StorageClass ......... ${G_SC}
Metrics Server ....... ${G_METRICS}
Timezone ............. ${TIMEZONE}
Swap ................. ${G_SWAP}
Firewall ............. ${G_FIREWALL}
Project .............. ${G_PROJECT}
====================================================
 Host Provisioning Completed
====================================================
SUMMARY
}

############################################################
# Main
############################################################
main() {
  # Set up log file + mirror all stdout/stderr into it from here on
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/bootstrap-host.log"
    touch "$LOG_FILE"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1

  info "Logging to $LOG_FILE"

  step_environment_validation
  step_firewall_check
  step_system_update
  step_required_packages
  step_system_tuning
  step_disable_swap
  step_time_sync
  step_install_k3s
  step_kubectl
  step_helm
  step_storage
  step_metrics_server
  step_git_sync
  step_permissions
  step_final_validation
  step_host_summary
}

main "$@"

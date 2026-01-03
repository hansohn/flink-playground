#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing prerequisites for Flink autoscaling environment (macOS Homebrew) ==="

# ---------------------------------------------------------
# Helper function
# ---------------------------------------------------------

install_if_missing() {
  local pkg="$1"
  local brew_name="${2:-$1}"

  if brew list --versions "$brew_name" >/dev/null 2>&1; then
    echo "[OK] $pkg already installed"
  else
    echo "[INSTALL] $pkg"
    brew install "$brew_name"
  fi
}

cask_if_missing() {
  local pkg="$1"
  local brew_name="${2:-$1}"

  if brew list --cask --versions "$brew_name" >/dev/null 2>&1; then
    echo "[OK] $pkg already installed"
  else
    echo "[INSTALL] $pkg"
    brew install --cask "$brew_name"
  fi
}

# ---------------------------------------------------------
# Ensure Homebrew is installed
# ---------------------------------------------------------

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing Homebrew first..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)" # for Apple Silicon
fi

echo "Updating Homebrew..."
brew update

# ---------------------------------------------------------
# Required tools
# ---------------------------------------------------------

echo
echo "=== Installing core tools ==="

# Docker Desktop (required for kind to run containers)
cask_if_missing "Docker Desktop" docker

# Kubernetes & Helm tooling
install_if_missing "kubectl"
install_if_missing "helm"

# Kind
install_if_missing "kind"

# Java + Maven for building the Flink autoscaling job
install_if_missing "OpenJDK" openjdk
install_if_missing "Maven" maven

# Optional utilities
echo
echo "=== Installing optional utilities ==="
install_if_missing "jq"
install_if_missing "wget"
install_if_missing "GNU sed" gnu-sed

echo
echo "=== Final Checks ==="

echo -n "Docker: "
if docker --version 2>/dev/null; then
  echo "OK"
else
  echo "NOT FOUND"
fi

echo -n "kubectl: "
kubectl version --client --short || true

echo -n "kind: "
kind --version || true

echo -n "helm: "
helm version --short || true

echo -n "java: "
java --version || true

echo -n "mvn: "
mvn -version || true

echo
echo "🎉 All prerequisites installed!"
echo "You can now run:  make up"

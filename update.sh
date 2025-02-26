#!/bin/bash

set -euo pipefail  # 开启更严格的 shell 选项

# 常量定义
readonly RUSTDESK_DIR="/opt/rustdesk"
readonly GOHTTP_DIR="/opt/gohttp"
readonly NC='\033[0m' # No Color (for terminal output)

# 获取 RustDesk Server 的最新版本
get_latest_rustdesk_version() {
  curl -s "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" | \
  jq -r '.tag_name'
}

# 获取当前已安装的 RustDesk Server 版本
get_current_rustdesk_version() {
  if [ -d "$RUSTDESK_DIR" ] && command -v "$RUSTDESK_DIR/hbbr" >/dev/null 2>&1; then
      "$RUSTDESK_DIR/hbbr" --version 2>/dev/null | awk '{print $2}'
  else
    echo ""  # 返回空字符串，表示未安装
  fi
}

# 获取 gohttpserver 的最新版本
get_latest_gohttp_version() {
    curl -s "https://api.github.com/repos/codeskyblue/gohttpserver/releases/latest" | \
    jq -r '.tag_name'
}


# 停止服务
stop_services() {
  sudo systemctl stop gohttpserver.service 2>/dev/null || true
  sudo systemctl stop rustdesksignal.service 2>/dev/null || true
  sudo systemctl stop rustdeskrelay.service 2>/dev/null || true
}

# 启动服务
start_services() {
    sudo systemctl start rustdesksignal.service
    sudo systemctl start rustdeskrelay.service

     # Wait for rustdeskrelay to be ready.  Simpler loop.
    while ! sudo systemctl is-active --quiet rustdeskrelay.service; do
      echo -ne "Rustdesk Relay not ready yet...\n"
      sleep 3
    done

    sudo systemctl start gohttpserver.service
}


# 获取操作系统信息
get_os_info() {
  local os_name=""
  local os_version=""
  local upstream_id=""

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_name="$NAME"
    os_version="$VERSION_ID"
    upstream_id="${ID_LIKE:-$ID}"  # Use ID_LIKE if available, otherwise ID
    upstream_id=${upstream_id,,}   # Lowercase

  elif type lsb_release >/dev/null 2>&1; then
    os_name=$(lsb_release -si)
    os_version=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    os_name=$DISTRIB_ID
    os_version=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    os_name=Debian
    os_version=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    os_name=SuSE
    os_version=$(cat /etc/SuSe-release)
  elif [ -f /etc/redhat-release ]; then
    os_name=RedHat
    os_version=$(cat /etc/redhat-release)
  else
    os_name=$(uname -s)
    os_version=$(uname -r)
  fi

  echo "$os_name" "$os_version" "$upstream_id"
}

# 安装依赖
install_dependencies() {
  local os_name="$1"
  local upstream_id="$2"

  local prereq="curl wget unzip tar"
  local prereq_deb="dnsutils"
  local prereq_rpm="bind-utils"

  echo "Installing prerequisites..."

  if [[ "$os_name" == "Debian" || "$os_name" == "Ubuntu" || "$upstream_id" == "debian" || "$upstream_id" == "ubuntu" ]]; then
    sudo apt-get update
    sudo apt-get install -y "$prereq" "$prereq_deb"
  elif [[ "$os_name" == "CentOS" || "$os_name" == "RedHat" || "$upstream_id" == "rhel" ]]; then
    sudo yum update -y
    sudo yum install -y "$prereq" "$prereq_rpm"
  elif [[ "$upstream_id" == "arch" ]]; then
    sudo pacman -Syu
    sudo pacman -S "$prereq"  # Assuming prereq_arch is defined, or use a common list
  else
     echo "Unsupported OS: $os_name"
     echo "Currently supported: Debian, Ubuntu, CentOS, RedHat, Arch Linux"
     exit 1
  fi
}

# 更新 RustDesk Server
update_rustdesk() {
    local latest_version="$1"
    local arch="$(uname -m)"

    cd "$RUSTDESK_DIR" || { echo "Error: Could not cd to $RUSTDESK_DIR"; exit 1; }
    rm -f *.zip

    echo "Upgrading Rustdesk Server to version: $latest_version"

    local download_url=""
    local archive_name=""

     case "$arch" in
        x86_64)
          download_url="https://github.com/rustdesk/rustdesk-server/releases/download/${latest_version}/rustdesk-server-linux-amd64.zip"
          archive_name="rustdesk-server-linux-amd64.zip"
          ;;
        armv7l)
          download_url="https://github.com/rustdesk/rustdesk-server/releases/download/${latest_version}/rustdesk-server-linux-armv7.zip"
           archive_name="rustdesk-server-linux-armv7.zip"
          ;;
        aarch64)
          download_url="https://github.com/rustdesk/rustdesk-server/releases/download/${latest_version}/rustdesk-server-linux-arm64v8.zip"
          archive_name="rustdesk-server-linux-arm64v8.zip"
          ;;
        *)
          echo "Unsupported architecture: $arch"
          exit 1
          ;;
      esac

    wget "$download_url" -O "$archive_name" || { echo "Download failed."; exit 1; }
    unzip -j -o "$archive_name" "*/hbbs" "*/hbbr" -d "$RUSTDESK_DIR" || { echo "Unzip failed."; exit 1; }
    rm -f "$archive_name"

}

# 更新 gohttpserver
update_gohttp() {
    local latest_version="$1"
    local arch="$(uname -m)"

    if [ ! -f "$GOHTTP_DIR/gohttpserver" ]; then
      echo "gohttpserver is not installed. Skipping update."
      return
    fi

    cd "$GOHTTP_DIR" || { echo "Error: Could not cd to $GOHTTP_DIR"; exit 1; }
    
    local download_url=""
    local archive_name=""

    case "$arch" in
      x86_64)
          download_url="https://github.com/codeskyblue/gohttpserver/releases/download/${latest_version}/gohttpserver_${latest_version}_linux_amd64.tar.gz"
          archive_name="gohttpserver_${latest_version}_linux_amd64.tar.gz"
          ;;
      aarch64)
           download_url="https://github.com/codeskyblue/gohttpserver/releases/download/${latest_version}/gohttpserver_${latest_version}_linux_arm64.tar.gz"
          archive_name="gohttpserver_${latest_version}_linux_arm64.tar.gz"
          ;;
      armv7l)
          echo "Go HTTP Server not supported on 32bit ARM devices"
          exit 1
          ;;
      *)
          echo "Unsupported architecture: $arch"
          exit 1
          ;;
    esac

    wget "$download_url" -O "$archive_name" || { echo "Download failed."; exit 1;}
    tar -xf "$archive_name" || { echo "Extraction failed."; exit 1;}
    rm -f "$archive_name"

}



# 主逻辑
main() {
  read -r os_name os_version upstream_id <<< "$(get_os_info)"

  if [ "$DEBUG" = "true" ]; then
    echo "OS: $os_name"
    echo "VER: $os_version"
    echo "UPSTREAM_ID: $upstream_id"
    exit 0
  fi

  install_dependencies "$os_name" "$upstream_id"

  local latest_rustdesk_version="$(get_latest_rustdesk_version)"
  local current_rustdesk_version="$(get_current_rustdesk_version)"

  stop_services

    if [ "$latest_rustdesk_version" != "$current_rustdesk_version" ]; then
        if [ ! -d "$RUSTDESK_DIR" ]; then
          echo "RustDesk directory not found.  Run install.sh first."
          exit 1
        fi

        update_rustdesk "$latest_rustdesk_version"
    else
        echo "RustDesk Server is up to date."
    fi

  local latest_gohttp_version="$(get_latest_gohttp_version)"
  update_gohttp "$latest_gohttp_version"

  start_services


  echo "Updates are complete."
}

main "$@"

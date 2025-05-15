#!/bin/bash
## Do not modify this file. You will lose the ability to install and auto-update!

## Environment variables that can be set:
## ROOT_USERNAME - Predefined root username
## ROOT_USER_EMAIL - Predefined root user email
## ROOT_USER_PASSWORD - Predefined root user password
## DOCKER_ADDRESS_POOL_BASE - Custom Docker address pool base (default: 10.0.0.0/8)
## DOCKER_ADDRESS_POOL_SIZE - Custom Docker address pool size (default: 24)
## DOCKER_POOL_FORCE_OVERRIDE - Force override Docker address pool configuration (default: false)
## AUTOUPDATE - Set to "false" to disable auto-updates
## REGISTRY_URL - Custom registry URL for Docker images (default: ghcr.io)

set -e # Exit immediately if a command exits with a non-zero status
## $1 could be empty, so we need to disable this check
#set -u # Treat unset variables as an error and exit
set -o pipefail # Cause a pipeline to return the status of the last command that exited with a non-zero status
CDN="https://cdn.coollabs.io/coolify"
DATE=$(date +"%Y%m%d-%H%M%S")

OS_TYPE=$(grep -w "ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')
ENV_FILE="/data/coolify/source/.env"
VERSION="20"
DOCKER_VERSION="27.0"
# TODO: Ask for a user
CURRENT_USER=$USER

if [ $EUID != 0 ]; then
    echo "Please run this script as root or with sudo"
    exit
fi

echo -e "Welcome to Coolify Installer!"
echo -e "This script will install everything for you. Sit back and relax."
echo -e "Source code: https://github.com/coollabsio/coolify/blob/main/scripts/install.sh\n"

# Predefined root user
ROOT_USERNAME=${ROOT_USERNAME:-}
ROOT_USER_EMAIL=${ROOT_USER_EMAIL:-}
ROOT_USER_PASSWORD=${ROOT_USER_PASSWORD:-}

if [ -n "${REGISTRY_URL+x}" ]; then
    echo "Using registry URL from environment variable: $REGISTRY_URL"
else
    if [ -f "$ENV_FILE" ] && grep -q "^REGISTRY_URL=" "$ENV_FILE"; then
        REGISTRY_URL=$(grep "^REGISTRY_URL=" "$ENV_FILE" | cut -d '=' -f2)
        echo "Using registry URL from .env: $REGISTRY_URL"
    else
        REGISTRY_URL="ghcr.io"
        echo "Using default registry URL: $REGISTRY_URL"
    fi
fi

# Docker address pool configuration defaults
DOCKER_ADDRESS_POOL_BASE_DEFAULT="10.0.0.0/8"
DOCKER_ADDRESS_POOL_SIZE_DEFAULT=24

# Check if environment variables were explicitly provided
DOCKER_POOL_BASE_PROVIDED=false
DOCKER_POOL_SIZE_PROVIDED=false
DOCKER_POOL_FORCE_OVERRIDE=${DOCKER_POOL_FORCE_OVERRIDE:-false}

if [ -n "${DOCKER_ADDRESS_POOL_BASE+x}" ]; then
    DOCKER_POOL_BASE_PROVIDED=true
fi

if [ -n "${DOCKER_ADDRESS_POOL_SIZE+x}" ]; then
    DOCKER_POOL_SIZE_PROVIDED=true
fi

restart_docker_service() {
    # Check if systemctl is available
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker
        if [ $? -eq 0 ]; then
            echo " - Docker daemon restarted successfully"
        else
            echo " - Failed to restart Docker daemon"
            return 1
        fi
    # Check if service command is available
    elif command -v service >/dev/null 2>&1; then
        service docker restart
        if [ $? -eq 0 ]; then
            echo " - Docker daemon restarted successfully"
        else
            echo " - Failed to restart Docker daemon"
            return 1
        fi
    # If neither systemctl nor service is available
    else
        echo " - Error: No service management system found"
        return 1
    fi
}

# Function to compare address pools
compare_address_pools() {
    local base1="$1"
    local size1="$2"
    local base2="$3"
    local size2="$4"

    # Normalize CIDR notation for comparison
    local ip1=$(echo "$base1" | cut -d'/' -f1)
    local prefix1=$(echo "$base1" | cut -d'/' -f2)
    local ip2=$(echo "$base2" | cut -d'/' -f1)
    local prefix2=$(echo "$base2" | cut -d'/' -f2)

    # Compare IPs and prefixes
    if [ "$ip1" = "$ip2" ] && [ "$prefix1" = "$prefix2" ] && [ "$size1" = "$size2" ]; then
        return 0 # Pools are the same
    else
        return 1 # Pools are different
    fi
}

# Docker address pool configuration
DOCKER_ADDRESS_POOL_BASE=${DOCKER_ADDRESS_POOL_BASE:-"$DOCKER_ADDRESS_POOL_BASE_DEFAULT"}
DOCKER_ADDRESS_POOL_SIZE=${DOCKER_ADDRESS_POOL_SIZE:-$DOCKER_ADDRESS_POOL_SIZE_DEFAULT}

# Load Docker address pool configuration from .env file if it exists and environment variables were not provided
if [ -f "/data/coolify/source/.env" ] && [ "$DOCKER_POOL_BASE_PROVIDED" = false ] && [ "$DOCKER_POOL_SIZE_PROVIDED" = false ]; then
    ENV_DOCKER_ADDRESS_POOL_BASE=$(grep -E "^DOCKER_ADDRESS_POOL_BASE=" /data/coolify/source/.env | cut -d '=' -f2 || true)
    ENV_DOCKER_ADDRESS_POOL_SIZE=$(grep -E "^DOCKER_ADDRESS_POOL_SIZE=" /data/coolify/source/.env | cut -d '=' -f2 || true)

    if [ -n "$ENV_DOCKER_ADDRESS_POOL_BASE" ]; then
        DOCKER_ADDRESS_POOL_BASE="$ENV_DOCKER_ADDRESS_POOL_BASE"
    fi

    if [ -n "$ENV_DOCKER_ADDRESS_POOL_SIZE" ]; then
        DOCKER_ADDRESS_POOL_SIZE="$ENV_DOCKER_ADDRESS_POOL_SIZE"
    fi
fi

# Check if daemon.json exists and extract existing address pool configuration
EXISTING_POOL_CONFIGURED=false
if [ -f /etc/docker/daemon.json ]; then
    if jq -e '.["default-address-pools"]' /etc/docker/daemon.json >/dev/null 2>&1; then
        EXISTING_POOL_BASE=$(jq -r '.["default-address-pools"][0].base' /etc/docker/daemon.json 2>/dev/null || true)
        EXISTING_POOL_SIZE=$(jq -r '.["default-address-pools"][0].size' /etc/docker/daemon.json 2>/dev/null || true)

        if [ -n "$EXISTING_POOL_BASE" ] && [ -n "$EXISTING_POOL_SIZE" ] && [ "$EXISTING_POOL_BASE" != "null" ] && [ "$EXISTING_POOL_SIZE" != "null" ]; then
            echo "Found existing Docker network pool: $EXISTING_POOL_BASE/$EXISTING_POOL_SIZE"
            EXISTING_POOL_CONFIGURED=true

            # Check if environment variables were explicitly provided
            if [ "$DOCKER_POOL_BASE_PROVIDED" = false ] && [ "$DOCKER_POOL_SIZE_PROVIDED" = false ]; then
                DOCKER_ADDRESS_POOL_BASE="$EXISTING_POOL_BASE"
                DOCKER_ADDRESS_POOL_SIZE="$EXISTING_POOL_SIZE"
            else
                # Check if force override is enabled
                if [ "$DOCKER_POOL_FORCE_OVERRIDE" = true ]; then
                    echo "Force override enabled - network pool will be updated with $DOCKER_ADDRESS_POOL_BASE/$DOCKER_ADDRESS_POOL_SIZE."
                else
                    echo "Custom pool provided but force override not enabled - using existing configuration."
                    echo "To force override, set DOCKER_POOL_FORCE_OVERRIDE=true"
                    echo "This won't change the existing docker networks, only the pool configuration for the newly created networks."
                    DOCKER_ADDRESS_POOL_BASE="$EXISTING_POOL_BASE"
                    DOCKER_ADDRESS_POOL_SIZE="$EXISTING_POOL_SIZE"
                    DOCKER_POOL_BASE_PROVIDED=false
                    DOCKER_POOL_SIZE_PROVIDED=false
                fi
            fi
        fi
    fi
fi

# Validate Docker address pool configuration
if ! [[ $DOCKER_ADDRESS_POOL_BASE =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "Warning: Invalid network pool base format: $DOCKER_ADDRESS_POOL_BASE"
    if [ "$EXISTING_POOL_CONFIGURED" = true ]; then
        echo "Using existing configuration: $EXISTING_POOL_BASE"
        DOCKER_ADDRESS_POOL_BASE="$EXISTING_POOL_BASE"
    else
        echo "Using default configuration: $DOCKER_ADDRESS_POOL_BASE_DEFAULT"
        DOCKER_ADDRESS_POOL_BASE="$DOCKER_ADDRESS_POOL_BASE_DEFAULT"
    fi
fi

if ! [[ $DOCKER_ADDRESS_POOL_SIZE =~ ^[0-9]+$ ]] || [ "$DOCKER_ADDRESS_POOL_SIZE" -lt 16 ] || [ "$DOCKER_ADDRESS_POOL_SIZE" -gt 28 ]; then
    echo "Warning: Invalid network pool size: $DOCKER_ADDRESS_POOL_SIZE (must be 16-28)"
    if [ "$EXISTING_POOL_CONFIGURED" = true ]; then
        echo "Using existing configuration: $EXISTING_POOL_SIZE"
        DOCKER_ADDRESS_POOL_SIZE="$EXISTING_POOL_SIZE"
    else
        echo "Using default configuration: $DOCKER_ADDRESS_POOL_SIZE_DEFAULT"
        DOCKER_ADDRESS_POOL_SIZE=$DOCKER_ADDRESS_POOL_SIZE_DEFAULT
    fi
fi

TOTAL_SPACE=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
AVAILABLE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
REQUIRED_TOTAL_SPACE=30
REQUIRED_AVAILABLE_SPACE=20
WARNING_SPACE=false

if [ "$TOTAL_SPACE" -lt "$REQUIRED_TOTAL_SPACE" ]; then
    WARNING_SPACE=true
    cat <<EOF
WARNING: Insufficient total disk space!

Total disk space:     ${TOTAL_SPACE}GB
Required disk space:  ${REQUIRED_TOTAL_SPACE}GB

==================
EOF
fi

if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_AVAILABLE_SPACE" ]; then
    cat <<EOF
WARNING: Insufficient available disk space!

Available disk space:   ${AVAILABLE_SPACE}GB
Required available space: ${REQUIRED_AVAILABLE_SPACE}GB

==================
EOF
    WARNING_SPACE=true
fi

if [ "$WARNING_SPACE" = true ]; then
    echo "Sleeping for 5 seconds."
    sleep 5
fi

mkdir -p /data/coolify/{source,ssh,applications,databases,backups,services,proxy,webhooks-during-maintenance,sentinel}
mkdir -p /data/coolify/ssh/{keys,mux}
mkdir -p /data/coolify/proxy/dynamic

chown -R 9999:root /data/coolify
chmod -R 700 /data/coolify

INSTALLATION_LOG_WITH_DATE="/data/coolify/source/installation-${DATE}.log"

exec > >(tee -a $INSTALLATION_LOG_WITH_DATE) 2>&1

getAJoke() {
    JOKES=$(curl -s --max-time 2 "https://v2.jokeapi.dev/joke/Programming?blacklistFlags=nsfw,religious,political,racist,sexist,explicit&format=txt&type=single" || true)
    if [ "$JOKES" != "" ]; then
        echo -e " - Until then, here's a joke for you:\n"
        echo -e "$JOKES\n"
    fi
}

# Check if the OS is manjaro, if so, change it to arch
if [ "$OS_TYPE" = "manjaro" ] || [ "$OS_TYPE" = "manjaro-arm" ]; then
    OS_TYPE="arch"
fi

# Check if the OS is Endeavour OS, if so, change it to arch
if [ "$OS_TYPE" = "endeavouros" ]; then
    OS_TYPE="arch"
fi

# Check if the OS is Asahi Linux, if so, change it to fedora
if [ "$OS_TYPE" = "fedora-asahi-remix" ]; then
    OS_TYPE="fedora"
fi

# Check if the OS is popOS, if so, change it to ubuntu
if [ "$OS_TYPE" = "pop" ]; then
    OS_TYPE="ubuntu"
fi

# Check if the OS is linuxmint, if so, change it to ubuntu
if [ "$OS_TYPE" = "linuxmint" ]; then
    OS_TYPE="ubuntu"
fi

#Check if the OS is zorin, if so, change it to ubuntu
if [ "$OS_TYPE" = "zorin" ]; then
    OS_TYPE="ubuntu"
fi

if [ "$OS_TYPE" = "arch" ] || [ "$OS_TYPE" = "archarm" ]; then
    OS_VERSION="rolling"
else
    OS_VERSION=$(grep -w "VERSION_ID" /etc/os-release | cut -d "=" -f 2 | tr -d '"')
fi

# Install xargs on Amazon Linux 2023 - lol
if [ "$OS_TYPE" = 'amzn' ]; then
    dnf install -y findutils >/dev/null
fi

LATEST_VERSION=$(curl --silent $CDN/versions.json | grep -i version | xargs | awk '{print $2}' | tr -d ',')
LATEST_HELPER_VERSION=$(curl --silent $CDN/versions.json | grep -i version | xargs | awk '{print $6}' | tr -d ',')
LATEST_REALTIME_VERSION=$(curl --silent $CDN/versions.json | grep -i version | xargs | awk '{print $8}' | tr -d ',')

if [ -z "$LATEST_HELPER_VERSION" ]; then
    LATEST_HELPER_VERSION=latest
fi

if [ -z "$LATEST_REALTIME_VERSION" ]; then
    LATEST_REALTIME_VERSION=latest
fi

case "$OS_TYPE" in
arch | ubuntu | debian | raspbian | centos | fedora | rhel | ol | rocky | sles | opensuse-leap | opensuse-tumbleweed | almalinux | amzn | alpine) ;;
*)
    echo "This script only supports Debian, Redhat, Arch Linux, Alpine Linux, or SLES based operating systems for now."
    exit
    ;;
esac

# Overwrite LATEST_VERSION if user pass a version number
if [ "$1" != "" ]; then
    LATEST_VERSION=$1
    LATEST_VERSION="${LATEST_VERSION,,}"
    LATEST_VERSION="${LATEST_VERSION#v}"
fi

echo -e "---------------------------------------------"
echo "| Operating System  | $OS_TYPE $OS_VERSION"
echo "| Docker            | $DOCKER_VERSION"
echo "| Coolify           | $LATEST_VERSION"
echo "| Helper            | $LATEST_HELPER_VERSION"
echo "| Realtime          | $LATEST_REALTIME_VERSION"
echo "| Docker Pool       | $DOCKER_ADDRESS_POOL_BASE (size $DOCKER_ADDRESS_POOL_SIZE)"
echo "| Registry URL      | $REGISTRY_URL"
echo -e "---------------------------------------------\n"
echo -e "1. Installing required packages (curl, wget, git, jq, openssl). "

case "$OS_TYPE" in
arch)
    pacman -Sy --noconfirm --needed curl wget git jq openssl >/dev/null || true
    ;;
alpine)
    sed -i '/^#.*\/community/s/^#//' /etc/apk/repositories
    apk update >/dev/null
    apk add curl wget git jq openssl >/dev/null
    ;;
ubuntu | debian | raspbian)
    apt-get update -y >/dev/null
    apt-get install -y curl wget git jq openssl >/dev/null
    ;;
centos | fedora | rhel | ol | rocky | almalinux | amzn)
    if [ "$OS_TYPE" = "amzn" ]; then
        dnf install -y wget git jq openssl >/dev/null
    else
        if ! command -v dnf >/dev/null; then
            yum install -y dnf >/dev/null
        fi
        if ! command -v curl >/dev/null; then
            dnf install -y curl >/dev/null
        fi
        dnf install -y wget git jq openssl >/dev/null
    fi
    ;;
sles | opensuse-leap | opensuse-tumbleweed)
    zypper refresh >/dev/null
    zypper install -y curl wget git jq openssl >/dev/null
    ;;
*)
    echo "This script only supports Debian, Redhat, Arch Linux, or SLES based operating systems for now."
    exit
    ;;
esac

echo -e "2. Check OpenSSH server configuration. "

# Detect OpenSSH server
SSH_DETECTED=false
if [ -x "$(command -v systemctl)" ]; then
    if systemctl status sshd >/dev/null 2>&1; then
        echo " - OpenSSH server is installed."
        SSH_DETECTED=true
    elif systemctl status ssh >/dev/null 2>&1; then
        echo " - OpenSSH server is installed."
        SSH_DETECTED=true
    fi
elif [ -x "$(command -v service)" ]; then
    if service sshd status >/dev/null 2>&1; then
        echo " - OpenSSH server is installed."
        SSH_DETECTED=true
    elif service ssh status >/dev/null 2>&1; then
        echo " - OpenSSH server is installed."
        SSH_DETECTED=true
    fi
fi

if [ "$SSH_DETECTED" = "false" ]; then
    echo " - OpenSSH server not detected. Installing OpenSSH server."
    case "$OS_TYPE" in
    arch)
        pacman -Sy --noconfirm openssh >/dev/null
        systemctl enable sshd >/dev/null 2>&1
        systemctl start sshd >/dev/null 2>&1
        ;;
    alpine)
        apk add openssh >/dev/null
        rc-update add sshd default >/dev/null 2>&1
        service sshd start >/dev/null 2>&1
        ;;
    ubuntu | debian | raspbian)
        apt-get update -y >/dev/null
        apt-get install -y openssh-server >/dev/null
        systemctl enable ssh >/dev/null 2>&1
        systemctl start ssh >/dev/null 2>&1
        ;;
    centos | fedora | rhel | ol | rocky | almalinux | amzn)
        if [ "$OS_TYPE" = "amzn" ]; then
            dnf install -y openssh-server >/dev/null
        else
            dnf install -y openssh-server >/dev/null
        fi
        systemctl enable sshd >/dev/null 2>&1
        systemctl start sshd >/dev/null 2>&1
        ;;
    sles | opensuse-leap | opensuse-tumbleweed)
        zypper install -y openssh >/dev/null
        systemctl enable sshd >/dev/null 2>&1
        systemctl start sshd >/dev/null 2>&1
        ;;
    *)
        echo "###############################################################################"
        echo "WARNING: Could not detect and install OpenSSH server - this does not mean that it is not installed or not running, just that we could not detect it."
        echo -e "Please make sure it is installed and running, otherwise Coolify cannot connect to the host system. \n"
        echo "###############################################################################"
        exit 1
        ;;
    esac
    echo " - OpenSSH server installed successfully."
    SSH_DETECTED=true
fi

# Detect SSH PermitRootLogin
SSH_PERMIT_ROOT_LOGIN=$(sshd -T | grep -i "permitrootlogin" | awk '{print $2}') || true
if [ "$SSH_PERMIT_ROOT_LOGIN" = "yes" ] || [ "$SSH_PERMIT_ROOT_LOGIN" = "without-password" ] || [ "$SSH_PERMIT_ROOT_LOGIN" = "prohibit-password" ]; then
    echo " - SSH PermitRootLogin is enabled."
else
    echo " - SSH PermitRootLogin is disabled."
    echo "   If you have problems with SSH, please read this: https://coolify.io/docs/knowledge-base/server/openssh"
fi

# Detect if docker is installed via snap
if [ -x "$(command -v snap)" ]; then
    SNAP_DOCKER_INSTALLED=$(snap list docker >/dev/null 2>&1 && echo "true" || echo "false")
    if [ "$SNAP_DOCKER_INSTALLED" = "true" ]; then
        echo " - Docker is installed via snap."
        echo "   Please note that Coolify does not support Docker installed via snap."
        echo "   Please remove Docker with snap (snap remove docker) and reexecute this script."
        exit 1
    fi
fi

install_docker() {
    curl -s https://releases.rancher.com/install-docker/${DOCKER_VERSION}.sh | sh 2>&1 || true
    if ! [ -x "$(command -v docker)" ]; then
        curl -s https://get.docker.com | sh -s -- --version ${DOCKER_VERSION} 2>&1
        if ! [ -x "$(command -v docker)" ]; then
            echo " - Docker installation failed."
            echo "   Maybe your OS is not supported?"
            echo " - Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
            exit 1
        fi
    fi
}
echo -e "3. Check Docker Installation. "
if ! [ -x "$(command -v docker)" ]; then
    echo " - Docker is not installed. Installing Docker. It may take a while."
    getAJoke
    case "$OS_TYPE" in
    "almalinux")
        dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
        if ! [ -x "$(command -v docker)" ]; then
            echo " - Docker could not be installed automatically. Please visit https://docs.docker.com/engine/install/ and install Docker manually to continue."
            exit 1
        fi
        systemctl start docker >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        ;;
    "alpine")
        apk add docker docker-cli-compose >/dev/null 2>&1
        rc-update add docker default >/dev/null 2>&1
        service docker start >/dev/null 2>&1
        if ! [ -x "$(command -v docker)" ]; then
            echo " - Failed to install Docker with apk. Try to install it manually."
            echo "   Please visit https://wiki.alpinelinux.org/wiki/Docker for more information."
            exit 1
        fi
        ;;
    "arch")
        pacman -Sy docker docker-compose --noconfirm >/dev/null 2>&1
        systemctl enable docker.service >/dev/null 2>&1
        if ! [ -x "$(command -v docker)" ]; then
            echo " - Failed to install Docker with pacman. Try to install it manually."
            echo "   Please visit https://wiki.archlinux.org/title/docker for more information."
            exit 1
        fi
        ;;
    "amzn")
        dnf install docker -y >/dev/null 2>&1
        DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
        mkdir -p $DOCKER_CONFIG/cli-plugins >/dev/null 2>&1
        curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o $DOCKER_CONFIG/cli-plugins/docker-compose >/dev/null 2>&1
        chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose >/dev/null 2>&1
        systemctl start docker >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        if ! [ -x "$(command -v docker)" ]; then
            echo " - Failed to install Docker with dnf. Try to install it manually."
            echo "   Please visit https://www.cyberciti.biz/faq/how-to-install-docker-on-amazon-linux-2/ for more information."
            exit 1
        fi
        ;;
    "centos" | "fedora" | "rhel")
        if [ -x "$(command -v dnf5)" ]; then
            # dnf5 is available
            dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/$OS_TYPE/docker-ce.repo --overwrite >/dev/null 2>&1
        else
            # dnf5 is not available, u

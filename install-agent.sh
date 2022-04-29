#!/bin/bash
# The script requires root permissions

set -e

function print_help() {
    cat <<END
This is the trento-agent installer.
Trento agent is a single process that discovers information of your target SAP infrastructure and pushes them to a control plane,
your single pane of glass on your SAP Applications.

Usage:

  sudo ./install-agent.sh --ssh-address <host-ip> --server-url <trento-server-url> --api-key <your-api-key>

Arguments:
  --ssh-address     The address to which the trento-agent should be reachable for ssh connection by the runner for check execution.
  --server-url      The trento server url.
  --api-key         The API key generated byt the trento server installation.
  --rolling         Use the rolling version instead of the stable one.
  --use-tgz         Use the trento tar.gz file from GH releases rather than the RPM.
  --interval        The polling interval in seconds for the discoveries.
  --help            Print this help.
END
}

case "$1" in
--help)
    print_help
    exit 0
    ;;
esac

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
fi

ARGUMENT_LIST=(
    "ssh-address:"
    "server-url:"
    "api-key:"
    "rolling"
    "use-tgz"
    "interval:"
)

readonly TRENTO_VERSION=1.0.0

opts=$(
    getopt \
        --longoptions "$(printf "%s," "${ARGUMENT_LIST[@]}")" \
        --name "$(basename "$0")" \
        --options "" \
        -- "$@"
)

eval set "--$opts"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --ssh-address)
        SSH_ADDRESS=$2
        shift 2
        ;;

    --server-url)
        SERVER_URL=$2
        shift 2
        ;;

    --api-key)
        API_KEY=$2
        shift 2
        ;;

    --rolling)
        USE_ROLLING=true
        shift 1
        ;;

    --use-tgz)
        USE_TGZ=true
        shift 1
        ;;

    --interval)
        INTERVAL=$2
        shift 2
        ;;

    *)
        break
        ;;
    esac
done

AGENT_CONFIG_PATH="/etc/trento"
AGENT_CONFIG_FILE="$AGENT_CONFIG_PATH/agent.yaml"
AGENT_CONFIG_TEMPLATE='
ssh-address: @SSH_ADDRESS@
server-url: @SERVER_URL@
api-key: @API_KEY@
cloud-discovery-period: @INTERVAL@s
cluster-discovery-period: @INTERVAL@s
host-discovery-period: @INTERVAL@s
sapsystem-discovery-period: @INTERVAL@s
'

. /etc/os-release
if [[ ! $PRETTY_NAME =~ "SUSE" ]]; then
    echo "Warning: non-SUSE operating system, forcing --use-tgz"
    USE_TGZ=true
fi

echo "Installing trento-agent..."

function check_installer_deps() {
    if ! which unzip >/dev/null 2>&1; then
        echo "unzip is required by this script. Please install it with: zypper in -y unzip"
        exit 1
    fi
    if ! which curl >/dev/null 2>&1; then
        echo "curl is required by this script. Please install it with: zypper in -y curl"
        exit 1
    fi
}

function configure_installation() {
    if [[ -z "$SSH_ADDRESS" ]]; then
        read -rp "Please provide an ssh address for the agent: " SSH_ADDRESS </dev/tty
    fi
    if [[ -z "$SERVER_URL" ]]; then
        read -rp "Please provide the server url: " SERVER_URL </dev/tty
    fi

    if [[ -z "$API_KEY" ]]; then
        read -rp "Please provide the API key: " API_KEY </dev/tty
    fi
}

function install_trento() {
    if [[ -f "/usr/lib/systemd/system/trento-agent.service" ]]; then
        echo "* Warning: Trento already installed. Stopping..."
        systemctl stop trento-agent
    fi

    if [[ -n "$USE_TGZ" ]]; then
        echo "* Downloading trento tar.gz from GitHub..."
        install_trento_tgz
    else
        install_trento_rpm
    fi
}

function install_trento_rpm() {
    if [[ -n "$USE_ROLLING" ]]; then
        TRENTO_REPO=${TRENTO_REPO:-"https://download.opensuse.org/repositories/devel:/sap:/trento:/factory/15.3/devel:sap:trento:factory.repo"}
        TRENTO_REPO_KEY=${TRENTO_REPO_KEY:-"https://download.opensuse.org/repositories/devel:/sap:/trento:/factory/15.3/repodata/repomd.xml.key"}
    else
        TRENTO_REPO=${TRENTO_REPO:-"https://download.opensuse.org/repositories/devel:/sap:/trento/15.3/devel:sap:trento.repo"}
        TRENTO_REPO_KEY=${TRENTO_REPO_KEY:-"https://download.opensuse.org/repositories/devel:/sap:/trento/15.3/repodata/repomd.xml.key"}
    fi

    rpm --import "${TRENTO_REPO_KEY}" >/dev/null
    path=${TRENTO_REPO%/*}/
    if zypper lr --details | cut -d'|' -f9 | grep "$path" >/dev/null 2>&1; then
        echo "* $path repository already exists. Skipping."
    else
        echo "* Adding Trento repository: $path."
        zypper ar "$TRENTO_REPO" >/dev/null
    fi
    zypper ref >/dev/null
    if which trento >/dev/null 2>&1; then
        echo "* Trento is already installed. Updating trento"
        zypper up -y trento-agent >/dev/null
    else
        echo "* Installing trento"
        zypper in -y trento-agent >/dev/null
    fi
}

function install_trento_tgz() {
    ARCH=$(uname -m | sed "s~x86_64~amd64~" | sed "s~aarch64~arm64~")
    local bin_dir=${BIN_DIR:-"/usr/bin"}
    local sysd_dir=${SYSD_DIR:-"/usr/lib/systemd/system"}
    local repo_owner=${TRENTO_REPO_OWNER:-"trento-project"}

    if [[ -n "$USE_ROLLING" ]]; then
        TRENTO_TGZ_URL=https://github.com/${repo_owner}/agent/releases/download/rolling/trento-agent-${ARCH}.tgz
    else
        TRENTO_TGZ_URL=https://github.com/${repo_owner}/agent/releases/download/${TRENTO_VERSION}/trento-agent-${ARCH}.tgz
    fi

    echo "* Downloading trento from $TRENTO_TGZ_URL ..."

    curl -f -sS -O -L "${TRENTO_TGZ_URL}" >/dev/null
    tar -zxf trento-agent-${ARCH}.tgz

    mv trento-agent ${bin_dir}/trento-agent
    mv packaging/systemd/trento-agent.service ${sysd_dir}/trento-agent.service
    systemctl daemon-reload
    rm trento-agent-${ARCH}.tgz
}

function setup_trento() {
    local interval=${INTERVAL:-"10"}

    echo "* Generating trento-agent config..."

    mkdir -p ${AGENT_CONFIG_PATH} && touch ${AGENT_CONFIG_FILE}

    echo "$AGENT_CONFIG_TEMPLATE" |
        sed "s|@SERVER_URL@|${SERVER_URL}|g" |
        sed "s|@SSH_ADDRESS@|${SSH_ADDRESS}|g" |
        sed "s|@API_KEY@|${API_KEY}|g" |
        sed "s|@INTERVAL@|${interval}|g" \
            >${AGENT_CONFIG_FILE}
}

check_installer_deps
configure_installation
install_trento
setup_trento

echo -e "\e[92mDone.\e[97m"
echo -e "Now you can start trento-agent with: \033[1msystemctl start trento-agent\033[0m"
echo -e "Please make sure the \033[1mserver\033[0m is running before starting the agent."

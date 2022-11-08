#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------


USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
UPDATE_RC="${UPDATE_RC:-"true"}"

MICROSOFT_GPG_KEYS_URI="https://packages.microsoft.com/keys/microsoft.asc"

set -eu

# Clean up
rm -rf /var/lib/apt/lists/*

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Ensure that login shells get the correct path if the user updated the PATH using ENV.
rm -f /etc/profile.d/00-restore-env.sh
echo "export PATH=${PATH//$(sh -lc 'echo $PATH')/\$PATH}" > /etc/profile.d/00-restore-env.sh
chmod +x /etc/profile.d/00-restore-env.sh

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

function updaterc() {
    if [ "${UPDATE_RC}" = "true" ]; then
        echo "Updating /etc/bash.bashrc and /etc/zsh/zshrc..."
        if [[ "$(cat /etc/bash.bashrc)" != *"$1"* ]]; then
            echo -e "$1" >> /etc/bash.bashrc
        fi
        if [ -f "/etc/zsh/zshrc" ] && [[ "$(cat /etc/zsh/zshrc)" != *"$1"* ]]; then
            echo -e "$1" >> /etc/zsh/zshrc
        fi
    fi
}

apt_get_update()
{
    if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -y
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"
    fi
}

install_dotnet_using_apt() {
    echo "Attempting to auto-install dotnet..."
    install_from_microsoft_feed=false
    apt_get_update
    DOTNET_INSTALLATION_PACKAGE="dotnet6"
    apt-get -yq install $DOTNET_INSTALLATION_PACKAGE || install_from_microsoft_feed="true"

    if [ "${install_from_microsoft_feed}" = "true" ]; then
        echo "Attempting install from microsoft apt feed..."
        curl -sSL ${MICROSOFT_GPG_KEYS_URI} | gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg
        echo "deb [arch=${architecture} signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/microsoft-${ID}-${VERSION_CODENAME}-prod ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/microsoft.list
        apt-get update -y
        DOTNET_INSTALLATION_PACKAGE="dotnet-sdk-6.0"
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE="true" apt-get install -yq $DOTNET_INSTALLATION_PACKAGE
    fi

    echo -e "Finished attempt to install dotnet.  Sdks installed:\n"
    dotnet --list-sdks

    # Clean up
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
}

. /etc/os-release
architecture="$(dpkg --print-architecture)"

# Currently, oryx is not supported with "jammy"
if [[ "jammy" = *"${VERSION_CODENAME}"* ]]; then
    echo "(!) Unsupported distribution version '${VERSION_CODENAME}'."
    exit 1
fi

# If we don't already have Oryx installed, install it now.
if  oryx --version > /dev/null ; then
    echo "oryx is already installed. Skipping installation."
    # Clean up
    rm -rf /var/lib/apt/lists/*
    exit 0
fi

echo "Installing Oryx..."

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive


# Install dependencies
check_packages git sudo curl ca-certificates apt-transport-https gnupg2 dirmngr libc-bin

if ! cat /etc/group | grep -e "^oryx:" > /dev/null 2>&1; then
    groupadd -r oryx
fi
usermod -a -G oryx "${USERNAME}"

# Required to decide if we want to clean up dotnet later.
DOTNET_INSTALLATION_PACKAGE=""

# Install dotnet unless available
if ! dotnet --version > /dev/null ; then
    echo "'dotnet' was not detected. Attempting to install the latest version of the dotnet sdk to build oryx."
    install_dotnet_using_apt

    if ! dotnet --version > /dev/null ; then
        echo "(!) Please install Dotnet before installing Oryx"
        exit 1
    fi
fi

BUILD_SCRIPT_GENERATOR=/usr/local/buildscriptgen
ORYX=/usr/local/oryx
GIT_ORYX=/opt/tmp/oryx-repo

mkdir -p ${BUILD_SCRIPT_GENERATOR}
mkdir -p ${ORYX}

git clone https://github.com/microsoft/Oryx $GIT_ORYX
cd $GIT_ORYX

# https://github.com/microsoft/Oryx/commit/74e4830b3636e5cfbce5b3e3358bd5bb66a87f45 is breaking the `oryx` tool
# Pinning to a previous working commit until the upstream issue is fixed.
git reset --hard 2b19efca9729673fc259e6a817be3cc0bb73b9d5

$GIT_ORYX/build/buildSln.sh

dotnet publish -property:ValidateExecutableReferencesMatchSelfContained=false -r linux-x64 -o ${BUILD_SCRIPT_GENERATOR} -c Release $GIT_ORYX/src/BuildScriptGeneratorCli/BuildScriptGeneratorCli.csproj
dotnet publish -r linux-x64 -o ${BUILD_SCRIPT_GENERATOR} -c Release $GIT_ORYX/src/BuildServer/BuildServer.csproj

chmod a+x ${BUILD_SCRIPT_GENERATOR}/GenerateBuildScript

ln -s ${BUILD_SCRIPT_GENERATOR}/GenerateBuildScript ${ORYX}/oryx
cp -f $GIT_ORYX/images/build/benv.sh ${ORYX}/benv
cp -f $GIT_ORYX/images/build/logger.sh ${ORYX}/logger

ORYX_INSTALL_DIR="/opt"
mkdir -p "${ORYX_INSTALL_DIR}"

# Directory used by the oryx tool to cache the automatically installed python packages from `requirements.txt`
PIP_CACHE_DIR="/usr/local/share/pip-cache/lib"
mkdir -p ${PIP_CACHE_DIR}

updaterc "export ORYX_SDK_STORAGE_BASE_URL=https://oryx-cdn.microsoft.io && export ENABLE_DYNAMIC_INSTALL=true && DYNAMIC_INSTALL_ROOT_DIR=$ORYX_INSTALL_DIR && ORYX_PREFER_USER_INSTALLED_SDKS=true && export DEBIAN_FLAVOR=focal-scm"

chown -R "${USERNAME}:oryx" "${ORYX_INSTALL_DIR}" "${BUILD_SCRIPT_GENERATOR}" "${ORYX}" "${PIP_CACHE_DIR}"
chmod -R g+r+w "${ORYX_INSTALL_DIR}" "${BUILD_SCRIPT_GENERATOR}" "${ORYX}" "${PIP_CACHE_DIR}"
find "${ORYX_INSTALL_DIR}" -type d -print0 | xargs -n 1 -0 chmod g+s
find "${BUILD_SCRIPT_GENERATOR}" -type d -print0 | xargs -n 1 -0 chmod g+s
find "${ORYX}" -type d -print0 | xargs -n 1 -0 chmod g+s
find "${PIP_CACHE_DIR}" -type d -print0 | xargs -n 1 -0 chmod g+s

# /opt/tmp/build and /opt/tmp/images is required by Oryx for dynamically installing platforms
cp -rf $GIT_ORYX/build /opt/tmp
cp -rf $GIT_ORYX/images /opt/tmp

# Clean up
rm -rf $GIT_ORYX

# Remove NuGet installed by the build/buildSln.sh
rm -rf /root/.nuget
rm -rf /root/.local/share/NuGet

# Remove dotnet if installed by the oryx feature
if [[ "${DOTNET_INSTALLATION_PACKAGE}" != "" ]]; then
    apt purge -yq $DOTNET_INSTALLATION_PACKAGE
fi

# Clean up
rm -rf /var/lib/apt/lists/*

echo "Done!"

#!/usr/bin/env bash

set -e -x -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HISTORY_DIR="${DIR}/.."
TOOLS_DIR="${DIR}/../../tools"

function check_env {
    if [ -z "${DOCKER_IMAGE}" ]; then
        echo "ERROR: Missing required DOCKER_IMAGE in env. See check in ${DIR}/universe.sh" 1>&2
        env
        exit 1
    fi
}

function make_universe {
    TEMPLATE_DEFAULT_DOCKER_IMAGE=${DOCKER_IMAGE} \
    TEMPLATE_HTTPS_PROTOCOL='https://' \
        ${TOOLS_DIR}/build_package.sh spark-history $HISTORY_DIR aws
}

check_env
make_universe

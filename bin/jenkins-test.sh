#!/bin/bash

set -ex
set -o pipefail

export S3_BUCKET=spark-build
export S3_PREFIX=
export DOCKER_IMAGE=mesosphere/spark-dev:${GIT_COMMIT}
# export DCOS_URL=http://mgummelt-elasticl-1u0grr02hczzt-463448784.us-west-2.elb.amazonaws.com/

function make_distribution {
    # ./build/sbt assembly
    pushd spark
    
    if [ -f make-distribution.sh ]; then
        ./make-distribution.sh -Phadoop-2.4 -DskipTests
    else
        ./dev/make-distribution.sh -Phadoop-2.4 -DskipTests
    fi

    # tmp
    #wget http://spark-build.s3.amazonaws.com/spark-0738bc281ea93f09c541e47d61b98fe7babc74e0.tgz
    #tar xvf spark-0738bc281ea93f09c541e47d61b98fe7babc74e0.tgz
    #rm spark-0738bc281ea93f09c541e47d61b98fe7babc74e0.tgz
    #mv spark-0738bc281ea93f09c541e47d61b98fe7babc74e0 dist

    local DIST="spark-${GIT_COMMIT}"
    mv dist ${DIST}
    tar czf ${DIST}.tgz ${DIST}

    popd
}

function upload_to_s3 {
    pushd spark
    
    aws s3 cp \
        --acl public-read \
        spark-*.tgz \
        "s3://${S3_BUCKET}/${S3_PREFIX}"

    popd
}

function update_manifest {
    pushd spark-build
    
    # update manifest.json    
    SPARK_DIST=$(ls ../spark/spark*.tgz)
    SPARK_URI="http://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}$(basename ${SPARK_DIST})"
    cat manifest.json | jq ".spark_uri=\"${SPARK_URI}\"" > manifest.json.tmp
    mv manifest.json.tmp manifest.json

    popd
}

function install_cli {
    curl -O https://downloads.mesosphere.io/dcos-cli/install.sh
    mkdir cli
    bash install.sh cli http://change.me --add-path no
    source cli/bin/env-setup

    # hack because the installer forces an old CLI version
    pip install -U dcoscli
}

function docker_login {
    docker login --username="${DOCKER_USERNAME}" --password="${DOCKER_PASSWORD}"
}

function spark_test {
    install_cli
    
    pushd spark-build
    docker_login    
    make docker
    CLUSTER_NAME=spark-package-${BUILD_NUMBER} \
                TEST_RUNNER_DIR=$(pwd)/../mesos-spark-integration-tests/test-runner/ \
                DCOS_CHANNEL=testing/continuous \
                DCOS_USERNAME=bootstrapuser \
                DCOS_PASSWORD=deleteme \
                make test
    popd
}

function upload_distribution {
    make_distribution
    upload_to_s3    
    update_manifest
}

function main {
    # prereqs
    #pip install virtualenv httpie
    #curl -LO https://dl.bintray.com/sbt/native-packages/sbt/0.13.9/sbt-0.13.9.tgz
    #tar xvf sbt-0.13.9.tgz
    #export PATH=$(pwd)/sbt/bin:$PATH
    
    upload_distribution
    spark_test    
}

main

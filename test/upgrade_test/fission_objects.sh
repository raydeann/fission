#!/bin/bash
set -eu

ns="fission"
ROOT=$(pwd)
PREV_STABLE_VERSION=1.13.1
HELM_VARS_PREV_RELEASE="routerServiceType=NodePort,analytics=false"
HELM_VARS_LATEST_RELEASE="routerServiceType=NodePort,repository=docker.io/library,image=fission-bundle,pullPolicy=IfNotPresent,imageTag=latest,fetcher.image=docker.io/library/fetcher,fetcher.imageTag=latest,postInstallReportImage=reporter,preUpgradeChecksImage=preupgradechecks,analytics=false"

doit() {
    echo "! $*"
    "$@"
}

dump_system_info() {
    echo "System Info"
    doit go version
    doit docker version
    doit kubectl version
    doit helm version
}

install_stable_release() {
    doit helm repo add fission-charts https://fission.github.io/fission-charts/
    doit helm repo update

    echo "Creating namespace $ns"
    doit kubectl create ns $ns

    echo "Creating CRDs"
    doit kubectl create -k "github.com/fission/fission/crds/v1?ref=$PREV_STABLE_VERSION"

    echo "Installing Fission $PREV_STABLE_VERSION"
    doit helm install --debug --wait --version $PREV_STABLE_VERSION \
        --namespace $ns fission fission-charts/fission-all --set $HELM_VARS_PREV_RELEASE

    echo "Download fission cli $PREV_STABLE_VERSION"
    curl -Lo fission https://github.com/fission/fission/releases/download/$PREV_STABLE_VERSION/fission-$PREV_STABLE_VERSION-linux-amd64 && chmod +x fission && sudo mv fission /usr/local/bin/
    doit fission version
}

create_fission_objects() {
    echo "-----------------#########################################--------------------"
    echo "                   Preparing for fission object creation"
    echo "-----------------#########################################--------------------"
    echo "Creating function environment."
    if fission env create --name nodejs --image fission/node-env:latest; then
        echo "Successfully created function environment"
    else
        echo "Environemnt creation failed"
        exit 1
    fi

    echo "Creating function"
    curl -LO https://raw.githubusercontent.com/fission/examples/master/nodejs/hello.js
    if fission function create --name hello --env nodejs --code hello.js; then
        echo "Successfully created function"
    else
        echo "Function creation failed"
        exit 1
    fi
    sleep 5
}

test_fission_objects() {
    fission env list
    fission function list
    echo "-----------------###############################--------------------"
    echo "                   Running fission object tests"
    echo "-----------------###############################--------------------"
    if fission function test --name hello; then
        echo "----------------------**********************-------------------------"
        echo "                           Test success"
        echo "----------------------**********************-------------------------"
    else
        echo "----------------------**********************-------------------------"
        echo "                            Test failed"
        echo "----------------------**********************-------------------------"
        exit 1
    fi
}

build_docker_images() {
    echo "Building new docker images"
    doit docker build -t fission-bundle -f cmd/fission-bundle/Dockerfile.fission-bundle .
    doit docker build -t fetcher -f cmd/fetcher/Dockerfile.fission-fetcher .
    doit docker build -t builder -f cmd/builder/Dockerfile.fission-builder .
    doit docker build -t reporter -f cmd/reporter/Dockerfile.reporter .
    doit docker build -t preupgradechecks -f cmd/preupgradechecks/Dockerfile.fission-preupgradechecks .
}

kind_image_load() {
    echo "Loading Docker images into Kind cluster."
    doit kind load docker-image fission-bundle --name kind
    doit kind load docker-image fetcher --name kind
    doit kind load docker-image builder --name kind
    doit kind load docker-image reporter --name kind
    doit kind load docker-image preupgradechecks --name kind
}

install_fission_cli() {
    echo "Installing new Fission cli"
    doit sudo make install-fission-cli
    sudo chmod +x /usr/local/bin/fission
}

install_current_release() {
    echo "Running Fission upgrade"
    doit helm dependency update "$ROOT"/charts/fission-all
    doit make update-crds
    doit helm upgrade --debug --wait --namespace $ns --set $HELM_VARS_LATEST_RELEASE fission "$ROOT"/charts/fission-all
}

"$@"

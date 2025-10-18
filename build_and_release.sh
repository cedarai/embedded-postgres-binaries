#!/bin/bash

set -e

rm -rf release
mkdir -p release

function do_build {
    version="$1"
    echo "=== Building ${version} ==="
    echo

    ARCH_NAME=${ARCH_NAME:-amd64}
    ./gradlew clean install -Pversion="${version}.0" -PpgVersion="${version}" -ParchName=${ARCH_NAME} -PpostgisVersion=$POSTGIS_VERSION -PpgroutingVersion=$PGROUTING_VERSION -PpgvectorVersion=0.8.0
    cp custom-debian-platform/build/tmp/buildCustomDebianBundle/bundle/postgres-linux-debian.txz "release/postgresql-${version}-linux-${ARCH_NAME}.txz"
}

# Note: Release publishing is handled by the GitHub Actions workflow.
# This script now only builds and stages artifacts under ./release

versions=("${PG_VERSION:-16.6}")
for version in "${versions[@]}"; do
    do_build "$version"
done

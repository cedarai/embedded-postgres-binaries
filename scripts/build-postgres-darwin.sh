#!/bin/bash
set -ex

# Dependency versions for PostGIS and PostgreSQL
PROJ_VERSION=8.2.1
GEOS_VERSION=3.8.3
GDAL_VERSION=3.4.3
POSTGIS_VERSION=
PGROUTING_VERSION=
LITE_OPT=false

# Parse options
while getopts "v:g:r:l" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    r) PGROUTING_VERSION=$OPTARG ;;
    l) LITE_OPT=true ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ] ; then
  echo "PostgreSQL version parameter is required!" && exit 1;
fi
if echo "$PG_VERSION" | grep -q '^9\.' && [ "$LITE_OPT" = true ] ; then
  echo "Lite option is supported only for PostgreSQL 10 or later!" && exit 1;
fi

ICU_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.' && [ "$LITE_OPT" != true ] && echo true || echo false)

# Directories
TRG_DIR=$PWD/bundle
SRC_DIR=$PWD/src
INSTALL_DIR=$PWD/pg-build
mkdir -p $TRG_DIR $SRC_DIR $INSTALL_DIR

# Install Homebrew dependencies
brew update
brew install pkg-config icu4c libxml2 libxslt openssl@3 zlib perl python3 patchelf curl cmake pcre boost gettext

# Dynamically set environment variables for Homebrew dependencies using brew --prefix
export PATH="$(brew --prefix icu4c)/bin:$(brew --prefix icu4c)/sbin:$(brew --prefix python3)/bin:$(brew --prefix pcre)/bin:$(brew --prefix gettext)/bin:$PATH"
export LDFLAGS="-L$(brew --prefix icu4c)/lib -L$(brew --prefix openssl@3)/lib -L$(brew --prefix pcre)/lib -L$(brew --prefix boost)/lib -L$(brew --prefix gettext)/lib -L$INSTALL_DIR/lib"
export CPPFLAGS="-I$(brew --prefix icu4c)/include -I$(brew --prefix openssl@3)/include -I$(brew --prefix pcre)/include -I$(brew --prefix boost)/include -I$(brew --prefix gettext)/include -I$INSTALL_DIR/include"
export PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$INSTALL_DIR/lib/pkgconfig"

# Set Python path dynamically
PYTHON_PATH="$(brew --prefix python3)/bin/python3"

# Additional ICU-specific environment variables
export ICU_CFLAGS="-I$(brew --prefix icu4c)/include"
export ICU_LIBS="-L$(brew --prefix icu4c)/lib -licuuc -licudata -licui18n"

# Helper function to configure static linking
build_with_static_linking() {
    ./configure --disable-static --prefix=$INSTALL_DIR "$@"
}

# Function to codesign a binary
sign_binary() {
    local binary_path="$1"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$binary_path"
}

# Build proj
wget -O proj.tar.gz "https://download.osgeo.org/proj/proj-$PROJ_VERSION.tar.gz"
mkdir -p $SRC_DIR/proj
tar -xf proj.tar.gz -C $SRC_DIR/proj --strip-components 1
cd $SRC_DIR/proj
build_with_static_linking
make -j$(sysctl -n hw.ncpu)
make install

# Build GEOS (apply workaround for WKBWriter error)
wget -O geos.tar.bz2 "https://download.osgeo.org/geos/geos-$GEOS_VERSION.tar.bz2"
mkdir -p $SRC_DIR/geos
tar -xf geos.tar.bz2 -C $SRC_DIR/geos --strip-components 1
cd $SRC_DIR/geos

# Correct function name inconsistencies in WKBWriter.cpp
sed -i '' 's/WriteCoordinateSequence/writeCoordinateSequence/g' src/io/WKBWriter.cpp
sed -i '' 's/WriteCoordinate/writeCoordinate/g' src/io/WKBWriter.cpp

# Include necessary headers in WKBWriter.h
sed -i '' '1i\
#include <cstddef>
' include/geos/io/WKBWriter.h

build_with_static_linking
make -j$(sysctl -n hw.ncpu)
make install

# Build GDAL
wget -O gdal.tar.xz "https://download.osgeo.org/gdal/$GDAL_VERSION/gdal-$GDAL_VERSION.tar.xz"
mkdir -p $SRC_DIR/gdal
tar -xf gdal.tar.xz -C $SRC_DIR/gdal --strip-components 1
cd $SRC_DIR/gdal
build_with_static_linking --with-proj=$INSTALL_DIR --without-hdf5
make -j$(sysctl -n hw.ncpu)
make install

# Build PostgreSQL with local proj, geos, and gdal
wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"
mkdir -p $SRC_DIR/postgresql
tar -xf postgresql.tar.bz2 -C $SRC_DIR/postgresql --strip-components 1
cd $SRC_DIR/postgresql
./configure \
    CFLAGS="-Os" \
    PYTHON="$PYTHON_PATH" \
    --prefix=$INSTALL_DIR \
    --enable-integer-datetimes \
    --enable-thread-safety \
    --with-uuid=e2fs \
    --with-includes="$INSTALL_DIR/include" \
    --with-libraries="$INSTALL_DIR/lib" \
    $([ "$ICU_ENABLED" = true ] && echo "--with-icu") \
    --with-libxml \
    --with-libxslt \
    --with-openssl \
    --with-perl \
    --with-python \
    --with-tcl \
    --without-readline
make -j$(sysctl -n hw.ncpu) world
make install-world

# Build PostGIS with locally built proj, geos, and gdal
if [ -n "$POSTGIS_VERSION" ]; then
    wget -O postgis.tar.gz "https://download.osgeo.org/postgis/source/postgis-$POSTGIS_VERSION.tar.gz"
    mkdir -p $SRC_DIR/postgis
    tar -xf postgis.tar.gz -C $SRC_DIR/postgis --strip-components 1
    cd $SRC_DIR/postgis
    ./configure \
        --prefix=$INSTALL_DIR \
        --with-pgconfig=$INSTALL_DIR/bin/pg_config \
        --with-geosconfig=$INSTALL_DIR/bin/geos-config \
        --with-projdir=$INSTALL_DIR \
        --with-gdalconfig=$INSTALL_DIR/bin/gdal-config \
        --without-protobuf
    make -j$(sysctl -n hw.ncpu)
    make install
fi

# Build pgRouting if specified
if [ -n "$PGROUTING_VERSION" ]; then
    wget -O pgrouting.tar.gz "https://github.com/pgRouting/pgrouting/archive/v$PGROUTING_VERSION.tar.gz"
    mkdir -p $SRC_DIR/pgrouting
    tar -xf pgrouting.tar.gz -C $SRC_DIR/pgrouting --strip-components 1
    cd $SRC_DIR/pgrouting
    mkdir -p build
    cd build
    cmake -DWITH_DOC=OFF -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR ..
    make -j$(sysctl -n hw.ncpu)
    make install
fi

# Define the specific binaries to check
binaries_to_check=(
    "bin/initdb"
    "bin/pg_ctl"
    "bin/postgres"
    "bin/pg_dump"
    "bin/pg_dumpall"
    "bin/pg_restore"
    "bin/pg_isready"
    "bin/psql"
)

# Loop through each specified binary to update library paths
for binary in "${binaries_to_check[@]}"; do
    binary_path="$INSTALL_DIR/$binary"

    # Only process if the binary exists
    if [ -f "$binary_path" ]; then
        otool -L "$binary_path" | awk '{print $1}' | grep -E '/opt/homebrew|/usr/local|@executable_path|'"$INSTALL_DIR" | while read dep; do
            # Copy the dependency to the lib folder if it’s not already there
            cp -Lf "$dep" "$INSTALL_DIR/lib/" 2>/dev/null || true
            install_name_tool -change "$dep" "@loader_path/../lib/$(basename "$dep")" "$binary_path"
            
            # Create version-agnostic symlinks
            base_name=$(basename "$dep")
            symlink_name=$(echo "$base_name" | sed -E 's/([._][0-9]+)+\.dylib$/.dylib/')  # e.g., libcrypto.3.dylib -> libcrypto.dylib

            if [ "$symlink_name" != "$base_name" ]; then
                ln -sf "$base_name" "$INSTALL_DIR/lib/$symlink_name"
            fi
        done
        sign_binary "$binary_path"
    fi
done

# Copy ICU dependencies and update paths
icu_libs=("libicudata.76.dylib" "libicuuc.76.dylib" "libicui18n.76.dylib")

for icu_lib in "${icu_libs[@]}"; do
    # Copy each ICU library to the bundle's lib directory
    cp -Lf "$(brew --prefix icu4c)/lib/$icu_lib" "$INSTALL_DIR/lib/"

    # Adjust internal paths to use @loader_path
    install_name_tool -id "@loader_path/../lib/$icu_lib" "$INSTALL_DIR/lib/$icu_lib"
    otool -L "$INSTALL_DIR/lib/$icu_lib" | awk '{print $1}' | grep "@loader_path" | while read dep; do
        install_name_tool -change "$dep" "@loader_path/../lib/$(basename "$dep")" "$INSTALL_DIR/lib/$icu_lib"
    done
    sign_binary "$INSTALL_DIR/lib/$icu_lib"
done

# Update library paths within each .dylib in the lib directory
for dylib in $INSTALL_DIR/lib/*.dylib; do
    install_name_tool -id "@loader_path/../lib/$(basename "$dylib")" "$dylib"
    otool -L "$dylib" | awk '{print $1}' | grep -E '/opt/homebrew|/usr/local|@executable_path|'"$INSTALL_DIR" | while read dep; do
        # Ensure the library is copied to the lib folder if it’s not already there
        cp -Lf "$dep" "$INSTALL_DIR/lib/" 2>/dev/null || true
        install_name_tool -change "$dep" "@loader_path/../lib/$(basename "$dep")" "$dylib"
        
        # Create version-agnostic symlinks
        base_name=$(basename "$dep")
        symlink_name=$(echo "$base_name" | sed -E 's/([._][0-9]+)+\.dylib$/.dylib/')  # e.g., libcrypto.3.dylib -> libcrypto.dylib

        if [ "$symlink_name" != "$base_name" ]; then
            ln -sf "$base_name" "$INSTALL_DIR/lib/$symlink_name"
        fi
    done
done

# Loop through all .dylib and .so files in the lib folder to sign them
for lib_file in $INSTALL_DIR/lib/*.{dylib,so}; do
    # Check if the file exists (to handle cases where there may be no .dylib or .so files)
    if [ -f "$lib_file" ]; then
        echo "Signing $lib_file..."
        sign_binary "$lib_file"
    fi
done

# **Step 2: Create a Zip Archive for Notarization**
cd $INSTALL_DIR
rm -f lib/pgxs/src/test/regress/pg_regress
cp -Rf $(git rev-parse --show-toplevel)/share/postgresql/extension/* share/extension
zip -r $TRG_DIR/postgres-macos.zip \
    share \
    lib \
    bin/initdb \
    bin/pg_ctl \
    bin/postgres \
    bin/pg_dump \
    bin/pg_dumpall \
    bin/pg_restore \
    bin/pg_isready \
    bin/psql

# Function to sign, notarize, and staple
notarize_and_staple() {
    local package_path="$1"

    # Unlock the keychain
    security unlock-keychain -p "$KEYCHAIN_PASSWD" ~/Library/Keychains/login.keychain

    # Submit for notarization
    STATUS=$(xcrun notarytool submit "$package_path" \
                              --team-id "$APPLE_TEAM_ID" \
                              --apple-id "$APPLE_ID" \
                              --password "$APPLE_APP_SPECIFIC_PASSWORD" 2>&1)

    # Get the submission ID
    SUBMISSION_ID=$(echo "$STATUS" | awk -F ': ' '/id:/ { print $2; exit; }')
    echo "Notarization submission ID: $SUBMISSION_ID"

    # Wait for notarization to complete
    xcrun notarytool wait "$SUBMISSION_ID" \
                          --team-id "$APPLE_TEAM_ID" \
                          --apple-id "$APPLE_ID" \
                          --password "$APPLE_APP_SPECIFIC_PASSWORD"

    # Check the notarization status
    REQUEST_STATUS=$(xcrun notarytool info "$SUBMISSION_ID" \
                     --team-id "$APPLE_TEAM_ID" \
                     --apple-id "$APPLE_ID" \
                     --password "$APPLE_APP_SPECIFIC_PASSWORD" 2>&1 | \
                     awk -F ': ' '/status:/ { print $2; }')

    if [[ "$REQUEST_STATUS" != "Accepted" ]]; then
        echo "Notarization failed."
        exit 1
    fi
}

# **Step 3: Notarize the Zip Archive**
notarize_and_staple "$TRG_DIR/postgres-macos.zip"

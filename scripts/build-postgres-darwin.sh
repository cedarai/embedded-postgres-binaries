#!/bin/bash
set -ex

# Dependency versions for PostGIS and PostgreSQL
PROJ_VERSION=8.2.1
GEOS_VERSION=3.8.3
GDAL_VERSION=3.4.3
POSTGIS_VERSION=
PGVECTOR_VERSION=
PGROUTING_VERSION=
LITE_OPT=false

# Parse options
while getopts "v:g:r:s:l" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    g) POSTGIS_VERSION=$OPTARG ;;
    r) PGROUTING_VERSION=$OPTARG ;;
    s) PGVECTOR_VERSION=$OPTARG ;;
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

export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion)"

ICU_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.' && [ "$LITE_OPT" != true ] && echo true || echo false)

# Directories
TRG_DIR=$PWD/bundle
SRC_DIR=$PWD/src
INSTALL_DIR=$PWD/pg-build
mkdir -p $TRG_DIR $SRC_DIR $INSTALL_DIR

# Install Homebrew dependencies
brew update
brew install python3 || true
brew install pkg-config icu4c libxml2 libxslt json-c openssl@3 zlib perl patchelf curl cmake pcre boost gettext

# Dynamically set environment variables for Homebrew dependencies using brew --prefix
export PATH="$(brew --prefix cmake)/bin:$(brew --prefix icu4c)/bin:$(brew --prefix icu4c)/sbin:$(brew --prefix python3)/bin:$(brew --prefix pcre)/bin:$(brew --prefix gettext)/bin:$PATH"
export LDFLAGS="-L$(brew --prefix icu4c)/lib -L$(brew --prefix openssl@3)/lib -L$(brew --prefix pcre)/lib -L$(brew --prefix boost)/lib -L$(brew --prefix gettext)/lib -L$(brew --prefix libpng)/lib -L$INSTALL_DIR/lib"
export CPPFLAGS="-I$(brew --prefix icu4c)/include -I$(brew --prefix openssl@3)/include -I$(brew --prefix pcre)/include -I$(brew --prefix boost)/include -I$(brew --prefix gettext)/include -I$(brew --prefix libpng)/include -I$INSTALL_DIR/include"
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
        --with-jsondir="$(brew --prefix json-c)" \
        --without-protobuf
    make -j$(sysctl -n hw.ncpu)
    make install
fi

# Build pgvector (v$PGVECTOR_VERSION) if requested
if [ -n "$PGVECTOR_VERSION" ]; then
    echo "Building pgvector v$PGVECTOR_VERSION"
    wget -O pgvector.tar.gz "https://github.com/pgvector/pgvector/archive/refs/tags/v$PGVECTOR_VERSION.tar.gz"
    mkdir -p $SRC_DIR/pgvector
    tar -xf pgvector.tar.gz -C $SRC_DIR/pgvector --strip-components 1
    cd $SRC_DIR/pgvector
    make USE_PGXS=1 PG_CONFIG=$INSTALL_DIR/bin/pg_config
    make USE_PGXS=1 PG_CONFIG=$INSTALL_DIR/bin/pg_config install
fi

# Build pgRouting if specified
if [ -n "$PGROUTING_VERSION" ]; then
    wget -O pgrouting.tar.gz "https://github.com/pgRouting/pgrouting/archive/v$PGROUTING_VERSION.tar.gz"
    mkdir -p $SRC_DIR/pgrouting
    tar -xf pgrouting.tar.gz -C $SRC_DIR/pgrouting --strip-components 1
    cd $SRC_DIR/pgrouting
    mkdir -p build
    cd build
    cmake -DWITH_DOC=OFF -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
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

# Copy ICU dylibs from Homebrew (any versioned variants) into the bundle lib dir
icu_dir="$(brew --prefix icu4c)/lib"
mkdir -p "$INSTALL_DIR/lib"
for base in libicudata libicuuc libicui18n; do
    for f in "${icu_dir}/${base}".*.dylib; do
        [ -e "$f" ] || continue
        cp -Lf "$f" "$INSTALL_DIR/lib/"
        install_name_tool -id "@loader_path/../lib/$(basename "$f")" "$INSTALL_DIR/lib/$(basename "$f")" || true
        sign_binary "$INSTALL_DIR/lib/$(basename "$f")"
    done
done

# Function to recursively copy dependencies and update paths
process_dependencies() {
    local file_path="$1"

    # Update the ID of the library to use @loader_path
    install_name_tool -id "@loader_path/../lib/$(basename "$file_path")" "$file_path"

    # Get the dependencies using otool
    otool -L "$file_path" | awk '{print $1}' | grep -E '/opt/homebrew|/usr/local|@executable_path|'"$INSTALL_DIR" | while read dep; do
        # If the dependency is not already in the lib directory, copy it
        if [ ! -f "$INSTALL_DIR/lib/$(basename "$dep")" ]; then
            cp -Lf "$dep" "$INSTALL_DIR/lib/" 2>/dev/null || true

            # Recursively process the newly copied dependency
            if [ -f "$INSTALL_DIR/lib/$(basename "$dep")" ]; then
                process_dependencies "$INSTALL_DIR/lib/$(basename "$dep")"
            fi
        fi

        # Update the path to use @loader_path
        install_name_tool -change "$dep" "@loader_path/../lib/$(basename "$dep")" "$file_path"

        # Create version-agnostic symlinks if necessary
        base_name=$(basename "$dep")
        symlink_name=$(echo "$base_name" | sed -E 's/([._][0-9]+)+\.dylib$/.dylib/')  # e.g., libcrypto.3.dylib -> libcrypto.dylib

        if [ "$symlink_name" != "$base_name" ]; then
            ln -sf "$base_name" "$INSTALL_DIR/lib/$symlink_name"
        fi
    done
}

# Process all .so and .dylib files in the lib directory
for lib_file in $INSTALL_DIR/lib/*.{so,dylib}; do
    if [ -f "$lib_file" ]; then
        process_dependencies "$lib_file"
    fi
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
rm -rf lib/pgxs/src/test/
rm -rf lib/Python
PG_ROUTING_SO=$(ls lib/libpgrouting-* | sed -e 's|.*/||' -e 's/\.so$//')
ln -s $PG_ROUTING_SO.so lib/$PG_ROUTING_SO.dylib
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

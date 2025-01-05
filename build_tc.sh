#!/usr/bin/env bash

if [[ -z $GITHUB_TOKEN ]]; then
    echo "[ERROR] Missing GitHub Token!"
    exit 1
fi

WORKDIR=$(pwd)
LLVM_VERSION=19.1.6
ZSTD_VERSION=v1.5.6
INSTALL_FOLDER=$WORKDIR/install
BUILD_DATE=$(date +%Y%m%d)
BUILD_TAG=$(date +%Y%m%d-%H%M)
NPROC=$(nproc --all)
CUSTOM_FLAGS="LLVM_PARALLEL_TABLEGEN_JOBS=${NPROC} LLVM_PARALLEL_COMPILE_JOBS=${NPROC} LLVM_PARALLEL_LINK_JOBS=${NPROC} LLVM_OPTIMIZED_TABLEGEN=ON CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' CMAKE_EXE_LINKER_FLAGS='-g0 -O3' CMAKE_MODULE_LINKER_FLAGS='-g0 -O3' CMAKE_SHARED_LINKER_FLAGS='-g0 -O3' CMAKE_STATIC_LINKER_FLAGS='-g0 -O3'"

if [[ $1 == "final" ]]; then
    FINAL=true
    ADD="--final"
else
    FINAL=false
fi

# Build ZSTD
git clone --depth=1 https://github.com/facebook/zstd -b $ZSTD_VERSION $WORKDIR/zstd
cd $WORKDIR/zstd
cmake build/cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_FOLDER/.zstd"
make -j${NPROC}
make install -j${NPROC}
cd $WORKDIR

# Build LLVM
$WORKDIR/build-llvm.py $ADD \
    --build-type "Release" \
    --build-stage1-only \
    --defines "$CUSTOM_FLAGS" \
    --install-folder "$INSTALL_FOLDER" \
    --lto thin \
    --pgo llvm \
    --projects clang lld polly \
    --quiet-cmake \
    --ref "llvmorg-$LLVM_VERSION" \
    --shallow-clone \
    --targets AArch64 ARM X86 \
    --no-update \
    --vendor-string "gacorprjkt"

# Check LLVM files
if [[ -f "$INSTALL_FOLDER/bin/clang" ]] || [[ -f "$WORKDIR/build/llvm/instrumented/profdata.prof" ]]; then
    :
else
    echo "[ERROR] Build LLVM Failed"
    exit 1
fi

if $FINAL; then
    # Build Binutils
    $WORKDIR/build-binutils.py \
        --targets aarch64 arm x86_64 \
        --install-folder "$INSTALL_FOLDER"

    # Strip binaries
    OBJCOPY=$INSTALL_FOLDER/bin/llvm-objcopy
    find "$INSTALL_FOLDER" -type f -exec file {} \; >.file-idx
    grep "not strip" .file-idx | tr ':' ' ' | awk '{print $1}' | while read -r file; do
        $OBJCOPY --strip-all-gnu "$file"
    done
    rm -rf strip .file-idx

    ## Release
    CLANG_VERSION="$($INSTALL_FOLDER/bin/clang --version | head -n1 | cut -d ' ' -f4)"
    BINUTILS_VERSION=$($INSTALL_FOLDER/bin/aarch64-linux-gnu-ld --version | head -n1 | grep -o '[0-9].*')
    ZSTD_VERSION=$(echo "$ZSTD_VERSION" | tr -d 'v')
    GLIBC_VERSION=$(ldd --version | head -n1 | grep -oE '[^ ]+$')
    MESSAGE="clang ${CLANG_VERSION}-${BUILD_DATE}"
    
    # Compress
    cd $INSTALL_FOLDER
    tar -I"$INSTALL_FOLDER/.zstd/bin/zstd --ultra -22 -T0" -cf clang.tar.zst *
    ARCHIVE_SIZE=$(du -m clang.tar.zst | cut -f1)
    cd $WORKDIR
    
    # Set README
    git config --global user.name gacorprjkt-bot
    git config --global user.email gacorprjkt-bot@pornhub.com
    git clone https://Asteroidd21:${GITHUB_TOKEN}@github.com/Asteroidd21/gacorprjkt-clang $WORKDIR/clang-rel
    cd $WORKDIR/clang-rel
    cat dummy |
        sed "s/LLVM_VERSION/${CLANG_VERSION} (${BUILD_DATE})/g" |
        sed "s/ARCHIVE_SIZE/${ARCHIVE_SIZE}MB/g" |
        sed "s/ZSTD_VERSION/${ZSTD_VERSION}/g" |
        sed "s/BINUTILS_VERSION/${BINUTILS_VERSION}/g" |
        sed "s/GLIBC_VERSION/${GLIBC_VERSION}/g" >README.md
    git add .
    git commit -m "${MESSAGE}"
    git push origin main || exit 1
    
    # Upload Archive
    mv $INSTALL_FOLDER/clang.tar.zst .
    hub release create -a clang.tar.zst -m "${MESSAGE}" ${BUILD_TAG}
    cd $WORKDIR
fi

#!/usr/bin/env bash

if [[ -z $TELEGRAM_TOKEN ]]; then
    echo "Please add TELEGRAM_TOKEN secret!"
    exit 1
fi

if [[ -z $GITHUB_TOKEN ]]; then
    echo "Please add GITHUB_TOKEN secret!"
    exit 1
fi

export WORKDIR=$(pwd)
export VENDOR_STRING=gacorprjkt
export TAG=llvmorg-19.1.6
export INSTALL_FOLDER=$WORKDIR/install
export CHAT_ID=-1002254721074
export BUILD_DATE=$(date +%Y%m%d)
export BUILD_TAG=$(date +%Y%m%d-%H%M-%Z)
export NPROC=$(($(nproc --all) * 2))
export FLAGS="
  LLVM_PARALLEL_TABLEGEN_JOBS=${NPROC}
  LLVM_PARALLEL_COMPILE_JOBS=${NPROC}
  LLVM_PARALLEL_LINK_JOBS=${NPROC}
  LLVM_OPTIMIZED_TABLEGEN=ON
  CMAKE_C_FLAGS='-O3 -pipe -ffunction-sections -fdata-sections -fno-plt -fmerge-all-constants -fomit-frame-pointer -funroll-loops -falign-functions=64 -march=skylake -mtune=skylake -mllvm -polly -mllvm -polly-position=early -mllvm -polly-vectorizer=stripmine -mllvm -polly-run-dce'
  CMAKE_CXX_FLAGS='-O3 -pipe -ffunction-sections -fdata-sections -fno-plt -fmerge-all-constants -fomit-frame-pointer -funroll-loops -falign-functions=64 -march=skylake -mtune=skylake -mllvm -polly -mllvm -polly-position=early -mllvm -polly-vectorizer=stripmine -mllvm -polly-run-dce'
  CMAKE_EXE_LINKER_FLAGS='-O3 --lto-O3 --lto-CGO3 --gc-sections --strip-debug'
  CMAKE_MODULE_LINKER_FLAGS='-O3 --lto-O3 --lto-CGO3 --gc-sections --strip-debug'
  CMAKE_SHARED_LINKER_FLAGS='-O3 --lto-O3 --lto-CGO3 --gc-sections --strip-debug'
  CMAKE_STATIC_LINKER_FLAGS='-O3 --lto-O3 --lto-CGO3 --gc-sections --strip-debug'
  "

if [[ $1 == "final" ]]; then
    export FINAL=true
else
    export FINAL=false
fi

if $FINAL; then
    STATUS="FINAL"
    ADD="--final"
else
    STATUS="PROF"
fi

send_info() {
    curl -s -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage \
        -d chat_id="${CHAT_ID}" \
        -d "parse_mode=html" \
        -d text="<b>[$STATUS] </b><code>${1}</code>" \
        -o /dev/null
}

send_file() {
    curl -s -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument \
        -F document=@"${2}" \
        -F chat_id="${CHAT_ID}" \
        -F "parse_mode=html" \
        -F caption="${1}" \
        -o /dev/null
}

# Build ZSTD
ZSTD_VERSION=v1.5.6
git clone --depth=1 https://github.com/facebook/zstd -b $ZSTD_VERSION $WORKDIR/zstd
cd $WORKDIR/zstd
(
cmake build/cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_FOLDER/.zstd"
make -j${NPROC}
make install -j${NPROC}
) |& tee -a $WORKDIR/build.log
cd $WORKDIR

# Build LLVM
send_info "Building $VENDOR_STRING clang..."

$WORKDIR/build-llvm.py ${ADD} \
    --ref "$TAG" \
    --build-type "Release" \
    --build-stage1-only \
    --defines "$FLAGS" \
    --install-folder "$INSTALL_FOLDER" \
    --lto thin \
    --pgo llvm \
    --projects clang lld polly \
    --shallow-clone \
    --targets AArch64 X86 \
    --no-update \
    --vendor-string "$VENDOR_STRING" |& tee -a $WORKDIR/build.log

# Check LLVM files
if [[ -f "$INSTALL_FOLDER/bin/clang" ]] || [[ -f "$WORKDIR/build/llvm/instrumented/profdata.prof" ]]; then
    send_info "Build finished."
else
    send_info "Build failed."
    send_file "Build log" $WORKDIR/build.log
    exit 1
fi

if $FINAL; then
    # Strip binaries
    OBJCOPY=$INSTALL_FOLDER/bin/llvm-objcopy
    find "$INSTALL_FOLDER" -type f -exec file {} \; >.file-idx
    grep "not strip" .file-idx | tr ':' ' ' | awk '{print $1}' | while read -r file; do
        $OBJCOPY --strip-all-gnu "$file"
    done
    rm -rf strip .file-idx

    # Release
    send_info "Releasing into GitHub..."
    CLANG_VERSION="$($INSTALL_FOLDER/bin/clang --version | head -n1 | cut -d ' ' -f4)"
    MESSAGE="clang ${CLANG_VERSION}-${BUILD_DATE}"
    cd $INSTALL_FOLDER
    tar -I"$INSTALL_FOLDER/.zstd/bin/zstd --ultra -22 -T0" -cf clang.tar.zst *
    cd $WORKDIR
    git config --global user.name gacorprjkt-bot
    git config --global user.email gacorprjkt-bot@pornhub.com
    git clone https://linastorvalds:${GITHUB_TOKEN}@github.com/linastorvalds/gacorprjkt-clang $WORKDIR/clang-rel
    cd $WORKDIR/clang-rel
    cat dummy |
        sed "s/LLVM_VERSION/${CLANG_VERSION}-${BUILD_DATE}/g" |
        sed "s/SIZE_MB/$(du -m $INSTALL_FOLDER/clang.tar.zst | cut -f1)/g" |
        sed "s/ZSTD_VERSION/${ZSTD_VERSION}/g" >README.md
    git commit --allow-empty -as -m "${MESSAGE}"
    git push origin main || exit 1
    mv $INSTALL_FOLDER/clang.tar.zst .
    hub release create -a clang.tar.zst -m "${MESSAGE}" ${BUILD_TAG}
    send_info "Toolchain released."
    cd $WORKDIR
fi

#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eu

case "$(uname -m)" in
    "aarch64")
        binutils_target=aarch64
        llvm_targets=(AArch64 ARM) # for 32-bit vDSO
        kernel_target=AArch64
        ;;
    "x86_64")
        binutils_target=x86_64
        llvm_targets=(X86)
        kernel_target=${llvm_targets[0]}
        ;;
esac

echo "[+] Checking if mirror is available"
git_mirror_args=()
if ping -c1 -w3 10.0.1.8 >/dev/null 2>&1; then
    echo "[+] Mirror is available"
    git_mirror_args+=(
        -c url.http://10.0.1.8:50000/git/.insteadOf=https://git.kernel.org/
        -c url.http://10.0.1.8:50000/git/.insteadOf=https://github.com/
    )
else
    echo "[-] Mirror is unavailable"
fi

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | rust) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_rust
    do_binutils
    do_kernel
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets "$binutils_target"
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    # Refresh mirrorlist to avoid dead mirrors
    apt-get update -y

    apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        pkg-config \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" "${git_mirror_args[@]}" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            "${git_mirror_args[@]}" \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['$kernel_target']}
builder.toolchain_prefix = Path('$install')
builder.silent = False

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    local branch=release/23.x
    local llvm=$src/llvm-project
    if [[ -d $llvm ]]; then
        git -C "$llvm" "${git_mirror_args[@]}" fetch --depth=1 origin $branch
        git -C "$llvm" reset --hard FETCH_HEAD
    else
        git clone \
            "${git_mirror_args[@]}" \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://github.com/llvm/llvm-project.git \
            "$llvm"
    fi

    "$base"/build-llvm.py \
        --assertions \
        --build-stage1-only \
        --build-target distribution \
        --check-targets clang lld llvm \
        --distribution-profile rust \
        --install-folder "$install" \
        --install-target distribution \
        --llvm-folder "$llvm" \
        --multicall \
        --projects clang lld \
        --quiet-cmake \
        --show-build-commands \
        --targets "${llvm_targets[@]}" \
        "${extra_args[@]}"
}

function do_rust() {
    "$base"/build-rust.py \
        --debug \
        --llvm-install-folder "$install" \
        --install-folder "$install" \
        --show-build-commands
}

parse_parameters "$@"
do_"${action:=all}"

#!/usr/bin/env bash
#
# build_kernel.sh - build oppo mt6771 kernel, always asks which defconfig to use
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths / toolchain (matches build.config.aarch64)
# ---------------------------------------------------------------------------
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${KERNEL_DIR}/out"
CONFIGS_DIR="${KERNEL_DIR}/arch/arm64/configs"

CLANG_BIN="${KERNEL_DIR}/toolchain/clang/host/linux-x86/clang-r383902/bin"
GCC_BIN="${KERNEL_DIR}/toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"

export ARCH=arm64
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-androidkernel-

JOBS="$(nproc)"

# ---------------------------------------------------------------------------
# clang resolves the external assembler/linker by looking for a binary named
# "<CLANG_TRIPLE>as" ("aarch64-linux-gnu-as") on PATH. This toolchain only
# ships "aarch64-linux-android-*" / "aarch64-linux-androidkernel-*" binaries,
# so that lookup misses and clang silently falls back to the HOST /usr/bin/as
# (which doesn't understand arm64 flags like -EL -> "unrecognized option").
#
# Fix: generate a shim dir of symlinks under the CLANG_TRIPLE name pointing
# at the real cross binutils, and put it first on PATH.
# ---------------------------------------------------------------------------
SHIM_DIR="${KERNEL_DIR}/.toolchain-shim"
rm -rf "${SHIM_DIR}"
mkdir -p "${SHIM_DIR}"

for tool in as ld ld.bfd ld.gold ar nm objcopy objdump ranlib strip size readelf elfedit; do
    src=""
    if [[ -x "${GCC_BIN}/aarch64-linux-androidkernel-${tool}" ]]; then
        src="${GCC_BIN}/aarch64-linux-androidkernel-${tool}"
    elif [[ -x "${GCC_BIN}/aarch64-linux-android-${tool}" ]]; then
        src="${GCC_BIN}/aarch64-linux-android-${tool}"
    fi
    if [[ -n "${src}" ]]; then
        ln -sf "${src}" "${SHIM_DIR}/${CLANG_TRIPLE}${tool}"
    fi
done

export PATH="${SHIM_DIR}:${CLANG_BIN}:${GCC_BIN}:${PATH}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -d "${CONFIGS_DIR}" ]]; then
    echo "Error: defconfig directory not found: ${CONFIGS_DIR}" >&2
    exit 1
fi

if [[ ! -x "${CLANG_BIN}/clang" ]]; then
    echo "Error: clang not found at ${CLANG_BIN}/clang" >&2
    exit 1
fi

if [[ ! -x "${SHIM_DIR}/${CLANG_TRIPLE}as" ]]; then
    echo "Error: could not build assembler shim (${CLANG_TRIPLE}as) - check GCC_BIN path" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Always ask which defconfig to build
# ---------------------------------------------------------------------------
mapfile -t DEFCONFIGS < <(cd "${CONFIGS_DIR}" && ls -1 *_defconfig 2>/dev/null | sort)

if [[ ${#DEFCONFIGS[@]} -eq 0 ]]; then
    echo "Error: no *_defconfig files found in ${CONFIGS_DIR}" >&2
    exit 1
fi

echo "Available defconfigs:"
select DEFCONFIG in "${DEFCONFIGS[@]}"; do
    if [[ -n "${DEFCONFIG:-}" ]]; then
        break
    else
        echo "Invalid choice, try again."
    fi
done

echo
echo "==> Building with: ${DEFCONFIG}"
echo "==> Output dir:    ${OUT_DIR}"
echo "==> Jobs:           ${JOBS}"
echo

# ---------------------------------------------------------------------------
# Clean previous out dir for a fresh config (comment out if you want incremental builds)
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"

MAKE_ARGS=(
    -C "${KERNEL_DIR}"
    O="${OUT_DIR}"
    ARCH="${ARCH}"
    CROSS_COMPILE="${CROSS_COMPILE}"
    CLANG_TRIPLE="${CLANG_TRIPLE}"
    CC=clang
    -j"${JOBS}"
)

echo "==> make ${DEFCONFIG}"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

echo "==> make (build)"
make "${MAKE_ARGS[@]}"

# ---------------------------------------------------------------------------
# Report expected output files (from build.config.aarch64 FILES list)
# ---------------------------------------------------------------------------
echo
echo "==> Build finished. Checking expected output files:"
for f in "arch/arm64/boot/Image.gz" "vmlinux" "System.map"; do
    if [[ -f "${OUT_DIR}/${f}" ]]; then
        echo "  [OK] ${OUT_DIR}/${f}"
    else
        echo "  [MISSING] ${OUT_DIR}/${f}"
    fi
done

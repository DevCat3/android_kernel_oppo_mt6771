#!/bin/bash

echo "========================================="
echo "Complete Kernel and Modules Build Script"
echo "========================================="

# ============================================
# CONFIGURATION — Edit paths here
# ============================================

# Root of your kernel-dev workspace
KERNEL_DEV_ROOT="/home/devcat3/Desktop/oppo/"

# Kernel source directory (relative to KERNEL_DEV_ROOT)
KERNEL_SOURCE_DIR="android_kernel_oppo_mt6771"

# Full path to kernel source (derived)
KERNEL_DIR="${KERNEL_DEV_ROOT}/${KERNEL_SOURCE_DIR}"

# Toolchain paths (relative to KERNEL_DIR)
GCC_AARCH64_REL="toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-"
GCC_ARM32_REL="toolchain/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-"
CLANG_REL="toolchain/clang/host/linux-x86/clang-r383902/bin"

# Vendor modules root
VENDOR_MODULES="${KERNEL_DEV_ROOT}/vendor/mediatek/kernel_modules"

# Where collected .ko files go (flat directory)
MODULES_COLLECTION="${KERNEL_DEV_ROOT}/modules_collection"

# Defconfig name
DEFCONFIG="oppo6771_defconfig"

# Parallel build jobs
BUILD_JOBS=4

# Target architecture
BUILD_ARCH="arm64"

# Clang triple
CLANG_TRIPLE="aarch64-linux-gnu-"

# ============================================
# DERIVED PATHS — Do not edit below this line
# ============================================
KERNEL_OUT="${KERNEL_DIR}/out"
AUTOCONF_H="${KERNEL_OUT}/include/generated/autoconf.h"
CROSS_COMPILE="${KERNEL_DIR}/${GCC_AARCH64_REL}"
CROSS_COMPILE_ARM32="${KERNEL_DIR}/${GCC_ARM32_REL}"
CLANG_TOOL_PATH="${KERNEL_DIR}/${CLANG_REL}"

# Connectivity module shortcuts (derived from VENDOR_MODULES)
CONN_DIR="${VENDOR_MODULES}/connectivity"
CONN_COMMON="${CONN_DIR}/common"
CONN_WLAN_ADAPTOR="${CONN_DIR}/wlan/adaptor"
CONN_WLAN_GEN3="${CONN_DIR}/wlan/core/gen3"
CONN_WLAN_GEN2="${CONN_DIR}/wlan/core/gen2"
CONN_WLAN_GEN4_7668="${CONN_DIR}/wlan/core/gen4-mt7668"
CONN_WLAN_GEN4_7663="${CONN_DIR}/wlan/core/gen4-mt7663"
CONN_WLAN_GEN4M="${CONN_DIR}/wlan/core/gen4m"
CONN_BT="${CONN_DIR}/bt/mt66xx/legacy"
CONN_FM="${CONN_DIR}/fmradio"
CONN_GPS="${CONN_DIR}/gps"

# ============================================
# PART 1: SET ENVIRONMENT VARIABLES
# ============================================
echo ""
echo "Step 1: Setting up environment..."

cd "${KERNEL_DIR}" || exit 1

export CROSS_COMPILE="${CROSS_COMPILE}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
export ARCH="${BUILD_ARCH}"
export CLANG_TOOL_PATH="${CLANG_TOOL_PATH}"
export PATH="${CLANG_TOOL_PATH}:${PATH//"${CLANG_TOOL_PATH}:"}"

mkdir -p "${MODULES_COLLECTION}"

# ============================================
# PART 2: BUILD THE KERNEL
# ============================================
echo ""
echo "Step 2: Building kernel..."
echo "========================================="

make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" \
  CC=clang \
  LD=ld.lld \
  AS=aarch64-linux-android-as \
  ARCH="${BUILD_ARCH}" \
  CLANG_TRIPLE="${CLANG_TRIPLE}" \
  "${DEFCONFIG}"

make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" \
  CC=clang \
  LD=ld.lld \
  AS=aarch64-linux-android-as \
  ARCH="${BUILD_ARCH}" \
  CLANG_TRIPLE="${CLANG_TRIPLE}" \
  KCFLAGS="-Wno-strict-prototypes" \
  -j"${BUILD_JOBS}"

# Copy kernel images
cp "${KERNEL_OUT}/arch/${BUILD_ARCH}/boot/Image"        "${KERNEL_DIR}/arch/${BUILD_ARCH}/boot/Image"
cp "${KERNEL_OUT}/arch/${BUILD_ARCH}/boot/Image.gz"     "${KERNEL_DIR}/arch/${BUILD_ARCH}/boot/Image.gz"
cp "${KERNEL_OUT}/arch/${BUILD_ARCH}/boot/Image.gz-dtb" "${KERNEL_DIR}/arch/${BUILD_ARCH}/boot/Image.gz-dtb"

echo "✓ Kernel built successfully!"

# ============================================
# PART 3: BUILD ALL VENDOR MODULES
# ============================================
echo ""
echo "Step 3: Building vendor modules..."
echo "========================================="

# --------------------------------------------
# Helper: merge_symvers <src_dir> <dst_dir>
#   Appends all new symbols from src_dir/Module.symvers
#   into dst_dir/Module.symvers, avoiding duplicates.
# --------------------------------------------
merge_symvers() {
    local src_dir=$1
    local dst_dir=$2
    local src="${src_dir}/Module.symvers"
    local dst="${dst_dir}/Module.symvers"

    if [ ! -f "$src" ]; then
        echo "  ⚠ No Module.symvers found in $src_dir — skipping merge"
        return 1
    fi

    touch "$dst"

    local added=0
    while IFS= read -r line; do
        if ! grep -qF "$line" "$dst"; then
            echo "$line" >> "$dst"
            added=$((added + 1))
        fi
    done < "$src"

    echo "  ✓ Merged Module.symvers: $src → $dst ($added new symbols)"
}

# --------------------------------------------
# Helper: build_module <dir> <name>
# --------------------------------------------
build_module() {
    local dir=$1
    local name=$2

    if [ -d "$dir" ] && [ -f "$dir/Makefile" ]; then
        echo ""
        echo "Building: $name"
        cd "$dir"

        make -C "${KERNEL_OUT}" M="$(pwd)" modules \
            AUTOCONF_H="${AUTOCONF_H}" \
            CC=clang \
            LD=ld.lld \
            ARCH="${BUILD_ARCH}" \
            CLANG_TRIPLE="${CLANG_TRIPLE}" \
            CROSS_COMPILE="${CROSS_COMPILE}" \
            CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"

        if [ $? -eq 0 ]; then
            echo "✓ $name built successfully"
            cd "${KERNEL_DIR}"
            return 0
        else
            echo "✗ $name failed to build"
            cd "${KERNEL_DIR}"
            return 1
        fi
    else
        echo "⚠ Directory not found or missing Makefile: $dir"
        return 1
    fi
}

# ============================================
# Build order with symvers merging
#
# Dependency tree:
#   kernel (Module.symvers in KERNEL_OUT)
#     └── common
#           └── wlan/adaptor  (exports register_set_p2p_mode_handler)
#                 └── wlan/core/gen3
#           └── bt/mt66xx/legacy
#           └── fmradio
#           └── gps
# ============================================

# --- 1. Common ---
build_module "${CONN_COMMON}" "Common Modules"

# --- 2. WLAN Adaptor ---
merge_symvers "${CONN_COMMON}" "${CONN_WLAN_ADAPTOR}"
build_module  "${CONN_WLAN_ADAPTOR}" "WLAN Adaptor"

# --- 3. Wi-Fi Gen3 ---
merge_symvers "${CONN_COMMON}"       "${CONN_WLAN_GEN3}"
merge_symvers "${CONN_WLAN_ADAPTOR}" "${CONN_WLAN_GEN3}"
build_module  "${CONN_WLAN_GEN3}" "Wi-Fi Gen3"

# Uncomment below if you ever re-enable gen2/gen4 variants:
#merge_symvers "${CONN_COMMON}"       "${CONN_WLAN_GEN2}"
#merge_symvers "${CONN_WLAN_ADAPTOR}" "${CONN_WLAN_GEN2}"
#build_module  "${CONN_WLAN_GEN2}" "Wi-Fi Gen2"

#merge_symvers "${CONN_COMMON}"       "${CONN_WLAN_GEN4_7668}"
#merge_symvers "${CONN_WLAN_ADAPTOR}" "${CONN_WLAN_GEN4_7668}"
#build_module  "${CONN_WLAN_GEN4_7668}" "Wi-Fi Gen4 MT7668"

#merge_symvers "${CONN_COMMON}"       "${CONN_WLAN_GEN4_7663}"
#merge_symvers "${CONN_WLAN_ADAPTOR}" "${CONN_WLAN_GEN4_7663}"
#build_module  "${CONN_WLAN_GEN4_7663}" "Wi-Fi Gen4 MT7663"

#merge_symvers "${CONN_COMMON}"       "${CONN_WLAN_GEN4M}"
#merge_symvers "${CONN_WLAN_ADAPTOR}" "${CONN_WLAN_GEN4M}"
#build_module  "${CONN_WLAN_GEN4M}" "Wi-Fi Gen4m"

# --- 4. Bluetooth ---
merge_symvers "${CONN_COMMON}" "${CONN_BT}"
build_module  "${CONN_BT}" "Bluetooth"

# --- 5. FM Radio ---
merge_symvers "${CONN_COMMON}" "${CONN_FM}"
build_module  "${CONN_FM}" "FM Radio"

# --- 6. GPS ---
merge_symvers "${CONN_COMMON}" "${CONN_GPS}"
build_module  "${CONN_GPS}" "GPS"

# --- 7. Remaining standalone modules ---
build_module "${VENDOR_MODULES}/met_drv/4.14" "met_drv"
build_module "${VENDOR_MODULES}/met_drv_v2"   "met_drv_v2"
build_module "${VENDOR_MODULES}/udc"           "udc"


# ============================================
# PART 4: COLLECT ALL MODULES
# ============================================
echo ""
echo "Step 4: Collecting all modules..."
echo "========================================="

echo "Collecting all vendor modules..."
find "${VENDOR_MODULES}" -name "*.ko" -type f 2>/dev/null | while read module; do
    cp -v "$module" "${MODULES_COLLECTION}/" 2>/dev/null
done

echo "Collecting kernel out modules..."
find "${KERNEL_OUT}" -name "*.ko" -type f ! -path "*/modules_install/*" 2>/dev/null | while read module; do
    cp -v "$module" "${MODULES_COLLECTION}/" 2>/dev/null
done

# ============================================
# PART 5: CREATE MODULE INFO FILE
# ============================================
echo ""
echo "Step 5: Creating module information file..."
echo "========================================="

INFO_FILE="${MODULES_COLLECTION}/modules_info.txt"
cat > "${INFO_FILE}" << EOF
========================================
Kernel and Modules Build Information
========================================
Build Date: $(date)
Kernel Source: ${KERNEL_DIR}
Kernel Version: $(make -C "${KERNEL_OUT}" kernelrelease 2>/dev/null)
Build Architecture: ${BUILD_ARCH}

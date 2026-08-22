#!/bin/bash
# ─────────────────────────────────────────────────────────────
# build-blutter-cli.sh —— 构建原版 CLI 形态的 blutter 引擎(arm64)
# 含全部实战修复:递归找 .a / set-e 守卫 / HINTS+_DIR 跳过包搜索 /
# atomic_ref 强制包含(库+可执行)/ capstone 头文件扁平化 / Darwin 限定 -dead_strip
# ─────────────────────────────────────────────────────────────
set -euo pipefail

DART_VERSION=""
BLUTTER_COMMIT="528acbe83ba35a3a53fb97b231cb5f968c7068d1"
NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/output"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT=""
JOBS=$(nproc 2>/dev/null || echo 4)
BLUTTER_REPO="https://github.com/worawit/blutter.git"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dart-version)    DART_VERSION="$2"; shift 2 ;;
        --ndk-path)        NDK_PATH="$2"; shift 2 ;;
        --blutter-commit)  BLUTTER_COMMIT="$2"; shift 2 ;;
        --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
        --build-root)      BUILD_ROOT="$2"; shift 2 ;;
        --jobs)            JOBS="$2"; shift 2 ;;
        *) echo "ERROR: Unknown $1"; exit 1 ;;
    esac
done

[ -n "$DART_VERSION" ] || { echo "ERROR: --dart-version required"; exit 1; }
[ -d "$NDK_PATH" ]     || { echo "ERROR: NDK not found at $NDK_PATH"; exit 1; }
[ -z "$BUILD_ROOT" ] && BUILD_ROOT="$(mktemp -d -t blutter-cli-XXXXXX)"
mkdir -p "$BUILD_ROOT"

TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake"
[ -f "$TOOLCHAIN_FILE" ] || { echo "ERROR: NDK toolchain not found"; exit 1; }

BLUTTER_DIR="$BUILD_ROOT/blutter"
CAPSTONE_BUILD_DIR="$BUILD_ROOT/capstone_build"
EXE_BUILD_DIR="$BUILD_ROOT/exe_build"
ARCH_TAG="android_arm64"
DARTLIB="dartvm${DART_VERSION}_${ARCH_TAG}"

echo "════════════════════════════════════════════"
echo " blutter-cli Build: Dart $DART_VERSION @ blutter ${BLUTTER_COMMIT:0:8}"
echo "════════════════════════════════════════════"

# ═════ Step 1: 克隆 Blutter ═════
echo "─── [1/6] Cloning Blutter @ ${BLUTTER_COMMIT:0:8} ───"
mkdir -p "$BLUTTER_DIR"
git -C "$BLUTTER_DIR" init -q 2>/dev/null || true
git -C "$BLUTTER_DIR" remote remove origin 2>/dev/null || true
git -C "$BLUTTER_DIR" remote add origin "$BLUTTER_REPO"
git -C "$BLUTTER_DIR" fetch --depth 1 origin "$BLUTTER_COMMIT"
git -C "$BLUTTER_DIR" checkout -f FETCH_HEAD

# ═════ Step 2: 注入 NDK + 全部补丁 ═════
echo "─── [2/6] Patching (NDK inject / template / exe target) ───"

BLUTTER_FETCH="$BLUTTER_DIR/dartvm_fetch_build.py"
if ! grep -q "fler-dart NDK injected" "$BLUTTER_FETCH" 2>/dev/null; then
python3 - "$BLUTTER_FETCH" "$NDK_PATH" << 'PYEOF'
import sys
fetch_file = sys.argv[1]; ndk_path = sys.argv[2]
with open(fetch_file, 'r') as f: c = f.read()
old = "    subprocess.run([CMAKE_CMD, '-GNinja', '-B', builddir,"
new = ("    # fler-dart NDK injected\n"
       "    tc = '" + ndk_path + "/build/cmake/android.toolchain.cmake'\n"
       "    subprocess.run([CMAKE_CMD, '-GNinja', '-B', builddir,\n"
       "        f'-DCMAKE_TOOLCHAIN_FILE={tc}',\n"
       "        f'-DANDROID_ABI=arm64-v8a', f'-DANDROID_PLATFORM=android-31',\n"
       "        f'-DANDROID_STL=c++_static',")
assert old in c, "fetch_build anchor not found"
c = c.replace(old, new)
with open(fetch_file, 'w') as f: f.write(c)
print("  dartvm_fetch_build.py: patched OK")
PYEOF
fi

BLUTTER_TEMPLATE="$BLUTTER_DIR/scripts/CMakeLists.txt"
python3 - "$BLUTTER_TEMPLATE" "$BLUTTER_DIR" << 'PYEOF'
import sys
tmpl = sys.argv[1]; blutter_dir = sys.argv[2]
with open(tmpl, 'r') as f: c = f.read()
c = c.replace(
    "find_package(ICU REQUIRED uc)",
    "# fler-dart-patched-v2\n# fler-dart: ICU optional\nif(ANDROID)\n    find_package(ICU QUIET)\n    set(ICU_LIBRARIES \"\")\nelse()\n    find_package(ICU REQUIRED uc)\nendif()")
c = c.replace(
    "target_compile_options(${LIBNAME} PRIVATE ${cc_opts})",
    "target_compile_options(${LIBNAME} PRIVATE ${cc_opts})\nif(ANDROID)\n    target_compile_options(${LIBNAME} PRIVATE -include \"" + blutter_dir + "/atomic_ref_compat.h\")\nendif()")
c = c.replace(
    "if (MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()",
    "if(ANDROID)\n\ttarget_link_libraries(${LIBNAME} PUBLIC atomic log ${ICU_LIBRARIES})\nelseif(MSVC)\n\ttarget_link_libraries(${LIBNAME} PUBLIC ${ICU_LIBRARIES})\nelse()\n\ttarget_link_libraries(${LIBNAME} PUBLIC dl pthread ${ICU_LIBRARIES})\nendif()")
c = c.replace(
    "include(sourcelist.cmake)\nadd_library",
    "include(sourcelist.cmake)\nif(ANDROID)\n    list(FILTER SRCS EXCLUDE REGEX \"regexp\")\nendif()\nadd_library")
with open(tmpl, 'w') as f: f.write(c)
print("  CMake template: patched OK")
PYEOF

cp "$REPO_DIR/dartvm/src/atomic_ref_compat.h" "$BLUTTER_DIR/" 2>/dev/null || true

python3 - "$BLUTTER_DIR/blutter/CMakeLists.txt" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f: s = f.read()
old = 'if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang")'
new = ('# blutter-cli: -dead_strip is macOS ld64 only\n'
       'if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND CMAKE_SYSTEM_NAME MATCHES "Darwin")')
if 'blutter-cli: -dead_strip' not in s:
    assert old in s, "Clang guard anchor not found"
    s = s.replace(old, new, 1)
    print("  exe CMakeLists: Darwin guard applied")
old2 = 'find_package(${DARTLIB} REQUIRED PATHS "${PROJECT_SOURCE_DIR}/../packages")'
new2 = ('# blutter-cli: HINTS bypasses cross-compile re-rooting\n'
        'find_package(${DARTLIB} REQUIRED HINTS "${DARTVM_PACKAGES_HINT}/lib/cmake/${DARTLIB}" PATHS "${PROJECT_SOURCE_DIR}/../packages")')
if 'DARTVM_PACKAGES_HINT' not in s:
    assert old2 in s, "find_package anchor not found"
    s = s.replace(old2, new2, 1)
    print("  exe CMakeLists: find_package HINTS injected")
old3 = "target_compile_options(${BINNAME} PRIVATE ${cc_opts})"
new3 = ("target_compile_options(${BINNAME} PRIVATE ${cc_opts})\n"
        "if(ANDROID)\n"
        "\t# blutter-cli: NDK libc++ lacks std::atomic_ref\n"
        "\ttarget_compile_options(${BINNAME} PRIVATE -include \"${PROJECT_SOURCE_DIR}/../atomic_ref_compat.h\")\n"
        "endif()")
if 'atomic_ref_compat' not in s:
    assert old3 in s, "BINNAME opts anchor not found"
    s = s.replace(old3, new3, 1)
    print("  exe CMakeLists: atomic_ref force-include added")
# (d) regexp 桩目标:SDK 库排除了 regexp 源码,可执行链接需要这些符号(共享库容忍未定义,可执行不容忍)
old4 = "add_executable(${BINNAME} ${SRCS})"
new4 = ("add_executable(${BINNAME} ${SRCS})\n"
        "if(DEFINED BLUTTER_CLI_STUBS_CPP AND EXISTS \"${BLUTTER_CLI_STUBS_CPP}\")\n"
        "    add_library(blutter_cli_stubs STATIC \"${BLUTTER_CLI_STUBS_CPP}\")\n"
        "    target_link_libraries(${BINNAME} PRIVATE blutter_cli_stubs)\n"
        "endif()")
if 'blutter_cli_stubs' not in s:
    assert old4 in s, "add_executable anchor not found"
    s = s.replace(old4, new4, 1)
    print("  exe CMakeLists: regexp stubs target added")
with open(p, 'w', encoding='utf-8') as f: f.write(s)
PYEOF

# ═════ Step 3: Dart VM ARM64 静态库 ═════
echo "─── [3/6] Building Dart VM static lib ───"
cd "$BLUTTER_DIR"
pip install -q -r requirements.txt 2>/dev/null || true
export ANDROID_NDK_HOME="$NDK_PATH"
export ANDROID_NDK_ROOT="$NDK_PATH"
export FLER_NDK="$NDK_PATH"

PACKAGES_DIR="$BLUTTER_DIR/packages"
find_dartvm_a() {
    [ -d "$PACKAGES_DIR/lib" ] && find "$PACKAGES_DIR/lib" -name "*.a" 2>/dev/null | head -1 || true
}
CACHED_A="$(find_dartvm_a)"
if [ -n "$CACHED_A" ] && command -v file > /dev/null; then
    if ! file "$CACHED_A" | grep -qi "ARM\|aarch64"; then
        echo "Cached lib is not ARM64, forcing rebuild"
        rm -rf "$BLUTTER_DIR/build"
        find "$PACKAGES_DIR/lib" -name "*.a" -delete
    fi
fi
if [ -z "$(find_dartvm_a)" ]; then
    rm -rf "$BLUTTER_DIR/build"
    python3 dartvm_fetch_build.py "$DART_VERSION" android arm64
fi
DARTVM_A="$(find_dartvm_a)"
[ -n "$DARTVM_A" ] || { echo "ERROR: Dart VM static lib not found"; exit 1; }
if command -v file > /dev/null; then
    file "$DARTVM_A" | grep -qi "ARM\|aarch64" || { echo "ERROR: Dart VM lib is NOT arm64"; exit 1; }
fi
echo "Dart VM lib OK: $DARTVM_A ($(ls -lh "$DARTVM_A" | awk '{print $5}'))"

# ═════ Step 4: 版本兼容宏 ═════
VER_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
VER_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)
VERSION_DEFINES=""
if [ "$VER_MAJOR" -lt 3 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DOLD_MAP_SET_NAME=ON -DHAS_TYPE_REF=ON -DHAS_SHARED_CLASS_TABLE=ON"
else
    VERSION_DEFINES="$VERSION_DEFINES -DHAS_RECORD_TYPE=ON"
fi
if [ "$VER_MAJOR" -ge 3 ] && [ "$VER_MINOR" -ge 6 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DUNIFORM_INTEGER_ACCESS=ON -DNO_METHOD_EXTRACTOR_STUB=ON"
fi
if [ "$VER_MAJOR" -eq 2 ] && [ "$VER_MINOR" -lt 16 ]; then
    VERSION_DEFINES="$VERSION_DEFINES -DNO_INIT_LATE_STATIC_FIELD=ON"
fi
echo "Version defines: $VERSION_DEFINES"

# ═════ Step 5: Capstone 静态库 + 头文件扁平化 ═════
echo "─── [5/6] Building Capstone 5.0.9 (static) ───"
CAPSTONE_SRC="$BUILD_ROOT/capstone-src"
CAPSTONE_PREFIX="$BUILD_ROOT/capstone-prefix"
if [ ! -d "$CAPSTONE_SRC" ]; then
    mkdir -p "$CAPSTONE_SRC"
    curl -sL "https://github.com/capstone-engine/capstone/archive/refs/tags/5.0.9.tar.gz" \
        -o "$BUILD_ROOT/capstone.tar.gz"
    tar xzf "$BUILD_ROOT/capstone.tar.gz" -C "$CAPSTONE_SRC" --strip-components=1
fi
mkdir -p "$CAPSTONE_BUILD_DIR"
cd "$CAPSTONE_BUILD_DIR"
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX="$CAPSTONE_PREFIX" \
    -DCAPSTONE_BUILD_TESTS=OFF \
    -DCAPSTONE_BUILD_CSTOOL=OFF \
    -DCAPSTONE_BUILD_CSTEST=OFF \
    "$CAPSTONE_SRC"
cmake --build . -j "$JOBS"
cmake --install . > /dev/null
# 扁平化:blutter 用 #include <capstone.h>,官方布局在 include/capstone/ 子目录
cp "$CAPSTONE_PREFIX"/include/capstone/*.h "$CAPSTONE_PREFIX/include/" 2>/dev/null || true
PKG_CONFIG_PATH="$CAPSTONE_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH

# ═════ Step 5.5: regexp 桩符号 ═════
# SDK 库在 Android 下排除了 regexp 源码(缺 ICU),但 bootstrap 原生注册表
# 无条件引用 DN_RegExp_* 等符号;blutter 是静态分析器,不会执行这些运行时入口,
# 空实现即可满足链接器。独立 STATIC 目标,避免与 PCH 冲突。
STUBS_CPP="$BUILD_ROOT/stubs.cpp"
cat > "$STUBS_CPP" << 'CPPEOF'
namespace dart {
class Thread; class Zone; class NativeArguments; class RegExp; class Object;

class BootstrapNatives {
 public:
  static void DN_RegExp_factory(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getPattern(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getIsMultiLine(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getIsCaseSensitive(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getIsUnicode(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getIsDotAll(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getGroupCount(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_getGroupNameMap(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_ExecuteMatch(Thread*, Zone*, NativeArguments*);
  static void DN_RegExp_ExecuteMatchSticky(Thread*, Zone*, NativeArguments*);
};

void BootstrapNatives::DN_RegExp_factory(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getPattern(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getIsMultiLine(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getIsCaseSensitive(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getIsUnicode(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getIsDotAll(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getGroupCount(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_getGroupNameMap(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_ExecuteMatch(Thread*, Zone*, NativeArguments*) {}
void BootstrapNatives::DN_RegExp_ExecuteMatchSticky(Thread*, Zone*, NativeArguments*) {}

void CreateSpecializedFunction(Thread*, Zone*, const RegExp&, long, bool, const Object&) {}

extern const void (*kCaseInsensitiveCompareUCS2RuntimeEntry)(Thread*, Zone*, NativeArguments*) = nullptr;
extern const void (*kCaseInsensitiveCompareUTF16RuntimeEntry)(Thread*, Zone*, NativeArguments*) = nullptr;
}  // namespace dart
CPPEOF

# ═════ Step 6: 链接原版可执行 ═════
echo "─── [6/6] Linking vanilla blutter executable ───"
mkdir -p "$EXE_BUILD_DIR"
cd "$EXE_BUILD_DIR"
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-31 \
    -DANDROID_STL=c++_static \
    -DDARTLIB="$DARTLIB" \
    -DDARTVM_PACKAGES_HINT="$PACKAGES_DIR" \
    "-D${DARTLIB}_DIR=$PACKAGES_DIR/lib/cmake/$DARTLIB" \
    -DCMAKE_FIND_ROOT_PATH="$PACKAGES_DIR;$CAPSTONE_PREFIX" \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/pkg-config \
    -DBLUTTER_CLI_STUBS_CPP="$STUBS_CPP" \
    $VERSION_DEFINES \
    "$BLUTTER_DIR/blutter"
cmake --build . -j "$JOBS"

BINNAME="blutter_$DARTLIB"
[ -f "$BINNAME" ] || BINNAME=$(find . -maxdepth 1 -type f -name "blutter_*" | head -1 | xargs -r basename)
[ -f "$BINNAME" ] || { echo "ERROR: executable not found"; ls -la; exit 1; }

mkdir -p "$OUTPUT_DIR"
OUT_SO="$OUTPUT_DIR/blutter-cli_${DART_VERSION}_${ARCH_TAG}.so"
cp "$BINNAME" "$OUT_SO"
STRIP_BIN="$(find "$NDK_PATH/toolchains" -name "llvm-strip" 2>/dev/null | head -1)"
[ -n "$STRIP_BIN" ] && "$STRIP_BIN" "$OUT_SO" || true

echo ""
echo "════════════════════════════════════════════"
echo " Build complete: $OUT_SO ($(ls -lh "$OUT_SO" | awk '{print $5}'))"
command -v file > /dev/null && file "$OUT_SO"
echo "════════════════════════════════════════════"

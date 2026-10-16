#!/bin/zsh
# Builds Barrel's Wine from CodeWeavers' CrossOver open-source release (LGPL) on an Apple Silicon
# Mac and packages it as dist/barrel-wine-<version>.tar.xz. Runs in CI (.github/workflows/wine.yml).
# Build steps follow pedrosimoess/wine-macos27-steam-build (MIT).
#
# Usage: engine/build.sh <crossover-version>      e.g. engine/build.sh 26.3.0
# Needs Homebrew, Xcode or the Command Line Tools, Rosetta 2 and about 6 GB of disk.
set -euo pipefail

CX=${1:?Usage: engine/build.sh <crossover-version>}
here=${0:A:h}
WORK=${WORK:-$here/../.engine-build}
OUT=${OUT:-$here/../dist}
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)'   # codeweavers.com refuses curl's default agent
X86=(/usr/bin/arch -x86_64)

step() { print -r -- "==> $*" }
die()  { print -u2 -r -- "build: $*"; exit 1 }

mkdir -p "$WORK" "$OUT"
WORK=${WORK:A} OUT=${OUT:A}
src=$WORK/src build=$WORK/build stage=$WORK/stage libs=$WORK/libs

step "Build tools"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
brew install --quiet bison flex mingw-w64 freetype gnutls sdl2 >/dev/null
BREW=$(brew --prefix)
SDK=$(xcrun --show-sdk-path)
# Resolve the compilers natively: the xcrun shims can break when called under Rosetta.
CLANG=$(xcrun -f clang) CLANGXX=$(xcrun -f clang++)
export SDKROOT=$SDK PATH="$BREW/opt/bison/bin:$BREW/opt/flex/bin:${CLANG:h}:$PATH"

step "x86_64 libraries (Sikarugir Template, the same ones Barrel uses at runtime)"
if [[ ! -e $libs/libfreetype.6.dylib ]]; then
  url=$(curl -fsSL https://api.github.com/repos/Sikarugir-App/Template/releases/tags/v1.0 |
    jq -r '.assets | map(select(.name | test("^Template-[0-9.]+\\.tar\\.xz$"))) | sort_by(.updated_at) | last | .browser_download_url')
  rm -rf "$libs"; mkdir -p "$libs"
  curl -fsSL "$url" | tar -xJf - -C "$libs" --strip-components=3 "${${url:t}%.tar.xz}.app/Contents/Frameworks"
fi
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libvulkan.1.dylib; do
  [[ -e $libs/$lib ]] || die "$lib missing from the Template"
done

step "CrossOver $CX sources"
if [[ ! -f $src/configure ]]; then
  rm -rf "$src" "$WORK/extract"; mkdir -p "$WORK/extract"
  curl -fsSL -A "$UA" "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX.tar.gz" |
    tar -xzf - -C "$WORK/extract" sources/wine
  mv "$WORK/extract/sources/wine" "$src"; rm -rf "$WORK/extract"
  for p in $here/patches/*.patch(N); do
    print -r -- "    applying ${p:t}"
    patch -s -p1 -d "$src" < "$p"
  done
fi
wine_version=$(<"$src/VERSION")
print -r -- "    $wine_version"

step "Configure"
mkdir -p "$build" "$WORK/empty-pkgconfig"
if [[ ! -f $build/Makefile ]]; then
  ( cd "$build"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    # Only configure runs under Rosetta so it detects an x86_64 host; clang cross-compiles with -arch.
    # --without-opengl only drops EGL/X11 OpenGL; the Mac driver still provides OpenGL (as in Gcenx's builds).
    $X86 "$src/configure" --prefix="$stage" \
      --enable-archs=i386,x86_64 --disable-tests --disable-winebth_sys --disable-winemenubuilder \
      --without-alsa --without-capi --with-coreaudio --without-dbus --without-ffmpeg \
      --without-fontconfig --with-freetype --without-gettext --without-gettextpo --without-gphoto \
      --with-gnutls --without-gssapi --without-gstreamer --without-inotify --without-krb5 \
      --without-netapi --without-opengl --without-oss --without-pcap --without-pulse --without-sane \
      --with-sdl --without-udev --without-usb --without-v4l2 --with-vulkan --without-wayland --without-x \
      CC="$CLANG -arch x86_64 -isysroot $SDK" CXX="$CLANGXX -arch x86_64 -isysroot $SDK" \
      OBJC="$CLANG -arch x86_64 -isysroot $SDK" \
      CFLAGS='-O2 -Wno-error' OBJCFLAGS='-O2 -Wno-error' CROSSCFLAGS='-O2 -Wno-error' \
      PKG_CONFIG_LIBDIR="$WORK/empty-pkgconfig" \
      FREETYPE_CFLAGS="-I$BREW/opt/freetype/include/freetype2" FREETYPE_LIBS="-L$libs -lfreetype" \
      GNUTLS_CFLAGS="-I$BREW/opt/gnutls/include" GNUTLS_LIBS="-L$libs -lgnutls" \
      SDL2_CFLAGS="-I$BREW/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$libs -lSDL2" \
      ac_cv_lib_soname_freetype=libfreetype.6.dylib ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
      ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib ac_cv_lib_soname_vulkan=libvulkan.1.dylib
  ) > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log"; rm -f "$build/Makefile"; die "configure failed" }
  # CrossOver's win32u/vulkan.c needs SONAME_LIBVULKAN even when configure doesn't define it.
  grep -q '^#define SONAME_LIBVULKAN' "$build/include/config.h" ||
    print '\n#define SONAME_LIBVULKAN "libvulkan.1.dylib"' >> "$build/include/config.h"
fi
grep -q 'SONAME_LIBFREETYPE "libfreetype.6.dylib"' "$build/include/config.h" || die "configure didn't find freetype"
grep -q 'SONAME_LIBGNUTLS "libgnutls.30.dylib"' "$build/include/config.h" || die "configure didn't find gnutls"
# Build-time tools (sfnt2fon…) load these by bare name, relative to the build folder.
for lib in $libs/*.dylib(N); do ln -sf "$lib" "$build/${lib:t}"; done

step "Compile ($JOBS jobs)"
make -C "$build" -j"$JOBS" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; die "make failed" }

step "Install"
rm -rf "$stage"
make -C "$build" install-lib > "$WORK/install.log" 2>&1 || { tail -30 "$WORK/install.log"; die "install failed" }
[[ -x $stage/bin/wine && -f $stage/lib/wine/x86_64-unix/ntdll.so && -d $stage/lib/wine/i386-windows ]] ||
  die "the install is incomplete"
# DXMT finds the Mac driver through this symbol.
nm -gU "$stage/lib/wine/x86_64-unix/winemac.so" | grep -q ' _macdrv_functions$' || die "winemac.so doesn't export macdrv_functions"

step "Wine Mono and Gecko"
mono=$(grep -oE 'WINE_MONO_VERSION "[0-9.]+"' "$src/dlls/mscoree/mscoree_private.h" | grep -oE '[0-9.]+')
gecko=$(grep -oE 'GECKO_VERSION "[0-9.]+"' "$src/dlls/appwiz.cpl/addons.c" | grep -oE '[0-9.]+')
mkdir -p "$stage/share/wine/mono" "$stage/share/wine/gecko"
curl -fsSL "https://dl.winehq.org/wine/wine-mono/$mono/wine-mono-$mono-x86.tar.xz" | tar -xJf - -C "$stage/share/wine/mono"
for arch in x86 x86_64; do
  curl -fsSL "https://dl.winehq.org/wine/wine-gecko/$gecko/wine-gecko-$gecko-$arch.tar.xz" | tar -xJf - -C "$stage/share/wine/gecko"
done
print -r -- "    Mono $mono, Gecko $gecko"

step "Package"
print -r -- "Barrel Wine, CrossOver $CX sources ($wine_version)" > "$stage/version"
rm -rf "$stage/include" "$stage/share/man" "$stage/share/applications"
tar -cJf "$OUT/barrel-wine-$CX.tar.xz" -C "$stage" .
print -r -- "$OUT/barrel-wine-$CX.tar.xz ($(du -h "$OUT/barrel-wine-$CX.tar.xz" | cut -f1))"

#!/usr/bin/env bash
set -uo pipefail
SRCDIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$SRCDIR/../prefix-android"
OUT="${GITHUB_WORKSPACE:-$PWD}/out"
LOG="${GITHUB_WORKSPACE:-$SRCDIR/..}/logs"
API=29
TC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export CC="$TC/bin/aarch64-linux-android$API-clang"
export CXX="$TC/bin/aarch64-linux-android$API-clang++"
export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_ALLOW_CROSS=1
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export PATH="$TC/bin:$PATH"
HOST=aarch64-linux-android
JOBS=$(nproc 2>/dev/null || echo 4)
mkdir -p "$PREFIX/lib/pkgconfig" "$OUT" "$LOG" /tmp/asrc
"$AR" rcs "$PREFIX/lib/libpthread.a"  # NDK r23+ dropped stub libs; tools/ hardcodes -lpthread
cd /tmp/asrc

fetch() { local d="$1" u="$2"; [ -d "$d" ] && return 0
  wget -q --tries=3 -O "$d.tb" "$u" || return 1
  mkdir -p "$d"; tar xf "$d.tb" -C "$d" --strip-components=1 || return 1; }

stage() { local n="$1"; shift; echo "########## START $n ##########"
  if ( set -e; "$@" ) > "$LOG/$n.log" 2>&1; then
    echo "########## OK $n ##########"; return 0
  else echo "########## FAIL $n ##########"; cat "$LOG/$n.log"; return 1; fi }

build_lib() { local d="$1" v="$2" repo="$3"; shift 3
  fetch "$d-$v" "https://github.com/libimobiledevice/$d/releases/download/$v/$d-$v.tar.bz2" \
    || fetch "$d-$v" "https://github.com/$repo/archive/refs/tags/$v.tar.gz" \
    || { rm -rf "$d-$v"; git clone --depth 1 "https://github.com/$repo.git" "$d-$v"; } || return 1
  ( cd "$d-$v" && { [ -f configure ] || NOCONFIGURE=1 ./autogen.sh; } \
    && ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared "$@" \
    && make -j"$JOBS" && make install ) }

s_openssl() { fetch openssl-3.0.15 https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz || return 1
  cd openssl-3.0.15 && ./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests \
    --prefix="$PREFIX" && make -j"$JOBS" build_libs && make install_sw; }

s_libusb() { fetch libusb-1.0.27 https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 || return 1
  cd libusb-1.0.27 && ./configure --host="$HOST" --prefix="$PREFIX" \
    --enable-static --disable-shared --disable-udev && make -j"$JOBS" && make install; }

s_plist() {
  fetch libplist-2.7.0 "https://github.com/libimobiledevice/libplist/releases/download/2.3.0/libplist-2.7.0.tar.bz2" \
    || fetch libplist-2.7.0 "https://github.com/libimobiledevice/libplist/archive/refs/tags/2.7.0.tar.gz" \
    || { rm -rf libplist-2.7.0; git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist-2.7.0; } || return 1
  cd libplist-2.7.0
  echo "2.7.0" > .tarball-version
  [ -f configure ] || NOCONFIGURE=1 ./autogen.sh
  echo "===== configure --help (cython/python section) ====="
  ./configure --help | grep -i -A2 "cython\|python"
  echo "===== raw configure.ac cython/python block ====="
  grep -n -A15 "AC_ARG_WITH(\[cython\]" configure.ac 2>/dev/null || echo "(no configure.ac present)"
  echo "===== grep generated configure script itself ====="
  grep -n "without-cython\|build_cython" configure | head -20
  ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared --without-cython CYTHON=false \
    && make -j"$JOBS" && make install
}

s_curl() { fetch curl-8.4.0 https://curl.se/download/curl-8.4.0.tar.xz || return 1
  cd curl-8.4.0 && ./configure --host="$HOST" --prefix="$PREFIX" \
    --enable-static --disable-shared --with-openssl="$PREFIX" \
    --without-libpsl --without-libidn2 --without-brotli --without-zstd \
    --without-nghttp2 --disable-ldap --disable-ldaps && make -j"$JOBS" && make install; }

# libssh2 with OpenSSL backend (wincng is Windows-only)
s_ssh2() { fetch libssh2-1.11.1 https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz || return 1
  cd libssh2-1.11.1 && ./configure --host="$HOST" --prefix="$PREFIX" \
    --enable-static --disable-shared --with-crypto=openssl --with-libssl-prefix="$PREFIX" \
    --without-libz --disable-examples-build && make -j"$JOBS" && make install; }

s_usbmuxd() { build_lib libusbmuxd 2.0.2 libimobiledevice/libusbmuxd; }

# libirecovery: tag 1.0.1 requires readline unconditionally; master has --without-tools
s_irecv() { rm -rf libirecovery-m; git clone --depth 1 https://github.com/libimobiledevice/libirecovery.git libirecovery-m || return 1
  cd libirecovery-m && NOCONFIGURE=1 ./autogen.sh \
    && ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared --without-tools \
    && make -j"$JOBS" && make install; }

s_glue() { build_lib libimobiledevice-glue 1.3.3 libimobiledevice/libimobiledevice-glue; }

s_tatsu() { build_lib libtatsu 1.0.3 libimobiledevice/libtatsu; }

# libimobiledevice: 1.3.0 tag (2020) predates libplist 2.3.0 and redefines
# PLIST_FORMAT_XML/BINARY enumerators already provided by modern libplist, causing
# a fatal compile error. Upstream confirms building from master resolves this.
s_imd() { rm -rf libimobiledevice-m; git clone --depth 1 https://github.com/libimobiledevice/libimobiledevice.git libimobiledevice-m || return 1
  cd libimobiledevice-m && NOCONFIGURE=1 ./autogen.sh \
    && ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared \
       --without-cython ac_cv_lib_pthread_pthread_once=yes \
    && sed -i '/^SUBDIRS/ s/ tools//' Makefile \
    && make -j"$JOBS" && make install; }

stage openssl  s_openssl  || true
stage libusb   s_libusb   || true
stage libplist s_plist    || true
stage curl     s_curl     || true
stage libssh2  s_ssh2     || true
stage usbmuxd  s_usbmuxd  || true
stage glue     s_glue     || true
stage irecovery s_irecv   || true
stage tatsu       s_tatsu    || true
stage imobiledevice s_imd || true

s_tr4mpass() {
  cd "$SRCDIR"
  make clean 2>/dev/null || true
  PKG_LIBS_TR4="libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2"
  STATIC_LDFLAGS="$(pkg-config --static --libs $PKG_LIBS_TR4) -lm -Wl,-z,muldefs"
  make -j"$JOBS" CC="$CC" NATIVE_CC=cc LDFLAGS="$STATIC_LDFLAGS"
  "$STRIP" tr4mpass || true
  cp tr4mpass "$OUT/tr4mpass-arm64"
}

stage tr4mpass s_tr4mpass

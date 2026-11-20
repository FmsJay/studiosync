#!/bin/sh
# Builds the live audio libraries (AOO with Opus, vendored here: README.md) into a static library for macOS and Linux, as
# build_windows.cmd does for Windows: sh extension/third_party/build_unix.sh <out.a> [extra compiler flags, e.g. the Mac's -arch lines].
# The CI (.github/workflows/extension.yml) links it into reaper_studiosync and the live audio test. The AOO_* flags must match the top of
# extension/rtaudio.cpp. Their symbols are hidden, so another plug-in carrying its own AOO or Opus (SonoBus) can't clash. (James, rt)
# libjuice and Monocypher (the connection without Tailscale, extension/nat.cpp) go into the same archive.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = "--one" ]; then # (one file, run by xargs below, several at once)
  f="$2"; o="$SS_OBJ/$(echo "$f" | tr '/' '_').o"
  case "$f" in
    opus/*) # (Opus in plain C, float, no SIMD paths: one build runs on every CPU, as on Windows)
      exec ${CC:-cc} -c $SS_FLAGS -DOPUS_BUILD -DUSE_ALLOCA -DHAVE_LRINTF -I"$here/opus/include" -I"$here/opus/celt" -I"$here/opus/silk" \
        -I"$here/opus/silk/float" "$here/$f" -o "$o" ;;
    libjuice/src/server.c) # (its sends go through extension/nat.cpp's nat_relay_sendto: the relay's caps, rt-nat3)
      exec ${CC:-cc} -c $SS_FLAGS -DJUICE_STATIC -Dudp_sendto=nat_relay_sendto -I"$here/libjuice/include/juice" "$here/$f" -o "$o" ;;
    libjuice/*|monocypher/*) # (the connection without Tailscale, extension/nat.cpp: plain C, symbols hidden like the rest)
      exec ${CC:-cc} -c $SS_FLAGS -DJUICE_STATIC -I"$here/libjuice/include/juice" "$here/$f" -o "$o" ;;
    *)
      exec ${CXX:-c++} -c -std=c++17 $SS_FLAGS -DAOO_BUILD -DAOO_NET=0 -DAOO_USE_OPUS=1 -DAOO_USE_IPV6=0 -DAOO_SAMPLE_SIZE=32 \
        -DAOO_MAX_PACKET_SIZE=4096 -DAOO_LOG_LEVEL=kAooLogLevelWarning -DAOO_HAVE_ATOMIC_DOUBLE -DAOO_HAVE_ATOMIC_INT64 -DAOO_HAVE_PTHREAD_RWLOCK \
        -DOSC_HOST_LITTLE_ENDIAN -I"$here/aoo" -I"$here/aoo/include" -I"$here/aoo/aoo" -I"$here/aoo/deps/oscpack" -I"$here/opus/include" \
        "$here/$f" -o "$o" ;;
  esac
fi
out="$1"; shift
SS_OBJ="$(mktemp -d)"
SS_FLAGS="-O2 -fPIC -fvisibility=hidden -DNDEBUG -DOPUS_EXPORT= $*"
export SS_OBJ SS_FLAGS
{ tr -d '\r' < "$here/opus/sources.txt" | sed 's|^|opus/|'; tr -d '\r' < "$here/aoo/sources.txt" | sed 's|^|aoo/|'
  (cd "$here" && ls libjuice/src/*.c monocypher/monocypher.c); } |
  xargs -n 1 -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" sh "$0" --one
rm -f "$out"
# (macOS: -arch arm64 -arch x86_64 makes universal objects, which only libtool puts in an archive)
if [ "$(uname)" = Darwin ]; then libtool -static -o "$out" "$SS_OBJ"/*.o; else ar rcs "$out" "$SS_OBJ"/*.o; fi
rm -rf "$SS_OBJ"
ls -l "$out"

#!/usr/bin/env bash
set -euo pipefail

log() {
  echo -e "\n==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
OUTDIR="${OUTDIR:-$PROJECT_DIR/Release}"
IMAGE_NAME="${IMAGE_NAME:-liquidsoap-appimage-builder:local}"
CONTAINER_NAME="${CONTAINER_NAME:-liquidsoap-appimage-builder}"
WORKDIR_HOST="${WORKDIR_HOST:-$PROJECT_DIR/.docker-build-work}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"

require_cmd docker

mkdir -p "$OUTDIR"
mkdir -p "$WORKDIR_HOST"

OUTDIR="$(cd "$OUTDIR" && pwd)"
WORKDIR_HOST="$(cd "$WORKDIR_HOST" && pwd)"

TMP_CONTEXT="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_CONTEXT"

  if [ "$KEEP_WORKDIR" = "1" ]; then
    return
  fi

  if rm -rf "$WORKDIR_HOST" 2>/dev/null; then
    return
  fi

  log "Direct cleanup failed, trying cleanup through a temporary Docker container"
  docker run --rm \
    -v "$WORKDIR_HOST:/target" \
    alpine:3.20 \
    sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true' >/dev/null 2>&1 || true

  rm -rf "$WORKDIR_HOST" 2>/dev/null || true
}
trap cleanup EXIT

log "Preparing Docker build context"

cat > "$TMP_CONTEXT/Dockerfile" <<'DOCKERFILE_EOF'
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
  build-essential \
  nasm \
  git curl ca-certificates \
  pkg-config \
  autoconf automake libtool \
  opam \
  libssl-dev \
  libcurl4-gnutls-dev \
  libmad0-dev \
  libfaad-dev \
  libsamplerate0-dev \
  libogg-dev \
  libvorbis-dev \
  libmp3lame-dev \
  zlib1g-dev \
  unzip \
  libsdl2-dev \
  libsdl2-image-dev \
  libsdl2-ttf-dev \
  libffi-dev \
  libgmp-dev \
  file \
  patchelf \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY inner-build.sh /build/inner-build.sh
RUN chmod +x /build/inner-build.sh

VOLUME ["/out", "/work"]

CMD ["/build/inner-build.sh"]
DOCKERFILE_EOF

cat > "$TMP_CONTEXT/inner-build.sh" <<'INNER_BUILD_EOF'
#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $*"; }

ARCH="$(uname -m)"
JOBS="${JOBS:-$(nproc)}"

OUTDIR="${OUTDIR:-/out}"
WORKROOT="${WORKROOT:-/work}"
PREFIX="${PREFIX:-$WORKROOT/prefix}"
APPDIR="${APPDIR:-$WORKROOT/AppDir}"
OPAMROOT="${OPAMROOT:-$WORKROOT/opamroot}"
HOST_UID="${HOST_UID:-}"
HOST_GID="${HOST_GID:-}"

fix_ownership() {
  if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" "$WORKROOT" "$OUTDIR" 2>/dev/null || true
  fi
}
trap fix_ownership EXIT

mkdir -p "$OUTDIR" "$WORKROOT" "$PREFIX" "$APPDIR" "$OPAMROOT"

export HOME="${HOME:-$WORKROOT/home}"
mkdir -p "$HOME"

export OPAMYES=1
export OPAMCOLOR=never
export OPAMROOT

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib"
export PATH="$PREFIX/bin:$PATH"

# ---------------- OPAM + OCaml 4.14 ----------------
log "Init OPAM + OCaml 4.14"
[ -f "$OPAMROOT/config" ] || opam init --bare --disable-sandboxing

opam switch list --short | grep -qx "liquiold" || \
  opam switch create liquiold ocaml-base-compiler.4.14.1

eval "$(opam env --switch=liquiold)"
opam install -y dune conf-pkg-config conf-libcurl conf-openssl

# ---------------- Legacy audio OPAM packages ----------------
log "Install legacy audio OPAM packages"
opam install -y mad faad samplerate ogg vorbis lame

# ---------------- fdk-aac ----------------
log "Build libfdk-aac"
cd "$WORKROOT"
rm -rf fdk-aac
git clone https://github.com/mstorsjo/fdk-aac.git
cd fdk-aac
autoreconf -fiv
./configure --prefix="$PREFIX" --enable-shared --disable-static
make -j"$JOBS"
make install

# ---------------- fdkaac CLI ----------------
log "Build fdkaac CLI"
cd "$WORKROOT"
rm -rf fdkaac
git clone https://github.com/nu774/fdkaac.git
cd fdkaac
autoreconf -fiv
./configure --prefix="$PREFIX"
make -j"$JOBS"
make install

# ---------------- FFmpeg ----------------
log "Build FFmpeg"
cd "$WORKROOT"
rm -rf FFmpeg
git clone https://github.com/FFmpeg/FFmpeg.git
cd FFmpeg
git checkout n6.1.1

./configure \
  --prefix="$PREFIX" \
  --enable-shared \
  --disable-static \
  --disable-doc \
  --disable-programs \
  --enable-gpl \
  --enable-nonfree \
  --enable-openssl \
  --enable-network \
  --enable-protocol=file \
  --enable-protocol=http \
  --enable-protocol=https \
  --enable-protocol=tcp \
  --enable-libmp3lame \
  --enable-libvorbis \
  --enable-libfdk-aac

make -j"$JOBS"
make install

# ---------------- ocaml-ffmpeg pinned to bundled FFmpeg ----------------
log "Rebuild ocaml-ffmpeg against bundled FFmpeg"
cd "$WORKROOT"
rm -rf ocaml-ffmpeg
git clone https://github.com/savonet/ocaml-ffmpeg.git
cd ocaml-ffmpeg
git checkout v1.2.8

for p in ffmpeg-av ffmpeg-avcodec ffmpeg-avdevice ffmpeg-avfilter ffmpeg-avutil ffmpeg-swresample ffmpeg-swscale
do
  opam pin add -y --no-action "$p" "$WORKROOT/ocaml-ffmpeg"
done

opam install -y --no-depexts \
  ffmpeg-av ffmpeg-avcodec ffmpeg-avdevice ffmpeg-avfilter ffmpeg-avutil ffmpeg-swresample ffmpeg-swscale

opam install -y fdkaac --no-depexts

# ---------------- Liquidsoap 2.4.1 ----------------
log "Install Liquidsoap 2.4.1"

export LIQUIDSOAP_DISABLE_SDL=1

cd "$WORKROOT"
rm -rf liquidsoap
git clone https://github.com/savonet/liquidsoap.git
cd liquidsoap
git checkout v2.4.1

opam install -y --deps-only . --no-depexts
opam install -y .

LIQ_BIN="$(opam var bin)/liquidsoap"
[ -x "$LIQ_BIN" ] || { echo "ERROR: liquidsoap binary not found"; exit 1; }

# ---------------- Stage AppDir ----------------
log "Stage AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/liquidsoap-lang" \
         "$APPDIR/etc/ssl/certs"

install -m 0755 "$LIQ_BIN" "$APPDIR/usr/bin/liquidsoap-custom"
install -m 0755 "$PREFIX/bin/fdkaac" "$APPDIR/usr/bin/fdkaac"
cp -a "$(opam var share)/liquidsoap-lang/"* "$APPDIR/usr/share/liquidsoap-lang/"
install -m 0755 /usr/bin/curl "$APPDIR/usr/bin/curl"

if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
  cp -a /etc/ssl/certs/ca-certificates.crt "$APPDIR/etc/ssl/certs/ca-certificates.crt"
fi

cp -a "$PREFIX/lib/"*.so* "$APPDIR/usr/lib/" || true
cp -a /usr/lib/*/libssl.so* /usr/lib/*/libcrypto.so* "$APPDIR/usr/lib/" 2>/dev/null || true
cp -a /usr/lib/*/libcurl.so* "$APPDIR/usr/lib/" 2>/dev/null || true
cp -a /usr/lib/*/libSDL2*.so* "$APPDIR/usr/lib/" || true
cp -a /usr/lib/*/libcurl.so* "$APPDIR/usr/lib/" 2>/dev/null || true
cp -a /usr/lib/*/libssl.so* /usr/lib/*/libcrypto.so* "$APPDIR/usr/lib/" 2>/dev/null || true

cat > "$APPDIR/AppRun" <<'APP_RUN_EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"

export LD_LIBRARY_PATH="$HERE/usr/lib"
export PATH="$HERE/usr/bin:$PATH"

if [ -f "$HERE/etc/ssl/certs/ca-certificates.crt" ]; then
  export SSL_CERT_FILE="$HERE/etc/ssl/certs/ca-certificates.crt"
fi

exec "$HERE/usr/bin/liquidsoap-custom" \
  --stdlib "$HERE/usr/share/liquidsoap-lang/libs/stdlib.liq" \
  "$@"
APP_RUN_EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/liquidsoap-custom.desktop" <<'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Liquidsoap Custom
Exec=liquidsoap-custom
Icon=liquidsoap-custom
Terminal=true
Categories=AudioVideo;
DESKTOP_EOF

cat > "$APPDIR/liquidsoap-custom.svg" <<'SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
  <rect width="64" height="64" fill="#202020"/>
  <text x="32" y="40" font-size="28" text-anchor="middle" fill="#ffffff">LS</text>
</svg>
SVG_EOF

# ---------------- Build AppImage via linuxdeploy ----------------
log "Build AppImage via linuxdeploy"
cd "$WORKROOT"
rm -f ./*.AppImage
rm -rf squashfs-root
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
curl -L -o linuxdeploy.AppImage "$LINUXDEPLOY_URL"
chmod +x linuxdeploy.AppImage
./linuxdeploy.AppImage --appimage-extract >/dev/null

./squashfs-root/AppRun \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/liquidsoap-custom.desktop" \
  --icon-file "$APPDIR/liquidsoap-custom.svg" \
  --output appimage

GEN="$(ls -1 ./*.AppImage | head -n 1 || true)"
[ -n "$GEN" ] || { echo "ERROR: AppImage not generated"; exit 1; }

FINAL="$OUTDIR/liquidsoap-WB.AppImage"
mv -f "$GEN" "$FINAL"
chmod +x "$FINAL"

# ---------------- Quick checks ----------------
log "Sanity checks"
"$FINAL" --version || true
"$FINAL" --list-protocols | grep -E '(^|[[:space:]])http(s)?:' -n || true
"$FINAL" --list-encoders | grep -i -E 'fdkaac|aac' -n || true

log "DONE: $FINAL"
INNER_BUILD_EOF

BUILD_ARGS=()
if [ -n "$DOCKER_PLATFORM" ]; then
  BUILD_ARGS+=(--platform "$DOCKER_PLATFORM")
fi

log "Building Docker image: $IMAGE_NAME"
docker build "${BUILD_ARGS[@]}" -t "$IMAGE_NAME" "$TMP_CONTEXT"

RUN_ARGS=(
  --rm
  --name "$CONTAINER_NAME"
  -v "$OUTDIR:/out"
  -v "$WORKDIR_HOST:/work"
  -e OUTDIR=/out
  -e WORKROOT=/work
  -e HOST_UID="$HOST_UID"
  -e HOST_GID="$HOST_GID"
)

if [ -n "$DOCKER_PLATFORM" ]; then
  RUN_ARGS+=(--platform "$DOCKER_PLATFORM")
fi

if [ -n "${JOBS:-}" ]; then
  RUN_ARGS+=(-e "JOBS=$JOBS")
fi

log "Running container build"
docker run "${RUN_ARGS[@]}" "$IMAGE_NAME"

log "Build finished"
log "Artifact directory: $OUTDIR"
ls -lah "$OUTDIR"

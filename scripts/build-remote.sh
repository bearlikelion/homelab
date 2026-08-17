#!/usr/bin/env bash
# Build Godot on the server instead of this machine.
#
# Syncs the checkout up, compiles there, copies the binary back. rsync moves
# only what changed, so the first run is the slow one.
#
#   build-remote.sh mark [scons args...]    # godot-mark, 4.7.2-rc
#   build-remote.sh dev  [scons args...]    # godot-dev, 4.8-dev
#   build-remote.sh here [scons args...]    # whatever checkout you are in
#   build-remote.sh sync <mark|dev|here>    # push the tree, compile nothing
#   build-remote.sh shell                   # ssh in, ccache on PATH
#
# Both trees are the bearlikelion/godot fork on mark/mp4, so they share a
# ccache: the mp4 module and most of core are identical between them.
#
# Env: GODOT_JOBS (default 22), GODOT_TARGET (editor), GODOT_PLATFORM (linuxbsd)
set -euo pipefail

BUILD_HOST="${BUILD_HOST:-192.168.1.150}"
BUILD_USER="${BUILD_USER:-root}"
BUILD_ROOT="${BUILD_ROOT:-/build}"

ENGINE_DIR="${ENGINE_DIR:-$HOME/Source/Godot/Engine}"
declare -A CHECKOUTS=(
  [mark]="$ENGINE_DIR/godot-mark"
  [dev]="$ENGINE_DIR/godot-dev"
)

SSH=(ssh -o ConnectTimeout=10 "${BUILD_USER}@${BUILD_HOST}")

die() { echo "error: $*" >&2; exit 1; }
log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

resolve() {
  case "${1:-}" in
    mark|dev) echo "${CHECKOUTS[$1]}" ;;
    here|"")  pwd ;;
    *)        die "unknown checkout '$1' (use mark, dev or here)" ;;
  esac
}

# The mp4 module links a static decode-only ffmpeg from thirdparty/ffmpeg.
# Those .a files are gitignored, so they live only in a working tree: if they
# do not reach the server the module quietly falls back to dlopen'd system
# ffmpeg and you get a different binary than the one you tested locally.
check_ffmpeg() {
  local src="$1"
  [[ -d "$src/modules/mp4" ]] || return 0
  if [[ ! -f "$src/thirdparty/ffmpeg/lib-linuxbsd-x86_64/libavcodec.a" ]]; then
    log "warning: no static ffmpeg in $(basename "$src"); mp4 will fall back to system ffmpeg"
  fi
}

# .git is excluded because the build never reads it and it is the bulk of the
# tree. Object files and binaries regenerate on the far side. Static libs are
# NOT excluded: thirdparty/ffmpeg/*.a is gitignored and must ship.
rsync_tree() {
  local src="$1" dest="$2"
  log "syncing $(basename "$src") -> $BUILD_HOST:$dest"
  rsync -a --delete --info=progress2 \
    --exclude='.git/' \
    --exclude='bin/' \
    --exclude='.sconsign.dblite' \
    --exclude='*.o' \
    --exclude='*.os' \
    --exclude='*.obj' \
    --exclude='*.pyc' \
    --exclude='__pycache__/' \
    -e 'ssh -o ConnectTimeout=10' \
    "$src/" "${BUILD_USER}@${BUILD_HOST}:$dest/"
}

cmd_build() {
  local which="${1:-here}"; shift || true
  local src dest name
  src="$(resolve "$which")"
  [[ -f "$src/SConstruct" ]] || die "no SConstruct in $src"
  name="$(basename "$src")"
  dest="$BUILD_ROOT/src/$name"

  check_ffmpeg "$src"
  "${SSH[@]}" "mkdir -p '$dest'"
  rsync_tree "$src" "$dest"

  log "building $name with ${GODOT_JOBS:-22} jobs"
  # -t keeps scons' progress line-buffered so it streams instead of arriving
  # in one lump at the end.
  "${SSH[@]}" -t "
    set -e
    export CCACHE_DIR=$BUILD_ROOT/ccache
    export PATH=/usr/lib/ccache:\$PATH
    cd '$dest'
    scons -j${GODOT_JOBS:-22} \
      platform=${GODOT_PLATFORM:-linuxbsd} \
      target=${GODOT_TARGET:-editor} \
      scons_cache=$BUILD_ROOT/ccache/scons \
      $*
  "

  log "fetching binaries"
  mkdir -p "$src/bin"
  rsync -a --info=progress2 -e 'ssh -o ConnectTimeout=10' \
    "${BUILD_USER}@${BUILD_HOST}:$dest/bin/" "$src/bin/"
  log "done: $src/bin"
  ls -lh "$src/bin" 2>/dev/null | tail -n +2 || true
}

cmd_sync() {
  local src dest name
  src="$(resolve "${1:-here}")"
  name="$(basename "$src")"
  dest="$BUILD_ROOT/src/$name"
  check_ffmpeg "$src"
  "${SSH[@]}" "mkdir -p '$dest'"
  rsync_tree "$src" "$dest"
  log "synced to $dest"
}

cmd_shell() {
  exec "${SSH[@]}" -t "cd $BUILD_ROOT && exec bash -l"
}

case "${1:-}" in
  mark|dev|here) cmd_build "$@" ;;
  sync)          shift; cmd_sync "$@" ;;
  shell)         cmd_shell ;;
  *)             sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 1 ;;
esac

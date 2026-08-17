# Build box

Compiling Godot on a laptop ties it up for half an hour. The host is a dual
E5-2690 (32 threads, 125G) that idles most of the day, so the compiling moves
there.

Container 150, `build`, 24 cores and 32G. Nothing is proxied to it: builds are
driven over ssh, so it has no internal name.

## Godot

Two checkouts, both the `bearlikelion/godot` fork on `mark/mp4`:

| Name | Upstream base | Path |
|---|---|---|
| `godot-mark` | 4.7.2-rc | `Godot/Engine/godot-mark` |
| `godot-dev` | 4.8-dev | `Godot/Engine/godot-dev` |

    build-remote.sh mark           # build godot-mark
    build-remote.sh dev            # build godot-dev
    build-remote.sh here           # build the checkout you are standing in
    build-remote.sh sync mark      # push the tree, compile nothing
    build-remote.sh shell          # ssh in, ccache on PATH

Extra scons arguments pass straight through, so
`build-remote.sh mark dev_build=yes` works. `GODOT_JOBS`, `GODOT_TARGET` and
`GODOT_PLATFORM` override the defaults (22, `editor`, `linuxbsd`).

Binaries come back to `bin/` in the local checkout, the same place a local
build would leave them.

## The mp4 module

The fork carries `modules/mp4`, which links a static decode-only FFmpeg from
`thirdparty/ffmpeg/lib-linuxbsd-x86_64/`. **Those `.a` files are gitignored**,
so they exist only in a working tree, never in the repo. The sync deliberately
does not exclude static libraries for that reason.

Without them the module still compiles: it falls back to dlopen'ing system
FFmpeg at runtime, using the vendored headers. That is a different binary from
the one built locally, so `build-remote.sh` warns when the static libs are
missing rather than letting the difference pass unnoticed.

Neither path needs FFmpeg installed on the build box: static links at build
time, dlopen at run time.

## Storage

Everything large is on the `fast` pool via a bind mount at `/build`, not in the
container rootfs:

| Path | Holds |
|---|---|
| `/build/src` | source checkouts |
| `/build/artifacts` | build output kept for download |
| `/build/ccache` | compiler cache, capped at 50G |

vzdump skips bind mounts, so none of it lands in the nightly archive, the same
reason `/tank/media` is mounted rather than copied.

Both checkouts share one ccache. They are the same fork on the same branch, so
core and the mp4 module are largely identical between them and the second build
of a pair is much faster.

`fast` is a mirror of the two 2T disks the old PVE install booted from. Nothing
here is backed up: it is all either regenerable or a copy of the workstation.

## Resource sharing

`cores` is a limit, not a reservation, so an idle build box costs the other
containers nothing. During a build 24 threads are busy and 8 stay free, which
is why the box still answers ssh and Plex still transcodes.

`startup_order` is 50, last of everything. A build is never more important than
the services people use.

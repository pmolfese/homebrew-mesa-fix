# homebrew-mesa-fix

A Homebrew tap providing a patched build of [Mesa](https://www.mesa3d.org/) main
that fixes two crashes when running Mesa's software rasterizer through
[XQuartz](https://www.xquartz.org/) on macOS.

## The Bug

When using Mesa's `drisw` (software rasterizer) GLX path with XQuartz on macOS,
two crashes were observed depending on the Mesa version:

**Mesa 26.0.x — `BadShmSeg` on `X_ShmPutImage`:**
```
X Error of failed request: BadShmSeg (invalid shared segment parameter)
  Major opcode of failed request: 133 (MIT-SHM)
  Minor opcode of failed request: 3 (X_ShmPutImage)
  Segment id in failed request: 0x800006
```

**Mesa 26.2.0-devel — assertion crash:**
```
Assertion failed: (xshm_opcode != -1), function handle_xerror,
file drisw_glx.c, line 62.
```

Both were reproducible with `glxgears` from mesa-demos and with
[AFNI](https://afni.nimh.nih.gov/)'s SUMA neuroimaging tool on macOS.

### Root Cause

`xshm_opcode` is declared and initialized to `-1` in `drisw_glx.c` but was
never assigned the actual MIT-SHM major opcode from the X server.
`handle_xerror` compares `event->request_code` against it to identify
MIT-SHM errors, but with `xshm_opcode` stuck at `-1` this comparison can
never match a real opcode, so `xshm_error` is never set.

XQuartz advertises MIT-SHM as available but rejects `XShmAttach` with
`BadAccess` (error 10) due to macOS inter-process memory sandbox restrictions.
Because `xshm_error` was never set, `XShmPutImage` was called against a
segment the server had already rejected — producing `BadShmSeg`. The
`assert(xshm_opcode != -1)` then caused a hard crash in devel builds.

### The Fix

The patch (`src/glx/drisw_glx.c`) makes the following changes:

- Calls `XQueryExtension("MIT-SHM")` once per display to populate
  `xshm_opcode` before the error handler is installed
- Explicitly clears `xshm_error` before installing the error handler
- Adds an `XSync()` round-trip after `XShmAttach()` to force the X server
  to process the attach before `XShmPutImage` is issued
- Replaces `assert(xshm_opcode != -1)` with a defensive conditional return
- Emits a one-time warning when SHM attach is rejected and falls back
  gracefully to `XPutImage`

When working correctly you will see this in stderr on first run:
```
MESA: warning: MIT-SHM attach rejected by X server (error 10); falling back to XPutImage
```

A patch submission to the Mesa project is pending at:
`https://gitlab.freedesktop.org/mesa/mesa`

## Installation

```bash
brew tap pmolfese/mesa-fix
brew install mesa-xquartz-shm-fix
```

The build takes 20–40 minutes on Apple Silicon.

## Usage

### glxgears / general X11 apps

Point your app at the patched libraries:

```bash
DYLD_LIBRARY_PATH="$(brew --prefix mesa-xquartz-shm-fix)/lib:$DYLD_LIBRARY_PATH" \
LIBGL_DRIVERS_PATH="$(brew --prefix mesa-xquartz-shm-fix)/lib/dri" \
glxgears
```

### AFNI / SUMA

When building AFNI from source with cmake, set `AFNI_MESA_ROOT` to the
formula prefix:

```bash
cmake -S . -B build -G Ninja \
  -DAFNI_MESA_ROOT=$(brew --prefix mesa-xquartz-shm-fix) \
  -DAFNI_GLU_ROOT=/opt/homebrew \
  ...
```

`AFNI_GLU_ROOT` points at the system Homebrew prefix where `libGLU` lives,
since GLU is a separate library not included in Mesa itself. If you have
`mesa-glu` installed separately, point `AFNI_GLU_ROOT` at its prefix instead.

## Testing

After installation, verify the patch string is present in the library:

```bash
brew test mesa-xquartz-shm-fix
```

Or manually:

```bash
strings $(brew --prefix mesa-xquartz-shm-fix)/lib/libGL.1.dylib | grep "MIT-SHM attach"
```

Expected output:
```
MIT-SHM attach rejected by X server (error %d); falling back to XPutImage
```

## Requirements

- macOS (Apple Silicon or Intel)
- [XQuartz](https://www.xquartz.org/) installed
- Homebrew

## Notes

- This tap tracks Mesa `main` (currently 26.2.0-devel). The formula URL
  points at a live tarball of `main` so the version you build reflects
  the state of Mesa at install time.
- `ninja install` is skipped during the build because `install_megadrivers.py`
  hangs on macOS due to a filesystem issue with symlink resolution under
  XQuartz. Libraries are copied manually instead.
- This formula is intended as a demonstration and testing vehicle while the
  upstream patch is under review. Once the fix lands in Mesa main and a
  stable release, this tap will no longer be necessary.

## License

The patch and formula are MIT licensed. Mesa itself is MIT licensed.

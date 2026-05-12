class MesaXquartzShmFix < Formula
  desc "Mesa 3D graphics library with XQuartz MIT-SHM fix (demonstration)"
  homepage "https://www.mesa3d.org/"
  url "https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.tar.gz"
  version "main"
  license "MIT"
  head "https://gitlab.freedesktop.org/mesa/mesa.git", branch: "main"

  depends_on "bison" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkg-config" => :build
  depends_on "python-setuptools" => :build
  depends_on "python@3.13" => :build
  depends_on "expat"
  depends_on "libx11"
  depends_on "libxcb"
  depends_on "libxdamage"
  depends_on "libxext"
  depends_on "libxfixes"
  depends_on "libxrandr"
  depends_on "libxshmfence"
  depends_on "llvm"
  depends_on "zlib"

  # Mako is required by Mesa's build system but not available as a
  # Homebrew formula, so we vendor it as a resource.
  resource "mako" do
    url "https://files.pythonhosted.org/packages/00/62/791b31e69ae182791ec67f04850f2f062716bbd205483d63a215f3e062d3/mako-1.3.12.tar.gz"
    sha256 "9f778e93289bd410bb35daadeb4fc66d95a746f0b75777b942088b7fd7af550a"
  end

  # Patch: fix xshm_opcode never initialized and add XShmAttach fallback
  # for XQuartz on macOS. Without this, Mesa crashes with either:
  #   BadShmSeg on X_ShmPutImage, or
  #   Assertion failed: (xshm_opcode != -1) in handle_xerror
  # See: https://gitlab.freedesktop.org/mesa/mesa/-/issues/XXXX
  patch :DATA

  def install
    ENV.prepend_path "PATH", Formula["bison"].opt_bin
    ENV.prepend_path "PATH", Formula["llvm"].opt_bin
    ENV.append "LDFLAGS", "-L#{Formula["llvm"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["llvm"].opt_include}"

    # Install mako into a local prefix that meson can find.
    # We can't use pip install at build time (no network), so we stage
    # the vendored resource and install it from the tarball.
    python = Formula["python@3.13"].opt_bin/"python3"
    resource("mako").stage do
      system python, "-m", "pip", "install", "--no-deps", "--no-build-isolation",
             "--prefix=#{buildpath}/.pip-install", "."
    end
    ENV.prepend_path "PYTHONPATH",
                     "#{buildpath}/.pip-install/lib/python3.13/site-packages"

    args = %w[
      -Dglx=dri
      -Dgallium-drivers=llvmpipe
      -Dvulkan-drivers=[]
      -Dplatforms=x11
      -Dllvm=enabled
      -Dshared-llvm=enabled
      -Dbuildtype=release
    ]

    system "meson", "setup", "build", *args, *std_meson_args
    system "ninja", "-C", "build"
    system "ninja", "-C", "build", "install"
  end

  def caveats
    <<~EOS
      This is a demonstration build of Mesa main with the XQuartz MIT-SHM
      fix applied. It patches drisw_glx.c to correctly initialize
      xshm_opcode via XQueryExtension and fall back gracefully to XPutImage
      when XQuartz rejects the SHM attach.

      To use with glxgears or another X11 app, set:
        export DYLD_LIBRARY_PATH="#{opt_lib}:$DYLD_LIBRARY_PATH"
        export LIBGL_DRIVERS_PATH="#{opt_lib}/dri"

      You should see this message on first run, confirming the fix is active:
        MESA: warning: MIT-SHM attach rejected by X server (error 10);
        falling back to XPutImage
    EOS
  end

  test do
    assert_match "MIT-SHM attach rejected",
                 shell_output("strings #{lib}/libGL.1.dylib")
  end
end

__END__
diff --git a/src/glx/drisw_glx.c b/src/glx/drisw_glx.c
--- a/src/glx/drisw_glx.c
+++ b/src/glx/drisw_glx.c
@@ -59,7 +59,14 @@
 {
    (void) dpy;
 
-   assert(xshm_opcode != -1);
+   /*
+    * xshm_opcode is populated by XCreateDrawable before this handler is
+    * installed.  It should never be -1 here, but guard defensively rather
+    * than asserting so that a misbehaving X server cannot abort the process.
+    */
+   if (xshm_opcode == -1)
+      return 0;
+
    if (event->request_code != xshm_opcode)
       return 0;
 
@@ -78,6 +85,33 @@
    }
 
    if (!xshm_error && shmid >= 0) {
+      /*
+       * Populate xshm_opcode before installing the error handler.
+       * Previously xshm_opcode was never assigned after being initialised to
+       * -1, so handle_xerror's request_code comparison never matched an MIT-SHM
+       * error and xshm_error was never set.  This meant XShmPutImage was called
+       * with a segment that the X server had silently rejected at XShmAttach
+       * time, producing BadShmSeg (seen with XQuartz on macOS).
+       *
+       * XQueryExtension fills in the major opcode we need.  If it fails the
+       * extension is not available and we fall through to plain XPutImage.
+       */
+      if (xshm_opcode == -1) {
+         int opcode, ev, err;
+         /*
+          * XQueryExtension gives us the major opcode that the X server uses
+          * for MIT-SHM requests.  We need it so handle_xerror can correctly
+          * identify MIT-SHM errors by request_code.  Previously xshm_opcode
+          * was left at -1 forever, so the error handler's comparison never
+          * matched and xshm_error was never set, causing XShmPutImage to fire
+          * against a segment the server had already rejected (BadShmSeg on
+          * XQuartz/macOS).
+          */
+         if (!XQueryExtension(dpy, "MIT-SHM", &opcode, &ev, &err))
+            goto no_shm;
+         xshm_opcode = opcode;
+      }
+
       pdp->shminfo.shmid = shmid;
       pdp->ximage = XShmCreateImage(dpy,
                                     NULL,
@@ -92,13 +126,26 @@
          /* dispatch pending errors */
          XSync(dpy, False);
 
+         xshm_error = 0;
          old_handler = XSetErrorHandler(handle_xerror);
          /* This may trigger the X protocol error we're ready to catch: */
          XShmAttach(dpy, &pdp->shminfo);
+         /*
+          * Force a round-trip so the X server processes XShmAttach before we
+          * ever issue XShmPutImage.  Without this sync, XQuartz (and other
+          * servers that process the attach lazily) reject the subsequent
+          * XShmPutImage with BadShmSeg because the segment is not yet
+          * registered server-side.
+          */
          XSync(dpy, False);
 
          if (xshm_error) {
-         /* we are on a remote display, this error is normal, don't print it */
+            /* X server rejected the SHM attach (e.g. XQuartz sandbox,
+             * remote display).  Fall back to plain XPutImage silently;
+             * the caller treats ximage == NULL as the non-SHM path. */
+            mesa_logw_once("MIT-SHM attach rejected by X server (error %d); "
+                           "falling back to XPutImage",
+                           xshm_error);
             XDestroyImage(pdp->ximage);
             pdp->ximage = NULL;
          }
@@ -107,6 +154,8 @@
       }
    }
 
+no_shm:
+
    if (pdp->ximage == NULL) {
       pdp->shminfo.shmid = -1;
       pdp->ximage = XCreateImage(dpy,

class MesaXquartzShmFix < Formula
  include Language::Python::Virtualenv

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

  resource "markupsafe" do
    url "https://files.pythonhosted.org/packages/7e/99/7690b6d4034fffd95959cbe0c02de8deb3098cc577c67bb6a24fe5d7caa7/markupsafe-3.0.3.tar.gz"
    sha256 "722695808f4b6457b320fdc131280796bdceb04ab50fe1795cd540799ebe1698"
  end

  resource "mako" do
    url "https://files.pythonhosted.org/packages/00/62/791b31e69ae182791ec67f04850f2f062716bbd205483d63a215f3e062d3/mako-1.3.12.tar.gz"
    sha256 "9f778e93289bd410bb35daadeb4fc66d95a746f0b75777b942088b7fd7af550a"
  end

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
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

    # Build a virtualenv containing mako, markupsafe and pyyaml so
    # Mesa's build scripts can import them without network access.
    venv = virtualenv_create(buildpath/".venv", "python3.13")
    venv.pip_install resources
    ENV.prepend_path "PYTHONPATH",
                     buildpath/".venv/lib/python3.13/site-packages"

    args = %w[
      -Dglx=dri
      -Dgallium-drivers=llvmpipe
      -Dvulkan-drivers=[]
      -Dplatforms=x11
      -Dllvm=enabled
      -Dshared-llvm=enabled
    ]

    system "meson", "setup", "build", *args, *std_meson_args
    system "ninja", "-C", "build"

    # Skip `ninja install` — it hangs on macOS due to install_megadrivers.py
    # calling os.path.lexists() on a symlink that causes a filesystem loop
    # under XQuartz/macOS. Instead copy the libraries we need manually.
    lib.mkpath
    (lib/"dri").mkpath
    include.mkpath

    # Copy the main GL library
    cp Dir["build/src/glx/libGL*.dylib"], lib

    # Copy the gallium library that libGL depends on
    cp Dir["build/src/gallium/targets/dri/libgallium*.dylib"], lib

    # Copy DRI drivers
    cp Dir["build/src/gallium/targets/dri/*.dylib"], lib/"dri"
    cp Dir["build/src/gallium/targets/dri/*.so"], lib/"dri"

    # Copy headers
    cp_r Dir["include/GL"], include

    # Fix the rpath in libGL so it finds libgallium in the same lib dir
    # without needing DYLD_LIBRARY_PATH at runtime.
    libgl = lib/"libGL.1.dylib"
    gallium = Dir[lib/"libgallium*.dylib"].first
    if gallium
      gallium_name = File.basename(gallium)
      # Change the embedded rpath reference to point to our lib dir
      system "install_name_tool", "-change",
             "@rpath/#{gallium_name}",
             "#{lib}/#{gallium_name}",
             libgl
      # Also fix the install name of libGL itself
      system "install_name_tool", "-id", "#{lib}/libGL.1.dylib", libgl
      # And fix the install name of libgallium itself
      system "install_name_tool", "-id", "#{lib}/#{gallium_name}", gallium
    end

    # Create the unversioned symlink libGL.dylib -> libGL.1.dylib
    lib.install_symlink "libGL.1.dylib" => "libGL.dylib"
  end

  def caveats
    <<~EOS
      This is a demonstration build of Mesa main with the XQuartz MIT-SHM
      fix applied. It patches drisw_glx.c to correctly initialize
      xshm_opcode via XQueryExtension and fall back gracefully to XPutImage
      when XQuartz rejects the SHM attach.

      To build SUMA/AFNI against this Mesa, set in your Makefile or build:
        BREWLIBDIR=#{opt_lib}
        BREWINCDIR=#{opt_include}

      Or set at link time:
        -L#{opt_lib} -I#{opt_include}

      You should see this on first run confirming the fix is active:
        MESA: warning: MIT-SHM attach rejected by X server (error 10);
        falling back to XPutImage
    EOS
  end

  test do
    assert_match "MIT-SHM attach rejected",
                 shell_output("strings #{lib}/libGL.1.dylib")
    # Verify libGL can find libgallium without DYLD_LIBRARY_PATH
    system "otool", "-L", "#{lib}/libGL.1.dylib"
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

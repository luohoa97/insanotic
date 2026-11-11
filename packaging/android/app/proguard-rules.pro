# SPDX-License-Identifier: GPL-3.0-or-later
#
# SDL's native code (libSDL2.so) calls these Java classes and methods by
# name through JNI, and libmain.so loads them the same way, so R8 must
# neither rename nor remove anything in them.
-keep class org.libsdl.app.** { *; }
-keep class org.insanotic.android.GameActivity { *; }
# the engine's HTTP(S) downloads (libcurl.c) call this class through JNI
-keep class org.insanotic.android.HttpFetch { *; }

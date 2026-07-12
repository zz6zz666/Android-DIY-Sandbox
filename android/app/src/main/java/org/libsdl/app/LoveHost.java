package org.libsdl.app;

import android.content.Context;
import android.util.Log;
import android.view.Surface;

/**
 * Hosts an embedded SDL/LÖVE instance that renders into a Flutter-managed
 * texture Surface (TextureRegistry.SurfaceProducer) instead of an on-screen
 * SurfaceView. This lets the game behave as a normal Flutter widget ("sticker
 * canvas") that composites with other Flutter widgets at any size/position.
 *
 * SDL cannot cleanly re-initialize within one process, so the instance is kept
 * alive for the app session and merely paused/resumed as the surface comes and
 * goes (widget shown/hidden, app background/foreground).
 */
public class LoveHost {
    private static final String TAG = "LoveHost";
    private static boolean sBooted = false;

    /** First-time boot of the embedded LÖVE engine into the given texture surface. */
    public static synchronized void start(Context host, Surface surface, int width, int height,
                                          String[] libraries, String mainSharedObject,
                                          String mainFunction, String[] arguments) {
        if (sBooted) {
            // Already running: just (re)attach the new surface and resume.
            resume(surface, width, height);
            return;
        }
        Log.v(TAG, "start(): booting embedded LÖVE (texture mode) " + width + "x" + height);

        for (String lib : libraries) {
            SDL.loadLibrary(lib, host);
        }
        SDLActivity.mBrokenLibraries = false;

        SDL.setupJNI();
        SDL.initialize();

        SDL.setContext(host);
        SDLActivity.mSingleton = null;
        SDLActivity.mSurface = null;               // no SurfaceView in texture mode
        SDLActivity.mIsEmbedded = true;
        SDLActivity.mHostActivity = host;
        SDLActivity.mEmbedMainLib = mainSharedObject;
        SDLActivity.mEmbedMainFunc = mainFunction;
        SDLActivity.mEmbedArgs = arguments != null ? arguments : new String[0];
        SDLActivity.mEmbedTextureSurface = surface;
        // Must be created on the UI thread (needs the main Looper).
        SDLActivity.mEmbedCommandHandler = new SDLActivity.SDLCommandHandler();
        SDLActivity.mSDLThread = null;
        SDLActivity.mSDLMainFinished = false;
        SDLActivity.mActivityCreated = true;

        SDLActivity.mClipboardHandler = new SDLClipboardHandler();
        SDLActivity.mHIDDeviceManager = HIDDeviceManager.acquire(host);

        SDLActivity.nativeSetNaturalOrientation(SDLActivity.getNaturalOrientation());
        SDLActivity.mCurrentRotation = SDLActivity.getCurrentRotation();
        SDLActivity.onNativeRotationChanged(SDLActivity.mCurrentRotation);
        try {
            SDLActivity.mCurrentLocale = host.getResources().getConfiguration().getLocales().get(0);
        } catch (Exception ignored) {
        }

        float density = host.getResources().getDisplayMetrics().density;
        SDLActivity.nativeSetScreenResolution(width, height, width, height, density, 60.0f);
        SDLActivity.onNativeResize();
        SDLActivity.onNativeSurfaceChanged();

        SDLActivity.mEmbedSurfaceReady = true;
        SDLActivity.mHasFocus = true;
        SDLActivity.mIsResumedCalled = true;
        SDLActivity.mNextNativeState = SDLActivity.NativeState.RESUMED;
        SDLActivity.handleNativeState();

        sBooted = true;
    }

    public static synchronized boolean isBooted() {
        return sBooted;
    }

    /** Resume rendering (widget shown / app resumed). Surface is left untouched. */
    public static synchronized void resume(Surface surface, int width, int height) {
        if (!sBooted) {
            return;
        }
        if (SDLActivity.mCurrentNativeState == SDLActivity.NativeState.RESUMED) {
            return; // already running
        }
        Log.v(TAG, "resume(): unblocking SDL thread");
        SDLActivity.mHasFocus = true;
        SDLActivity.mIsResumedCalled = true;
        SDLActivity.mNextNativeState = SDLActivity.NativeState.RESUMED;
        SDLActivity.handleNativeState();
    }

    /**
     * Suspend rendering (widget hidden / app backgrounded). We deliberately do NOT
     * destroy or swap the SDL surface here: that caused SDL to operate on a stale
     * ANativeWindow and crash. Instead we only pause the native state, which blocks
     * the SDL thread at its event pump — the engine stays in memory, idle.
     */
    public static synchronized void pause() {
        if (!sBooted) {
            return;
        }
        if (SDLActivity.mCurrentNativeState == SDLActivity.NativeState.PAUSED) {
            return; // already suspended
        }
        Log.v(TAG, "pause(): blocking SDL thread (surface kept)");
        SDLActivity.mNextNativeState = SDLActivity.NativeState.PAUSED;
        SDLActivity.mIsResumedCalled = false;
        SDLActivity.handleNativeState();
    }

    /** The texture was resized. */
    public static synchronized void resize(int width, int height) {
        if (!sBooted || !SDLActivity.mEmbedSurfaceReady) {
            return;
        }
        float density = 2.0f;
        try {
            density = SDLActivity.mHostActivity.getResources().getDisplayMetrics().density;
        } catch (Exception ignored) {
        }
        SDLActivity.nativeSetScreenResolution(width, height, width, height, density, 60.0f);
        SDLActivity.onNativeResize();
    }

    /** Forward a finger touch from Flutter. x/y are normalized (0..1). */
    public static void touch(int pointerId, int action, float x, float y, float pressure) {
        if (!sBooted) {
            return;
        }
        SDLActivity.onNativeTouch(0, pointerId, action, x, y, pressure);
    }

    /** Forward a keyboard key event from Flutter. keycode = Android KeyEvent keycode. */
    public static void keyDown(int keycode) {
        if (!sBooted) {
            return;
        }
        SDLActivity.onNativeKeyDown(keycode);
    }

    public static void keyUp(int keycode) {
        if (!sBooted) {
            return;
        }
        SDLActivity.onNativeKeyUp(keycode);
    }

    /** Forward text input from Flutter keyboard into SDL's text input system. */
    public static void textInput(String text) {
        if (!sBooted || text == null || text.isEmpty()) {
            return;
        }
        SDLInputConnection.nativeCommitText(text, 0);
    }
}

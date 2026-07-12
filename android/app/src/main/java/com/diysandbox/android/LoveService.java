package com.diysandbox.android;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.graphics.Rect;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;
import android.view.Surface;

import androidx.annotation.Keep;

import org.libsdl.app.LoveHost;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

/**
 * Hosts ONE love2d instance in its own process. Because SDL/love keeps global
 * state per process, running each canvas in a separate process is the only way
 * to get truly independent, simultaneously-running instances.
 *
 * The Service itself is the SDL "context": love's native code calls the @Keep
 * methods below on it via JNI.
 */
public abstract class LoveService extends Service {
    private static final String TAG = "LoveService";

    private ILoveCallback callback;

    private static final String[] LOVE_LIBS = {
        "c++_shared", "SDL3", "oboe", "openal", "luajit-love", "liblove", "love"
    };
    private static final String MAIN_SHARED_OBJECT = "liblove.so";
    private static final String MAIN_FUNCTION = "SDL_main";

    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean immersive;

    private final ILoveService.Stub binder = new ILoveService.Stub() {
        @Override
        public void start(Surface surface, int width, int height, String gamePath, String bridgeArg, ILoveCallback cb) {
            callback = cb;
            final String[] args;
            if (gamePath == null) {
                args = new String[0];
            } else if (bridgeArg != null && !bridgeArg.isEmpty()) {
                args = new String[]{gamePath, bridgeArg};
            } else {
                args = new String[]{gamePath};
            }
            main.post(() -> LoveHost.start(LoveService.this, surface, width, height,
                LOVE_LIBS, MAIN_SHARED_OBJECT, MAIN_FUNCTION, args));
        }

        @Override
        public void resize(int width, int height) {
            main.post(() -> LoveHost.resize(width, height));
        }

        @Override
        public void pauseGame() {
            main.post(LoveHost::pause);
        }

        @Override
        public void resumeGame(Surface surface) {
            main.post(() -> LoveHost.resume(surface, 0, 0));
        }

        @Override
        public void touch(int id, int action, float x, float y, float p) {
            LoveHost.touch(id, action, x, y, p);
        }

        @Override
        public void key(int keycode, boolean down) {
            if (down) LoveHost.keyDown(keycode); else LoveHost.keyUp(keycode);
        }

        @Override
        public void textInput(String text) {
            LoveHost.textInput(text);
        }

        @Override
        public void stop() {
            // SDL cannot be torn down cleanly in-process; stop the whole process.
            main.post(() -> {
                stopSelf();
                android.os.Process.killProcess(android.os.Process.myPid());
            });
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    // ================= love native @Keep bridge (called on this Service) =================

    @Keep
    public void vibrate(double seconds) {
        Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
        if (v != null) {
            long ms = (long) (seconds * 1000.);
            if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE));
            } else {
                v.vibrate(ms);
            }
        }
    }

    @Keep
    public boolean hasBackgroundMusic() {
        AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        return am != null && am.isMusicActive();
    }

    @Keep
    public float getDPIScale() {
        return getResources().getDisplayMetrics().density;
    }

    @Keep
    public Rect getSafeArea() {
        return null; // no window in a service; host manages insets
    }

    @Keep
    public String getCRequirePath() {
        ApplicationInfo ai = getApplicationInfo();
        if ((ai.flags & ApplicationInfo.FLAG_EXTRACT_NATIVE_LIBS) != 0) {
            return ai.nativeLibraryDir + "/?.so";
        }
        return ai.sourceDir + "!/lib/" + Build.SUPPORTED_ABIS[0] + "/?.so";
    }

    @Keep
    public void setImmersiveMode(boolean enable) {
        immersive = enable;
    }

    @Keep
    public boolean getImmersiveMode() {
        return immersive;
    }

    @Keep
    public boolean hasRecordAudioPermission() {
        return checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED;
    }

    @Keep
    public void requestRecordAudioPermission() {
        if (callback != null) {
            try {
                callback.requestRecordAudioPermission();
            } catch (android.os.RemoteException e) {
                Log.w(TAG, "requestRecordAudioPermission callback failed", e);
            }
        } else {
            Log.w(TAG, "requestRecordAudioPermission ignored (no callback set)");
        }
    }

    @Keep
    public void showRecordingAudioPermissionMissingDialog() {
        Log.w(TAG, "audio recording requested without permission");
    }

    @Keep
    public String[] buildFileTree() {
        HashMap<String, Boolean> map = buildFileTree(getAssets(), "", new HashMap<>());
        ArrayList<String> result = new ArrayList<>();
        for (Map.Entry<String, Boolean> e : map.entrySet()) {
            result.add((e.getValue() ? "d" : "f") + e.getKey());
        }
        return result.toArray(new String[0]);
    }

    private HashMap<String, Boolean> buildFileTree(AssetManager am, String dir, HashMap<String, Boolean> map) {
        String stripped = dir.endsWith("/") ? dir.substring(0, dir.length() - 1) : dir;
        try {
            InputStream test = am.open(stripped);
            test.close();
            map.put(stripped, false);
        } catch (FileNotFoundException e) {
            String[] list = null;
            try {
                list = am.list(stripped);
            } catch (IOException ignored) {
            }
            map.put(dir, true);
            if (!stripped.equals(dir)) map.put(stripped, true);
            if (list != null) {
                for (String path : list) buildFileTree(am, dir + path + "/", map);
            }
        } catch (IOException ignored) {
        }
        return map;
    }
}

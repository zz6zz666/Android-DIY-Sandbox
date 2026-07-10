package com.astrbot.astrbot_android;

import android.app.Activity;
import android.content.Context;
import android.util.Log;
import android.view.Surface;

import androidx.annotation.NonNull;

import org.libsdl.app.LoveHost;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

/**
 * Bridges Flutter and the embedded LÖVE engine that renders into a Flutter
 * texture (SurfaceProducer). The Dart side shows a Texture(textureId) widget
 * that composites like any other Flutter widget.
 *
 * LÖVE/SDL is single-instance per process, so one SurfaceProducer is created
 * and kept alive for the app session; the widget being shown/hidden simply
 * resumes/pauses rendering.
 */
public class LoveTextureController implements MethodChannel.MethodCallHandler {
    private static final String TAG = "LoveTextureController";
    public static final String CHANNEL = "love_texture_channel";

    private static final String[] LOVE_LIBS = {
        "c++_shared", "SDL3", "oboe", "openal", "luajit-love", "liblove", "love"
    };
    private static final String MAIN_SHARED_OBJECT = "liblove.so";
    private static final String MAIN_FUNCTION = "SDL_main";

    private final Activity activity;
    private final TextureRegistry textureRegistry;

    private TextureRegistry.SurfaceProducer producer;
    private int width, height;

    public LoveTextureController(@NonNull Activity activity, @NonNull TextureRegistry textureRegistry) {
        this.activity = activity;
        this.textureRegistry = textureRegistry;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "start": {
                int w = argInt(call, "width", 1);
                int h = argInt(call, "height", 1);
                String path = call.argument("path");
                if (path == null || path.isEmpty()) {
                    path = extractBundledGame();
                }
                long id = start(w, h, path);
                result.success(id);
                break;
            }
            case "resize": {
                width = argInt(call, "width", width);
                height = argInt(call, "height", height);
                if (producer != null) {
                    producer.setSize(width, height);
                    LoveHost.resize(width, height);
                }
                result.success(null);
                break;
            }
            case "resume": {
                if (producer != null) {
                    LoveHost.resume(producer.getSurface(), width, height);
                }
                result.success(null);
                break;
            }
            case "pause": {
                LoveHost.pause();
                result.success(null);
                break;
            }
            case "touch": {
                int pid = argInt(call, "id", 0);
                int action = argInt(call, "action", 0);
                double x = call.argument("x") != null ? ((Number) call.argument("x")).doubleValue() : 0;
                double y = call.argument("y") != null ? ((Number) call.argument("y")).doubleValue() : 0;
                double p = call.argument("p") != null ? ((Number) call.argument("p")).doubleValue() : 1.0;
                LoveHost.touch(pid, action, (float) x, (float) y, (float) p);
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private long start(int w, int h, String path) {
        this.width = Math.max(1, w);
        this.height = Math.max(1, h);

        if (producer == null) {
            producer = textureRegistry.createSurfaceProducer();
        }
        producer.setSize(width, height);

        Surface surface = producer.getSurface();
        LoveHost.start(activity, surface, width, height, LOVE_LIBS, MAIN_SHARED_OBJECT, MAIN_FUNCTION,
            path != null ? new String[]{path} : new String[0]);

        // NOTE: intentionally NO SurfaceProducer.Callback here. Pause/resume is driven
        // solely from the Dart side (page visibility + app lifecycle) to avoid two
        // sources racing to attach/detach the surface (which crashed SDL).
        return producer.id();
    }

    private int argInt(MethodCall call, String key, int def) {
        Object v = call.argument(key);
        return (v instanceof Number) ? ((Number) v).intValue() : def;
    }

    private String extractBundledGame() {
        try {
            File out = new File(activity.getFilesDir(), "sample.love");
            try (InputStream in = activity.getAssets().open("game.love");
                 OutputStream os = new FileOutputStream(out)) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            }
            return out.getAbsolutePath();
        } catch (Exception e) {
            Log.e(TAG, "failed to extract bundled game", e);
            return null;
        }
    }
}

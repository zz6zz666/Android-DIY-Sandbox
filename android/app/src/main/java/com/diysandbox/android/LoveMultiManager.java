package com.diysandbox.android;

import android.Manifest;
import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.graphics.PixelFormat;
import android.media.ImageReader;
import android.os.Build;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;
import android.view.Surface;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import org.libsdl.app.LoveHost;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

/**
 * Manages multiple love2d canvases, each in its own process. One manager per
 * Flutter engine; canvases are allocated slots 0..MAX-1 on demand.
 *
 * Method-channel key routing: every call carries a mandatory "canvasId" (int).
 */
public class LoveMultiManager implements MethodChannel.MethodCallHandler {
    private static final String TAG = "LoveMultiManager";
    public static final String CHANNEL = "love_texture_channel";

    private static final int MAX_SLOTS = 10;
    private static final Class<?>[] SLOT_CLASSES = {
        LoveService0.class, LoveService1.class, LoveService2.class, LoveService3.class,
        LoveService4.class, LoveService5.class, LoveService6.class, LoveService7.class,
        LoveService8.class, LoveService9.class
    };

    private final Activity activity;
    private final TextureRegistry textureRegistry;
    private final Slot[] slots = new Slot[MAX_SLOTS];

    private static class Slot {
        TextureRegistry.SurfaceProducer producer;
        ILoveService binder;
        ServiceConnection conn;
        int width, height;
        boolean started;
        boolean connecting;
        boolean headless;
        ImageReader headlessReader;
        Surface headlessSurface;
    }

    public LoveMultiManager(@NonNull Activity activity, @NonNull TextureRegistry textureRegistry) {
        this.activity = activity;
        this.textureRegistry = textureRegistry;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        int cid = argInt(call, "canvasId", -1);
        if (cid < 0 || cid >= MAX_SLOTS) {
            result.error("INVALID_ID", "canvasId must be 0.." + (MAX_SLOTS - 1), null);
            return;
        }
        switch (call.method) {
            case "start": {
                int w = argInt(call, "width", 1);
                int h = argInt(call, "height", 1);
                String path = call.argument("path");
                String bridge = call.argument("bridge");
                start(cid, w, h, path, bridge, result);
                break;
            }
            case "resize": {
                Slot slot = slots[cid];
                if (slot != null) {
                    slot.width = argInt(call, "width", slot.width);
                    slot.height = argInt(call, "height", slot.height);
                    if (slot.producer != null) slot.producer.setSize(slot.width, slot.height);
                    if (slot.binder != null) callBinder(slot.binder, binder -> binder.resize(slot.width, slot.height));
                }
                result.success(null);
                break;
            }
            case "resume": {
                Slot slot = slots[cid];
                if (slot != null && slot.binder != null) {
                    callBinder(slot.binder, binder -> {
                        if (slot.producer != null) binder.resumeGame(slot.producer.getSurface());
                    });
                }
                result.success(null);
                break;
            }
            case "pause": {
                Slot slot = slots[cid];
                if (slot != null && slot.binder != null) callBinder(slot.binder, ILoveService::pauseGame);
                result.success(null);
                break;
            }
            case "destroy": {
                // 彻底销毁该画布: 杀掉其独立进程 (SDL 无法在进程内重新初始化),
                // 释放纹理并清空槽位, 下次 start 将全新启动一个进程 → 从头运行。
                destroy(cid);
                result.success(null);
                break;
            }
            case "touch": {
                Slot slot = slots[cid];
                if (slot != null && slot.binder != null) {
                    int pid = argInt(call, "id", 0);
                    int action = argInt(call, "action", 0);
                    float x = call.argument("x") != null ? ((Number) call.argument("x")).floatValue() : 0f;
                    float y = call.argument("y") != null ? ((Number) call.argument("y")).floatValue() : 0f;
                    float p = call.argument("p") != null ? ((Number) call.argument("p")).floatValue() : 1f;
                    callBinder(slot.binder, binder -> binder.touch(pid, action, x, y, p));
                }
                result.success(null);
                break;
            }
            case "key": {
                Slot slot = slots[cid];
                if (slot != null && slot.binder != null) {
                    int keycode = argInt(call, "keycode", 0);
                    boolean down = Boolean.TRUE.equals(call.argument("down"));
                    callBinder(slot.binder, binder -> binder.key(keycode, down));
                }
                result.success(null);
                break;
            }
            case "textInput": {
                Slot slot = slots[cid];
                if (slot != null && slot.binder != null) {
                    String text = call.argument("text");
                    if (text != null && !text.isEmpty()) {
                        callBinder(slot.binder, binder -> binder.textInput(text));
                    }
                }
                result.success(null);
                break;
            }
            case "startHeadless": {
                String path = call.argument("path");
                String bridge = call.argument("bridge");
                startHeadless(cid, path, bridge, result);
                break;
            }
            case "destroyHeadless": {
                destroyHeadless(cid, result);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private ILoveCallback createRecordPermissionCallback(int cid) {
        return new ILoveCallback.Stub() {
            @Override
            public void requestRecordAudioPermission() {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
                final String perm = Manifest.permission.RECORD_AUDIO;
                if (ContextCompat.checkSelfPermission(activity, perm) == PackageManager.PERMISSION_GRANTED)
                    return;
                activity.runOnUiThread(() ->
                    ActivityCompat.requestPermissions(activity, new String[]{perm}, 1000 + cid));
            }
        };
    }

    private void start(int cid, int w, int h, String path, String bridge, MethodChannel.Result result) {
        if (slots[cid] != null) {
            // Already allocated (a fresh widget is re-mounting the same canvas).
            // Resize if needed, then RESUME rendering onto the current surface:
            // the previous widget's dispose() paused the (still-alive) engine, so
            // without an explicit resume here the re-mounted canvas stays frozen.
            final Slot slot = slots[cid];
            if (w != slot.width || h != slot.height) {
                slot.width = w;
                slot.height = h;
                if (slot.producer != null) slot.producer.setSize(w, h);
                if (slot.binder != null) callBinder(slot.binder, b -> b.resize(w, h));
            }
            if (slot.binder != null && slot.producer != null) {
                callBinder(slot.binder, b -> b.resumeGame(slot.producer.getSurface()));
            }
            result.success(slot.producer.id());
            return;
        }

        final Slot slot = new Slot();
        slot.width = w;
        slot.height = h;
        slot.producer = textureRegistry.createSurfaceProducer();
        slot.producer.setSize(w, h);
        slots[cid] = slot;
        final long texId = slot.producer.id();
        slot.connecting = true;

        final ILoveCallback callback = createRecordPermissionCallback(cid);

        Intent intent = new Intent(activity, SLOT_CLASSES[cid]);
        ServiceConnection conn = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                slot.connecting = false;
                slot.binder = ILoveService.Stub.asInterface(service);
                try {
                    slot.binder.start(slot.producer.getSurface(), slot.width, slot.height, path, bridge, callback);
                    slot.started = true;
                } catch (RemoteException e) {
                    Log.e(TAG, "start service call failed for canvas " + cid, e);
                }
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                slot.binder = null;
            }
        };
        slot.conn = conn;
        activity.bindService(intent, conn, Context.BIND_AUTO_CREATE);

        result.success(texId);
    }

    /** 彻底销毁一个画布槽位: 杀进程 + 解绑 + 释放纹理, 使下次 start 全新启动。 */
    private void destroy(int cid) {
        Slot slot = slots[cid];
        if (slot == null) return;
        slots[cid] = null;
        // 先请求服务停止 (stop() 内部会 killProcess, 保证 SDL 全新初始化)。
        if (slot.binder != null) {
            callBinder(slot.binder, ILoveService::stop);
        }
        // 解绑我们这一侧的连接。
        if (slot.conn != null) {
            try {
                activity.unbindService(slot.conn);
            } catch (IllegalArgumentException ignored) {
            }
        }
        // 释放 Flutter 纹理。
        if (slot.producer != null) {
            try {
                slot.producer.release();
            } catch (Exception ignored) {
            }
        }
    }

    /** 启动 headless love 进程 (无渲染 Texture, 纯音频等后台用途)。 */
    private void startHeadless(int cid, String path, String bridge, MethodChannel.Result result) {
        if (slots[cid] != null) {
            final Slot slot = slots[cid];
            if (slot.producer != null) {
                result.error("SLOT_OCCUPIED", "canvas " + cid + " 已被可视画布占用", null);
                return;
            }
            if (slot.binder != null && slot.started) {
                result.success(null);
                return;
            }
        }

        final Slot slot = new Slot();
        slot.headless = true;
        slot.width = 32;
        slot.height = 32;
        slot.headlessReader = ImageReader.newInstance(32, 32, PixelFormat.RGBA_8888, 2);
        slot.headlessSurface = slot.headlessReader.getSurface();
        slots[cid] = slot;
        slot.connecting = true;

        Intent intent = new Intent(activity, SLOT_CLASSES[cid]);
        ServiceConnection conn = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                slot.connecting = false;
                slot.binder = ILoveService.Stub.asInterface(service);
                try {
                    slot.binder.start(slot.headlessSurface, slot.width, slot.height, path, bridge, createRecordPermissionCallback(cid));
                    slot.started = true;
                } catch (RemoteException e) {
                    Log.e(TAG, "startHeadless service call failed for canvas " + cid, e);
                }
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                slot.binder = null;
            }
        };
        slot.conn = conn;
        activity.bindService(intent, conn, Context.BIND_AUTO_CREATE);

        result.success(null);
    }

    private void destroyHeadless(int cid, MethodChannel.Result result) {
        Slot slot = slots[cid];
        if (slot == null || !slot.headless) {
            result.success(null);
            return;
        }
        slots[cid] = null;
        if (slot.binder != null) {
            callBinder(slot.binder, ILoveService::stop);
        }
        if (slot.conn != null) {
            try {
                activity.unbindService(slot.conn);
            } catch (IllegalArgumentException ignored) {
            }
        }
        if (slot.headlessSurface != null) {
            slot.headlessSurface.release();
        }
        if (slot.headlessReader != null) {
            slot.headlessReader.close();
        }
        result.success(null);
    }

    private void callBinder(ILoveService binder, BinderCall block) {
        try {
            block.call(binder);
        } catch (RemoteException e) {
            Log.e(TAG, "binder call failed", e);
        }
    }

    private interface BinderCall {
        void call(ILoveService binder) throws RemoteException;
    }

    private int argInt(MethodCall call, String key, int def) {
        Object v = call.argument(key);
        return (v instanceof Number) ? ((Number) v).intValue() : def;
    }
}

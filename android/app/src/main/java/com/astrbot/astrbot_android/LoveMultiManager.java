package com.astrbot.astrbot_android;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;
import android.view.Surface;

import androidx.annotation.NonNull;

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

    private static final int MAX_SLOTS = 4;
    private static final Class<?>[] SLOT_CLASSES = {
        LoveService0.class, LoveService1.class, LoveService2.class, LoveService3.class
    };

    private final Activity activity;
    private final TextureRegistry textureRegistry;
    private final Slot[] slots = new Slot[MAX_SLOTS];

    private static class Slot {
        TextureRegistry.SurfaceProducer producer;
        ILoveService binder;
        int width, height;
        boolean started;
        boolean connecting;
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
                start(cid, w, h, path, result);
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
            default:
                result.notImplemented();
        }
    }

    private void start(int cid, int w, int h, String path, MethodChannel.Result result) {
        if (slots[cid] != null) {
            // Already allocated: resize if needed.
            if (w != slots[cid].width || h != slots[cid].height) {
                slots[cid].width = w;
                slots[cid].height = h;
                slots[cid].producer.setSize(w, h);
                if (slots[cid].binder != null) callBinder(slots[cid].binder, b -> b.resize(w, h));
            }
            result.success(slots[cid].producer.id());
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

        Intent intent = new Intent(activity, SLOT_CLASSES[cid]);
        activity.bindService(intent, new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                slot.connecting = false;
                slot.binder = ILoveService.Stub.asInterface(service);
                try {
                    slot.binder.start(slot.producer.getSurface(), slot.width, slot.height, path);
                    slot.started = true;
                } catch (RemoteException e) {
                    Log.e(TAG, "start service call failed for canvas " + cid, e);
                }
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
                slot.binder = null;
            }
        }, Context.BIND_AUTO_CREATE);

        result.success(texId);
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

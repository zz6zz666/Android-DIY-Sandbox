package com.astrbot.astrbot_android;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.graphics.Rect;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.DisplayCutout;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.widget.Toast;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.fragment.app.FragmentActivity;
import androidx.fragment.app.FragmentManager;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterFragment;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.GeneratedPluginRegistrant;

public class MainActivity extends FragmentActivity {
    FlutterFragment flutterFragment;
    private static final String TAG_FLUTTER_FRAGMENT = "flutter_fragment";
    Context mContext;
    FragmentManager fragmentManager = getSupportFragmentManager();

    // 文件选择器相关
    private static final int FILE_CHOOSER_REQUEST_CODE = 1;
    private ValueCallback<Uri[]> filePathCallback;

    // 双击返回退出相关
    private boolean doubleBackToExitPressedOnce = false;
    private static final int DOUBLE_BACK_INTERVAL = 2000; // 2秒内连续按返回键

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mContext = this;
        setContentView(com.astrbot.astrbot_android.R.layout.my_activity_layout);

        flutterFragment = (FlutterFragment) fragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT);
        FlutterEngine flutterEngine = new FlutterEngine(this, null, false);
        flutterEngine.getDartExecutor().executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault());
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "astrbot_channel").setMethodCallHandler((call, result) -> {
            if ("lib_path".equals(call.method)) {
                result.success(mContext.getApplicationContext().getApplicationInfo().nativeLibraryDir);
            } else {
                result.notImplemented();
            }
        });
        GeneratedPluginRegistrant.registerWith(flutterEngine);
        // LÖVE (love2d) texture bridge: renders the game into a Flutter texture.
        MethodChannel loveChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), LoveMultiManager.CHANNEL);
        loveChannel.setMethodCallHandler(
                new LoveMultiManager(this, flutterEngine.getRenderer()));
        // 系统通知桥: Lua host.notify / host.cancel_notify 由此发送。
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "astr_notify")
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "notify": {
                            int id = call.argument("id") != null
                                    ? ((Number) call.argument("id")).intValue() : 1;
                            String title = call.argument("title");
                            String body = call.argument("body");
                            String channel = call.argument("channel");
                            Boolean ongoing = call.argument("ongoing");
                            postNotification(id, title, body, channel,
                                    ongoing != null && ongoing);
                            result.success(id);
                            break;
                        }
                        case "cancel": {
                            int id = call.argument("id") != null
                                    ? ((Number) call.argument("id")).intValue() : 1;
                            NotificationManagerCompat.from(mContext).cancel(id);
                            result.success(null);
                            break;
                        }
                        default:
                            result.notImplemented();
                    }
                });
        FlutterEngineCache.getInstance().put("my_engine_id", flutterEngine);
        if (flutterFragment == null) {
            flutterFragment = FlutterFragment.withCachedEngine("my_engine_id").build();
        }
        fragmentManager
                .beginTransaction()
                .add(com.astrbot.astrbot_android.R.id.fl_container, flutterFragment, TAG_FLUTTER_FRAGMENT)
                .commit();
    }


    @Override
    public void onPostResume() {
        super.onPostResume();
        flutterFragment.onPostResume();
    }

    private void postNotification(int id, String title, String body, String channelId,
                                  boolean ongoing) {
        if (channelId == null || channelId.isEmpty()) channelId = "astrbot_lua_notify";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm =
                    (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) {
                NotificationChannel ch = new NotificationChannel(
                        channelId, "应用通知", NotificationManager.IMPORTANCE_DEFAULT);
                nm.createNotificationChannel(ch);
            }
        }
        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (open != null) {
            open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        } else {
            open = new Intent();
        }
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pi = PendingIntent.getActivity(this, id, open, piFlags);
        NotificationCompat.Builder b = new NotificationCompat.Builder(this, channelId)
                .setSmallIcon(getApplicationInfo().icon)
                .setContentTitle(title != null ? title : "")
                .setContentText(body != null ? body : "")
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body != null ? body : ""))
                .setAutoCancel(!ongoing)
                .setOngoing(ongoing)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setContentIntent(pi);
        try {
            NotificationManagerCompat.from(this).notify(id, b.build());
        } catch (SecurityException e) {
            Log.w("MainActivity", "notify denied (no POST_NOTIFICATIONS permission): " + e);
        }
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        flutterFragment.onNewIntent(intent);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        // 处理文件选择器返回的结果
        if (requestCode == FILE_CHOOSER_REQUEST_CODE) {
            if (filePathCallback == null) {
                return;
            }

            Uri[] results = null;
            if (resultCode == Activity.RESULT_OK && data != null) {
                String dataString = data.getDataString();
                if (dataString != null) {
                    results = new Uri[]{Uri.parse(dataString)};
                } else if (data.getClipData() != null) {
                    // 处理多文件选择
                    int count = data.getClipData().getItemCount();
                    results = new Uri[count];
                    for (int i = 0; i < count; i++) {
                        results[i] = data.getClipData().getItemAt(i).getUri();
                    }
                }
            }

            filePathCallback.onReceiveValue(results);
            filePathCallback = null;
        }

        // 传递给 FlutterFragment
        flutterFragment.onActivityResult(requestCode, resultCode, data);
    }

    // 用于从 Flutter 端调用的方法，触发文件选择器
    public void openFileChooser(ValueCallback<Uri[]> callback) {
        filePathCallback = callback;

        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);

        Intent chooserIntent = Intent.createChooser(intent, "选择文件");
        startActivityForResult(chooserIntent, FILE_CHOOSER_REQUEST_CODE);
    }

    @Override
    public void onBackPressed() {
        // 实现双击返回退出到桌面，但不传递给Flutter层
        if (doubleBackToExitPressedOnce) {
            // 第二次按返回键，移动到后台（返回桌面）
            moveTaskToBack(true);
            return;
        }

        // 第一次按返回键，显示提示
        this.doubleBackToExitPressedOnce = true;
        Toast.makeText(this, "再按一次返回桌面", Toast.LENGTH_SHORT).show();

        // 2秒后重置标志
        new Handler().postDelayed(() -> doubleBackToExitPressedOnce = false, DOUBLE_BACK_INTERVAL);

        // 不调用 super.onBackPressed() 和 flutterFragment.onBackPressed()
        // 确保返回事件不会传递给 Flutter 层
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode,
            @NonNull String[] permissions,
            @NonNull int[] grantResults
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        flutterFragment.onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults
        );
    }

    @Override
    public void onUserLeaveHint() {
        flutterFragment.onUserLeaveHint();
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        flutterFragment.onTrimMemory(level);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
    }

    // ==================================================================
    // LÖVE (love2d) native bridge methods.
    // love's native code (love::android::*) calls these via JNI on the
    // current Activity (SDL.getContext()), which is this MainActivity when a
    // game runs embedded in a Flutter texture. Mirrors love's expected @Keep API.
    // ==================================================================

    private Vibrator loveVibrator;
    private boolean loveImmersive;

    @Keep
    public void vibrate(double seconds) {
        if (loveVibrator == null) {
            loveVibrator = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
        }
        if (loveVibrator != null) {
            long duration = (long) (seconds * 1000.);
            if (Build.VERSION.SDK_INT >= 26) {
                loveVibrator.vibrate(VibrationEffect.createOneShot(duration, VibrationEffect.DEFAULT_AMPLITUDE));
            } else {
                loveVibrator.vibrate(duration);
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
        // Embedded in a bounded region: the host manages insets, so no extra safe area.
        if (Build.VERSION.SDK_INT >= 28 && getWindow() != null
                && getWindow().getDecorView().getRootWindowInsets() != null) {
            DisplayCutout cutout = getWindow().getDecorView().getRootWindowInsets().getDisplayCutout();
            if (cutout != null && loveImmersive) {
                Rect rect = new Rect();
                rect.set(cutout.getSafeInsetLeft(), cutout.getSafeInsetTop(),
                        cutout.getSafeInsetRight(), cutout.getSafeInsetBottom());
                return rect;
            }
        }
        return null;
    }

    @Keep
    public String getCRequirePath() {
        ApplicationInfo appInfo = getApplicationInfo();
        if ((appInfo.flags & ApplicationInfo.FLAG_EXTRACT_NATIVE_LIBS) != 0) {
            return appInfo.nativeLibraryDir + "/?.so";
        }
        String abi = Build.SUPPORTED_ABIS[0];
        return appInfo.sourceDir + "!/lib/" + abi + "/?.so";
    }

    @Keep
    public void setImmersiveMode(boolean enable) {
        // Do not alter the host window when embedded; just remember the flag.
        loveImmersive = enable;
    }

    @Keep
    public boolean getImmersiveMode() {
        return loveImmersive;
    }

    @Keep
    public boolean hasRecordAudioPermission() {
        return ActivityCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    @Keep
    public void requestRecordAudioPermission() {
        if (hasRecordAudioPermission()) {
            return;
        }
        runOnUiThread(() -> ActivityCompat.requestPermissions(this,
                new String[]{android.Manifest.permission.RECORD_AUDIO}, 3));
    }

    @Keep
    public void showRecordingAudioPermissionMissingDialog() {
        Log.w("MainActivity", "LÖVE requested audio recording without permission");
    }

    @Keep
    public String[] buildFileTree() {
        HashMap<String, Boolean> map = buildFileTree(getAssets(), "", new HashMap<>());
        ArrayList<String> result = new ArrayList<>();
        for (Map.Entry<String, Boolean> data : map.entrySet()) {
            result.add((data.getValue() ? "d" : "f") + data.getKey());
        }
        return result.toArray(new String[0]);
    }

    private HashMap<String, Boolean> buildFileTree(AssetManager assetManager, String dir, HashMap<String, Boolean> map) {
        String strippedDir = dir.endsWith("/") ? dir.substring(0, dir.length() - 1) : dir;
        try {
            InputStream test = assetManager.open(strippedDir);
            test.close();
            map.put(strippedDir, false);
        } catch (FileNotFoundException e) {
            String[] list = null;
            try {
                list = assetManager.list(strippedDir);
            } catch (IOException ignored) {
            }
            map.put(dir, true);
            if (!strippedDir.equals(dir)) {
                map.put(strippedDir, true);
            }
            if (list != null) {
                for (String path : list) {
                    buildFileTree(assetManager, dir + path + "/", map);
                }
            }
        } catch (IOException ignored) {
        }
        return map;
    }

}

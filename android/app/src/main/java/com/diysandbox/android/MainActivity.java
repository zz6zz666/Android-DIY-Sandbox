package com.diysandbox.android;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.ComponentName;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
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
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.fragment.app.FragmentActivity;
import androidx.fragment.app.FragmentManager;

import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import androidx.media.session.MediaButtonReceiver;

import com.norman.webviewup.lib.UpgradeCallback;
import com.norman.webviewup.lib.WebViewUpgrade;
import com.norman.webviewup.lib.source.UpgradeAssetSource;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterFragment;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.GeneratedPluginRegistrant;

public class MainActivity extends FragmentActivity implements UpgradeCallback {
    private static final String TAG = "DiySandboxChromium";
    private static final String BUNDLED_WEBVIEW_ASSET =
            "134.0.6998.39_min26_arm64.apk";
    private static final String BUNDLED_WEBVIEW_VERSION = "134.0.6998.39";

    FlutterFragment flutterFragment;
    private static final String TAG_FLUTTER_FRAGMENT = "flutter_fragment";
    Context mContext;
    FragmentManager fragmentManager = getSupportFragmentManager();

    // 文件选择器相关
    private static final int FILE_CHOOSER_REQUEST_CODE = 1;
    private ValueCallback<Uri[]> filePathCallback;

    // MediaSession (系统媒体控件)
    private MediaSessionCompat mediaSession;
    private static final String MEDIA_CHANNEL_ID = "sandbox_media_session";
    private static final int MEDIA_NOTIFY_ID = 2000;

    // 双击返回退出相关
    private boolean doubleBackToExitPressedOnce = false;
    private static final int DOUBLE_BACK_INTERVAL = 2000; // 2秒内连续按返回键
    private ProgressBar kernelProgressBar;
    private TextView kernelStatusText;
    private boolean flutterAttached = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        mContext = this;
        setContentView(com.diysandbox.android.R.layout.my_activity_layout);
        hideNavigationBar();
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            Window window = getWindow();
            if (window != null && window.getDecorView() != null) {
                window.getDecorView().setOnSystemUiVisibilityChangeListener(visibility -> {
                    if ((visibility & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0) {
                        new Handler().postDelayed(this::hideNavigationBar, 500);
                    }
                });
            }
        }

        if (BuildConfig.USE_BUNDLED_CHROMIUM) {
            initializeBundledWebView();
        } else {
            initializeFlutter();
        }
    }

    private void initializeBundledWebView() {
        showKernelLoadingUi();
        WebViewUpgrade.addUpgradeCallback(this);

        if (WebViewUpgrade.isCompleted()) {
            onUpgradeComplete();
            return;
        }

        try {
            UpgradeAssetSource source = new UpgradeAssetSource(
                    getApplicationContext(),
                    BUNDLED_WEBVIEW_ASSET,
                    BUNDLED_WEBVIEW_VERSION
            );
            WebViewUpgrade.upgrade(source);
        } catch (Throwable throwable) {
            onUpgradeError(throwable);
        }
    }

    private void initializeFlutter() {
        if (flutterAttached || isFinishing() || isDestroyed()) {
            return;
        }
        flutterAttached = true;
        flutterFragment = (FlutterFragment) fragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT);
        FlutterEngine flutterEngine = new FlutterEngine(this, null, false);
        flutterEngine.getDartExecutor().executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault());
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "sandbox_channel").setMethodCallHandler((call, result) -> {
            if ("lib_path".equals(call.method)) {
                result.success(mContext.getApplicationContext().getApplicationInfo().nativeLibraryDir);
            } else if ("build_flavor".equals(call.method)) {
                result.success(BuildConfig.USE_BUNDLED_CHROMIUM ? "chromium" : "normal");
            } else if ("webview_kernel_info".equals(call.method)) {
                boolean bundled = WebViewUpgrade.isCompleted();
                String packageName = bundled
                        ? WebViewUpgrade.getUpgradeWebViewPackageName()
                        : WebViewUpgrade.getSystemWebViewPackageName();
                String version = bundled
                        ? WebViewUpgrade.getUpgradeWebViewVersion()
                        : WebViewUpgrade.getSystemWebViewPackageVersion();
                Map<String, Object> info = new HashMap<>();
                info.put("source", bundled ? "bundled" : "system");
                info.put("packageName", packageName == null ? "" : packageName);
                info.put("version", version == null ? "" : version);
                result.success(info);
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
        // 系统媒体会话 (通知栏播放控件)
        MethodChannel mediaSessionCh = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "media_session");
        mediaSessionCh.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "init": {
                    initMediaSession(mediaSessionCh);
                    result.success(null);
                    break;
                }
                case "updateMetadata": {
                    String title = call.argument("title");
                    String artist = call.argument("artist");
                    String album = call.argument("album");
                    int duration = call.argument("duration") != null
                            ? ((Number) call.argument("duration")).intValue() : 0;
                    String artwork = call.argument("artwork");
                    updateMediaSessionMetadata(title, artist, album, duration);
                    if (artwork != null && !artwork.isEmpty()) {
                        updateMediaSessionArtwork(artwork);
                    }
                    result.success(null);
                    break;
                }
                case "updatePlaybackState": {
                    String state = call.argument("state");
                    int position = call.argument("position") != null
                            ? ((Number) call.argument("position")).intValue() : 0;
                    updateMediaSessionPlaybackState(state, position);
                    result.success(null);
                    break;
                }
                case "release": {
                    releaseMediaSession();
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
                .add(com.diysandbox.android.R.id.fl_container, flutterFragment, TAG_FLUTTER_FRAGMENT)
                .commitAllowingStateLoss();
        View splashContainer = findViewById(com.diysandbox.android.R.id.splash_container);
        if (splashContainer != null) {
            splashContainer.setVisibility(View.GONE);
        }
    }

    private void showKernelLoadingUi() {
        FrameLayout container = findViewById(com.diysandbox.android.R.id.splash_container);
        if (container == null) {
            return;
        }
        container.removeAllViews();
        container.setVisibility(View.VISIBLE);
        container.setBackgroundColor(Color.WHITE);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        content.setPadding(padding, padding, padding, padding);

        kernelStatusText = new TextView(this);
        kernelStatusText.setText("正在准备内置 Chromium 内核...");
        kernelStatusText.setTextColor(Color.DKGRAY);
        kernelStatusText.setTextSize(16);
        kernelStatusText.setGravity(Gravity.CENTER);

        kernelProgressBar = new ProgressBar(
                this,
                null,
                android.R.attr.progressBarStyleHorizontal
        );
        kernelProgressBar.setMax(100);
        kernelProgressBar.setProgress(0);

        content.addView(
                kernelStatusText,
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                )
        );
        LinearLayout.LayoutParams progressParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        progressParams.topMargin = (int) (16 * getResources().getDisplayMetrics().density);
        content.addView(kernelProgressBar, progressParams);

        FrameLayout.LayoutParams contentParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
        );
        container.addView(content, contentParams);
    }

    @Override
    public void onUpgradeProcess(float percent) {
        runOnUiThread(() -> {
            int progress = Math.max(0, Math.min(100, Math.round(percent * 100)));
            if (kernelProgressBar != null) {
                kernelProgressBar.setProgress(progress);
            }
            if (kernelStatusText != null) {
                kernelStatusText.setText("正在准备内置 Chromium 内核 " + progress + "%");
            }
        });
    }

    @Override
    public void onUpgradeComplete() {
        runOnUiThread(() -> {
            WebViewUpgrade.removeUpgradeCallback(this);
            Log.i(
                    TAG,
                    "Bundled WebView enabled: "
                            + WebViewUpgrade.getUpgradeWebViewPackageName()
                            + " "
                            + WebViewUpgrade.getUpgradeWebViewVersion()
            );
            initializeFlutter();
        });
    }

    @Override
    public void onUpgradeError(Throwable throwable) {
        runOnUiThread(() -> {
            WebViewUpgrade.removeUpgradeCallback(this);
            Log.e(TAG, "Bundled WebView failed; falling back to system WebView", throwable);
            if (kernelStatusText != null) {
                kernelStatusText.setText("内置 Chromium 内核加载失败，正在使用系统 WebView");
            }
            new Handler().postDelayed(this::initializeFlutter, 700);
        });
    }


    @Override
    public void onPostResume() {
        super.onPostResume();
        if (flutterFragment != null) {
            flutterFragment.onPostResume();
        }
        hideNavigationBar();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        // 每次重新获得焦点时(含从最近任务返回、用户上滑短暂唤出系统栏后)重新隐藏三键导航栏,
        // 保证从启动到全程始终隐藏(粘性沉浸),但保留顶部状态栏。
        if (hasFocus) hideNavigationBar();
    }

    /** 隐藏底部三键/两键导航栏(粘性沉浸),保留状态栏。全程强制,启动即生效。 */
    private void hideNavigationBar() {
        // 仅在三键/两键导航设备上隐藏; 手势导航设备若隐藏会拦截"上滑回桌面"手势
        // (需上滑两次且卡顿), 故保持系统默认。
        if (!shouldHideNavBar()) return;
        Window window = getWindow();
        if (window == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            WindowInsetsController c = window.getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            window.getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        }
    }

    /**
     * 是否应隐藏导航栏。仅三键(0)/两键(1)导航时隐藏; 手势导航(2)时返回 false,
     * 避免拦截系统的上滑回桌面手势。Q 以下无手势导航, 一律视为三键。
     */
    private boolean shouldHideNavBar() {
        try {
            int resId = getResources().getIdentifier(
                    "config_navBarInteractionMode", "integer", "android");
            if (resId > 0) {
                return getResources().getInteger(resId) != 2; // 2 = 手势导航
            }
        } catch (Exception ignored) {
        }
        return true; // 取不到(旧系统): 只有三键, 隐藏
    }

    private void postNotification(int id, String title, String body, String channelId,
                                  boolean ongoing) {
        if (channelId == null || channelId.isEmpty()) channelId = "sandbox_lua_notify";
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
        if (flutterFragment != null) {
            flutterFragment.onNewIntent(intent);
        }
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
        if (flutterFragment != null) {
            flutterFragment.onActivityResult(requestCode, resultCode, data);
        }
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
        if (flutterFragment != null) {
            flutterFragment.onRequestPermissionsResult(
                    requestCode,
                    permissions,
                    grantResults
            );
        }
    }

    @Override
    public void onUserLeaveHint() {
        if (flutterFragment != null) {
            flutterFragment.onUserLeaveHint();
        }
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if (flutterFragment != null) {
            flutterFragment.onTrimMemory(level);
        }
    }

    @Override
    protected void onDestroy() {
        WebViewUpgrade.removeUpgradeCallback(this);
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

    // ==================================================================
    // MediaSession (system media controls / notification)
    // ==================================================================

    private void initMediaSession(MethodChannel ch) {
        if (mediaSession != null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel nc = new NotificationChannel(
                    MEDIA_CHANNEL_ID, "媒体播放", NotificationManager.IMPORTANCE_LOW);
            nc.setDescription("音频播放控制");
            nc.setShowBadge(false);
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) nm.createNotificationChannel(nc);
        }

        // 不设置 MediaButtonReceiver 组件: 在 Android 12+ (API 31+) 框架会把媒体按键
        // 直接派发到 session 的 Callback (onPlay/onPause/...)。若指定了 MBR 组件, 按键会被
        // 转发到广播 PendingIntent, 而本 app 没有处理 ACTION_MEDIA_BUTTON 的 Service, 导致丢弃。
        mediaSession = new MediaSessionCompat(this, "DIY_Sandbox_Media");
        mediaSession.setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS |
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS);
        mediaSession.setCallback(new MediaSessionCompat.Callback() {
            @Override
            public void onPlay() {
                ch.invokeMethod("onMediaButton",
                        java.util.Collections.singletonMap("action", "play"));
            }
            @Override
            public void onPause() {
                ch.invokeMethod("onMediaButton",
                        java.util.Collections.singletonMap("action", "pause"));
            }
            @Override
            public void onSkipToNext() {
                ch.invokeMethod("onMediaButton",
                        java.util.Collections.singletonMap("action", "skip_next"));
            }
            @Override
            public void onSkipToPrevious() {
                ch.invokeMethod("onMediaButton",
                        java.util.Collections.singletonMap("action", "skip_prev"));
            }
            @Override
            public void onSeekTo(long pos) {
                Map<String, Object> args = new HashMap<>();
                args.put("action", "seek");
                args.put("position", ((double) pos) / 1000.0);
                ch.invokeMethod("onMediaButton", args);
            }
        });
    }

    private void updateMediaSessionMetadata(String title, String artist, String album, int durationSec) {
        if (mediaSession == null) return;
        // 合并式更新: 仅覆盖本次传入的非空字段, 保留其余已有元数据 (标题/歌手/封面)。
        // 否则仅更新播放状态 (updateMediaSession({state=...})) 时会把标题/歌手清空。
        MediaMetadataCompat existing = mediaSession.getController() != null
                ? mediaSession.getController().getMetadata() : null;
        MediaMetadataCompat.Builder b = existing != null
                ? new MediaMetadataCompat.Builder(existing)
                : new MediaMetadataCompat.Builder();
        if (title != null && !title.isEmpty()) b.putString(MediaMetadataCompat.METADATA_KEY_TITLE, title);
        if (artist != null && !artist.isEmpty()) b.putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist);
        if (album != null && !album.isEmpty()) b.putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album);
        if (durationSec > 0) {
            b.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationSec * 1000L);
        }
        mediaSession.setMetadata(b.build());
        buildMediaNotification();
    }

    // 当前封面 (供通知 setLargeIcon 用) 与其来源 key (避免重复加载)。
    private Bitmap currentArt;
    private String currentArtKey;

    private void updateMediaSessionArtwork(final String artwork) {
        if (mediaSession == null) return;
        if (artwork.equals(currentArtKey)) return;   // 同一封面, 已加载
        currentArtKey = artwork;
        new Thread(new Runnable() {
            @Override public void run() {
                final Bitmap bmp = loadArtworkBitmap(artwork);
                if (bmp == null) return;
                runOnUiThread(new Runnable() {
                    @Override public void run() {
                        if (mediaSession == null) return;
                        // 来源已切换 (快速切歌), 丢弃这张过期封面。
                        if (!artwork.equals(currentArtKey)) return;
                        currentArt = bmp;
                        MediaMetadataCompat existing = mediaSession.getController() != null
                                ? mediaSession.getController().getMetadata() : null;
                        MediaMetadataCompat.Builder b = existing != null
                                ? new MediaMetadataCompat.Builder(existing)
                                : new MediaMetadataCompat.Builder();
                        b.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bmp);
                        b.putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, bmp);
                        mediaSession.setMetadata(b.build());
                        buildMediaNotification();
                    }
                });
            }
        }).start();
    }

    /// 从本地路径或 http(s) URL 加载封面, 下采样到约 512px 防 OOM。失败返回 null。
    private Bitmap loadArtworkBitmap(String artwork) {
        try {
            byte[] data;
            if (artwork.startsWith("http://") || artwork.startsWith("https://")) {
                HttpURLConnection conn = (HttpURLConnection) new URL(artwork).openConnection();
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(10000);
                conn.setInstanceFollowRedirects(true);
                InputStream in = conn.getInputStream();
                java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
                in.close();
                conn.disconnect();
                data = bos.toByteArray();
            } else {
                String p = artwork.startsWith("file://") ? Uri.parse(artwork).getPath() : artwork;
                java.io.File f = new java.io.File(p);
                if (!f.exists()) return null;
                data = new byte[(int) f.length()];
                java.io.FileInputStream fis = new java.io.FileInputStream(f);
                int off = 0, r;
                while (off < data.length && (r = fis.read(data, off, data.length - off)) != -1) off += r;
                fis.close();
            }
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(data, 0, data.length, opts);
            int sample = 1;
            int max = Math.max(opts.outWidth, opts.outHeight);
            while (max / sample > 512) sample *= 2;
            opts.inJustDecodeBounds = false;
            opts.inSampleSize = sample;
            return BitmapFactory.decodeByteArray(data, 0, data.length, opts);
        } catch (Exception e) {
            Log.w("MediaSessionCB", "load artwork failed: " + e);
            return null;
        }
    }

    private void updateMediaSessionPlaybackState(String state, int positionSec) {
        if (mediaSession == null) return;
        int pbState;
        long pos = positionSec * 1000L;
        if ("playing".equals(state)) {
            pbState = PlaybackStateCompat.STATE_PLAYING;
        } else if ("paused".equals(state)) {
            pbState = PlaybackStateCompat.STATE_PAUSED;
        } else {
            pbState = PlaybackStateCompat.STATE_STOPPED;
            pos = 0;
        }
        PlaybackStateCompat pb = new PlaybackStateCompat.Builder()
                .setState(pbState, pos, 1.0f)
                .setActions(PlaybackStateCompat.ACTION_PLAY
                        | PlaybackStateCompat.ACTION_PAUSE
                        | PlaybackStateCompat.ACTION_PLAY_PAUSE
                        | PlaybackStateCompat.ACTION_STOP
                        | PlaybackStateCompat.ACTION_SKIP_TO_NEXT
                        | PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                        | PlaybackStateCompat.ACTION_SEEK_TO)
                .build();
        mediaSession.setPlaybackState(pb);
        mediaSession.setActive(pbState != PlaybackStateCompat.STATE_STOPPED);
        buildMediaNotification();
    }

    private void buildMediaNotification() {
        if (mediaSession == null) return;
        MediaMetadataCompat meta = mediaSession.getController().getMetadata();
        PlaybackStateCompat pb = mediaSession.getController().getPlaybackState();
        if (meta == null || pb == null) return;

        String title = meta.getString(MediaMetadataCompat.METADATA_KEY_TITLE);
        String artist = meta.getString(MediaMetadataCompat.METADATA_KEY_ARTIST);
        boolean playing = pb.getState() == PlaybackStateCompat.STATE_PLAYING;

        Intent open = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (open == null) open = new Intent();
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent contentPI = PendingIntent.getActivity(
                this, MEDIA_NOTIFY_ID, open, piFlags);

        NotificationCompat.Builder b = new NotificationCompat.Builder(this, MEDIA_CHANNEL_ID)
                .setSmallIcon(getApplicationInfo().icon)
                .setContentTitle(title != null ? title : "")
                .setContentText(artist != null ? artist : "")
                .setContentIntent(contentPI)
                .setOngoing(playing)
                .setAutoCancel(!playing)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setStyle(new androidx.media.app.NotificationCompat.MediaStyle()
                        .setMediaSession(mediaSession.getSessionToken())
                        .setShowActionsInCompactView(0));

        if (currentArt != null) b.setLargeIcon(currentArt);   // 通知栏封面

        // Play/Pause action button
        int actionIcon = playing
                ? android.R.drawable.ic_media_pause
                : android.R.drawable.ic_media_play;
        String actionLabel = playing ? "暂停" : "播放";
        PendingIntent actionPI = MediaButtonReceiver.buildMediaButtonPendingIntent(
                this, playing ? PlaybackStateCompat.ACTION_PAUSE
                        : PlaybackStateCompat.ACTION_PLAY);
        b.addAction(new NotificationCompat.Action(actionIcon, actionLabel, actionPI));

        try {
            NotificationManagerCompat.from(this).notify(MEDIA_NOTIFY_ID, b.build());
        } catch (SecurityException e) {
            Log.w("MainActivity", "media notify denied: " + e);
        }
    }

    private void releaseMediaSession() {
        if (mediaSession != null) {
            mediaSession.setActive(false);
            mediaSession.release();
            mediaSession = null;
        }
        currentArt = null;
        currentArtKey = null;
        NotificationManagerCompat.from(this).cancel(MEDIA_NOTIFY_ID);
    }

}

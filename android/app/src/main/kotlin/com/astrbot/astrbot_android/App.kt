package com.astrbot.astrbot_android

import android.app.Application
import android.util.Log
import com.norman.webviewup.lib.UpgradeCallback
import com.norman.webviewup.lib.WebViewUpgrade
import com.norman.webviewup.lib.source.UpgradeAssetSource
import java.io.File

/**
 * 自定义 Application: 启动时用内置的现代 Chromium WebView 内核 APK 升级本 App 的 WebView。
 *
 * 内核 (assets/webview/webview.apk, Chromium 134) 随 App 打包, 完全离线;
 * 仅改变本 App 自身 WebView 的解析, 不影响系统 WebView 或其他应用。
 * 必须在任何 WebView 创建之前调用, 因此放在 Application.onCreate。
 * 加载失败时自动回退到系统 WebView, 不影响 App 启动。
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            WebViewUpgrade.addUpgradeCallback(object : UpgradeCallback {
                override fun onUpgradeProcess(percent: Float) {}

                override fun onUpgradeComplete() {
                    Log.d(TAG, "WebView 内核升级完成: ${WebViewUpgrade.getUpgradeWebViewPackageName()} " +
                            WebViewUpgrade.getUpgradeWebViewVersion())
                }

                override fun onUpgradeError(throwable: Throwable?) {
                    Log.e(TAG, "WebView 内核升级失败, 回退系统内核", throwable)
                }
            })
            WebViewUpgrade.upgrade(
                UpgradeAssetSource(
                    this,
                    "webview/webview.apk",
                    File(filesDir, "webview_core/webview.apk"),
                )
            )
        } catch (e: Throwable) {
            Log.e(TAG, "WebViewUpgrade 初始化异常, 回退系统内核", e)
        }
    }

    companion object {
        private const val TAG = "AstrBotWebView"
    }
}

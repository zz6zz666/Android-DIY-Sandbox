package com.astrbot.astrbot_android

import android.app.Application
import android.util.Log
import com.hearthappy.x5core.X5CoreManager
import com.hearthappy.x5core.interfaces.X5CoreListener

/**
 * 自定义 Application: 启动时从内置离线包安装/加载腾讯 X5 内核。
 * 内核随 App 打包(webX5Core arm64), 无需线上拉取, 老安卓也能获得现代 Blink 内核。
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            X5CoreManager.initX5Core(baseContext, listener = object : X5CoreListener {
                override fun onCoreInitFinished() {
                    Log.d(TAG, "X5 onCoreInitFinished")
                }

                override fun onViewInitFinished(isX5: Boolean) {
                    Log.d(TAG, "X5 onViewInitFinished isX5=$isX5")
                }

                override fun onInstallFinish(stateCode: Int) {
                    // stateCode==200 表示离线内核安装成功, 重启 App 后生效
                    Log.d(TAG, "X5 onInstallFinish stateCode=$stateCode")
                }
            })
        } catch (e: Throwable) {
            Log.e(TAG, "initX5Core error", e)
        }
    }

    companion object {
        private const val TAG = "AstrBotX5"
    }
}

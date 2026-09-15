package com.smartcart.smart_cart_app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 조작 화면이 떠 있는 동안 화면 꺼짐 방지 (lib/main.dart의 _setScreenAwake).
        // FLAG_KEEP_SCREEN_ON은 이 화면이 보일 때만 적용되고, 앱이 사라지면 저절로 풀린다.
        // 플러그인 대신 직접 쓰는 이유: Windows에서 네이티브 플러그인을 빌드하려면 개발자 모드가 필요하다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smart_cart/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepOn" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

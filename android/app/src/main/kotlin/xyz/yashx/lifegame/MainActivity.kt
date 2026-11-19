package xyz.yashx.lifegame

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Secure Chat (v2.11.0, point 10): the Dart side toggles Android
    // FLAG_SECURE while a secure chat is open, so screenshots and
    // screen recordings are blocked for that chat.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lifegame/secure_chat",
        ).setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                val on = call.argument<Boolean>("on") ?: false
                if (on) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}

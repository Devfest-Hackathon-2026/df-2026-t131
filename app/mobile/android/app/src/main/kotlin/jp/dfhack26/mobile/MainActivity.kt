package jp.dfhack26.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var gaze: GazePlugin? = null
    private var audioState: AudioStatePlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        gaze = GazePlugin(applicationContext, messenger)
        audioState = AudioStatePlugin(applicationContext, messenger)
        TonePlugin(messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        gaze?.dispose()
        audioState?.dispose()
        gaze = null
        audioState = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

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
        tone = TonePlugin(applicationContext, messenger)
        voicevox = VoicevoxPlugin(applicationContext, messenger)
    }

    private var voicevox: VoicevoxPlugin? = null
    private var tone: TonePlugin? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        gaze?.dispose()
        audioState?.dispose()
        voicevox?.dispose()
        tone?.dispose()
        tone = null
        gaze = null
        audioState = null
        voicevox = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

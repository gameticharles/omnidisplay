import QtQuick
import Quickshell.Io

// One command, run once. Optional input goes to stdin and stdin is closed,
// so payloads never travel in argv. Calls back with the exit code (or the
// one the control script printed after its exit marker), stdout and stderr,
// then destroys itself. Created by Service.run().
Process {
  id: proc

  property string input: ""
  property bool hasInput: false
  property var callback: null

  property bool _exited: false
  property int _code: -1
  property bool _outDone: false
  property bool _errDone: false
  property bool _finished: false

  readonly property string marker: "__omnidisplay_exit="

  stdinEnabled: hasInput

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: { proc._outDone = true; proc._finish() }
  }
  stderr: StdioCollector {
    waitForEnd: true
    onStreamFinished: { proc._errDone = true; proc._finish() }
  }

  onStarted: {
    if (!hasInput) return
    write(input)
    input = ""
    stdinEnabled = false
  }

  onExited: function(exitCode) {
    _code = exitCode
    _exited = true
    _finish()
  }

  function _finish() {
    if (_finished || !_exited || !_outDone || !_errDone) return
    _finished = true
    var out = String(stdout.text || "")
    var code = _code
    var at = out.lastIndexOf(marker)
    if (at >= 0) {
      var parsed = parseInt(out.substring(at + marker.length), 10)
      if (isFinite(parsed)) code = parsed
      out = out.substring(0, at).replace(/\n$/, "")
    }
    var cb = callback
    callback = null
    if (typeof cb === "function") {
      try { cb(code, out, String(stderr.text || "")) } catch (e) { console.warn("omnidisplay: callback failed:", e) }
    }
    Qt.callLater(function() { proc.destroy() })
  }
}

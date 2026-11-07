import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'moderation.dart';

// On a phone the checks run in web/moderate.js too, inside a hidden web view.
// A small server on 127.0.0.1 hands it the page, the file to check and the
// models, and takes the checked file back: big files don't fit through the
// web view's message channel. The models download once from the published
// site into the app's own storage.

/// Where the models come from; a test build can point it elsewhere with --dart-define.
const _published = String.fromEnvironment('FX_BASE', defaultValue: 'https://abdallah4f7.github.io/dardasha/app/fx/');

/// Everything moderate.js loads from fx/; nothing else is served or fetched.
const _fx = {
  'vision_bundle.mjs',
  'vision_wasm_internal.js',
  'vision_wasm_internal.wasm',
  'efficientdet_lite0.tflite',
  'pose_landmarker_full.task',
  'selfie_multiclass_256x256.tflite',
  'face-api.esm.js',
  'ssd_mobilenetv1_model-weights_manifest.json',
  'ssd_mobilenetv1_model.bin',
  'face_landmark_68_model-weights_manifest.json',
  'face_landmark_68_model.bin',
  'age_gender_model-weights_manifest.json',
  'age_gender_model.bin',
  'audio_bundle.mjs',
  'audio_wasm_internal.js',
  'audio_wasm_internal.wasm',
  'yamnet.tflite',
  'mediabunny.min.mjs',
};

const _page = '''<!doctype html>
<meta charset="utf-8">
<script>window.DARDASHA_FX = location.origin + '/fx/';</script>
<script src="/moderate.js"></script>
<script>
  const post = (m) => Dardasha.postMessage(JSON.stringify(m));
  const steps = (job) => {
    let last = -1;
    return (p) => {
      if (p - last < 0.02 && p < 1) return;
      last = p;
      post({ job, progress: p });
    };
  };
  window.bridge = {
    async analyze(job, kind) {
      try {
        const bytes = new Uint8Array(await (await fetch('/in/' + job)).arrayBuffer());
        post({ job, done: await dardashaModerate.analyze(kind, bytes, steps(job)) });
      } catch (e) {
        post({ job, error: String(e && e.message || e) });
      }
    },
    async finish(job, id, decision) {
      try {
        const bytes = await dardashaModerate.finish(id, decision, steps(job));
        if (bytes) await fetch('/out/' + job, { method: 'POST', body: bytes });
        post({ job, done: bytes ? 'bytes' : '' });
      } catch (e) {
        post({ job, error: String(e && e.message || e) });
      }
    },
    drop(id) {
      dardashaModerate.drop(id);
    },
  };
  post({ ready: true });
</script>
''';

class _Job {
  _Job(this.input, this.progress);
  final Uint8List? input;
  final void Function(double) progress;
  final done = Completer<String>();
  Uint8List? output;
}

class _Engine {
  static final instance = _Engine();
  static const _idle = Duration(minutes: 3);

  HttpServer? _server;
  WebViewController? _view;
  OverlayEntry? _entry;
  Completer<void>? _ready;
  Timer? _idleTimer;
  final _jobs = <String, _Job>{};
  final _downloads = <String, Future<File>>{};
  final _random = Random.secure();
  int _active = 0; // downloads under way
  int _received = 0;
  int _expected = 0;

  String _token() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> _start() async {
    _idleTimer?.cancel();
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<void>();
    try {
      final overlay = Moderation.navigatorKey?.currentState?.overlay;
      if (overlay == null) throw StateError('no overlay for the checks');
      final server = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_serve);
      final view = _view = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('Dardasha', onMessageReceived: (m) => _onMessage(m.message))
        ..setOnConsoleMessage((m) => debugPrint('moderate: ${m.message}'));
      // A web view only runs while it is on screen: one pixel, under everything that matters.
      _entry = OverlayEntry(
        builder: (_) => Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(child: Opacity(opacity: 0.01, child: WebViewWidget(controller: view))),
        ),
      );
      overlay.insert(_entry!);
      await view.loadRequest(Uri.parse('http://127.0.0.1:${server.port}/'));
      await ready.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      if (!ready.isCompleted) ready.completeError(e);
      _stop();
      rethrow;
    }
  }

  void _stop() {
    _idleTimer?.cancel();
    _entry?.remove();
    _entry = null;
    _view = null;
    _server?.close(force: true);
    _server = null;
    _ready = null;
    for (final j in _jobs.values) {
      if (!j.done.isCompleted) j.done.completeError(StateError('checks stopped'));
    }
    _jobs.clear();
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    if (_jobs.isEmpty) _idleTimer = Timer(_idle, _stop);
  }

  void _onMessage(String text) {
    final m = jsonDecode(text) as Map<String, dynamic>;
    if (m['ready'] == true) {
      if (_ready?.isCompleted == false) _ready!.complete();
      return;
    }
    final job = _jobs[m['job']];
    if (job == null || job.done.isCompleted) return;
    if (m['progress'] is num) {
      job.progress((m['progress'] as num).toDouble());
    } else if (m.containsKey('error')) {
      job.done.completeError(Exception(m['error']));
    } else {
      job.done.complete(m['done'] as String? ?? '');
    }
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (path == '/') {
        res.headers.contentType = ContentType.html;
        res.write(_page);
      } else if (path == '/moderate.js') {
        res.headers.contentType = ContentType('text', 'javascript', charset: 'utf-8');
        res.add((await rootBundle.load('web/moderate.js')).buffer.asUint8List());
      } else if (path.startsWith('/fx/') && _fx.contains(path.substring(4))) {
        final name = path.substring(4);
        final file = await _model(name);
        res.headers.contentType = _typeOf(name);
        await res.addStream(file.openRead());
      } else if (path.startsWith('/in/') && req.method == 'GET') {
        final job = _jobs[path.substring(4)];
        if (job?.input == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers.contentType = ContentType.binary;
          res.add(job!.input!);
        }
      } else if (path.startsWith('/out/') && req.method == 'POST') {
        final job = _jobs[path.substring(5)];
        final bytes = BytesBuilder(copy: false);
        await req.forEach(bytes.add);
        if (job == null) {
          res.statusCode = HttpStatus.notFound;
        } else {
          job.output = bytes.takeBytes();
        }
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      debugPrint('moderate server: $e');
      res.statusCode = HttpStatus.internalServerError;
    }
    await res.close();
  }

  static ContentType _typeOf(String name) => switch (name.split('.').last) {
    'mjs' || 'js' => ContentType('text', 'javascript', charset: 'utf-8'),
    'wasm' => ContentType('application', 'wasm'),
    'json' => ContentType.json,
    _ => ContentType.binary,
  };

  /// [name] from the app's storage, downloaded the first time it is needed.
  Future<File> _model(String name) => _downloads[name] ??= () async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/fx');
    final file = File('${dir.path}/$name');
    if (await file.exists()) return file;
    await dir.create(recursive: true);
    final part = File('${file.path}.part');
    final client = http.Client();
    _active++;
    try {
      final res = await client.send(http.Request('GET', Uri.parse('$_published$name')));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode} for $name');
      final size = res.contentLength ?? 0;
      _expected += size;
      final sink = part.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          _received += chunk.length;
          if (_expected > 0) Moderation.preparing.value = (_received / _expected).clamp(0, 1);
        }
      } finally {
        await sink.close();
      }
      return await part.rename(file.path);
    } catch (e) {
      _downloads.remove(name); // tried again next time
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close();
      if (--_active == 0) {
        _received = 0;
        _expected = 0;
        Moderation.preparing.value = null;
      }
    }
  }();

  Future<T> _run<T>(Uint8List? input, void Function(double) progress, String Function(String token) call,
      T Function(_Job job, String done) result) async {
    await _start();
    final token = _token();
    final job = _jobs[token] = _Job(input, progress);
    try {
      await _view!.runJavaScript(call(token));
      return result(job, await job.done.future);
    } finally {
      _jobs.remove(token);
      _restartIdleTimer();
    }
  }
}

Future<String> analyze(String kind, Uint8List bytes, void Function(double) progress) => _Engine.instance._run(
  bytes,
  progress,
  (t) => 'bridge.analyze(${jsonEncode(t)}, ${jsonEncode(kind)})',
  (_, done) => done,
);

Future<Uint8List?> finish(int id, String decision, void Function(double) progress) => _Engine.instance._run(
  null,
  progress,
  (t) => 'bridge.finish(${jsonEncode(t)}, $id, ${jsonEncode(decision)})',
  (job, done) => done == 'bytes' ? job.output : null,
);

void drop(int id) {
  final view = _Engine.instance._view;
  if (view != null) view.runJavaScript('bridge.drop($id)').ignore();
}

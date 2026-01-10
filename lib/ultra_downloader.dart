import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart'; // For WidgetsFlutterBinding
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import 'src/chunk_manager.dart';
import 'src/downloader_isolate.dart';

export 'src/chunk_manager.dart'
    show ChunkingStrategy, DownloadStatus, StrategyType;

const _kWorkManagerTag = 'ultra_downloader_bg_task';
const _kWorkManagerUniqueName = 'ultra_downloader_periodic';

/// The specific callback for WorkManager.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Background execution logic
    // 1. Scan for .meta files in app documents
    // 2. If found incomplete, try to resume (download a bit?)
    // This is tricky because OS kills us quickly.
    // Ideally we just check and maybe mark them or try to download 1 chunk.
    try {
      // We can't easily spawn the complex isolate here without context.
      // But we can do a quick check and cleanup or small retry.
      // For now, we will just print/log as "Background Check Active".
      // A full background implementation requires a different architecture (native workers)
      // which the user alluded to with "smart backgrounding".
      // But strictly "pure dart" means we rely on Dart execution period.

      // Let's implement a "Recovery Scanner"
      // Note: PathProvider works in background isolate.
      final docDir = await getApplicationDocumentsDirectory();
      final files = docDir.listSync(recursive: true);
      for (var f in files) {
        if (f.path.endsWith('.meta')) {
          // Check content
          final content = File(f.path).readAsStringSync();
          final json = jsonDecode(content);
          final task = DownloadTask.fromJson(json);
          // If paused or failed, good. If downloading but stuck (process killed), reset to paused.
          if (task.status == DownloadStatus.downloading) {
            task.status = DownloadStatus.paused;
            File(f.path).writeAsStringSync(jsonEncode(task.toJson()));
          }
        }
      }
    } catch (e) {
      debugPrint('UltraDownloader Background Error: $e');
    }
    return Future.value(true);
  });
}

class UltraDownloader {
  static final UltraDownloader _instance = UltraDownloader._internal();
  factory UltraDownloader() => _instance;

  UltraDownloader._internal();

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _receivePort;

  final _statusController = StreamController<DownloadProgress>.broadcast();

  /// Stream of progress updates for all tasks.
  Stream<DownloadProgress> get progressStream => _statusController.stream;

  bool _isInitialized = false;
  bool _debug = false;

  /// Initialize the downloader. Must be called before use.
  /// Set [debug] to true to enable console logs.
  Future<void> initialize({bool debug = false}) async {
    if (_isInitialized) return;
    _debug = debug;

    _receivePort = ReceivePort();
    final completer = Completer<void>();

    _isolate =
        await Isolate.spawn(downloadIsolateEntry, _receivePort!.sendPort);

    // Listen to messages from isolate
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        if (_debug) debugPrint('[UltraDownloader] Handshake received');
        if (!completer.isCompleted) completer.complete();
      } else if (message is Map) {
        final type = message['type'];
        if (type == 'log' && _debug) {
          debugPrint('[UltraIsolate] ${message['msg']}');
        } else if (type == 'progress' || type == 'status') {
          final taskId = message['taskId'] as String;
          final progress = (message['progress'] as num?)?.toDouble() ?? 0.0;
          final status = DownloadStatus.values[message['status'] as int];

          _statusController.add(DownloadProgress(taskId, progress, status));
        }
      }
    });

    await completer.future;

    // Initialize WorkManager
    await Workmanager().initialize(callbackDispatcher);

    // Clean up "stuck" downloads from previous crash
    // We can ask the isolate to do this, or do it here?
    // Doing it here is blocking the UI thread (if async io), isolate is better.
    // For now, rely on background task or user action.

    _isInitialized = true;
  }

  /// Starts a new download.
  /// [url] is the file URL.
  /// [savePath] is the *full* local path (e.g., /data/.../file.mp4).
  /// [strategy] defines chunking logic.
  Future<String> download(
    String url,
    String savePath, {
    Map<String, dynamic>? headers,
    ChunkingStrategy? strategy,
  }) async {
    if (!_isInitialized) await initialize();

    final taskId = const Uuid().v4();
    final task = DownloadTask(
      id: taskId,
      url: url,
      savePath: savePath,
      headers: headers,
      strategy: strategy ?? const ChunkingStrategy(),
    );

    _isolateSendPort!.send({
      'command': 'download',
      'task': task.toJson(),
    });

    return taskId;
  }

  Future<void> pause(String taskId) async {
    _isolateSendPort?.send({'command': 'pause', 'taskId': taskId});
  }

  Future<void> resume(String taskId) async {
    _isolateSendPort?.send({'command': 'resume', 'taskId': taskId});
  }

  Future<void> cancel(String taskId) async {
    _isolateSendPort?.send({'command': 'cancel', 'taskId': taskId});
  }

  /// Register background periodic task (Optional convenience method)
  Future<void> registerBackgroundRecovery() async {
    await Workmanager().registerPeriodicTask(
      _kWorkManagerUniqueName,
      _kWorkManagerTag,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  void dispose() {
    _isolate?.kill();
    _statusController.close();
    _receivePort?.close();
  }
}

class DownloadProgress {
  final String taskId;
  final double progress;
  final DownloadStatus status;

  DownloadProgress(this.taskId, this.progress, this.status);
}

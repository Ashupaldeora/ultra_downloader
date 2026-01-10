import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart'; // For WidgetsFlutterBinding
import 'package:uuid/uuid.dart';

import 'src/chunk_manager.dart';
import 'src/downloader_isolate.dart';

export 'src/chunk_manager.dart'
    show ChunkingStrategy, DownloadStatus, StrategyType, DownloadProgress;

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

    if (_debug) debugPrint('[UltraDownloader] Initialized');

    // Clean up "stuck" downloads from previous crash
    // We can ask the isolate to do this, or do it here?
    // For now, allow isolate to handle resumption via .meta files on its own.

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
    if (!_isInitialized) await initialize(debug: _debug);

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

  void dispose() {
    _isolate?.kill();
    _statusController.close();
    _receivePort?.close();
  }
}

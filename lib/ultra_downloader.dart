import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart'; // For WidgetsFlutterBinding
import 'package:uuid/uuid.dart';

import 'src/chunk_manager.dart';
import 'src/downloader_isolate.dart';

export 'src/chunk_manager.dart'
    show
        ChunkingStrategy,
        DownloadStatus,
        StrategyType,
        DownloadProgress,
        AuxiliaryFile;

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
  void Function(String)? _onLog;

  Future<void>? _initFuture;

  /// Initialize the downloader. Must be called before use.
  /// Set [debug] to true to enable console logs.
  /// Optionally pass [onLog] callback to receive all isolate log messages.
  Future<void> initialize({bool debug = false, void Function(String)? onLog}) {
    if (_isInitialized) return Future.value();

    // Return existing future if initialization is already in progress
    if (_initFuture != null) return _initFuture!;

    _initFuture = _initializeInternal(debug, onLog);
    return _initFuture!;
  }

  Future<void> _initializeInternal(
      bool debug, void Function(String)? onLog) async {
    _debug = debug;
    _onLog = onLog;

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
        if (type == 'log') {
          final msg = message['msg'] as String;
          if (_debug) debugPrint('[UltraIsolate] $msg');
          // Call external log handler if provided
          _onLog?.call(msg);
        } else if (type == 'progress' || type == 'status') {
          final taskId = message['taskId'] as String;
          final progress = (message['progress'] as num?)?.toDouble() ?? 0.0;
          final statusIndex = message['status'] as int? ?? 0;
          final status = DownloadStatus.values[statusIndex];

          _statusController.add(DownloadProgress(taskId, progress, status));
        }
      }
    });

    await completer.future;

    if (_debug) debugPrint('[UltraDownloader] Initialized');

    _isInitialized = true;
  }

  /// Retrieves the current status of a task from disk.
  /// This is used to recover state when the app restarts.
  /// It automatically handles:
  /// 1. Checking if the final file is already completed (priority).
  /// 2. Parsing the .meta file.
  /// 3. Verifying partial files for accurate progress.
  static Future<DownloadTask?> getTaskInfo(String savePath,
      {String? taskId}) async {
    try {
      // 1. Priority Check: Final File Existence
      final finalFile = File(savePath);
      if (finalFile.existsSync() && finalFile.lengthSync() > 0) {
        final size = finalFile.lengthSync();
        final chunks = [
          Chunk(id: 0, start: 0, end: size - 1, downloaded: size)
        ];

        return DownloadTask(
            id: taskId ?? 'recovered_completed',
            url: '', // Unknown from just file
            savePath: savePath,
            status: DownloadStatus.completed,
            totalSize: size,
            chunks: chunks);
      }

      // 2. Metadata Check
      final metaFile = File("$savePath.meta");
      if (!metaFile.existsSync()) {
        return null; // No record found
      }

      final jsonString = await metaFile.readAsString();
      final json = jsonDecode(jsonString);

      final task = DownloadTask.fromJson(json);

      // 3. Status Verification & Partial Scan
      if (task.status == DownloadStatus.completed) {
        // Meta says completed, but we didn't find the file above?
        // This implies the file was deleted or moved.
        task.status = DownloadStatus.failed;
        task.errorMessage = "File missing";
        return task;
      }

      // If paused/downloading/failed, check partials for precise progress
      if (task.status != DownloadStatus.completed) {
        for (var chunk in task.chunks) {
          final partFile = File("$savePath.part.${chunk.id}");
          if (partFile.existsSync()) {
            chunk.downloaded = partFile.lengthSync();
          }
        }
      }

      return task;
    } catch (e) {
      debugPrint("[UltraDownloader] Check Info Error: $e");
      return null;
    }
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
    String? id,
    List<AuxiliaryFile>? auxiliaries,
  }) async {
    if (!_isInitialized) await initialize(debug: _debug);

    final taskId = id ?? const Uuid().v4();
    final task = DownloadTask(
      id: taskId,
      url: url,
      savePath: savePath,
      headers: headers,
      strategy: strategy ?? const ChunkingStrategy(),
      auxiliaries: auxiliaries ?? const [],
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

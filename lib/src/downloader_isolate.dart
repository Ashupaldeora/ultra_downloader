import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'dart:ui'; // For IsolateNameServer
import 'package:dio/dio.dart';
import 'chunk_manager.dart';

/// Entry point for the downloader isolate.
void downloadIsolateEntry(SendPort sendPort) {
  final isolate = _DownloaderIsolate(sendPort);
  isolate.listen();
}

class _DownloaderIsolate {
  final SendPort _mainSendPort;
  final ReceivePort _isolateReceivePort = ReceivePort();

  // Active tasks: taskId -> _TaskRuntime
  final Map<String, _TaskRuntime> _activeTasks = {};
  // Paused tasks: taskId -> DownloadTask (kept in memory to allow resume by ID)
  final Map<String, DownloadTask> _pausedTasks = {};
  final Dio _dio = Dio();

  _DownloaderIsolate(this._mainSendPort) {
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
  }

  void _log(String msg) {
    _mainSendPort.send({'type': 'log', 'msg': msg});
  }

  void listen() {
    // Handshake: Send our ReceivePort to the main isolate
    _mainSendPort.send(_isolateReceivePort.sendPort);

    _isolateReceivePort.listen((message) {
      if (message is Map) {
        final command = message['command'];
        _log(
            'Received command: $command for taskId: ${message['taskId'] ?? message['task']?['id']}');
        switch (command) {
          case 'download':
            _startDownload(message['task'] as Map<String, dynamic>);
            break;
          case 'pause':
            _pauseDownload(message['taskId'] as String);
            break;
          case 'resume':
            _resumeDownload(message['taskId'] as String);
            break;
          case 'cancel':
            _cancelDownload(message['taskId'] as String);
            break;
        }
      }
    });
  }

  Future<void> _startDownload(Map<String, dynamic> taskJson) async {
    // Check if metadata exists on disk for this path
    // We prioritize the INVALID Task passed to getting the Path, then load the REAL task.
    var task = DownloadTask.fromJson(taskJson);
    final metaFile = File('${task.savePath}.meta');

    if (metaFile.existsSync()) {
      try {
        final json = jsonDecode(metaFile.readAsStringSync());
        final oldTask = DownloadTask.fromJson(json);
        // CRITICAL: We must preserve the NEW ID for this session,
        // otherwise the main thread won't recognize progress from the old ID.
        // We also want to keep the new URL/strategy if they changed?
        // For now, trust metadata for state, but ID must match session.
        task = oldTask;
        // We can't modify final field 'id'. We need to create a copy or handle it.
        // DownloadTask is immutable-ish. Let's create a copy with new ID.
        task = DownloadTask(
            id: taskJson['id'], // Use the NEW ID
            url: task.url,
            savePath: task.savePath,
            headers: task.headers,
            strategy: task.strategy,
            totalSize: task.totalSize,
            chunks: task.chunks,
            status: task.status,
            errorMessage: task.errorMessage);

        if (task.status == DownloadStatus.completed) {
          _broadcastStatus(_TaskRuntime(task, _mainSendPort));
          return;
        }
      } catch (e) {
        // Corrupt meta? overwrite.
      }
    }

    if (_activeTasks.containsKey(task.id)) return; // Already running

    // If it was paused, remove from paused list
    _pausedTasks.remove(task.id);

    final runtime = _TaskRuntime(task, _mainSendPort);
    _activeTasks[task.id] = runtime;

    try {
      await runtime.initialize();
      // Update metadata immediately (in case it's a new task or status change)
      task.status = DownloadStatus.downloading;
      _saveMetadata(runtime.task);

      // Calculate missing chunks or setup new ones
      if (runtime.task.chunks.isEmpty) {
        // New download
        final totalSize = await _getContentLength(task.url, task.headers);
        runtime.task.totalSize = totalSize;
        runtime.task.chunks =
            ChunkManager.calculateChunks(totalSize, runtime.task.strategy);
        _saveMetadata(runtime.task);
      }

      await runtime._openFile();

      // Fire requests
      List<Future> futures = [];
      bool allCompleted = true;

      for (var chunk in runtime.task.chunks) {
        if (!chunk.isCompleted) {
          allCompleted = false;
          futures.add(_downloadChunk(runtime, chunk));
        }
      }

      if (allCompleted) {
        _completeTask(runtime);
        return;
      }

      runtime.task.status = DownloadStatus.downloading;
      _broadcastStatus(runtime);

      await Future.wait(futures);

      // Verify completeness (simple check)
      if (runtime.task.chunks.every((c) => c.isCompleted)) {
        _completeTask(runtime);
      }
    } catch (e, st) {
      // If cancelled, it's not an error.
      if (runtime.isCancelled) return;
      _handleError(runtime, e, st);
    } finally {
      // Cleanup if not active anymore
      if (runtime.task.status != DownloadStatus.downloading) {
        _activeTasks.remove(task.id);
        runtime.closeFile();
      }
    }
  }

  Future<void> _downloadChunk(_TaskRuntime runtime, Chunk chunk) async {
    if (runtime.isCancelled) return;

    int retryCount = 0;
    const maxRetries = 5;

    while (retryCount < maxRetries && !runtime.isCancelled) {
      try {
        final start = chunk.start + chunk.downloaded;
        final end = chunk.end;

        if (start > end) return; // double check

        final headers = Map<String, dynamic>.from(runtime.task.headers ?? {});
        headers['Range'] = 'bytes=$start-$end';

        final response = await _dio.get<ResponseBody>(
          runtime.task.url,
          cancelToken: runtime.cancelToken, // Core fix for Zombie Bandwidth
          options: Options(
            responseType: ResponseType.stream,
            headers: headers,
          ),
        );

        final stream = response.data!.stream;
        ChunkStreamSubscription? subscription;
        final completer = Completer();

        subscription = ChunkStreamSubscription(stream.listen(
          (data) {
            if (runtime.isCancelled) {
              subscription?.cancel();
              return;
            }
            runtime.write(chunk, data);
          },
          onDone: () {
            runtime.flush(chunk);
            completer.complete();
          },
          onError: (e) {
            completer.completeError(e);
          },
          cancelOnError: true,
        ));

        runtime.literals.add(subscription);
        await completer.future;
        runtime.literals.remove(subscription);
        return; // Success
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel || CancelToken.isCancel(e)) {
          return;
        }
        retryCount++;
        if (retryCount >= maxRetries) rethrow; // Give up

        // Exponential backoff
        int delay = pow(2, retryCount).toInt() * 1000;
        await Future.delayed(Duration(milliseconds: delay));
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<int> _getContentLength(
      String url, Map<String, dynamic>? headers) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(headers: headers),
      );
      final lenStr = response.headers.value('content-length');
      if (lenStr != null) {
        return int.parse(lenStr);
      }
      throw Exception('Could not determine content length');
    } catch (e) {
      throw Exception('Failed to head url: $e');
    }
  }

  void _pauseDownload(String taskId) {
    final runtime = _activeTasks[taskId];
    if (runtime != null) {
      runtime.task.status = DownloadStatus.paused;
      runtime.cancelAll(); // This stops streams
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);
      _activeTasks.remove(taskId);
      _pausedTasks[taskId] = runtime.task; // Save for resume
      runtime.closeFile();
    }
  }

  void _resumeDownload(String taskId) {
    // 1. Try to find in paused tasks
    if (_pausedTasks.containsKey(taskId)) {
      final task = _pausedTasks[taskId]!;
      _startDownload(task.toJson());
    } else {
      // If not in paused tasks (e.g. app restart), we can't resume BY ID ONLY
      // because we don't know the path.
      // The user must use .download() with path to smart-resume.
      // But we can try to look in _activeTasks to see if it's already running?
      if (_activeTasks.containsKey(taskId)) return;

      // Error: cannot find task to resume.
      // For debugging, we might log this.
    }
  }

  void _cancelDownload(String taskId) {
    final runtime = _activeTasks[taskId];
    if (runtime != null) {
      runtime.task.status = DownloadStatus.canceled;
      runtime.cancelAll();
      _activeTasks.remove(taskId);
      runtime.closeFile();
      // Also remove from paused if present (though it shouldn't be active AND paused)
    }
    _pausedTasks.remove(taskId);

    // We can't easily delete file if we don't have the runtime/task object.
    // So we only delete if we found it.
    if (runtime != null) {
      final file = File(runtime.task.savePath);
      if (file.existsSync()) file.deleteSync();
      final meta = File('${runtime.task.savePath}.meta');
      if (meta.existsSync()) meta.deleteSync();
      _mainSendPort.send({
        'type': 'status',
        'taskId': taskId,
        'status': DownloadStatus.canceled.index
      });
    }
  }

  void _completeTask(_TaskRuntime runtime) {
    runtime.task.status = DownloadStatus.completed;
    _saveMetadata(runtime.task); // Keep metadata? Or delete? Usually delete.
    // Let's delete metadata on success to clean up.
    // We KEEP the metadata file as a source of truth for the "Completed" state.
    // This allows the app to know a file is finished even after a full restart / cache clear.
    _saveMetadata(runtime.task);
    _broadcastStatus(runtime);
    _activeTasks.remove(runtime.task.id);
    _pausedTasks.remove(runtime.task.id);
    runtime.closeFile();
  }

  void _handleError(_TaskRuntime runtime, Object e, StackTrace st) {
    runtime.task.status = DownloadStatus.failed;
    runtime.task.errorMessage = e.toString();
    _saveMetadata(runtime.task);
    _broadcastStatus(runtime);
    _activeTasks.remove(runtime.task.id);
    _pausedTasks.remove(runtime.task.id);
    runtime.closeFile();
  }

  void _saveMetadata(DownloadTask task) {
    final file = File('${task.savePath}.meta');
    file.writeAsStringSync(jsonEncode(task.toJson()));
  }

  void _broadcastStatus(_TaskRuntime runtime) {
    _mainSendPort.send({
      'type': 'progress',
      'taskId': runtime.task.id,
      'progress': runtime.task.progress,
      'status': runtime.task.status.index
    });

    // GENERIC MONITORING: (Added for Foreground Service Support)
    // Check if any external monitor is listening (e.g., Foreground Service)
    final monitorPort =
        IsolateNameServer.lookupPortByName('ultra_downloader_monitor_port');
    if (monitorPort != null) {
      monitorPort.send({
        'type': 'progress',
        'taskId': runtime.task.id,
        'progress': runtime.task.progress,
        'status': runtime.task.status.index
      });
    }
  }
}

class ChunkStreamSubscription {
  final StreamSubscription _sub;
  ChunkStreamSubscription(this._sub);
  void cancel() => _sub.cancel();
}

class _TaskRuntime {
  final DownloadTask task;
  final SendPort port;
  final CancelToken cancelToken = CancelToken();
  RandomAccessFile? _file;
  bool isCancelled = false;
  final List<ChunkStreamSubscription> literals = [];

  _TaskRuntime(this.task, this.port);

  Future<void> initialize() async {
    // any setup
  }

  Future<void> _openFile() async {
    final fileObj = File(task.savePath);
    if (!fileObj.existsSync()) {
      fileObj.createSync(recursive: true);
    }
    // FileMode.append preserves content and allows seeking on most platforms for RandomAccessFile
    _file = await fileObj.open(mode: FileMode.append);
  }

  void closeFile() {
    try {
      _file?.closeSync();
      _file = null;
    } catch (_) {}
  }

  void cancelAll() {
    isCancelled = true;
    cancelToken.cancel(); // Abort requests immediately
    for (var sub in literals) {
      sub.cancel();
    }
    literals.clear();
  }

  int _lastUpdate = 0;
  int _lastSave = 0;

  // Synchronous write to prevent race conditions in file pointer
  final Map<Chunk, BytesBuilder> _buffers = {};

  // Synchronous write to prevent race conditions in file pointer
  void write(Chunk chunk, List<int> data) {
    if (_file == null || isCancelled) return;

    // Initialize buffer if needed
    _buffers.putIfAbsent(chunk, () => BytesBuilder(copy: false)).add(data);

    // If buffer exceeds threshold (e.g. 1MB), flush it
    // 1MB * 16 chunks (max) = ~16MB RAM usage.
    // This reduces syscalls massively (16x compared to 64KB).
    // Trade-off: Progress bars might update slightly less frequently on very slow networks,
    // but for high-speed/background downloads, this is optimal.
    if (_buffers[chunk]!.length >= 1024 * 1024) {
      flush(chunk);
    }
  }

  void flush(Chunk chunk) {
    if (_file == null || isCancelled) return;
    final buffer = _buffers[chunk];
    if (buffer == null || buffer.isEmpty) return;

    final data = buffer.takeBytes();

    // ATOMIC BLOCK
    try {
      int offset = chunk.start + chunk.downloaded;
      _file!.setPositionSync(offset);
      _file!.writeFromSync(data);
      chunk.downloaded += data.length;
      _checkProgress();
    } catch (e) {
      isCancelled = true;
      port.send({
        'type': 'status',
        'taskId': task.id,
        'status': DownloadStatus.failed.index, // Using enum index
        'error': 'Write failed: $e'
      });
    }
  }

  void _checkProgress() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Throttle progress updates (500ms)
    if (now - _lastUpdate > 500) {
      _lastUpdate = now;
      port.send({
        'type': 'progress',
        'taskId': task.id,
        'progress': task.progress,
        'status': task.status.index
      });
    }

    // Throttle metadata saves (2 seconds)
    if (now - _lastSave > 2000) {
      _lastSave = now;
      saveMetadata();
    }
  }

  void saveMetadata() {
    try {
      final file = File('${task.savePath}.meta');
      file.writeAsStringSync(jsonEncode(task.toJson()));
    } catch (_) {
      // Ignore disk errors during throttle? or log?
    }
  }
}

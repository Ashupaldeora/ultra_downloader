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
        final taskId = message['taskId'] ?? message['task']?['id'];
        _log('Received command: $command for taskId: $taskId');

        switch (command) {
          case 'download':
            _startDownload(message['task'] as Map<String, dynamic>);
            break;
          case 'pause':
            _pauseDownload(taskId as String);
            break;
          case 'resume':
            _resumeDownload(taskId as String);
            break;
          case 'cancel':
            _cancelDownload(taskId as String);
            break;
        }
      }
    });
  }

  Future<void> _startDownload(Map<String, dynamic> taskJson) async {
    // 1. Initial Task Parsing
    var task = DownloadTask.fromJson(taskJson);

    // 2. Recovery Logic (Metadata Check)
    final metaFile = File('${task.savePath}.meta');
    if (metaFile.existsSync()) {
      try {
        final json = jsonDecode(metaFile.readAsStringSync());
        final oldTask = DownloadTask.fromJson(json);

        // Use the NEW ID passed from UI, but keep old state
        task = DownloadTask(
            id: taskJson['id'],
            url: task.url,
            savePath: task.savePath,
            headers: task.headers,
            strategy: task.strategy,
            totalSize: oldTask.totalSize,
            chunks: oldTask.chunks,
            status: oldTask.status,
            errorMessage: oldTask.errorMessage);

        if (task.status == DownloadStatus.completed) {
          // Verify file actually exists
          if (File(task.savePath).existsSync()) {
            _broadcastStatus(_TaskRuntime(task, _mainSendPort, _log));
            return;
          }
          // If missing, restart
          task.status = DownloadStatus.queued;
          task.chunks = [];
        }
      } catch (e) {
        _log("Meta file corrupt, ignoring: $e");
      }
    }

    if (_activeTasks.containsKey(task.id)) return;

    _pausedTasks.remove(task.id);

    final runtime = _TaskRuntime(task, _mainSendPort, _log);
    _activeTasks[task.id] = runtime;

    try {
      await runtime.initialize();

      // 3. Size & Chunk Calculation (if new)
      if (runtime.task.totalSize == 0 || runtime.task.chunks.isEmpty) {
        final totalSize = await _getContentLength(task.url, task.headers);
        runtime.task.totalSize = totalSize;
        runtime.task.chunks =
            ChunkManager.calculateChunks(totalSize, runtime.task.strategy);
        _saveMetadata(runtime.task);
      }

      // 4. Smart Resume (Partial Files Scan)
      // This updates chunk.downloaded based on actual disk usage
      await runtime.verifyPartialFiles();

      runtime.task.status = DownloadStatus.downloading;
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);

      // --- Processing Auxiliaries (Parallel Best Effort) ---
      if (runtime.task.auxiliaries.isNotEmpty) {
        final pendingAux =
            runtime.task.auxiliaries.where((a) => !a.isCompleted).toList();
        if (pendingAux.isNotEmpty) {
          _log("Processing ${pendingAux.length} auxiliaries...");
          await Future.wait(pendingAux.map((aux) async {
            if (runtime.isCancelled) return;
            try {
              await _downloadAuxiliary(runtime, aux);
              aux.isCompleted = true; // Mark done
              _saveMetadata(runtime.task); // Checkpoint
            } catch (e) {
              _log("⚠️ Auxiliary failed (ignoring): ${aux.url} -> $e");
              // Proceed despite error (Best Effort)
            }
          }));
        }
      }

      // 5. Fire Requests
      List<Future> futures = [];
      bool allCompleted = true;

      for (var chunk in runtime.task.chunks) {
        if (!chunk.isCompleted) {
          allCompleted = false;
          // Open the specific partial file for this chunk
          await runtime.openChunkFile(chunk);
          futures.add(_downloadChunk(runtime, chunk));
        }
      }

      if (allCompleted) {
        await _completeTask(runtime);
        return;
      }

      await Future.wait(futures);

      // Final verification
      if (runtime.task.chunks.every((c) => c.isCompleted) &&
          !runtime.isCancelled) {
        await _completeTask(runtime);
      }
    } catch (e, st) {
      if (runtime.isCancelled) return;
      _handleError(runtime, e, st);
    } finally {
      if (runtime.task.status != DownloadStatus.downloading) {
        _activeTasks.remove(task.id);
        runtime.closeAllFiles();
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

        if (start > end) return;

        final headers = Map<String, dynamic>.from(runtime.task.headers ?? {});
        headers['Range'] = 'bytes=$start-$end';

        final response = await _dio.get<ResponseBody>(
          runtime.task.url,
          cancelToken: runtime.cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: headers,
          ),
        );

        final stream = response.data!.stream;
        final completer = Completer();

        final subscription = ChunkStreamSubscription(stream.listen(
          (data) {
            if (runtime.isCancelled) {
              completer.complete();
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
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel || CancelToken.isCancel(e))
          return;

        retryCount++;
        if (retryCount >= maxRetries) rethrow;

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
      final response = await _dio.head(url, options: Options(headers: headers));
      final lenStr = response.headers.value('content-length');
      if (lenStr != null) return int.parse(lenStr);
      throw Exception('Could not determine content length');
    } catch (e) {
      throw Exception('Failed to head url: $e');
    }
  }

  void _pauseDownload(String taskId) {
    final runtime = _activeTasks[taskId];
    if (runtime != null) {
      runtime.task.status = DownloadStatus.paused;
      runtime.cancelAll();
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);
      _activeTasks.remove(taskId);
      _pausedTasks[taskId] = runtime.task;
      runtime.closeAllFiles();
    }
  }

  void _resumeDownload(String taskId) {
    if (_pausedTasks.containsKey(taskId)) {
      final task = _pausedTasks[taskId]!;
      _startDownload(task.toJson());
    } else {
      // Cannot resume if not active or paused (needs path from caller)
    }
  }

  void _cancelDownload(String taskId) {
    DownloadTask? taskToDelete;
    _TaskRuntime? runtime = _activeTasks[taskId];

    if (runtime != null) {
      // It's active
      taskToDelete = runtime.task;
      runtime.task.status = DownloadStatus.canceled;
      runtime.cancelAll();
      _activeTasks.remove(taskId);
      runtime.closeAllFiles();

      // Cleanup Partials for active task
      for (var chunk in runtime.task.chunks) {
        try {
          File(runtime.getPartPath(chunk)).deleteSync();
        } catch (_) {}
      }
    } else {
      // Check if it's paused
      taskToDelete = _pausedTasks[taskId];
      _pausedTasks.remove(taskId);
    }

    // Common Cleanup Logic
    if (taskToDelete != null) {
      // Delete Main File (if exists)
      try {
        final mainFile = File(taskToDelete.savePath);
        if (mainFile.existsSync()) mainFile.deleteSync();
        _log("Main file deleted: ${taskToDelete.savePath}");
      } catch (e) {
        _log("Failed to delete main file: $e");
      }

      // Delete Meta File
      try {
        final metaFile = File('${taskToDelete.savePath}.meta');
        if (metaFile.existsSync()) metaFile.deleteSync();
        _log("Meta file deleted for task: ${taskToDelete.id}");
      } catch (e) {
        _log("Failed to delete meta file: $e");
      }

      // Delete Partials
      for (var chunk in taskToDelete.chunks) {
        try {
          final partFile = File('${taskToDelete.savePath}.part.${chunk.id}');
          if (partFile.existsSync()) partFile.deleteSync();
        } catch (e) {
          _log("Failed to delete partial file for chunk ${chunk.id}: $e");
        }
      }
      _log("Partial files cleaned up for task: ${taskToDelete.id}");
    }

    _mainSendPort.send({
      'type': 'status',
      'taskId': taskId,
      'status': DownloadStatus.canceled.index
    });
  }

  Future<void> _completeTask(_TaskRuntime runtime) async {
    // MERGE LOGIC
    try {
      final destination = File(runtime.task.savePath);
      if (destination.existsSync()) destination.deleteSync();

      final sink = destination.openWrite(mode: FileMode.write);

      for (var chunk in runtime.task.chunks) {
        final partFile = File(runtime.getPartPath(chunk));
        if (!partFile.existsSync()) {
          throw Exception("Missing part file for chunk ${chunk.id}");
        }

        // Critical Size Check before Merge
        final partLen = partFile.lengthSync();
        final expectedLen = chunk.end - chunk.start + 1;
        // The last chunk might be smaller or exactly the size, but never larger.
        // Actually, for the last chunk, end is totalSize-1. So (end - start + 1) IS the expected size.
        // If the server doesn't support range requests correctly, we might get full file?
        // But here we assume we got ranges.

        if (partLen != expectedLen) {
          throw Exception(
              "Chunk ${chunk.id} size deviation! Expected $expectedLen, got $partLen. Aborting merge to prevent corruption.");
        }

        await sink.addStream(partFile.openRead());
      }

      // Delete parts only after all have been successfully written to the stream
      for (var chunk in runtime.task.chunks) {
        try {
          File(runtime.getPartPath(chunk)).deleteSync();
        } catch (e) {
          _log("Failed to delete merged part file ${chunk.id}: $e");
        }
      }

      await sink.flush();
      await sink.close();

      runtime.task.status = DownloadStatus.completed;
      // We keep metadata for existence checks, but maybe clear progress details?
      // Keeping identical to previous logic:
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);
      _activeTasks.remove(runtime.task.id);
      _pausedTasks.remove(runtime.task.id);
      runtime.closeAllFiles();
    } catch (e, st) {
      _handleError(runtime, e, st);
    }
  }

  void _handleError(_TaskRuntime runtime, Object e, StackTrace st) {
    runtime.task.status = DownloadStatus.failed;
    runtime.task.errorMessage = e.toString();
    _saveMetadata(runtime.task);
    _broadcastStatus(runtime);
    _activeTasks.remove(runtime.task.id);
    _pausedTasks.remove(runtime.task.id);
    runtime.closeAllFiles();
  }

  void _saveMetadata(DownloadTask task) {
    try {
      final file = File('${task.savePath}.meta');
      file.writeAsStringSync(jsonEncode(task.toJson()));
    } catch (e) {
      _log("Failed to save metadata: $e");
    }
  }

  void _broadcastStatus(_TaskRuntime runtime) {
    _mainSendPort.send({
      'type': 'progress',
      'taskId': runtime.task.id,
      'progress': runtime.task.progress,
      'status': runtime.task.status.index
    });

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

  Future<void> _downloadAuxiliary(
      _TaskRuntime runtime, AuxiliaryFile aux) async {
    int retries = 3;
    while (retries > 0) {
      if (runtime.isCancelled) return;
      try {
        final file = File(aux.savePath);
        if (!file.parent.existsSync()) file.parent.createSync(recursive: true);

        await _dio.download(aux.url, aux.savePath,
            options: Options(receiveTimeout: const Duration(minutes: 5)));
        return;
      } catch (e) {
        retries--;
        if (retries == 0) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
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

  // Map chunk ID to its open file handle
  final Map<int, RandomAccessFile> _openFiles = {};

  bool isCancelled = false;
  final List<ChunkStreamSubscription> literals = [];

  final void Function(String) logger;

  _TaskRuntime(this.task, this.port, this.logger);

  Future<void> initialize() async {}

  String getPartPath(Chunk chunk) => '${task.savePath}.part.${chunk.id}';

  Future<void> verifyPartialFiles() async {
    for (var chunk in task.chunks) {
      final file = File(getPartPath(chunk));
      if (file.existsSync()) {
        final len = file.lengthSync();
        final expectedChunkSize = chunk.end - chunk.start + 1;

        if (len > expectedChunkSize) {
          // If the file is larger than expected (overshot), it must be truncated to prevent corruption.
          // This can occur if a previous download attempt wrote more data than intended before a crash.
          try {
            final raf = file.openSync(mode: FileMode.append);
            raf.truncateSync(expectedChunkSize);
            raf.closeSync();
            chunk.downloaded = expectedChunkSize;
            logger(
                "Info: Truncated overshot chunk ${chunk.id}. Size adjusted: $len -> $expectedChunkSize");
          } catch (e) {
            logger("Error: Failed to truncate chunk ${chunk.id}: $e");

            // If truncation fails, the chunk is corrupt and cannot be recovered.
            // Delete the chunk and reset progress to 0 to force a redownload.
            try {
              file.deleteSync();
            } catch (deleteError) {
              logger("Failed to delete corrupt chunk file: $deleteError");
            }
            chunk.downloaded = 0;
          }
        } else {
          chunk.downloaded = len;
        }
      } else {
        chunk.downloaded = 0;
      }
    }
  }

  Future<void> openChunkFile(Chunk chunk) async {
    if (_openFiles.containsKey(chunk.id)) return;

    final fileObj = File(getPartPath(chunk));
    if (!fileObj.existsSync()) {
      fileObj.createSync(recursive: true);
    }

    // IMPORTANT: We use append mode so we continue where we left off.
    // verifyPartialFiles() ensures 'downloaded' matches file length.
    final raf = await fileObj.open(mode: FileMode.append);
    _openFiles[chunk.id] = raf;
  }

  void closeAllFiles() {
    for (var raf in _openFiles.values) {
      try {
        raf.closeSync();
      } catch (e) {
        logger("Failed to close file for chunk ${raf.path}: $e");
      }
    }
    _openFiles.clear();
  }

  void cancelAll() {
    isCancelled = true;
    cancelToken.cancel();
    for (var sub in literals) {
      sub.cancel();
    }
    literals.clear();
  }

  int _lastUpdate = 0;
  int _lastSave = 0;

  final Map<Chunk, BytesBuilder> _buffers = {};

  void write(Chunk chunk, List<int> data) {
    if (isCancelled) return;
    _buffers.putIfAbsent(chunk, () => BytesBuilder(copy: false)).add(data);
    if (_buffers[chunk]!.length >= 1024 * 1024) {
      // 1MB Buffer
      flush(chunk);
    }
  }

  void flush(Chunk chunk) {
    if (isCancelled) return;
    final buffer = _buffers[chunk];
    if (buffer == null || buffer.isEmpty) return;

    final raf = _openFiles[chunk.id];
    if (raf == null) return; // Should have been opened

    final data = buffer.takeBytes();
    try {
      raf.writeFromSync(data);
      chunk.downloaded += data.length;
      _checkProgress();
    } catch (e) {
      isCancelled = true;
      // report error
    }
  }

  void _checkProgress() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUpdate > 500) {
      _lastUpdate = now;
      port.send({
        'type': 'progress',
        'taskId': task.id,
        'progress': task.progress,
        'status': task.status.index
      });
    }

    if (now - _lastSave > 2000) {
      _lastSave = now;
      try {
        final file = File('${task.savePath}.meta');
        file.writeAsStringSync(jsonEncode(task.toJson()));
      } catch (e) {
        logger("Failed to auto-save metadata: $e");
      }
    }
  }
}

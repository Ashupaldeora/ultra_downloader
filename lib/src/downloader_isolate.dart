// =============================================================================
// ULTRA DOWNLOADER - Isolate-based Download Engine
// =============================================================================
//
// This file contains the core download logic running in a separate isolate.
// It handles chunked downloads, pause/resume, and file merging.
//
// ARCHITECTURE:
// - Main isolate sends commands (download, pause, resume, cancel)
// - This isolate processes commands and streams progress back
// - File I/O is buffered for performance but ALWAYS flushed before state changes
//
// CRITICAL: All buffer flushes MUST complete before:
// 1. Checking chunk completion status
// 2. Pausing/canceling downloads
// 3. Closing file handles
// 4. Merging part files
//
// =============================================================================

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
/// Spawned by UltraDownloader.initialize() in the main isolate.
void downloadIsolateEntry(SendPort sendPort) {
  final isolate = _DownloaderIsolate(sendPort);
  isolate.listen();
}

// =============================================================================
// _DownloaderIsolate - Core Download Controller
// =============================================================================

class _DownloaderIsolate {
  final SendPort _mainSendPort;
  final ReceivePort _isolateReceivePort = ReceivePort();

  /// Active downloads: taskId -> runtime state
  final Map<String, _TaskRuntime> _activeTasks = {};

  /// Paused downloads: taskId -> task metadata (kept for resume by ID)
  final Map<String, DownloadTask> _pausedTasks = {};

  final Dio _dio = Dio();

  _DownloaderIsolate(this._mainSendPort) {
    // Timeouts: connect quickly, but allow slow data on bad networks
    _dio.options.connectTimeout = const Duration(seconds: 30);
    // CRITICAL: receiveTimeout is time between data packets, NOT total download time.
    // For video downloads over slow/congested networks, we need a longer timeout.
    // 5 minutes allows for brief network hiccups without failing the download.
    _dio.options.receiveTimeout = const Duration(minutes: 5);
  }

  /// Sends a log message to the main isolate for debug output.
  void _log(String msg) {
    _mainSendPort.send({'type': 'log', 'msg': msg});
  }

  /// Starts listening for commands from the main isolate.
  void listen() {
    // Handshake: Send our ReceivePort to enable bidirectional communication
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

  // ===========================================================================
  // DOWNLOAD LIFECYCLE
  // ===========================================================================

  /// Initiates or resumes a download task.
  ///
  /// This method handles:
  /// 1. Parsing task metadata
  /// 2. Recovering from previous state (if .meta file exists)
  /// 3. Fetching content length and calculating chunks
  /// 4. Verifying partial files for accurate resume
  /// 5. Downloading auxiliary files (subtitles, etc.)
  /// 6. Firing parallel chunk downloads
  /// 7. Merging chunks into final file
  Future<void> _startDownload(Map<String, dynamic> taskJson) async {
    // -------------------------------------------------------------------------
    // PHASE 1: Initial Task Parsing
    // -------------------------------------------------------------------------
    var task = DownloadTask.fromJson(taskJson);

    // -------------------------------------------------------------------------
    // PHASE 2: Recovery Logic - Check for existing metadata
    // -------------------------------------------------------------------------
    final metaFile = File('${task.savePath}.meta');
    if (metaFile.existsSync()) {
      try {
        final json = jsonDecode(metaFile.readAsStringSync());
        final oldTask = DownloadTask.fromJson(json);

        // Preserve the NEW task ID from UI, but restore previous state
        task = DownloadTask(
            id: taskJson['id'],
            url: task.url,
            savePath: task.savePath,
            headers: task.headers,
            strategy: task.strategy,
            totalSize: oldTask.totalSize,
            chunks: oldTask.chunks,
            auxiliaries: oldTask.auxiliaries,
            status: oldTask.status,
            errorMessage: oldTask.errorMessage);

        // If metadata says completed, verify the file actually exists
        if (task.status == DownloadStatus.completed) {
          if (File(task.savePath).existsSync()) {
            _broadcastStatus(_TaskRuntime(task, _mainSendPort, _log));
            return; // Already done, nothing to do
          }
          // File missing despite "completed" status - restart from scratch
          _log(
              "Warning: Metadata says completed but file missing. Restarting.");
          task.status = DownloadStatus.queued;
          task.chunks = [];
        }
      } catch (e) {
        _log("Meta file corrupt, ignoring: $e");
      }
    }

    // Prevent duplicate downloads of the same task
    if (_activeTasks.containsKey(task.id)) {
      // Emit current state instead of silent return - prevents stale _startingTasks
      _log("Task ${task.id} already active, broadcasting current state");
      final existingRuntime = _activeTasks[task.id]!;
      _broadcastStatus(existingRuntime);
      return;
    }

    // Remove from paused queue (if was paused)
    _pausedTasks.remove(task.id);

    final runtime = _TaskRuntime(task, _mainSendPort, _log);
    _activeTasks[task.id] = runtime;

    try {
      await runtime.initialize();

      // -----------------------------------------------------------------------
      // PHASE 3: Size & Chunk Calculation (only for new downloads)
      // -----------------------------------------------------------------------
      if (runtime.task.totalSize == 0 || runtime.task.chunks.isEmpty) {
        final totalSize = await _getContentLength(task.url, task.headers);
        runtime.task.totalSize = totalSize;
        runtime.task.chunks =
            ChunkManager.calculateChunks(totalSize, runtime.task.strategy);
        _saveMetadata(runtime.task);
      }

      // -----------------------------------------------------------------------
      // PHASE 4: Smart Resume - Verify partial files on disk
      // This updates chunk.downloaded based on actual file sizes
      // -----------------------------------------------------------------------
      await runtime.verifyPartialFiles();

      runtime.task.status = DownloadStatus.downloading;
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);

      // -----------------------------------------------------------------------
      // PHASE 5: Process Auxiliary Files (parallel, best-effort)
      // These are small files like subtitles that should exist with the video
      // -----------------------------------------------------------------------
      if (runtime.task.auxiliaries.isNotEmpty) {
        final pendingAux =
            runtime.task.auxiliaries.where((a) => !a.isCompleted).toList();
        if (pendingAux.isNotEmpty) {
          _log("Processing ${pendingAux.length} auxiliaries...");
          await Future.wait(pendingAux.map((aux) async {
            if (runtime.isCancelled) return;
            try {
              await _downloadAuxiliary(runtime, aux);
              aux.isCompleted = true;
              _saveMetadata(runtime.task); // Checkpoint progress
            } catch (e) {
              _log("⚠️ Auxiliary failed (ignoring): ${aux.url} -> $e");
              // Best effort - don't fail main download for subtitle errors
            }
          }));
        }
      }

      // -----------------------------------------------------------------------
      // PHASE 6: Fire Parallel Chunk Downloads
      // -----------------------------------------------------------------------
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

      // All chunks were already complete (recovered from pause near 100%)
      if (allCompleted) {
        await _completeTask(runtime);
        return;
      }

      // Wait for all chunk downloads to complete (or error)
      // CRITICAL: We use eagerError: false so that if one chunk fails,
      // we wait for ALL chunks to either complete or be cancelled before proceeding.
      // This prevents the race condition where we close files while chunks are still writing.
      try {
        await Future.wait(futures, eagerError: false);
      } catch (e) {
        // One or more chunks failed. Cancel all remaining operations FIRST,
        // then let the error propagate up.
        _log("Chunk failure detected, cancelling remaining operations...");
        runtime.cancelAll();

        // Give running streams a moment to process cancellation
        await Future.delayed(const Duration(milliseconds: 100));

        rethrow;
      }

      // -----------------------------------------------------------------------
      // PHASE 7: CRITICAL - Flush ALL buffers before checking completion
      // -----------------------------------------------------------------------
      // This is essential! Each chunk stream calls flush() in its onDone,
      // but we must ensure ALL data is written to disk before we check
      // whether chunks are complete. Without this, small files or the last
      // few KB of any download can be lost.
      runtime.flushAllBuffers();

      // Brief delay to ensure all file I/O completes before verification
      await Future.delayed(const Duration(milliseconds: 100));

      // -----------------------------------------------------------------------
      // PHASE 8: Final Verification & Merge
      // -----------------------------------------------------------------------
      if (runtime.task.chunks.every((c) => c.isCompleted) &&
          !runtime.isCancelled) {
        await _completeTask(runtime);
      }
    } catch (e, st) {
      if (runtime.isCancelled) return;

      // CRITICAL: Cancel all operations BEFORE handling error!
      // This ensures no chunk is still writing when we close file handles.
      runtime.cancelAll();
      await Future.delayed(const Duration(milliseconds: 100));

      _handleError(runtime, e, st);
    } finally {
      // Cleanup: Remove from active tasks if not still downloading
      if (runtime.task.status != DownloadStatus.downloading) {
        _activeTasks.remove(task.id);
        runtime.closeAllFiles();
      }
    }
  }

  /// Downloads a single chunk using HTTP Range requests.
  ///
  /// Implements exponential backoff retry logic for transient failures.
  /// Data is buffered in memory (up to 1MB) before flushing to disk
  /// for performance optimization.
  Future<void> _downloadChunk(_TaskRuntime runtime, Chunk chunk) async {
    if (runtime.isCancelled) return;

    int retryCount = 0;
    const maxRetries = 5;

    while (retryCount < maxRetries && !runtime.isCancelled) {
      try {
        // Calculate byte range: resume from where we left off
        final start = chunk.start + chunk.downloaded;
        final end = chunk.end;

        // Already completed (can happen after verify + resume)
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
            // CRITICAL: Flush remaining buffer when stream completes
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
        return; // Success - exit retry loop
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel || CancelToken.isCancel(e)) {
          return; // Intentional cancellation, not an error
        }

        retryCount++;
        if (retryCount >= maxRetries) rethrow;

        // Exponential backoff: 2s, 4s, 8s, 16s, 32s
        int delay = pow(2, retryCount).toInt() * 1000;
        _log("Chunk ${chunk.id} retry $retryCount after ${delay}ms");
        await Future.delayed(Duration(milliseconds: delay));
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  /// Fetches the content length of a URL via HEAD request.
  Future<int> _getContentLength(
      String url, Map<String, dynamic>? headers) async {
    try {
      final response = await _dio.head(url, options: Options(headers: headers));
      final lenStr = response.headers.value('content-length');
      if (lenStr != null) return int.parse(lenStr);
      throw Exception('Server did not provide content-length header');
    } catch (e) {
      throw Exception('Failed to get content length: $e');
    }
  }

  // ===========================================================================
  // PAUSE / RESUME / CANCEL
  // ===========================================================================

  /// Pauses an active download.
  ///
  /// CRITICAL: We must flush all buffered data BEFORE marking as paused,
  /// otherwise data in memory will be lost and the resumed download will
  /// have gaps (causing corruption).
  void _pauseDownload(String taskId) {
    final runtime = _activeTasks[taskId];
    if (runtime == null) return;

    // Step 1: FLUSH ALL BUFFERS FIRST - This is critical!
    // Data in BytesBuilder must be written to disk before we close handles.
    runtime.flushAllBuffers();

    // Step 2: Now safe to mark as paused and cancel network operations
    runtime.task.status = DownloadStatus.paused;
    runtime.cancelAll();

    // Step 3: Save metadata with accurate progress (post-flush)
    _saveMetadata(runtime.task);
    _broadcastStatus(runtime);

    // Step 4: Cleanup - close file handles and move to paused queue
    _activeTasks.remove(taskId);
    _pausedTasks[taskId] = runtime.task;
    runtime.closeAllFiles();
  }

  /// Resumes a paused download.
  void _resumeDownload(String taskId) {
    if (_pausedTasks.containsKey(taskId)) {
      final task = _pausedTasks[taskId]!;
      _startDownload(task.toJson());
    } else {
      // Task not in paused queue - emit event so caller can re-submit with full data
      // This prevents stale _startingTasks entries in ForegroundService
      _log(
          "Resume failed: $taskId not in _pausedTasks, emitting failed status");
      _mainSendPort.send({
        'type': 'status',
        'taskId': taskId,
        'status': DownloadStatus.failed.index,
        'progress': 0.0,
      });
    }
  }

  /// Cancels a download and cleans up all associated files.
  void _cancelDownload(String taskId) {
    DownloadTask? taskToDelete;
    _TaskRuntime? runtime = _activeTasks[taskId];

    if (runtime != null) {
      // Active download - flush buffers before cleanup to ensure accurate state
      runtime.flushAllBuffers();

      taskToDelete = runtime.task;
      runtime.task.status = DownloadStatus.canceled;
      runtime.cancelAll();
      _activeTasks.remove(taskId);
      runtime.closeAllFiles();

      // Delete partial files for active task
      for (var chunk in runtime.task.chunks) {
        try {
          File(runtime.getPartPath(chunk)).deleteSync();
        } catch (_) {}
      }
    } else {
      // Check paused queue
      taskToDelete = _pausedTasks[taskId];
      _pausedTasks.remove(taskId);
    }

    // Common cleanup: delete main file, meta file, and any remaining partials
    if (taskToDelete != null) {
      // Delete main file (if exists)
      try {
        final mainFile = File(taskToDelete.savePath);
        if (mainFile.existsSync()) mainFile.deleteSync();
        _log("Main file deleted: ${taskToDelete.savePath}");
      } catch (e) {
        _log("Failed to delete main file: $e");
      }

      // Delete metadata file
      try {
        final metaFile = File('${taskToDelete.savePath}.meta');
        if (metaFile.existsSync()) metaFile.deleteSync();
        _log("Meta file deleted for task: ${taskToDelete.id}");
      } catch (e) {
        _log("Failed to delete meta file: $e");
      }

      // Delete any remaining partial files
      for (var chunk in taskToDelete.chunks) {
        try {
          final partFile = File('${taskToDelete.savePath}.part.${chunk.id}');
          if (partFile.existsSync()) partFile.deleteSync();
        } catch (e) {
          _log("Failed to delete partial file for chunk ${chunk.id}: $e");
        }
      }
      _log("Cleanup completed for task: ${taskToDelete.id}");
    }

    _mainSendPort.send({
      'type': 'status',
      'taskId': taskId,
      'status': DownloadStatus.canceled.index
    });
  }

  // ===========================================================================
  // COMPLETION & MERGE
  // ===========================================================================

  /// Merges all chunk part files into the final destination file.
  ///
  /// Optimized with buffered I/O (4MB chunks) to reduce the stall at 99%.
  /// CRITICAL: All file handles must be closed BEFORE reading part files.
  Future<void> _completeTask(_TaskRuntime runtime) async {
    try {
      // -----------------------------------------------------------------------
      // STEP 1: Close all file handles FIRST
      // -----------------------------------------------------------------------
      runtime.closeAllFiles();

      // -----------------------------------------------------------------------
      // STEP 2: Verify all chunks are present and correctly sized
      // -----------------------------------------------------------------------
      for (var chunk in runtime.task.chunks) {
        final partFile = File(runtime.getPartPath(chunk));
        if (!partFile.existsSync()) {
          throw Exception("Missing part file for chunk ${chunk.id}");
        }

        final partLen = partFile.lengthSync();
        final expectedLen = chunk.end - chunk.start + 1;

        // Check for incomplete chunk - undersized means download was interrupted
        // Oversized is OK (final flush may include extra, we read only what we need)
        if (partLen < expectedLen) {
          throw Exception(
              "Chunk ${chunk.id} incomplete! Expected $expectedLen bytes, "
              "got $partLen bytes. Download may have been interrupted.");
        }
      }

      // -----------------------------------------------------------------------
      // STEP 3: Merge with buffered I/O (4MB buffer for performance)
      // -----------------------------------------------------------------------
      final destination = File(runtime.task.savePath);
      if (destination.existsSync()) destination.deleteSync();

      // Sort chunks by ID for correct byte order
      final sortedChunks = List<Chunk>.from(runtime.task.chunks)
        ..sort((a, b) => a.id.compareTo(b.id));

      // Use RandomAccessFile for more control and better performance
      final raf = await destination.open(mode: FileMode.write);
      const bufferSize = 4 * 1024 * 1024; // 4MB buffer

      try {
        for (var chunk in sortedChunks) {
          final partFile = File(runtime.getPartPath(chunk));
          final partRaf = await partFile.open(mode: FileMode.read);

          try {
            while (true) {
              final bytes = await partRaf.read(bufferSize);
              if (bytes.isEmpty) break;
              await raf.writeFrom(bytes);
            }
          } finally {
            await partRaf.close();
          }
        }

        await raf.flush();
      } finally {
        await raf.close();
      }

      // -----------------------------------------------------------------------
      // STEP 4: VERIFY FINAL FILE SIZE
      // -----------------------------------------------------------------------
      final finalSize = destination.lengthSync();
      if (finalSize != runtime.task.totalSize) {
        throw Exception(
            "CORRUPTION DETECTED! Final file size $finalSize bytes does not "
            "match expected ${runtime.task.totalSize} bytes.");
      }
      _log("✅ Merge verified: $finalSize bytes");

      // -----------------------------------------------------------------------
      // STEP 5: Cleanup part files
      // -----------------------------------------------------------------------
      for (var chunk in runtime.task.chunks) {
        try {
          File(runtime.getPartPath(chunk)).deleteSync();
        } catch (e) {
          _log("Warning: Failed to delete part file ${chunk.id}: $e");
        }
      }

      // -----------------------------------------------------------------------
      // STEP 6: Update status and notify
      // -----------------------------------------------------------------------
      runtime.task.status = DownloadStatus.completed;
      _saveMetadata(runtime.task);
      _broadcastStatus(runtime);
      _activeTasks.remove(runtime.task.id);
      _pausedTasks.remove(runtime.task.id);
    } catch (e, st) {
      _handleError(runtime, e, st);
    }
  }

  // ===========================================================================
  // ERROR HANDLING & UTILITIES
  // ===========================================================================

  /// Handles download errors by updating status and notifying listeners.
  void _handleError(_TaskRuntime runtime, Object e, StackTrace st) {
    // CRITICAL: Flush all buffered data to preserve progress before marking failed.
    // Without this, retrying would have inaccurate progress and potential gaps.
    runtime.flushAllBuffers();

    runtime.task.status = DownloadStatus.failed;
    runtime.task.errorMessage = e.toString();
    _log("Download failed: $e\n$st");
    _saveMetadata(runtime.task);
    _broadcastStatus(runtime);
    _activeTasks.remove(runtime.task.id);
    _pausedTasks.remove(runtime.task.id);
    runtime.closeAllFiles();
  }

  /// Persists task metadata to disk for recovery after app restart.
  void _saveMetadata(DownloadTask task) {
    try {
      final file = File('${task.savePath}.meta');
      file.writeAsStringSync(jsonEncode(task.toJson()));
    } catch (e) {
      _log("Failed to save metadata: $e");
    }
  }

  /// Broadcasts progress/status update to main isolate and any registered monitors.
  ///
  /// When status is [DownloadStatus.completed], progress is forced to 1.0
  /// to ensure notifications always show 100% for completed downloads.
  void _broadcastStatus(_TaskRuntime runtime) {
    // Force 1.0 progress on completion - the merge is verified, so we know it's 100%
    final progress = runtime.task.status == DownloadStatus.completed
        ? 1.0
        : runtime.task.progress;

    final payload = {
      'type': 'progress',
      'taskId': runtime.task.id,
      'progress': progress,
      'status': runtime.task.status.index
    };

    _mainSendPort.send(payload);

    // Also notify any registered background monitors (e.g., for notifications)
    final monitorPort =
        IsolateNameServer.lookupPortByName('ultra_downloader_monitor_port');
    if (monitorPort != null) {
      monitorPort.send(payload);
    }
  }

  /// Downloads a small auxiliary file (e.g., subtitle, poster).
  /// Uses simple download (not chunked) with retry logic.
  /// Uses the same headers as the main download for CDN authentication.
  Future<void> _downloadAuxiliary(
      _TaskRuntime runtime, AuxiliaryFile aux) async {
    int retries = 3;
    while (retries > 0) {
      if (runtime.isCancelled) return;
      try {
        final file = File(aux.savePath);
        if (!file.parent.existsSync()) file.parent.createSync(recursive: true);

        // Use same headers as main download (excluding Range header)
        final headers = Map<String, dynamic>.from(runtime.task.headers ?? {});
        headers.remove('Range'); // Remove Range header if present

        await _dio.download(
          aux.url,
          aux.savePath,
          options: Options(
            receiveTimeout: const Duration(minutes: 5),
            headers: headers,
          ),
        );
        return;
      } catch (e) {
        retries--;
        if (retries == 0) rethrow;
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }
}

// =============================================================================
// Helper Classes
// =============================================================================

/// Wrapper for stream subscription to enable cancellation management.
class ChunkStreamSubscription {
  final StreamSubscription _sub;
  ChunkStreamSubscription(this._sub);
  void cancel() => _sub.cancel();
}

// =============================================================================
// _TaskRuntime - Per-Download State Manager
// =============================================================================
//
// Manages the runtime state of a single download task including:
// - File handles for each chunk's part file
// - Memory buffers for write optimization
// - Cancellation state
// - Progress tracking
//
// BUFFER STRATEGY:
// Data received from the network is accumulated in BytesBuilder buffers.
// When a buffer reaches 1MB, it's flushed to disk. This reduces I/O syscalls.
// CRITICAL: All buffers MUST be flushed before checking completion or pausing!
//
// =============================================================================

class _TaskRuntime {
  final DownloadTask task;
  final SendPort port;
  final CancelToken cancelToken = CancelToken();

  /// Open file handles: chunk ID -> RandomAccessFile
  final Map<int, RandomAccessFile> _openFiles = {};

  /// Cancellation flag - checked throughout the download process
  bool isCancelled = false;

  /// Active stream subscriptions (for cancellation)
  final List<ChunkStreamSubscription> literals = [];

  /// Logger function passed from isolate
  final void Function(String) logger;

  _TaskRuntime(this.task, this.port, this.logger);

  Future<void> initialize() async {}

  /// Returns the path to a chunk's partial file.
  String getPartPath(Chunk chunk) => '${task.savePath}.part.${chunk.id}';

  /// Verifies partial files on disk and updates chunk.downloaded accordingly.
  ///
  /// This is essential for accurate resume. If a partial file is larger than
  /// expected (overshot due to previous bug), it's truncated. If smaller,
  /// we use the actual size for accurate progress.
  Future<void> verifyPartialFiles() async {
    for (var chunk in task.chunks) {
      final file = File(getPartPath(chunk));
      if (file.existsSync()) {
        final len = file.lengthSync();
        final expectedChunkSize = chunk.end - chunk.start + 1;

        if (len > expectedChunkSize) {
          // OVERSHOT RECOVERY: File is larger than expected, truncate it.
          // This can occur if a previous download wrote more data than intended
          // before a crash or if there was a bug in buffer management.
          try {
            final raf = file.openSync(mode: FileMode.append);
            raf.truncateSync(expectedChunkSize);
            raf.closeSync();
            chunk.downloaded = expectedChunkSize;
            logger(
                "Info: Truncated overshot chunk ${chunk.id}. Size adjusted: $len -> $expectedChunkSize");
          } catch (e) {
            logger("Error: Failed to truncate chunk ${chunk.id}: $e");
            // If truncation fails, the chunk is corrupt and unrecoverable.
            // Delete it and reset progress to force redownload.
            try {
              file.deleteSync();
            } catch (deleteError) {
              logger("Failed to delete corrupt chunk file: $deleteError");
            }
            chunk.downloaded = 0;
          }
        } else {
          // Normal case: use actual file size
          chunk.downloaded = len;
        }
      } else {
        chunk.downloaded = 0;
      }
    }
  }

  /// Opens a chunk's partial file for appending.
  Future<void> openChunkFile(Chunk chunk) async {
    if (_openFiles.containsKey(chunk.id)) return;

    final fileObj = File(getPartPath(chunk));
    if (!fileObj.existsSync()) {
      fileObj.createSync(recursive: true);
    }

    // APPEND mode: continue writing where we left off
    // verifyPartialFiles() ensures 'downloaded' matches actual file length
    final raf = await fileObj.open(mode: FileMode.append);
    _openFiles[chunk.id] = raf;
  }

  /// Closes all open file handles.
  /// MUST be called before reading files for merge, or on cleanup.
  void closeAllFiles() {
    for (var entry in _openFiles.entries) {
      try {
        entry.value.closeSync();
      } catch (e) {
        logger("Failed to close file for chunk ${entry.key}: $e");
      }
    }
    _openFiles.clear();
  }

  /// Cancels all active operations (network requests and stream subscriptions).
  void cancelAll() {
    isCancelled = true;
    cancelToken.cancel();
    for (var sub in literals) {
      sub.cancel();
    }
    literals.clear();
  }

  // ---------------------------------------------------------------------------
  // BUFFERED WRITE SYSTEM
  // ---------------------------------------------------------------------------
  //
  // For performance, we buffer incoming data in memory (BytesBuilder) and
  // flush to disk when the buffer reaches 1MB. This significantly reduces
  // I/O syscalls compared to writing every packet immediately.
  //
  // CRITICAL: The flushAllBuffers() method MUST be called:
  // 1. Before checking chunk completion (data might still be in buffer)
  // 2. Before pausing (so progress is accurately recorded)
  // 3. Before closing file handles
  //
  // ---------------------------------------------------------------------------

  int _lastUpdate = 0;
  int _lastSave = 0;

  /// Per-chunk memory buffers
  final Map<Chunk, BytesBuilder> _buffers = {};

  /// Adds data to a chunk's buffer. Flushes to disk when buffer reaches 1MB.
  void write(Chunk chunk, List<int> data) {
    if (isCancelled) return;
    _buffers.putIfAbsent(chunk, () => BytesBuilder(copy: false)).add(data);
    if (_buffers[chunk]!.length >= 1024 * 1024) {
      // 1MB threshold reached - flush to disk
      flush(chunk);
    }
  }

  /// Flushes a single chunk's buffer to disk.
  void flush(Chunk chunk) {
    // NOTE: We intentionally DON'T check isCancelled here!
    // Even if cancelled, we must flush to preserve accurate progress.
    // The data is already received - discarding it would cause corruption on resume.

    final buffer = _buffers[chunk];
    if (buffer == null || buffer.isEmpty) return;

    final raf = _openFiles[chunk.id];
    if (raf == null) {
      // File handle not open - attempt recovery to prevent data loss
      logger(
          "⚠️ File handle null for chunk ${chunk.id}, attempting recovery flush...");
      try {
        final file = File('${task.savePath}.part.${chunk.id}');
        if (!file.existsSync()) {
          file.createSync(recursive: true);
        }
        final recoveryRaf = file.openSync(mode: FileMode.append);
        final data = buffer.takeBytes();
        recoveryRaf.writeFromSync(data);
        recoveryRaf.closeSync();
        chunk.downloaded += data.length;
        logger(
            "✅ Recovery flush successful for chunk ${chunk.id}: ${data.length} bytes");
        _checkProgress();
        return;
      } catch (e) {
        logger("❌ CRITICAL: Recovery flush failed for chunk ${chunk.id}: $e. "
            "Buffer has ${buffer.length} bytes that may be lost!");
        // Clear buffer anyway to prevent memory buildup
        buffer.takeBytes();
        return;
      }
    }

    final data = buffer.takeBytes();
    try {
      raf.writeFromSync(data);
      chunk.downloaded += data.length;
      _checkProgress();
    } catch (e) {
      logger("Error writing to chunk ${chunk.id}: $e");
      // Try recovery write before giving up
      try {
        final file = File('${task.savePath}.part.${chunk.id}');
        final recoveryRaf = file.openSync(mode: FileMode.append);
        recoveryRaf.writeFromSync(data);
        recoveryRaf.closeSync();
        chunk.downloaded += data.length;
        logger("✅ Recovery write successful after primary write error");
      } catch (recoveryError) {
        logger("❌ Recovery write failed: $recoveryError");
        isCancelled = true;
      }
    }
  }

  /// Flushes ALL chunk buffers to disk.
  /// CRITICAL: Must be called before completion check or pause/cancel!
  void flushAllBuffers() {
    for (var chunk in task.chunks) {
      flush(chunk);
    }
  }

  /// Throttled progress update - broadcasts every 500ms max.
  /// Also auto-saves metadata every 2 seconds.
  void _checkProgress() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Broadcast progress (throttled to every 500ms)
    if (now - _lastUpdate > 500) {
      _lastUpdate = now;
      port.send({
        'type': 'progress',
        'taskId': task.id,
        'progress': task.progress,
        'status': task.status.index
      });
    }

    // Auto-save metadata (throttled to every 2 seconds)
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

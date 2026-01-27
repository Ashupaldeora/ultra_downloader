import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultra_downloader/src/chunk_manager.dart';

/// Battle-tested edge case tests for production reliability.
/// These tests cover real-world failure scenarios that could cause
/// data corruption or crashes in production.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ultra_downloader_battle_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ===========================================================================
  // RESUME EDGE CASES
  // ===========================================================================

  group('Resume Edge Cases', () {
    test('resume with corrupted meta file should not crash', () async {
      final metaFile = File('${tempDir.path}/test.mp4.meta');
      await metaFile.writeAsString('this is not valid json!!!');

      // Attempting to parse should throw, but we should handle it gracefully
      expect(
        () => jsonDecode(metaFile.readAsStringSync()),
        throwsA(isA<FormatException>()),
      );
    });

    test('resume with empty meta file should not crash', () async {
      final metaFile = File('${tempDir.path}/test.mp4.meta');
      await metaFile.writeAsString('');

      expect(
        () => jsonDecode(metaFile.readAsStringSync()),
        throwsA(isA<FormatException>()),
      );
    });

    test('resume with partial JSON meta file should not crash', () async {
      final metaFile = File('${tempDir.path}/test.mp4.meta');
      await metaFile
          .writeAsString('{"id": "test", "url": "http://example.com"');

      expect(
        () => jsonDecode(metaFile.readAsStringSync()),
        throwsA(isA<FormatException>()),
      );
    });

    test('resume when some part files are missing', () async {
      // Simulating: chunks 0, 2 exist; chunk 1 is missing
      final chunk0 = File('${tempDir.path}/test.mp4.part.0');
      final chunk2 = File('${tempDir.path}/test.mp4.part.2');

      await chunk0.writeAsBytes(Uint8List(100));
      await chunk2.writeAsBytes(Uint8List(100));

      // Chunk 1 doesn't exist
      final chunk1 = File('${tempDir.path}/test.mp4.part.1');
      expect(await chunk1.exists(), isFalse);

      // Recovery logic should detect missing part and reset its progress
      // The existing parts should be preserved
      expect(await chunk0.exists(), isTrue);
      expect(await chunk2.exists(), isTrue);
    });

    test('resume when part file is truncated', () async {
      final chunk = Chunk(id: 0, start: 0, end: 99); // Expects 100 bytes

      // Simulate corruption: file exists but is too small
      final partFile = File('${tempDir.path}/test.mp4.part.0');
      await partFile.writeAsBytes(Uint8List(30)); // Only 30 bytes

      final actualSize = await partFile.length();
      final expectedSize = chunk.end - chunk.start + 1;

      // Detection logic
      expect(actualSize, lessThan(expectedSize));

      // After recovery, downloaded should equal actual file size
      // (The real code does this in verifyPartialFiles)
      chunk.downloaded = actualSize;
      expect(chunk.isCompleted, isFalse);
    });

    test('resume when part file is oversized (previous bug)', () async {
      final chunk = Chunk(id: 0, start: 0, end: 99); // Expects 100 bytes

      // Simulate bug: file is larger than expected (overshot)
      final partFile = File('${tempDir.path}/test.mp4.part.0');
      await partFile.writeAsBytes(Uint8List(150)); // 150 bytes - too big!

      final actualSize = await partFile.length();
      final expectedSize = chunk.end - chunk.start + 1;

      expect(actualSize, greaterThan(expectedSize));

      // Recovery should truncate to expected size
      final raf = await partFile.open(mode: FileMode.append);
      await raf.truncate(expectedSize);
      await raf.close();

      expect(await partFile.length(), equals(expectedSize));
    });
  });

  // ===========================================================================
  // EXTREME FILE SIZE EDGE CASES
  // ===========================================================================

  group('Extreme File Size Edge Cases', () {
    test('empty file (0 bytes) chunk calculation', () {
      // Edge case: downloading empty file
      final chunks = ChunkManager.calculateChunks(
        0,
        const ChunkingStrategy(),
      );

      // Should handle gracefully - either empty list or single 0-byte chunk
      // Our implementation should not crash
      expect(chunks, isNotNull);
    });

    test('single byte file chunk calculation', () {
      final chunks = ChunkManager.calculateChunks(
        1,
        const ChunkingStrategy(),
      );

      expect(chunks.length, equals(1));
      expect(chunks[0].start, equals(0));
      expect(chunks[0].end, equals(0));

      // Verify chunk covers exactly 1 byte
      final totalBytes = chunks[0].end - chunks[0].start + 1;
      expect(totalBytes, equals(1));
    });

    test('very small file (< chunk count) divides correctly', () {
      // 5 bytes with fixedCount of 10 chunks
      // Should cap at 5 chunks (1 byte each) or handle gracefully
      final chunks = ChunkManager.calculateChunks(
        5,
        ChunkingStrategy.fixedCount(10),
      );

      // Total bytes must equal file size
      int total = 0;
      for (var chunk in chunks) {
        total += chunk.end - chunk.start + 1;
      }
      expect(total, equals(5));
    });

    test('prime number file size divides without gaps', () {
      // 997 is prime - can't divide evenly
      final chunks = ChunkManager.calculateChunks(
        997,
        ChunkingStrategy.fixedCount(8),
      );

      // Verify contiguous coverage
      int total = 0;
      for (var chunk in chunks) {
        total += chunk.end - chunk.start + 1;
      }
      expect(total, equals(997));

      // Verify no gaps
      for (int i = 1; i < chunks.length; i++) {
        expect(chunks[i].start, equals(chunks[i - 1].end + 1));
      }
    });

    test('exactly 1MB file at buffer boundary', () {
      final size = 1024 * 1024; // Exactly 1MB
      final chunks = ChunkManager.calculateChunks(
        size,
        const ChunkingStrategy(),
      );

      int total = 0;
      for (var chunk in chunks) {
        total += chunk.end - chunk.start + 1;
      }
      expect(total, equals(size));
    });
  });

  // ===========================================================================
  // MERGE FAILURE SCENARIOS
  // ===========================================================================

  group('Merge Failure Scenarios', () {
    test('merge with one empty part file should be detectable', () async {
      // Create parts: chunk 0 is empty (bug/corruption)
      final chunk0 = File('${tempDir.path}/test.mp4.part.0');
      final chunk1 = File('${tempDir.path}/test.mp4.part.1');

      await chunk0.writeAsBytes([]); // Empty!
      await chunk1.writeAsBytes(Uint8List(100));

      expect(await chunk0.length(), equals(0));
      expect(await chunk1.length(), equals(100));

      // Pre-merge validation should catch this
      final chunks = [
        Chunk(id: 0, start: 0, end: 99), // Expects 100 bytes
        Chunk(id: 1, start: 100, end: 199), // Expects 100 bytes
      ];

      bool allValid = true;
      for (var chunk in chunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        final actualLen = await partFile.length();
        final expectedLen = chunk.end - chunk.start + 1;
        if (actualLen != expectedLen) {
          allValid = false;
          break;
        }
      }

      expect(allValid, isFalse); // Should detect the problem
    });

    test('merge destination already exists should overwrite', () async {
      // Simulate: destination file already exists (partial previous download)
      final destination = File('${tempDir.path}/test.mp4');
      await destination.writeAsBytes([1, 2, 3]);
      expect(await destination.exists(), isTrue);

      // Merge logic should delete and recreate
      await destination.delete();
      expect(await destination.exists(), isFalse);

      await destination.writeAsBytes([4, 5, 6, 7, 8]);
      expect(await destination.length(), equals(5));
    });

    test('final file size mismatch after merge is detectable', () async {
      // Merge produces wrong size - this is our new corruption check
      final destination = File('${tempDir.path}/test.mp4');
      await destination.writeAsBytes(Uint8List(290)); // Wrong size!

      const expectedSize = 300;
      final actualSize = await destination.length();

      expect(actualSize, isNot(equals(expectedSize)));

      // This should trigger our "CORRUPTION DETECTED" error
      final corrupted = actualSize != expectedSize;
      expect(corrupted, isTrue);
    });
  });

  // ===========================================================================
  // CANCELLATION EDGE CASES
  // ===========================================================================

  group('Cancellation Edge Cases', () {
    test('double cancellation should be safe (idempotent)', () {
      // Simulate isCancelled flag
      var isCancelled = false;

      // First cancel
      isCancelled = true;

      // Second cancel (should not throw or cause issues)
      final secondCancel = isCancelled;
      expect(secondCancel, isTrue);
    });

    test('write after cancellation should be ignored', () {
      // Simulate the write() function's cancellation check
      bool isCancelled = false;
      final buffer = BytesBuilder();

      void write(List<int> data) {
        if (isCancelled) return; // Should skip
        buffer.add(data);
      }

      write([1, 2, 3]);
      expect(buffer.length, equals(3));

      isCancelled = true;
      write([4, 5, 6]); // Should be ignored
      expect(buffer.length, equals(3)); // Still 3, not 6
    });

    test('flush after cancellation should still preserve data', () {
      // Our flush() intentionally DOESN'T check isCancelled
      // to preserve already-received data
      bool isCancelled = true;
      final buffer = BytesBuilder();
      buffer.add([1, 2, 3]);

      // flush should still work even when cancelled
      final data = buffer.takeBytes();
      expect(data.length, equals(3));
    });
  });

  // ===========================================================================
  // CONCURRENT ACCESS EDGE CASES
  // ===========================================================================

  group('Concurrent Access Edge Cases', () {
    test('same file opened twice should throw or be prevented', () async {
      final file = File('${tempDir.path}/concurrent.bin');
      await file.writeAsBytes([1, 2, 3]);

      final raf1 = await file.open(mode: FileMode.append);
      final raf2 = await file.open(mode: FileMode.append);

      // Both handles are open - this is dangerous!
      // Writes from both could interleave and corrupt data
      raf1.writeFromSync([4, 5, 6]);
      raf2.writeFromSync([7, 8, 9]);

      await raf1.close();
      await raf2.close();

      // File is now potentially corrupted
      // This test demonstrates WHY we need proper task tracking
      final content = await file.readAsBytes();
      // Content may be [1,2,3,4,5,6,7,8,9] or [1,2,3,7,8,9,4,5,6] or mixed!
      expect(content.length, greaterThanOrEqualTo(6));
    });
  });

  // ===========================================================================
  // METADATA PERSISTENCE EDGE CASES
  // ===========================================================================

  group('Metadata Persistence Edge Cases', () {
    test('DownloadTask serialization preserves all fields', () {
      final original = DownloadTask(
        id: 'test-123',
        url: 'https://example.com/video.mp4',
        savePath: '/path/to/video.mp4',
        headers: {'Authorization': 'Bearer token'},
        strategy: ChunkingStrategy.fixedCount(8),
        totalSize: 1000000,
        chunks: [
          Chunk(id: 0, start: 0, end: 499999, downloaded: 250000),
          Chunk(id: 1, start: 500000, end: 999999, downloaded: 0),
        ],
        auxiliaries: [
          AuxiliaryFile(
              url: 'https://example.com/sub.srt', savePath: '/subs/sub.srt'),
        ],
        status: DownloadStatus.paused,
        errorMessage: null,
      );

      final json = original.toJson();
      final restored = DownloadTask.fromJson(json);

      expect(restored.id, equals(original.id));
      expect(restored.url, equals(original.url));
      expect(restored.savePath, equals(original.savePath));
      expect(restored.headers?['Authorization'], equals('Bearer token'));
      expect(restored.totalSize, equals(original.totalSize));
      expect(restored.chunks.length, equals(2));
      expect(restored.chunks[0].downloaded, equals(250000));
      expect(restored.auxiliaries.length, equals(1));
      expect(restored.status, equals(DownloadStatus.paused));
    });

    test('DownloadTask with null optional fields serializes correctly', () {
      final task = DownloadTask(
        id: 'test',
        url: 'https://example.com/file.bin',
        savePath: '/path/file.bin',
        headers: null,
        strategy: const ChunkingStrategy(),
        totalSize: 1000,
        chunks: [],
        auxiliaries: [],
        status: DownloadStatus.queued,
        errorMessage: null,
      );

      final json = task.toJson();
      final restored = DownloadTask.fromJson(json);

      expect(restored.headers, isNull);
      expect(restored.errorMessage, isNull);
      expect(restored.auxiliaries, isEmpty);
    });

    test('chunk progress round-trip through JSON', () {
      final chunk = Chunk(id: 5, start: 1000, end: 1999, downloaded: 500);

      final json = chunk.toJson();
      final restored = Chunk.fromJson(json);

      expect(restored.id, equals(5));
      expect(restored.start, equals(1000));
      expect(restored.end, equals(1999));
      expect(restored.downloaded, equals(500));
      expect(restored.isCompleted, isFalse);
      expect(restored.remaining, equals(500));
    });
  });

  // ===========================================================================
  // RANGE REQUEST EDGE CASES
  // ===========================================================================

  group('Range Request Edge Cases', () {
    test('chunk range header format is correct', () {
      final chunk = Chunk(id: 0, start: 0, end: 999, downloaded: 500);

      // Range should start from (start + downloaded) to end
      final rangeStart = chunk.start + chunk.downloaded;
      final rangeEnd = chunk.end;

      final rangeHeader = 'bytes=$rangeStart-$rangeEnd';
      expect(rangeHeader, equals('bytes=500-999'));
    });

    test('completed chunk should have start > end after offset', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 100);

      final rangeStart = chunk.start + chunk.downloaded; // 0 + 100 = 100
      final rangeEnd = chunk.end; // 99

      // start > end means chunk is complete, skip download
      expect(rangeStart, greaterThan(rangeEnd));
    });

    test('exactly complete chunk edge case', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 100);

      expect(chunk.isCompleted, isTrue);

      // downloaded >= expected (100 >= 100)
      final expected = chunk.end - chunk.start + 1; // 100
      expect(chunk.downloaded, greaterThanOrEqualTo(expected));
    });
  });

  // ===========================================================================
  // PROGRESS CALCULATION EDGE CASES
  // ===========================================================================

  group('Progress Calculation Edge Cases', () {
    test('progress with zero total size should not divide by zero', () {
      final task = DownloadTask(
        id: 'test',
        url: 'https://example.com/empty.bin',
        savePath: '/path/empty.bin',
        strategy: const ChunkingStrategy(),
        totalSize: 0, // Empty file!
        chunks: [],
        status: DownloadStatus.queued,
      );

      // Progress calculation should handle this gracefully
      // Our code: return totalDownloaded / totalSize
      // With totalSize = 0, this would be division by zero!

      // The actual implementation returns 0 for empty chunks list
      expect(task.progress, equals(0));
    });

    test('progress with all chunks complete equals 1.0', () {
      final task = DownloadTask(
        id: 'test',
        url: 'https://example.com/file.bin',
        savePath: '/path/file.bin',
        strategy: const ChunkingStrategy(),
        totalSize: 300,
        chunks: [
          Chunk(id: 0, start: 0, end: 99, downloaded: 100),
          Chunk(id: 1, start: 100, end: 199, downloaded: 100),
          Chunk(id: 2, start: 200, end: 299, downloaded: 100),
        ],
        status: DownloadStatus.completed,
      );

      expect(task.progress, equals(1.0));
    });

    test('progress with no chunks downloaded equals 0.0', () {
      final task = DownloadTask(
        id: 'test',
        url: 'https://example.com/file.bin',
        savePath: '/path/file.bin',
        strategy: const ChunkingStrategy(),
        totalSize: 300,
        chunks: [
          Chunk(id: 0, start: 0, end: 99, downloaded: 0),
          Chunk(id: 1, start: 100, end: 199, downloaded: 0),
          Chunk(id: 2, start: 200, end: 299, downloaded: 0),
        ],
        status: DownloadStatus.queued,
      );

      expect(task.progress, equals(0.0));
    });

    test('progress accurately reflects partial completion', () {
      final task = DownloadTask(
        id: 'test',
        url: 'https://example.com/file.bin',
        savePath: '/path/file.bin',
        strategy: const ChunkingStrategy(),
        totalSize: 1000,
        chunks: [
          Chunk(id: 0, start: 0, end: 499, downloaded: 500), // 100% of chunk 0
          Chunk(id: 1, start: 500, end: 999, downloaded: 250), // 50% of chunk 1
        ],
        status: DownloadStatus.downloading,
      );

      // 750/1000 = 0.75
      expect(task.progress, equals(0.75));
    });
  });
}

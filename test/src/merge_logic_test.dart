import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ultra_downloader/src/chunk_manager.dart';

/// Tests for the merge and file operations logic.
/// These tests verify that chunks are correctly merged into a final file.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ultra_downloader_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('File Merge Logic', () {
    test('merging chunks produces correct file size', () async {
      // Create test chunks with known data
      final chunks = [
        Chunk(id: 0, start: 0, end: 99), // 100 bytes
        Chunk(id: 1, start: 100, end: 199), // 100 bytes
        Chunk(id: 2, start: 200, end: 299), // 100 bytes
      ];

      // Write part files
      for (var chunk in chunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        final data = Uint8List(chunk.end - chunk.start + 1);
        // Fill with chunk ID so we can verify order
        for (int i = 0; i < data.length; i++) {
          data[i] = chunk.id;
        }
        await partFile.writeAsBytes(data);
      }

      // Merge (simulating the actual merge logic)
      final destination = File('${tempDir.path}/test.mp4');
      final sink = destination.openWrite(mode: FileMode.write);

      // CRITICAL: Sort chunks by ID before merging
      final sortedChunks = List<Chunk>.from(chunks)
        ..sort((a, b) => a.id.compareTo(b.id));

      for (var chunk in sortedChunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        await sink.addStream(partFile.openRead());
      }
      await sink.flush();
      await sink.close();

      // Verify
      expect(await destination.exists(), isTrue);
      expect(await destination.length(), equals(300));

      // Verify content order
      final content = await destination.readAsBytes();
      expect(content[0], equals(0)); // First 100 bytes from chunk 0
      expect(content[100], equals(1)); // Next 100 bytes from chunk 1
      expect(content[200], equals(2)); // Last 100 bytes from chunk 2
    });

    test('unsorted chunks still merge correctly when sorted', () async {
      // Create chunks in WRONG order (simulating JSON parse edge case)
      final chunks = [
        Chunk(id: 2, start: 200, end: 299), // Out of order!
        Chunk(id: 0, start: 0, end: 99),
        Chunk(id: 1, start: 100, end: 199),
      ];

      // Write part files
      for (var chunk in chunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        final data = Uint8List(chunk.end - chunk.start + 1);
        for (int i = 0; i < data.length; i++) {
          data[i] = chunk.id;
        }
        await partFile.writeAsBytes(data);
      }

      // Merge WITH sorting
      final destination = File('${tempDir.path}/test.mp4');
      final sink = destination.openWrite(mode: FileMode.write);

      final sortedChunks = List<Chunk>.from(chunks)
        ..sort((a, b) => a.id.compareTo(b.id));

      for (var chunk in sortedChunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        await sink.addStream(partFile.openRead());
      }
      await sink.flush();
      await sink.close();

      // Verify content is in correct order despite unsorted input
      final content = await destination.readAsBytes();
      expect(content[0], equals(0));
      expect(content[100], equals(1));
      expect(content[200], equals(2));
    });

    test('unsorted chunks WITHOUT sorting cause corruption', () async {
      // This test proves WHY we need sorting
      final chunks = [
        Chunk(id: 2, start: 200, end: 299),
        Chunk(id: 0, start: 0, end: 99),
        Chunk(id: 1, start: 100, end: 199),
      ];

      for (var chunk in chunks) {
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        final data = Uint8List(chunk.end - chunk.start + 1);
        for (int i = 0; i < data.length; i++) {
          data[i] = chunk.id;
        }
        await partFile.writeAsBytes(data);
      }

      // Merge WITHOUT sorting (the OLD buggy way)
      final destination = File('${tempDir.path}/test_bad.mp4');
      final sink = destination.openWrite(mode: FileMode.write);

      for (var chunk in chunks) {
        // No sorting!
        final partFile = File('${tempDir.path}/test.mp4.part.${chunk.id}');
        await sink.addStream(partFile.openRead());
      }
      await sink.flush();
      await sink.close();

      // This produces WRONG content order (corrupted file)
      final content = await destination.readAsBytes();
      expect(content[0], equals(2)); // WRONG! Should be 0
      expect(content[100], equals(0)); // WRONG! Should be 1
      expect(content[200], equals(1)); // WRONG! Should be 2
    });
  });

  group('Chunk Size Verification', () {
    test('detects incomplete chunk', () async {
      final chunk = Chunk(id: 0, start: 0, end: 99); // Expects 100 bytes

      // Write incomplete part file (only 50 bytes)
      final partFile = File('${tempDir.path}/test.mp4.part.0');
      await partFile.writeAsBytes(Uint8List(50));

      final partLen = await partFile.length();
      final expectedLen = chunk.end - chunk.start + 1;

      expect(partLen, isNot(equals(expectedLen)));
      expect(partLen, lessThan(expectedLen));
    });

    test('detects oversized chunk', () async {
      final chunk = Chunk(id: 0, start: 0, end: 99); // Expects 100 bytes

      // Write oversized part file (150 bytes)
      final partFile = File('${tempDir.path}/test.mp4.part.0');
      await partFile.writeAsBytes(Uint8List(150));

      final partLen = await partFile.length();
      final expectedLen = chunk.end - chunk.start + 1;

      expect(partLen, isNot(equals(expectedLen)));
      expect(partLen, greaterThan(expectedLen));
    });
  });

  group('Buffer Write Simulation', () {
    test('buffered writes accumulate correctly', () async {
      // Simulates the BytesBuilder buffer behavior
      final buffer = BytesBuilder(copy: false);

      // Simulate receiving data packets
      buffer.add([1, 2, 3]);
      buffer.add([4, 5, 6]);
      buffer.add([7, 8, 9]);

      expect(buffer.length, equals(9));

      // Flush (take bytes clears the buffer)
      final data = buffer.takeBytes();
      expect(data.length, equals(9));
      expect(buffer.length, equals(0));

      // Verify data integrity
      expect(data, equals([1, 2, 3, 4, 5, 6, 7, 8, 9]));
    });

    test('taking bytes from empty buffer returns empty list', () {
      final buffer = BytesBuilder(copy: false);
      final data = buffer.takeBytes();
      expect(data.length, equals(0));
    });

    test('multiple flush cycles work correctly', () {
      final buffer = BytesBuilder(copy: false);

      // First cycle
      buffer.add([1, 2, 3]);
      var data = buffer.takeBytes();
      expect(data, equals([1, 2, 3]));

      // Second cycle
      buffer.add([4, 5, 6]);
      data = buffer.takeBytes();
      expect(data, equals([4, 5, 6]));

      // Third cycle
      buffer.add([7, 8, 9]);
      data = buffer.takeBytes();
      expect(data, equals([7, 8, 9]));
    });
  });

  group('Chunk Progress Tracking', () {
    test('isCompleted is true when downloaded equals chunk size', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 100);
      expect(chunk.isCompleted, isTrue);
    });

    test('isCompleted is false when download is incomplete', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 50);
      expect(chunk.isCompleted, isFalse);
    });

    test('isCompleted handles edge case of 0 bytes', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 0);
      expect(chunk.isCompleted, isFalse);
    });

    test('chunk remaining bytes calculation', () {
      final chunk = Chunk(id: 0, start: 0, end: 99, downloaded: 30);
      expect(chunk.remaining, equals(70));
    });
  });

  group('File Handle Safety', () {
    test('writing to closed file throws', () async {
      final file = File('${tempDir.path}/test_handle.bin');
      final raf = await file.open(mode: FileMode.write);
      await raf.close();

      // Attempting to write after close should throw
      expect(
        () => raf.writeFromSync([1, 2, 3]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('sync write completes before function returns', () async {
      final file = File('${tempDir.path}/test_sync.bin');
      final raf = await file.open(mode: FileMode.write);

      raf.writeFromSync([1, 2, 3, 4, 5]);
      raf.closeSync();

      // File should contain exactly what we wrote
      final content = await file.readAsBytes();
      expect(content, equals([1, 2, 3, 4, 5]));
    });
  });
}

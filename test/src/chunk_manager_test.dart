import 'package:flutter_test/flutter_test.dart';
import 'package:ultra_downloader/src/chunk_manager.dart';

void main() {
  group('ChunkManager', () {
    test('calculateChunks fixedCount', () {
      const totalSize = 1000;
      final strategy = const ChunkingStrategy.fixedCount(4);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 4);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 249);
      expect(chunks[3].end, 999);
    });

    test('calculateChunks fixedCount single chunk', () {
      const totalSize = 1000;
      final strategy = const ChunkingStrategy.fixedCount(1);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 1);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 999);
    });

    test('calculateChunks fixedSize', () {
      const totalSize = 1000;
      final strategy = const ChunkingStrategy.fixedSize(250); // 4 chunks
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 4);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 249);
      expect(chunks[3].end, 999);
    });

    test('calculateChunks fixedSize exact division', () {
      const totalSize = 1024;
      final strategy = const ChunkingStrategy.fixedSize(512); // 2 chunks
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 2);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 511);
      expect(chunks[1].start, 512);
      expect(chunks[1].end, 1023);
    });

    test('calculateChunks fixedSize remainder', () {
      const totalSize = 1025;
      final strategy = const ChunkingStrategy.fixedSize(512); // 3 chunks
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 3);
      // Implementation divides 1025 / 3 = 342 bytes per chunk
      // Chunk 0: 0-341
      // Chunk 1: 342-683
      // Chunk 2: 684-1024
      expect(chunks[2].start, 684);
      expect(chunks[2].end, 1024);
    });

    test('calculateChunks auto small file', () {
      const totalSize = 10 * 1024 * 1024; // 10MB
      final strategy = const ChunkingStrategy(type: StrategyType.auto);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 1);
    });

    test('calculateChunks auto medium file', () {
      const totalSize = 50 * 1024 * 1024; // 50MB
      final strategy = const ChunkingStrategy(type: StrategyType.auto);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 4);
    });

    test('calculateChunks auto large file', () {
      const totalSize = 200 * 1024 * 1024; // 200MB
      final strategy = const ChunkingStrategy(type: StrategyType.auto);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 8);
    });

    test('calculateChunks auto very large file', () {
      const totalSize = 600 * 1024 * 1024; // 600MB
      final strategy = const ChunkingStrategy(type: StrategyType.auto);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 16);
    });

    test('calculateChunks contiguous check', () {
      const totalSize = 1234567;
      final strategy = const ChunkingStrategy.fixedCount(5);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      for (int i = 0; i < chunks.length - 1; i++) {
        expect(chunks[i].end + 1, chunks[i + 1].start,
            reason: 'Gap between chunk $i and ${i + 1}');
      }
      expect(chunks.last.end, totalSize - 1);
    });

    test('calculateChunks max count safety', () {
      // Huge number of chunks requested, should cap at 32
      const totalSize = 1000000;
      final strategy = const ChunkingStrategy.fixedCount(100);
      final chunks = ChunkManager.calculateChunks(totalSize, strategy);

      expect(chunks.length, 32);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ultra_downloader/src/chunk_manager.dart';

void main() {
  group('Chunk', () {
    test('serialization', () {
      final chunk = Chunk(id: 1, start: 0, end: 100, downloaded: 50);
      final json = chunk.toJson();
      final fromJson = Chunk.fromJson(json);

      expect(fromJson.id, 1);
      expect(fromJson.start, 0);
      expect(fromJson.end, 100);
      expect(fromJson.downloaded, 50);
    });

    test('properties', () {
      final chunk = Chunk(id: 1, start: 0, end: 99, downloaded: 50); // Size 100
      expect(chunk.remaining, 50);
      expect(chunk.isCompleted, false);
      expect(chunk.currentOffset, 50);

      final completedChunk = Chunk(id: 1, start: 0, end: 99, downloaded: 100);
      expect(completedChunk.remaining, 0);
      expect(completedChunk.isCompleted, true);
    });
  });

  group('DownloadTask', () {
    test('serialization', () {
      final task = DownloadTask(
        id: '123',
        url: 'http://example.com',
        savePath: '/tmp/file',
        headers: {'User-Agent': 'Test'},
        strategy: const ChunkingStrategy.fixedCount(2),
        totalSize: 1000,
        chunks: [
          Chunk(id: 0, start: 0, end: 499),
          Chunk(id: 1, start: 500, end: 999)
        ],
        status: DownloadStatus.downloading,
      );

      final json = task.toJson();
      final fromJson = DownloadTask.fromJson(json);

      expect(fromJson.id, '123');
      expect(fromJson.url, 'http://example.com');
      expect(fromJson.headers?['User-Agent'], 'Test');
      expect(fromJson.strategy.type, StrategyType.fixedCount);
      expect(fromJson.chunks.length, 2);
      expect(fromJson.status, DownloadStatus.downloading);
    });

    test('progress calculation', () {
      final task = DownloadTask(
        id: '1',
        url: 'url',
        savePath: 'path',
        totalSize: 100,
        chunks: [
          Chunk(id: 0, start: 0, end: 49, downloaded: 25),
          Chunk(id: 1, start: 50, end: 99, downloaded: 25),
        ],
      );

      expect(task.progress, 0.5); // 50/100

      task.chunks[0].downloaded = 50;
      task.chunks[1].downloaded = 50;
      expect(task.progress, 1.0);
    });

    test('progress calculation empty', () {
      final task =
          DownloadTask(id: '1', url: 'url', savePath: 'path', totalSize: 0);
      expect(task.progress, 0.0);
    });
  });
}

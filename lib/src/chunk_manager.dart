import 'dart:math';

/// Defines how the file should be split into chunks.
class ChunkingStrategy {
  final StrategyType type;
  final int value;

  const ChunkingStrategy({
    this.type = StrategyType.auto,
    this.value = 0,
  });

  /// Strategy to use a fixed number of chunks.
  const ChunkingStrategy.fixedCount(int count)
      : type = StrategyType.fixedCount,
        value = count;

  /// Strategy to use a fixed size per chunk (in bytes).
  /// For example, 1024 * 1024 * 4 for 4MB.
  const ChunkingStrategy.fixedSize(int sizeInBytes)
      : type = StrategyType.fixedSize,
        value = sizeInBytes;

  factory ChunkingStrategy.fromJson(Map<String, dynamic> json) {
    return ChunkingStrategy(
      type: StrategyType.values[json['type'] as int],
      value: json['value'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.index,
      'value': value,
    };
  }
}

enum StrategyType {
  auto,
  fixedCount,
  fixedSize,
}

/// Represents a single download chunk.
class Chunk {
  final int id;
  final int start;
  final int end;
  int downloaded;

  Chunk({
    required this.id,
    required this.start,
    required this.end,
    this.downloaded = 0,
  });

  int get remaining => (end - start + 1) - downloaded;
  bool get isCompleted => downloaded >= (end - start + 1);
  int get currentOffset => start + downloaded;

  factory Chunk.fromJson(Map<String, dynamic> json) {
    return Chunk(
      id: json['id'] as int,
      start: json['start'] as int,
      end: json['end'] as int,
      downloaded: json['downloaded'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'start': start,
      'end': end,
      'downloaded': downloaded,
    };
  }
}

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  canceled,
}

/// Represents the state of a download task.
class DownloadTask {
  final String id;
  final String url;
  final String savePath;
  final Map<String, dynamic>? headers;
  final ChunkingStrategy strategy;
  int totalSize;
  List<Chunk> chunks;
  List<AuxiliaryFile> auxiliaries; // Added
  DownloadStatus status;
  String? errorMessage;

  DownloadTask({
    required this.id,
    required this.url,
    required this.savePath,
    this.headers,
    this.strategy = const ChunkingStrategy(),
    this.totalSize = 0,
    this.chunks = const [],
    this.auxiliaries = const [], // Added
    this.status = DownloadStatus.queued,
    this.errorMessage,
  });

  double get progress {
    if (totalSize == 0) return 0.0;
    int totalDownloaded =
        chunks.fold(0, (sum, chunk) => sum + chunk.downloaded);
    return totalDownloaded / totalSize;
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      url: json['url'] as String,
      savePath: json['savePath'] as String,
      headers: json['headers'] as Map<String, dynamic>?,
      strategy: ChunkingStrategy.fromJson(json['strategy']),
      totalSize: json['totalSize'] as int,
      chunks: (json['chunks'] as List)
          .map((e) => Chunk.fromJson(e as Map<String, dynamic>))
          .toList(),
      auxiliaries: (json['auxiliaries'] as List?)
              ?.map((e) => AuxiliaryFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [], // Added
      status: DownloadStatus.values[json['status'] as int],
      errorMessage: json['errorMessage'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'savePath': savePath,
      'headers': headers,
      'strategy': strategy.toJson(),
      'totalSize': totalSize,
      'chunks': chunks.map((e) => e.toJson()).toList(),
      'auxiliaries': auxiliaries.map((e) => e.toJson()).toList(), // Added
      'status': status.index,
      'errorMessage': errorMessage,
    };
  }
}

/// Represents a small auxiliary file (e.g., subtitle, image)
/// that must be downloaded before/alongside the main task.
class AuxiliaryFile {
  final String url;
  final String savePath;
  bool isCompleted;

  AuxiliaryFile({
    required this.url,
    required this.savePath,
    this.isCompleted = false,
  });

  factory AuxiliaryFile.fromJson(Map<String, dynamic> json) {
    return AuxiliaryFile(
      url: json['url'] as String,
      savePath: json['savePath'] as String,
      isCompleted: json['isCompleted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'savePath': savePath,
      'isCompleted': isCompleted,
    };
  }
}

/// Logic for calculating chunks.
class ChunkManager {
  static List<Chunk> calculateChunks(int totalSize, ChunkingStrategy strategy) {
    int count = 1;

    switch (strategy.type) {
      case StrategyType.fixedCount:
        count = max(1, strategy.value);
        break;
      case StrategyType.fixedSize:
        if (strategy.value > 0) {
          count = (totalSize / strategy.value).ceil();
        }
        break;
      case StrategyType.auto:
        // Ultra Downloader Smart Logic
        if (totalSize < 20 * 1024 * 1024) {
          count = 1; // < 20MB
        } else if (totalSize < 100 * 1024 * 1024) {
          count = 4; // 20MB - 100MB
        } else if (totalSize < 500 * 1024 * 1024) {
          count = 8; // 100MB - 500MB
        } else {
          count = 12; // > 500MB
        }
        break;
    }

    // Safety cap
    if (count > 32) count = 32;

    List<Chunk> chunks = [];
    int chunkSize = (totalSize / count).ceil();

    for (int i = 0; i < count; i++) {
      int start = i * chunkSize;
      int end = start + chunkSize - 1;
      if (i == count - 1) {
        end = totalSize - 1; // Ensure last chunk covers remainder
      }
      chunks.add(Chunk(id: i, start: start, end: end));
    }
    return chunks;
  }
}

class DownloadProgress {
  final String taskId;
  final double progress;
  final DownloadStatus status;

  DownloadProgress(this.taskId, this.progress, this.status);
}

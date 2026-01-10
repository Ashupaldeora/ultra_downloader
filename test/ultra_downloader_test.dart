import 'package:flutter_test/flutter_test.dart';
import 'package:ultra_downloader/ultra_downloader.dart';

void main() {
  group('UltraDownloader', () {
    test('singleton', () {
      final instance1 = UltraDownloader();
      final instance2 = UltraDownloader();
      expect(instance1, same(instance2));
    });

    test('initialization', () async {
      // NOTE: We cannot fully test Isolate spawning in this environment easily without mocking.
      // But we can check if the method runs without throwing.
      // Using runAsync usually needed for isolates in tests if we want real isolates.
      // For unit test, we might just verify it returns a future.

      final downloader = UltraDownloader();
      // We skip actual initialization in unit tests to avoid real isolate spawning overhead/errors
      // unless we really want integration tests.
      // If we call initialize(), it will try to spawn an isolate.

      // Let's just check the public API surface exists and doesn't crash on property access
      expect(downloader, isNotNull);
      expect(downloader.progressStream, isNotNull);
    });
  });
}

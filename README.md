# Ultra Downloader

A high-performance, concurrent, and resilient download manager for Flutter. 
Designed for speed, reliability, and ease of use, enabling ultra-fast downloads through parallel chunking and robust pause/resume capabilities.

## Features

*   **🚀 Ultra Fast**: Downloads files using parallel connections (chunking), maximizing bandwidth usage.
*   **⏯️ Pause & Resume**: Robust state management allows pausing and resuming downloads instantly.
*   **🧠 Smart Resume**: Automatically detects existing partial downloads and resumes from where they left off, even after app restarts.
*   **🔋 Background Support**: Built-in support for background persistent downloads using `workmanager`.
*   **🛡️ Resilient**: Handles network fluctuations and retries failed chunks automatically.
*   **🔌 Headers Support**: Pass custom headers (e.g., Auth tokens, Referer) to your requests.
*   **📊 Stream Progress**: Real-time progress updates via a strictly typed stream.

## Installation

Add `ultra_downloader` to your `pubspec.yaml`:

```yaml
dependencies:
  ultra_downloader:
    path: /path/to/ultra_downloader # Or git url
  path_provider: ^2.1.2 # Recommended for finding save paths
  permission_handler: ^11.0.0 # Required for storage permissions on Android 13+
```

## Setup

### Android

1.  **Permissions**: Add the following to your `AndroidManifest.xml` if you plan to save to public storage:

    ```xml
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
    <!-- For Android 13+ (API 33+) -->
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
    ```

2.  **Workmanager (Optional but Recommended)**: The package uses `workmanager` for background tasks. Ensure your `AndroidManifest.xml` is configured for it (usually auto-configured, but check `workmanager` docs if unsure).

## Usage

### 1. Initialize

Must be called before using any other method. Ideally in your `main()` function.

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Pass debug: true to see internal logs in console
  await UltraDownloader().initialize(debug: true);
  
  runApp(MyApp());
}
```

### 2. Start a Download

```dart
final url = 'https://example.com/large-file.mp4';
final savePath = '/storage/emulated/0/Download/my_video.mp4';

// Returns a unique taskId
final taskId = await UltraDownloader().download(
  url,
  savePath,
  headers: {'Authorization': 'Bearer ...'}, // Optional
);
```

### 3. Listen to Progress

```dart
UltraDownloader().progressStream.listen((event) {
  print('Task: ${event.taskId}');
  print('Progress: ${(event.progress * 100).toStringAsFixed(1)}%');
  print('Status: ${event.status}'); // queued, downloading, paused, completed, failed, canceled
});
```

### 4. Pause, Resume, Cancel

```dart
// Pause
await UltraDownloader().pause(taskId);

// Resume (Session based)
await UltraDownloader().resume(taskId);

// Cancel (Stops download and deletes file)
await UltraDownloader().cancel(taskId);
```

### 5. Smart Resume (App Restart)

If your app crashes or restarts, you can resume a download simply by calling `download()` again with the **same URL and savePath**.

The downloader will detect the `.meta` file on disk and automatically verify the downloaded chunks, resuming exactly where it left off.

```dart
// App restarts...
// User clicks "Download" on the same file again
final taskId = await UltraDownloader().download(url, samePath);
// -> Progress instantly jumps to e.g., 45% and continues.
```

## Advanced Configuration

### Chunking Strategy

You can control how the file is split:

```dart
await UltraDownloader().download(
  url,
  path,
  strategy: ChunkingStrategy.fixedCount(8), // Force 8 parallel connections
);

// Or by size
await UltraDownloader().download(
  url,
  path,
  strategy: ChunkingStrategy.fixedSize(1024 * 1024 * 5), // 5MB chunks
);
```

*Default is `ChunkingStrategy()` (Auto), which scales based on file size.*

## How it Works

1.  **Head Request**: Fetches file size and checks for `Accept-Ranges`.
2.  **Isolate Spawn**: Spawns a dedicated background Isolate to handle heavy I/O and network logic, keeping your UI jank-free.
3.  **Parallel Chunking**: Splits the file into logical ranges and downloads them concurrently using `Dio`.
4.  **offset-write**: Writes bytes directly to the correct position in the file using `RandomAccessFile`, preventing memory bloat.
5.  **Metadata Sync**: Periodically saves download state to a `.meta` JSON file to ensure crash resilience.

## License

MIT

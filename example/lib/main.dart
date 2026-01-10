import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ultra_downloader/ultra_downloader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UltraDownloader().initialize(debug: true);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ultra Downloader Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const DownloadScreen(),
    );
  }
}

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final String _url =
      '';
  // Use a large file for better testing if possible
  // 'https://speed.hetzner.de/100MB.bin';

  String? _taskId;
  double _progress = 0.0;
  DownloadStatus _status = DownloadStatus.queued;
  String _localPath = '';

  @override
  void initState() {
    super.initState();
    _listenToProgress();
  }

  void _listenToProgress() {
    UltraDownloader().progressStream.listen((event) {
      if (event.taskId == _taskId) {
        setState(() {
          _progress = event.progress;
          _status = event.status;
        });
      }
    });
  }

  Future<void> _startDownload() async {
    // 1. Check permissions (Android specific mostly)
    if (Platform.isAndroid) {
      // For public storage we need permission, for app docs we don't.
      // Let's use app docs for simplicity in this example to avoid complications.
      // Or ExternalStorage if we want user visibility.
    }

    final dir = await getDownloadsDirectory();
    final savePath = '/storage/emulated/0/Download/video.mp4';

    setState(() {
      _localPath = savePath;
      _status = DownloadStatus.queued;
      _progress = 0.0;
    });

    // Clean up previous test? No, we want to test Smart Resume.
    // To restart fresh, user should cancel or we can add a 'Force New' button.
    // For now, let's allow resume behavior.
    /*
    final file = File(savePath);
    if (file.existsSync()) file.deleteSync();
    final meta = File('$savePath.meta');
    if (meta.existsSync()) meta.deleteSync();
    */

    final id = await UltraDownloader().download(
      _url,
      savePath,
      headers: {"referer": "https://fmoviesunblocked.net/"},
      strategy: const ChunkingStrategy(), // Smart chunking
    );

    setState(() {
      _taskId = id;
    });
  }

  Future<void> _resumeDownload() async {
    // Scenario: App restarted, we want to resume "video.mp4"
    // We need to know the path.
    if (_taskId != null) {
      await UltraDownloader().resume(_taskId!);
    } else {
      // Simulate "Smart Resume" by calling download again on same path
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/video.mp4';
      final id = await UltraDownloader().download(_url, savePath);
      setState(() {
        _taskId = id;
      });
    }
  }

  Future<void> _pauseDownload() async {
    if (_taskId != null) {
      await UltraDownloader().pause(_taskId!);
    }
  }

  Future<void> _cancelDownload() async {
    if (_taskId != null) {
      await UltraDownloader().cancel(_taskId!);
      setState(() {
        _progress = 0.0;
        _taskId = null;
        _status = DownloadStatus.canceled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ultra Downloader')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Status: ${_status.name.toUpperCase()}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _progress, minHeight: 10),
              const SizedBox(height: 10),
              Text(
                '${(_progress * 100).toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 40),
              Wrap(
                spacing: 10,
                children: [
                  ElevatedButton.icon(
                    onPressed: _startDownload,
                    icon: const Icon(Icons.download),
                    label: const Text('Start New'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _pauseDownload,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _resumeDownload,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Resume'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.cancel),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Path: $_localPath',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

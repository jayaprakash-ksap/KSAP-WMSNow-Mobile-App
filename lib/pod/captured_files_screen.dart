import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../config/app_config.dart';
import '../services/upload_service.dart';

/// Lists everything still queued under AppConfig.camFolderName
/// (captured_images) - both Split IBLPN photos and POD signatures land
/// there. Two ways to get files off the phone:
/// - Automatic: if an Upload Server is configured (see the settings icon),
///   captures upload themselves right after being taken (see
///   _persistCapturedPhoto in main.dart / _persistSignature in
///   pod_screen.dart) and are deleted locally on confirmed success - so
///   this screen only ever shows what's still pending. "Sync Now" retries
///   whatever's left, e.g. after being out of WiFi range.
/// - Manual: the in-app Share sheet (added first, 2026-07-23) for whenever
///   no upload server is set up - works from anywhere, no network needed.
class CapturedFilesScreen extends StatefulWidget {
  const CapturedFilesScreen({super.key});

  @override
  State<CapturedFilesScreen> createState() => _CapturedFilesScreenState();
}

class _CapturedFilesScreenState extends State<CapturedFilesScreen> {
  List<File>? _files;
  String? _error;
  UploadServerConfig _uploadConfig =
      const UploadServerConfig(baseUrl: '', token: '');
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _uploadConfig = await AppConfig.loadUploadServer();
    await _load();
    if (_uploadConfig.isConfigured) await _syncNow();
  }

  Future<Directory> _folder() async {
    final docsDir = await getApplicationDocumentsDirectory();
    return Directory('${docsDir.path}/${AppConfig.camFolderName}');
  }

  Future<void> _load() async {
    setState(() {
      _files = null;
      _error = null;
    });
    try {
      final folder = await _folder();
      if (!await folder.exists()) {
        if (mounted) setState(() => _files = const []);
        return;
      }
      final entries = await folder.list().toList();
      final files = entries.whereType<File>().toList();
      // Newest first - whatever was just captured is the one you're most
      // likely here to grab.
      files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _syncNow() async {
    if (!_uploadConfig.isConfigured || _syncing) return;
    setState(() => _syncing = true);
    final folder = await _folder();
    final synced = await UploadService.syncPending(folder, _uploadConfig);
    if (!mounted) return;
    setState(() => _syncing = false);
    await _load();
    if (!mounted || synced == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Synced $synced file(s) to the upload server.')),
    );
  }

  Future<void> _editUploadServer() async {
    final urlCtrl = TextEditingController(text: _uploadConfig.baseUrl);
    final tokenCtrl = TextEditingController(text: _uploadConfig.token);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Upload Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.5:8765',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Matches tools/captured_files_receiver.py running on the '
              'project machine. Leave Server URL blank to keep files '
              'local-only (Share sheet still works).',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final config = UploadServerConfig(
      baseUrl: urlCtrl.text.trim(),
      token: tokenCtrl.text.trim(),
    );
    await AppConfig.saveUploadServer(config);
    if (!mounted) return;
    setState(() => _uploadConfig = config);
    if (config.isConfigured) await _syncNow();
  }

  String _nameOf(File f) => f.path.split(Platform.pathSeparator).last;

  Future<void> _shareFile(File file) async {
    await Share.shareXFiles([XFile(file.path)], text: _nameOf(file));
  }

  Future<void> _shareAll() async {
    final files = _files ?? const <File>[];
    if (files.isEmpty) return;
    await Share.shareXFiles(files.map((f) => XFile(f.path)).toList());
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Captured Files'),
        actions: [
          if (_uploadConfig.isConfigured)
            IconButton(
              icon: _syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload),
              tooltip: 'Sync Now',
              onPressed: _syncing ? null : _syncNow,
            ),
          IconButton(
            icon: const Icon(Icons.settings_ethernet),
            tooltip: 'Upload Server settings',
            onPressed: _editUploadServer,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          if (files != null && files.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Share all',
              onPressed: _shareAll,
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_uploadConfig.isConfigured)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(8),
              child: const Text(
                'No upload server configured - files stay on-device until '
                'shared manually. Tap the settings icon above to set one up.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Expanded(
            child: _error != null
                ? Center(child: Text('Failed to list files: $_error'))
                : files == null
                    ? const Center(child: CircularProgressIndicator())
                    : files.isEmpty
                        ? const Center(child: Text('No captured files yet.'))
                        : ListView.builder(
                            itemCount: files.length,
                            itemBuilder: (context, i) {
                              final file = files[i];
                              final name = _nameOf(file);
                              final lower = name.toLowerCase();
                              final isImage = lower.endsWith('.png') ||
                                  lower.endsWith('.jpg');
                              return ListTile(
                                leading: isImage
                                    ? SizedBox(
                                        width: 40,
                                        height: 40,
                                        child:
                                            Image.file(file, fit: BoxFit.cover),
                                      )
                                    : const Icon(Icons.insert_drive_file),
                                title:
                                    Text(name, overflow: TextOverflow.ellipsis),
                                subtitle:
                                    Text(file.statSync().modified.toString()),
                                trailing: IconButton(
                                  icon: const Icon(Icons.share),
                                  tooltip: 'Share',
                                  onPressed: () => _shareFile(file),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

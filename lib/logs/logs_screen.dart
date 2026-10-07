import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../config/app_config.dart';
import '../services/log_upload_service.dart';

/// Lists per-session activity log files under AppConfig.logFolderName - see
/// LogService. Mirrors CapturedFilesScreen's list+share+sync structure
/// (lib/pod/captured_files_screen.dart). Unlike captures (deleted locally
/// once synced), log files are NEVER deleted by syncing (see
/// LogUploadService.syncAll's doc comment) - they just accumulate for as
/// long as the operator keeps them; "Delete all" here is a manual, explicit
/// cleanup action rather than any automatic retention policy.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<File>? _files;
  String? _error;
  LogServerConfig _logConfig = const LogServerConfig(baseUrl: '', token: '');
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _logConfig = await AppConfig.loadLogServer();
    await _load();
    if (_logConfig.isConfigured) await _syncNow();
  }

  Future<void> _syncNow() async {
    if (!_logConfig.isConfigured || _syncing) return;
    setState(() => _syncing = true);
    final folder = await _folder();
    final synced = await LogUploadService.syncAll(folder, _logConfig);
    if (!mounted) return;
    setState(() => _syncing = false);
    if (synced == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Synced $synced log file(s) to the log server.')),
    );
  }

  Future<Directory> _folder() async {
    final docsDir = await getApplicationDocumentsDirectory();
    return Directory('${docsDir.path}/${AppConfig.logFolderName}');
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
      // Newest first - whatever session is currently open (or just ended) is
      // the one you're most likely here to check.
      files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
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

  Future<void> _deleteAll() async {
    final files = _files ?? const <File>[];
    if (files.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete all logs?'),
        content: Text('This permanently deletes all ${files.length} log '
            'file(s) on this device. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete all')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final f in files) {
      try {
        await f.delete();
      } catch (_) {
        // Best-effort - keep deleting the rest even if one file is locked.
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Logs'),
        actions: [
          if (_logConfig.isConfigured)
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
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          if (files != null && files.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Share all',
              onPressed: _shareAll,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Delete all',
              onPressed: _deleteAll,
            ),
          ],
        ],
      ),
      body: _error != null
          ? Center(child: Text('Failed to list files: $_error'))
          : files == null
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? const Center(child: Text('No log files yet.'))
                  : ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (context, i) {
                        final file = files[i];
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(_nameOf(file),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(file.statSync().modified.toString()),
                          trailing: IconButton(
                            icon: const Icon(Icons.share),
                            tooltip: 'Share',
                            onPressed: () => _shareFile(file),
                          ),
                        );
                      },
                    ),
    );
  }
}

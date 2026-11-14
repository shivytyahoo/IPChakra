import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// The "a newer release is available" dialog for the in-app
/// updater (Settings → Check for update).
///
/// Idle: shows the version, the release title and its notes, with
/// Download & install (when the release carries an APK), View
/// release (browser fallback) and Later. Downloading: a progress
/// bar with the percentage and no way to dismiss mid-download —
/// the file lands in the app cache and the system installer opens
/// the moment it is complete. A failed download stays in the
/// dialog with a Retry button instead of failing silently.
class UpdateAvailableDialog extends StatefulWidget {
  final UpdateCheckResult result;
  final UpdateService service;

  const UpdateAvailableDialog({
    super.key,
    required this.result,
    required this.service,
  });

  @override
  State<UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<UpdateAvailableDialog> {
  double? _progress;
  String? _error;

  bool get _downloading => _progress != null && _progress! < 1.0;

  Future<void> _downloadAndInstall() async {
    final apkUrl = widget.result.apkUrl;
    final version = widget.result.latestVersion;
    if (apkUrl == null || version == null) return;
    setState(() {
      _progress = 0.0;
      _error = null;
    });
    final path = await widget.service.downloadApk(
      apkUrl,
      version,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _progress = null;
        _error = 'Download failed — check your connection and retry.';
      });
      return;
    }
    final started = await widget.service.installApk(path);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started
              ? 'Installer opened — tap Install to update.'
              : 'Could not open the installer. Allow "Install unknown '
                  'apps" for IPChakra in Android Settings, then try again.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final notes = (result.releaseNotes ?? '').trim();
    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        title: Text('Update available — v${result.latestVersion ?? ''}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.releaseName != null &&
                  result.releaseName!.trim().isNotEmpty)
                Text(
                  result.releaseName!.trim(),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  notes.length > 1000
                      ? '${notes.substring(0, 1000)}…'
                      : notes,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(
                  'Downloading… ${(_progress! * 100).round()}%',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!_downloading) ...[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Later'),
            ),
            if (result.releaseUrl != null)
              TextButton(
                onPressed: () async {
                  final opened =
                      await widget.service.openUrl(result.releaseUrl!);
                  if (!context.mounted) return;
                  if (!opened) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not open the release page.'),
                      ),
                    );
                  }
                },
                child: const Text('View release'),
              ),
            if (result.apkUrl != null)
              FilledButton(
                onPressed:
                    _progress == null ? _downloadAndInstall : null,
                child: Text(_error == null ? 'Download & install' : 'Retry'),
              ),
          ],
        ],
      ),
    );
  }
}

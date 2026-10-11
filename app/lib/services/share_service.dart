import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/vpn_server.dart';

/// What a server's share action can honestly hand out.
enum SharePayloadKind {
  /// A proxy share link (vless://, ss://, …) — also QR-encodable.
  link,

  /// A full configuration text (an .ovpn file's contents).
  config,

  /// Public server details only (name, endpoint, peer key). Used
  /// for WireGuard entries: a WARP configuration carries the
  /// user's own private identity key, and a custom WireGuard
  /// configuration is generated fresh — with new keys — on every
  /// connect, so the app holds no .conf it could honestly share.
  details,
}

/// The text one server contributes to a share/copy/QR action.
class ServerSharePayload {
  final SharePayloadKind kind;

  /// The exact text that is shared, copied, or QR-encoded.
  final String text;

  /// Short human title (usually the server's name).
  final String title;

  const ServerSharePayload({
    required this.kind,
    required this.text,
    required this.title,
  });

  bool get isLink => kind == SharePayloadKind.link;
}

/// The share payload for [server], or null when the app currently
/// holds nothing shareable for it. [ovpnConfigText] supplies an
/// OpenVPN configuration that was loaded on demand (VPNBook/Mirror
/// entries fetch theirs through a config loader).
ServerSharePayload? sharePayloadFor(
  VpnServer server, {
  String? ovpnConfigText,
}) {
  if (server.isStealth) {
    final link = server.shareLink;
    if (link == null || link.isEmpty) return null;
    return ServerSharePayload(
      kind: SharePayloadKind.link,
      text: link,
      title: server.name,
    );
  }
  if (server.protocol == 'openvpn') {
    final config = ovpnConfigText ?? server.ovpnConfig;
    if (config == null || config.isEmpty) return null;
    return ServerSharePayload(
      kind: SharePayloadKind.config,
      text: config,
      title: '${server.name} (OpenVPN)',
    );
  }
  if (server.protocol == 'wireguard') {
    final lines = <String>[
      'IPChakra server: ${server.name}',
      if (server.country.isNotEmpty) 'Country: ${server.country}',
      if (server.endpoint != null) 'Endpoint: ${server.endpoint}',
      if (server.peerPublicKey != null)
        'Peer public key: ${server.peerPublicKey}',
      server.warp
          ? 'Type: Cloudflare WARP (Free Mode)'
          : 'Type: WireGuard',
      'Note: WireGuard configurations are generated on this device '
          'at connect time, so there is no .conf file to export.',
    ];
    return ServerSharePayload(
      kind: SharePayloadKind.details,
      text: lines.join('\n'),
      title: server.name,
    );
  }
  return null;
}

/// The share payload for [server], loading an on-demand OpenVPN
/// configuration first when the server carries a loader. Returns
/// null when nothing shareable could be produced.
Future<ServerSharePayload?> loadSharePayload(VpnServer server) async {
  final direct = sharePayloadFor(server);
  if (direct != null) return direct;
  final loader = server.configLoader;
  if (server.protocol == 'openvpn' && loader != null) {
    try {
      final config = await loader().timeout(const Duration(seconds: 15));
      return sharePayloadFor(server, ovpnConfigText: config);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Thin wrapper over the platform share sheet.
class ShareService {
  /// Show the system share sheet for [text]. Returns true when the
  /// sheet was shown (shared or dismissed by the user), false when
  /// no share sheet is available on this platform — the caller
  /// then falls back to the clipboard and says so.
  static Future<bool> shareText(String text, {String? subject}) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(text: text, subject: subject),
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }
}

/// The share UI for one server row (and for the connected session
/// on Home): a bottom sheet with Share, Copy, and — for share
/// links — Show QR code. Loads an on-demand configuration first
/// when the server needs one.
Future<void> showServerShareSheet(
  BuildContext context,
  VpnServer server,
) async {
  final payload = await loadSharePayload(server);
  if (!context.mounted) return;
  if (payload == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Nothing shareable is loaded for this server yet. '
          'Try again in a moment.',
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              subtitle: Text(payload.title),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final shown = await ShareService.shareText(
                  payload.text,
                  subject: 'IPChakra — ${payload.title}',
                );
                if (!shown && context.mounted) {
                  await Clipboard.setData(
                    ClipboardData(text: payload.text),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'The share sheet is not available here — '
                        'copied to the clipboard instead.',
                      ),
                    ),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(
                payload.isLink ? 'Copy link' : 'Copy',
              ),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await Clipboard.setData(ClipboardData(text: payload.text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to the clipboard.')),
                );
              },
            ),
            if (payload.isLink)
              ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: const Text('Show QR code'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showQrCodeDialog(context, payload);
                },
              ),
          ],
        ),
      );
    },
  );
}

/// A dialog holding the QR code for a share link, on a white card
/// so any scanner can read it regardless of the app theme.
void showQrCodeDialog(BuildContext context, ServerSharePayload payload) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(payload.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: payload.text,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Scan with any Xray/V2Ray client to import this server.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

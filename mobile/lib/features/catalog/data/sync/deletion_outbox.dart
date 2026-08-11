import 'dart:convert';

import 'package:homesync_mobile/core/logging/app_log.dart';
import 'package:homesync_mobile/features/settings/data/settings_store.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

/// Durable pending phone→PC soft-deletes (`DELETE /v1/files/{id}`).
///
/// Survives offline / degraded sessions; flushed on catalog refresh / resume.
@lazySingleton
class DeletionOutbox {
  DeletionOutbox(this._settings, this._log);

  final SettingsStore _settings;
  final AppLog _log;

  static const _kQueue = 'deletion_outbox_v1';

  Future<List<DeletionOutboxItem>> list() async {
    final raw = _settings.readRaw(_kQueue);
    if (raw == null || raw.isEmpty) return <DeletionOutboxItem>[];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => DeletionOutboxItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// File ids waiting for a server soft-delete.
  Future<Set<String>> pendingFileIds() async {
    return {for (final i in await list()) i.fileId};
  }

  /// Enqueue a PC soft-delete. Dedupes by [fileId] (keeps the earliest row).
  Future<DeletionOutboxItem> enqueue({
    required String fileId,
    String? title,
  }) async {
    final items = await list();
    for (final existing in items) {
      if (existing.fileId == fileId) return existing;
    }
    final item = DeletionOutboxItem(
      id: const Uuid().v4(),
      fileId: fileId,
      title: title,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    items.add(item);
    await _persist(items);
    _log.info('deletion', 'queued ${item.fileId} ${item.title ?? ''}');
    return item;
  }

  Future<void> remove(String id) async {
    final items = await list();
    items.removeWhere((e) => e.id == id);
    await _persist(items);
  }

  Future<int> removeByFileId(String fileId) async {
    final items = await list();
    final before = items.length;
    items.removeWhere((e) => e.fileId == fileId);
    final removed = before - items.length;
    if (removed > 0) await _persist(items);
    return removed;
  }

  Future<void> _persist(List<DeletionOutboxItem> items) async {
    await _settings.writeRaw(
      _kQueue,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}

class DeletionOutboxItem {
  const DeletionOutboxItem({
    required this.id,
    required this.fileId,
    this.title,
    required this.createdAt,
  });

  final String id;
  final String fileId;
  final String? title;
  final String createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_id': fileId,
        'title': title,
        'created_at': createdAt,
      };

  factory DeletionOutboxItem.fromJson(Map<String, dynamic> json) {
    return DeletionOutboxItem(
      id: json['id'] as String,
      fileId: json['file_id'] as String,
      title: json['title'] as String?,
      createdAt: json['created_at'] as String,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:homesync_mobile/features/catalog/data/sync/ingest_service.dart';

/// Isolated progress banner so ingest chunk updates do not rebuild the file list.
class IngestProgressBanner extends StatelessWidget {
  const IngestProgressBanner({super.key, required this.progress});

  final IngestFileProgress progress;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress.phase == 'preparing'
                        ? progress.title
                        : progress.phase == 'scanning'
                            ? '${progress.phaseLabel}: ${progress.title}'
                            : progress.total > 0
                                ? '${progress.phaseLabel} '
                                    '${progress.index}/${progress.total}: '
                                    '${progress.title}'
                                : '${progress.phaseLabel}: ${progress.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (progress.determinate) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${(progress.fraction.clamp(0.0, 1.0) * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress.determinate
                  ? progress.fraction.clamp(0.0, 1.0)
                  : null,
              minHeight: 4,
            ),
          ],
        ),
      ),
    );
  }
}

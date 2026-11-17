import 'package:campus_ui/campus_ui.dart';
import 'package:flutter/material.dart';

import 'outpass_format.dart';
import 'scan_log.dart';

/// Today's out pass list on the guard's phone: who was let through, newest first. It is for looking, not for
/// taking away: there is no export here. The full register, searching and the CSV belong to the college's admin
/// website, behind its login.
class OutpassScreen extends StatefulWidget {
  const OutpassScreen({super.key, required this.register, this.phoneNow});

  final OutpassRegister register;

  /// The phone's clock; tests replace it.
  final DateTime Function()? phoneNow;

  @override
  State<OutpassScreen> createState() => _OutpassScreenState();
}

class _OutpassScreenState extends State<OutpassScreen> {
  late final Future<List<OutpassEntry>> _entries = widget.register.entries(sinceS: _startOfTodayS);

  int get _startOfTodayS {
    final n = (widget.phoneNow ?? DateTime.now)();
    return DateTime(n.year, n.month, n.day).millisecondsSinceEpoch ~/ 1000;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text("Today's out pass list")),
      body: SafeArea(
        child: FutureBuilder<List<OutpassEntry>>(
          future: _entries,
          builder: (context, snapshot) {
            final entries = snapshot.data;
            if (entries == null) return const Center(child: CircularProgressIndicator());
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      Text('${entries.length} out', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      Icon(Icons.lock_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text('View only', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.fact_check_outlined, size: 56, color: scheme.onSurfaceVariant),
                                const SizedBox(height: 12),
                                Text('Nobody has gone out today', style: theme.textTheme.titleMedium),
                                const SizedBox(height: 4),
                                Text('Each student you scan is added here.', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          itemCount: entries.length,
                          separatorBuilder: (context, i) => const Divider(height: 1),
                          itemBuilder: (context, i) => _EntryTile(entries[i]),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Text('The full record and the CSV export are on the college admin website.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);

  final OutpassEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = DateTime.fromMillisecondsSinceEpoch(entry.scannedAt * 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          InitialsAvatar(name: entry.name, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${entry.rollNumber} · ${entry.branch} · Year ${entry.year}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatTime(t).substring(0, 5), style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';

/// For moderators: everything people reported, unhandled first.
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late Future<List<Report>> _reports = Api.reports();

  Future<void> _open(Report r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReportPage(reportId: r.id)));
    if (mounted) setState(() => _reports = Api.reports());
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.t('reports'))),
      body: FutureBuilder<List<Report>>(
        future: _reports,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text(l.t('error')));
          final reports = snap.data;
          if (reports == null) return const Center(child: CircularProgressIndicator());
          if (reports.isEmpty) return Center(child: Text(l.t('noReports')));
          return ListView.separated(
            itemCount: reports.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = reports[i];
              return ListTile(
                leading: Avatar(name: r.reported?.displayName ?? '?', url: r.reported?.avatarUrl),
                title: Text(r.reported?.displayName ?? '?'),
                subtitle: Text(_preview(l, r.type, r.content), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Chip(
                  label: Text(l.t(r.open ? 'reportOpen' : 'action_${r.action}')),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: r.open ? Theme.of(context).colorScheme.errorContainer : null,
                ),
                onTap: () => _open(r),
              );
            },
          );
        },
      ),
    );
  }
}

String _preview(L l, String type, String? content) => switch (type) {
  'text' => content ?? '',
  'file' => '📎 ${content ?? ''}',
  'image' => '📷 ${l.t('photo')}',
  'video' => '🎥 ${l.t('video')}',
  'voice' => '🎤 ${l.t('voiceMessage')}',
  _ => content ?? type,
};

/// One report: the message, the talk around it, and the decision.
class ReportPage extends StatefulWidget {
  const ReportPage({super.key, required this.reportId});

  final String reportId;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  static const _durations = {'banHour': 60, 'banDay': 1440, 'banWeek': 10080, 'banMonth': 43200};

  Report? _report;
  Ban? _ban;
  Map<String, dynamic>? _around;
  Object? _failed;
  String _action = 'delete';
  String _duration = 'banDay';
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (report, around) = await (Api.report(widget.reportId), Api.reportContext(widget.reportId)).wait;
      final ban = report.reportedId == null ? null : await Api.banOf(report.reportedId!);
      if (mounted) {
        setState(() {
          _report = report;
          _around = around;
          _ban = ban;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide() async {
    final l = L.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.t('action_$_action')),
        content: Text(l.t('decideQ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('confirmDecision'))),
        ],
      ),
    );
    if (go != true) return;
    await _guard(() async {
      await Api.resolveReport(
        widget.reportId,
        action: _action,
        minutes: _action == 'temp_ban' ? _durations[_duration] : null,
        reason: _reason.text,
      );
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _liftBan() => _guard(() async {
    await Api.liftBan(_report!.reportedId!);
    await _load();
  });

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('report')),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator()) : null,
      ),
      body: _failed != null
          ? Center(child: Text(l.t('error')))
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Line(label: l.t('reportedPerson'), value: _who(r.reported)),
                _Line(label: l.t('reporter'), value: _who(r.reporter)),
                if (_around?['name'] != null) _Line(label: l.t('groupName'), value: _around!['name'] as String),
                _Line(label: l.t('reportNote'), value: r.note ?? l.t('noNote')),
                const SizedBox(height: 8),
                Text(l.t('reportedMessage'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                _MessageView(type: r.type, content: r.content, mediaUrl: r.mediaUrl, highlight: true),
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: true,
                  title: Text(l.t('viewConversation')),
                  children: [
                    for (final m in (_around?['messages'] as List? ?? const []).cast<Map>())
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${m['sender'] ?? '?'} · ${formatTime(context, DateTime.parse(m['created_at'] as String).toLocal())}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            _MessageView(
                              type: m['type'] as String,
                              content: m['content'] as String?,
                              mediaUrl: m['media_url'] as String?,
                              highlight: DateTime.parse(m['created_at'] as String).toLocal() == r.messageAt,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const Divider(height: 32),
                if (_ban?.active == true) ...[
                  Text(l.t('personBanned'), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  OutlinedButton(onPressed: _busy ? null : _liftBan, child: Text(l.t('liftBan'))),
                  const SizedBox(height: 16),
                ],
                if (r.open)
                  ..._decision(l)
                else ...[
                  _Line(label: l.t('decision'), value: l.t('action_${r.action}')),
                  if (r.reason != null) _Line(label: l.t('reasonLabel'), value: r.reason!),
                ],
              ],
            ),
    );
  }

  List<Widget> _decision(L l) => [
    Text(l.t('decision'), style: Theme.of(context).textTheme.titleSmall),
    RadioGroup<String>(
      groupValue: _action,
      onChanged: (v) => setState(() => _action = v!),
      child: Column(
        children: [
          for (final a in const ['delete', 'temp_ban', 'ban', 'none'])
            RadioListTile<String>(contentPadding: EdgeInsets.zero, value: a, title: Text(l.t('action_$a'))),
        ],
      ),
    ),
    if (_action == 'temp_ban')
      DropdownButtonFormField<String>(
        initialValue: _duration,
        decoration: InputDecoration(labelText: l.t('banLength'), border: const OutlineInputBorder()),
        items: [for (final k in _durations.keys) DropdownMenuItem(value: k, child: Text(l.t(k)))],
        onChanged: (v) => setState(() => _duration = v!),
      ),
    const SizedBox(height: 12),
    TextField(
      controller: _reason,
      maxLines: 3,
      minLines: 2,
      maxLength: 1000,
      decoration: InputDecoration(labelText: l.t('reasonHint'), border: const OutlineInputBorder()),
    ),
    const SizedBox(height: 8),
    FilledButton(onPressed: _busy ? null : _decide, child: Text(l.t('confirmDecision'))),
  ];

  String _who(Profile? p) => p == null ? '?' : '${p.displayName} (@${p.username})';
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          Text(value),
        ],
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.type, this.content, this.mediaUrl, this.highlight = false});

  final String type;
  final String? content;
  final String? mediaUrl;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final url = mediaUrl;
    final picture = type == 'image' || type == 'sticker';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (picture && url != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: CachedNetworkImage(imageUrl: url),
            )
          else
            Text(_preview(l, type, content)),
          if (url != null && !picture)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              child: Text(l.t('openFile')),
            ),
        ],
      ),
    );
  }
}

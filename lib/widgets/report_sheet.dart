import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import 'common.dart';

/// Reports a message, with an optional note for the moderator.
Future<void> reportMessage(BuildContext context, Message m) async {
  final l = L.of(context);
  final controller = TextEditingController();
  final send = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(c).bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.t('reportMessage'), style: Theme.of(c).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            minLines: 2,
            maxLength: 1000,
            decoration: InputDecoration(hintText: l.t('reportHint'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('sendReport'))),
        ],
      ),
    ),
  );
  if (send != true) return;
  await Api.reportMessage(m, controller.text);
  if (context.mounted) toast(context, l.t('reportSent'));
}

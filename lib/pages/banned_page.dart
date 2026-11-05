import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';

/// All a banned account sees until the ban ends or is lifted.
class BannedPage extends StatelessWidget {
  const BannedPage({super.key, required this.ban, required this.onRetry});

  final Ban ban;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final until = ban.until;
    final locale = Localizations.localeOf(context).languageCode;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block, size: 72, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(l.t('banned'), style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  until == null
                      ? l.t('bannedForever')
                      : l.t('bannedUntil').replaceAll('{date}', DateFormat.yMMMd(locale).add_jm().format(until)),
                  textAlign: TextAlign.center,
                ),
                if (ban.reason != null) ...[
                  const SizedBox(height: 16),
                  Text(l.t('reasonLabel'), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(ban.reason!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                FilledButton.tonal(onPressed: onRetry, child: Text(l.t('checkAgain'))),
                TextButton(onPressed: () => db.auth.signOut(), child: Text(l.t('logout'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

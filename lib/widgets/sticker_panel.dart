import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../pages/sticker_maker_page.dart';
import '../services/api.dart';
import 'common.dart';

class StickerChoice {
  const StickerChoice({this.url, this.emoji});

  final String? url;
  final String? emoji;
}

const _emojiStickers = [
  '😂',
  '🤣',
  '😍',
  '🥰',
  '😘',
  '😎',
  '🤩',
  '🥳',
  '😭',
  '😡',
  '🤯',
  '😱',
  '🤔',
  '🙄',
  '😴',
  '🤤',
  '😇',
  '🤡',
  '👻',
  '💀',
  '👽',
  '🤖',
  '💩',
  '🙈',
  '👍',
  '👎',
  '👏',
  '🙏',
  '💪',
  '🤝',
  '✌️',
  '🫡',
  '❤️',
  '💔',
  '🔥',
  '✨',
  '🎉',
  '🎂',
  '☕',
  '🌹',
  '🐐',
  '🦁',
  '🐱',
  '🐶',
  '⚽',
  '🏆',
  '🕋',
  '🌙',
];

Future<void> showStickerPanel(BuildContext context, {required void Function(StickerChoice) onPick}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => SizedBox(
      height: MediaQuery.sizeOf(c).height * .5,
      child: _StickerPanel(
        onPick: (s) {
          Navigator.pop(c);
          onPick(s);
        },
      ),
    ),
  );
}

class _StickerPanel extends StatefulWidget {
  const _StickerPanel({required this.onPick});

  final void Function(StickerChoice) onPick;

  @override
  State<_StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<_StickerPanel> {
  List<String>? _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await Api.savedStickers();
      if (mounted) setState(() => _saved = s);
    } catch (e) {
      if (mounted) {
        setState(() => _saved = []);
        showError(context, e);
      }
    }
  }

  Future<void> _make() async {
    final url = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const StickerMakerPage()));
    if (url != null) _load();
  }

  Future<void> _remove(String url) async {
    final l = L.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: CachedNetworkImage(imageUrl: url, height: 120),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
          FilledButton.tonal(onPressed: () => Navigator.pop(c, true), child: Text(l.t('removeSticker'))),
        ],
      ),
    );
    if (ok != true) return;
    await Api.removeSticker(url);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final saved = _saved;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: l.t('myStickers')),
              Tab(text: l.t('emoji')),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                saved == null
                    ? const Center(child: CircularProgressIndicator())
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: saved.length + 1,
                        itemBuilder: (_, i) {
                          if (i == 0) {
                            return InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: _make,
                              child: Ink(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 2),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.add_photo_alternate_outlined, size: 28),
                                    const SizedBox(height: 4),
                                    Text(
                                      l.t('makeSticker'),
                                      style: const TextStyle(fontSize: 11),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                          final url = saved[i - 1];
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => widget.onPick(StickerChoice(url: url)),
                            onLongPress: () => _remove(url),
                            child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
                          );
                        },
                      ),
                GridView.count(
                  crossAxisCount: 6,
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final e in _emojiStickers)
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => widget.onPick(StickerChoice(emoji: e)),
                        child: Center(child: Text(e, style: const TextStyle(fontSize: 34))),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (saved != null && saved.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l.t('noStickers'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

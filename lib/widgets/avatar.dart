import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.url, this.radius = 22, this.group = false});

  final String name;
  final String? url;
  final double radius;
  final bool group;

  static const _palette = [
    Color(0xFF4F6BED),
    Color(0xFF00A884),
    Color(0xFFE5677D),
    Color(0xFFF2A33A),
    Color(0xFF8E5CF7),
    Color(0xFF1FA2D6),
    Color(0xFFDB5A3B),
    Color(0xFF3AA76D),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _palette[name.hashCode.abs() % _palette.length];
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      foregroundImage: url == null ? null : CachedNetworkImageProvider(url!),
      child: group
          ? Icon(Icons.group, color: Colors.white, size: radius)
          : Text(
              initial,
              style: TextStyle(color: Colors.white, fontSize: radius * .8, fontWeight: FontWeight.w600),
            ),
    );
  }
}

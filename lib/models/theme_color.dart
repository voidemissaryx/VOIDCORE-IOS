import 'dart:ui' show Color;

/// App theme colours the user can pick; each seeds the whole Material palette.
enum ThemeColor {
  green('Green', Color(0xFF1FA463)),
  teal('Teal', Color(0xFF00897B)),
  purple('Purple', Color(0xFF8B5CF6)),
  orange('Orange', Color(0xFFF57C00)),
  pink('Pink', Color(0xFFD81B60));

  final String label;
  final Color seed;
  const ThemeColor(this.label, this.seed);
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'break_first.dart';
import 'width_model.dart';

/// What if you could ask a [Text] its size before it is laid out?
///
/// ```dart
/// Text('hello', style: style).width       // its width on one line
/// Text(caption, maxLines: 3).canFit(240)  // whether all of it shows in 240 px
/// ```
///
/// Each answer is the size Flutter gives the widget (its RenderParagraph's) in a
/// box [maxWidth] wide: from the sidecar registered for the Text's font family
/// ([BreakFirst.register]) when the breaker decides, otherwise from a
/// [TextPainter] configured as the widget configures its own.
///
/// Without a BuildContext the Text is measured as if built under
/// [BreakFirst.defaultTextStyle] with no MediaQuery: no text scaling beyond its
/// own [Text.textScaler], left to right, no locale. [measure] with a context
/// resolves the style, text scaling, direction and locale as Text.build does
/// there.
extension BreakFirstText on Text {
  /// Width on one line, the widest line between hard breaks with its trailing
  /// spaces: the width Flutter gives this Text when nothing limits it.
  double get width => measure().width;

  /// Height in a box [maxWidth] wide.
  double height(double maxWidth) => measure().height(maxWidth);

  /// Number of lines shown in a box [maxWidth] wide.
  int lineCount(double maxWidth) => measure().lineCount(maxWidth);

  /// Whether all of the text shows in a box [maxWidth] wide and [maxHeight] high:
  /// no line cut by maxLines, not too high, and with softWrap false, not too wide.
  bool canFit(double maxWidth, {double maxHeight = double.infinity}) =>
      measure().canFit(maxWidth, maxHeight: maxHeight);

  /// This Text resolved once, for several questions; with [context], as Text.build
  /// resolves it there.
  TextMeasure measure([BuildContext? context]) => TextMeasure(this, context);
}

/// Languages whose locale gives the same layout as none (measured with Roboto:
/// flutter_bench/test/text_api_test.dart). Under another locale Flutter decides.
const Set<String> sameLayoutLocales = {'en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'ru', 'uk', 'el'};

/// A [Text] resolved for measuring, as [Text.build] resolves it: the answers of
/// [BreakFirstText], with the paragraph prepared once for all of them.
class TextMeasure {
  factory TextMeasure(Text text, [BuildContext? context]) {
    final dts = context == null ? null : DefaultTextStyle.of(context);
    var style = text.style == null || text.style!.inherit
        ? (dts?.style ?? BreakFirst.defaultTextStyle).merge(text.style)
        : text.style!;
    if (context != null && MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final lineHeight = context == null ? null : MediaQuery.maybeLineHeightScaleFactorOverrideOf(context);
    final letterSpacing = context == null ? null : MediaQuery.maybeLetterSpacingOverrideOf(context);
    final wordSpacing = context == null ? null : MediaQuery.maybeWordSpacingOverrideOf(context);
    final spacing = lineHeight == null && letterSpacing == null && wordSpacing == null
        ? null
        : TextStyle(height: lineHeight, letterSpacing: letterSpacing, wordSpacing: wordSpacing);
    final span = text.textSpan;
    var hasPlaceholder = false;
    span?.visitChildren((s) => !(hasPlaceholder = s is PlaceholderSpan));
    if (hasPlaceholder) throw ArgumentError('a Text with a WidgetSpan cannot be measured without laying out its widgets');
    return TextMeasure._(
      data: text.data,
      textSpan: spacing == null || span == null ? span : _withSpacing(span, spacing),
      style: spacing == null ? style : style.merge(spacing),
      // ignore: deprecated_member_use
      textScaler: switch ((text.textScaler, text.textScaleFactor)) {
        (final TextScaler s, _) => s,
        (null, final double f) => TextScaler.linear(f),
        (null, null) => context == null ? TextScaler.noScaling : MediaQuery.textScalerOf(context),
      },
      maxLines: text.maxLines ?? dts?.maxLines,
      softWrap: text.softWrap ?? dts?.softWrap ?? true,
      overflow: text.overflow ?? style.overflow ?? dts?.overflow ?? TextOverflow.clip,
      strutStyle: text.strutStyle?.merge(StrutStyle(height: lineHeight)),
      textWidthBasis: text.textWidthBasis ?? dts?.textWidthBasis ?? TextWidthBasis.parent,
      textHeightBehavior:
          text.textHeightBehavior ??
          dts?.textHeightBehavior ??
          (context == null ? null : DefaultTextHeightBehavior.maybeOf(context)),
      textAlign: text.textAlign ?? dts?.textAlign ?? TextAlign.start,
      textDirection: text.textDirection ?? (context == null ? null : Directionality.maybeOf(context)) ?? TextDirection.ltr,
      locale: text.locale ?? (context == null ? null : Localizations.maybeLocaleOf(context)),
      spanLocale: text.locale,
    );
  }

  TextMeasure._({
    required this.data,
    required this.textSpan,
    required this.style,
    required this.textScaler,
    required this.maxLines,
    required this.softWrap,
    required this.overflow,
    required this.strutStyle,
    required this.textWidthBasis,
    required this.textHeightBehavior,
    required this.textAlign,
    required this.textDirection,
    required this.locale,
    required this.spanLocale,
  });

  final String? data;
  final InlineSpan? textSpan;

  /// The resolved style: DefaultTextStyle, bold text and spacing overrides merged in.
  final TextStyle style;
  final TextScaler textScaler;
  final int? maxLines;
  final bool softWrap;
  final TextOverflow overflow;
  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final Locale? locale;

  /// The Text's own locale, its TextSpan's.
  final Locale? spanLocale;

  /// Font size after text scaling, px.
  late final double fontSize = textScaler.scale(style.fontSize ?? kDefaultFontSize);

  /// The sidecar the answers come from, or null when Flutter lays every one out:
  /// no sidecar for the font family, rich text, an ellipsis, or a style the
  /// sidecar does not describe (another weight, slant, variation, feature set,
  /// direction or locale). Leading distribution moves a line's leading, not its
  /// height (measured: Material 3's even distribution gives the same heights).
  late final BreakFirst? sidecar = _sidecar();

  late final LineOptions _options = LineOptions(
    letterSpacing: style.letterSpacing ?? 0,
    wordSpacing: style.wordSpacing ?? 0,
    height: style.height,
    maxLines: maxLines,
    strutStyle: strutStyle,
    textHeightBehavior: textHeightBehavior,
  );

  late final PreparedParagraph? _prepared = sidecar?.prepare(data!, _options);
  late final double? _sidecarWidth = _widthFromRecords();

  /// [BreakFirstText.width].
  late final double width = _sidecarWidth ?? _layout(double.infinity, (p) => p.width);

  /// Whether [width] came from the sidecar, without a layout.
  bool get widthFromSidecar => _sidecarWidth != null;

  /// Whether [height], [lineCount] and [canFit] at [maxWidth] come from the
  /// sidecar, without a layout.
  bool linesFromSidecar(double maxWidth) => _lines(maxWidth) != null;

  /// [BreakFirstText.height].
  double height(double maxWidth) {
    final n = _lines(maxWidth);
    return n == null ? _layout(maxWidth, (p) => p.height) : sidecar!.heightOfLines(_shown(n), fontSize, _options);
  }

  /// [BreakFirstText.lineCount].
  int lineCount(double maxWidth) {
    final n = _lines(maxWidth);
    return n == null ? _layout(maxWidth, (p) => p.computeLineMetrics().length) : _shown(n);
  }

  /// [BreakFirstText.canFit].
  bool canFit(double maxWidth, {double maxHeight = double.infinity}) {
    final n = _lines(maxWidth);
    final exceeds = n == null ? null : exceedsLines(data!, n, maxLines);
    if (exceeds == null) {
      return _layout(maxWidth, (p) => !p.didExceedMaxLines && p.height <= maxHeight && p.width <= maxWidth);
    }
    return !exceeds &&
        sidecar!.heightOfLines(_shown(n!), fontSize, _options) <= maxHeight &&
        (softWrap || width <= maxWidth);
  }

  int _shown(int lines) => math.min(lines, maxLines ?? lines);

  BreakFirst? _sidecar() {
    final bf = BreakFirst.registered(style.fontFamily);
    final s = style, l = locale;
    if (bf == null || data == null || textSpan != null || overflow == TextOverflow.ellipsis) return null;
    if (bf.model.rtl != (textDirection == TextDirection.rtl)) return null;
    if ((s.fontWeight ?? FontWeight.normal) != FontWeight.normal) return null;
    if ((s.fontStyle ?? FontStyle.normal) != FontStyle.normal) return null;
    if (s.fontVariations?.isNotEmpty ?? false) return null;
    if (!listEquals(s.fontFeatures ?? const [], bf.fontFeatures ?? const [])) return null;
    if (l != null && !sameLayoutLocales.contains(l.languageCode)) return null;
    return bf;
  }

  /// Lines at [maxWidth] before maxLines cuts them, or null when Flutter decides.
  int? _lines(double maxWidth) {
    final p = _prepared;
    if (p == null) return null;
    final n = p.records.lineCount(
      softWrap ? maxWidth : double.infinity,
      scaleFor(sidecar!.model, fontSize),
      letterSpacing: _options.letterSpacing,
      wordSpacing: _options.wordSpacing,
    );
    return n < 0 ? null : n;
  }

  /// Flutter's maxIntrinsicWidth from the width prefix: the widest line between
  /// hard breaks, trailing spaces included, plus the letter spacing of each of
  /// its glyph clusters. Only when glyph positions are exact in float32
  /// (measured: then equal bit for bit, with and without letter spacing), without
  /// word spacing, and with every line shown.
  double? _widthFromRecords() {
    final p = _prepared;
    if (p == null || textWidthBasis != TextWidthBasis.parent || _options.wordSpacing != 0) return null;
    final r = p.records, t = data!, ls = _options.letterSpacing, scale = scaleFor(sidecar!.model, fontSize);
    if (r.inexact || !exactPositions(scale, r.prefix[t.length] * scale + ls.abs() * t.length, ls)) return null;
    final loss = r.clusterLoss;
    var widest = 0.0, start = 0, lines = 0;
    for (var i = 0; i <= t.length; i++) {
      if (i < t.length && !isHardBreak(t.codeUnitAt(i))) continue;
      final clusters = loss == null ? i - start : i - start - (loss[i] - loss[start]);
      final w = (r.prefix[i] - r.prefix[start]) * scale + ls * clusters;
      if (w > widest) widest = w;
      start = i + 1;
      lines++;
    }
    return maxLines != null && lines > maxLines! ? null : widest;
  }

  /// [read] from a TextPainter configured as RenderParagraph configures its own,
  /// laid out in a box [maxWidth] wide.
  T _layout<T>(double maxWidth, T Function(TextPainter p) read) {
    final p = TextPainter(
      text: TextSpan(style: style, text: data, locale: spanLocale, children: textSpan == null ? null : [textSpan!]),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: maxLines,
      ellipsis: overflow == TextOverflow.ellipsis ? '…' : null,
      locale: locale,
      strutStyle: strutStyle,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
    )..layout(maxWidth: softWrap || overflow == TextOverflow.ellipsis ? maxWidth : double.infinity);
    try {
      return read(p);
    } finally {
      p.dispose();
    }
  }
}

/// MediaQuery's spacing overrides on every TextSpan, as Text.build applies them.
InlineSpan _withSpacing(InlineSpan span, TextStyle spacing) => span is! TextSpan || span.runtimeType != TextSpan
    ? span
    : TextSpan(
        text: span.text,
        children: span.children?.map((c) => _withSpacing(c, spacing)).toList(),
        style: span.style?.merge(spacing) ?? spacing,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        onEnter: span.onEnter,
        onExit: span.onExit,
        semanticsLabel: span.semanticsLabel,
        semanticsIdentifier: span.semanticsIdentifier,
        locale: span.locale,
        spellOut: span.spellOut,
      );

/// Exact line breaks and paragraph heights for Flutter, computed before shaping
/// from a precompiled, certified per-font width model (the sidecar).
///
/// High level: [BreakFirst.load], then [BreakFirst.height] or
/// [BreakFirst.lineStarts]. Build step: [buildSidecar]. The rest is the model
/// itself, for tools and experiments.
library;

export 'src/break_first.dart';
export 'src/dictionary_break.dart';
export 'src/engine.dart';
export 'src/text_measure.dart';
export 'src/width_model.dart';

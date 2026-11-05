/// The width model and the breaker alone, without Flutter: for a background
/// isolate, a server or a command-line tool. Decode the sidecar with
/// [WidthModel.decode], set [quantizeFontSize] and [hardBreakKerns] to what
/// [calibrateEngine] found on the target platform, then [buildRecords] and
/// [Records.lineCount] or [Records.lineStarts].
library;

export 'src/dictionary_break.dart';
export 'src/width_model.dart';

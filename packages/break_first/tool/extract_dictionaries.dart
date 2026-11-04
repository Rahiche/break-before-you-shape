// Copies ICU's word dictionaries for Thai, Lao, Khmer and Burmese out of the
// icudtl.dat that Flutter ships, byte for byte, into assets/dictionaries/.
//
//   dart tool/extract_dictionaries.dart [icudtl.dat] [out dir]
//
// Defaults: $FLUTTER_ROOT (or ~/development/flutter)/bin/cache/artifacts/engine/
// darwin-x64/icudtl.dat, and assets/dictionaries next to this tool. Every
// platform's icudtl.dat of one engine build carries the same brkitr data; the
// files are the ICU data items themselves (generic header, then the dictionary
// indexes and a BytesTrie), so their SHA-256 can be checked against the
// artifact. lib/src/dictionary_break.dart reads them (loadDictionary).
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

const _items = {
  'thaidict.dict': 'thaidict.dict',
  'laodict.dict': 'laodict.dict',
  'khmerdict.dict': 'khmerdict.dict',
  'burmesedict.dict': 'burmesedict.dict',
};

void main(List<String> args) {
  final home = Platform.environment['HOME'] ?? '';
  final flutter = Platform.environment['FLUTTER_ROOT'] ?? '$home/development/flutter';
  final icu = args.isNotEmpty ? args[0] : '$flutter/bin/cache/artifacts/engine/darwin-x64/icudtl.dat';
  final out = args.length > 1 ? args[1] : '${File(Platform.script.toFilePath()).parent.parent.path}/assets/dictionaries';
  final data = File(icu).readAsBytesSync();
  final items = icuDataItems(data);
  Directory(out).createSync(recursive: true);
  var total = 0;
  for (final MapEntry(key: item, value: file) in _items.entries) {
    final name = items.keys.firstWhere((k) => k.endsWith('/brkitr/$item'),
        orElse: () => throw StateError('$icu has no brkitr/$item'));
    // Drop the alignment padding after the item: generic header, then
    // indexes[IX_TOTAL_SIZE] bytes of dictionary data.
    final padded = items[name]!;
    final bd = ByteData.sublistView(padded);
    final header = bd.getUint16(0, Endian.little);
    final bytes = Uint8List.sublistView(padded, 0, header + bd.getInt32(header + 12, Endian.little));
    File('$out/$file').writeAsBytesSync(bytes);
    total += bytes.length;
    print('$name -> $out/$file (${bytes.length} bytes)');
  }
  print('total $total bytes');
}

/// The items of an ICU common data file (.dat): name -> bytes. The package
/// (e.g. "icudt78l/") is part of the name.
Map<String, Uint8List> icuDataItems(Uint8List dat) {
  final bd = ByteData.sublistView(dat);
  final headerSize = bd.getUint16(0, Endian.little);
  if (dat[2] != 0xDA || dat[3] != 0x27) throw const FormatException('not an ICU data file');
  if (dat[8] != 0) throw const FormatException('big-endian ICU data is not supported');
  final count = bd.getUint32(headerSize, Endian.little);
  final offsets = <(String, int)>[];
  for (var i = 0; i < count; i++) {
    final nameOff = bd.getUint32(headerSize + 4 + 8 * i, Endian.little);
    final dataOff = bd.getUint32(headerSize + 8 + 8 * i, Endian.little);
    var e = headerSize + nameOff;
    while (dat[e] != 0) {
      e++;
    }
    offsets.add((String.fromCharCodes(dat, headerSize + nameOff, e), headerSize + dataOff));
  }
  // Items are stored in TOC order; each one ends where the next begins (the
  // last at the end of the file). Sort by offset to be safe.
  final sorted = [...offsets]..sort((a, b) => a.$2.compareTo(b.$2));
  final out = <String, Uint8List>{};
  for (var i = 0; i < sorted.length; i++) {
    final end = i + 1 < sorted.length ? sorted[i + 1].$2 : dat.length;
    out[sorted[i].$1] = Uint8List.sublistView(dat, sorted[i].$2, end);
  }
  return out;
}

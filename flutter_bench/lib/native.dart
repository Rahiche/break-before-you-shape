// The C port of the breaker (native/break_first.c) behind dart:ffi, for the
// experiment that measures whether native code is worth the boundary. Paragraphs
// are copied into a buffer the C side owns; that copy is part of the cost.
import 'dart:ffi';
import 'dart:typed_data';

final class _Model extends Opaque {}

typedef _NewC = Pointer<_Model> Function(Pointer<Uint8>, IntPtr);
typedef _NewD = Pointer<_Model> Function(Pointer<Uint8>, int);

class NativeBreaker {
  NativeBreaker(String libraryPath, Uint8List sidecar) {
    final lib = DynamicLibrary.open(libraryPath);
    final alloc = lib.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('bf_alloc');
    final release = lib.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('bf_release');
    _reserve = lib.lookupFunction<Pointer<Uint16> Function(Pointer<_Model>, IntPtr, IntPtr),
        Pointer<Uint16> Function(Pointer<_Model>, int, int)>('bf_reserve', isLeaf: true);
    _offsetsOf = lib.lookupFunction<Pointer<Uint32> Function(Pointer<_Model>), Pointer<Uint32> Function(Pointer<_Model>)>(
        'bf_offsets', isLeaf: true);
    _outOf = lib.lookupFunction<Pointer<Int32> Function(Pointer<_Model>), Pointer<Int32> Function(Pointer<_Model>)>('bf_out',
        isLeaf: true);
    _lineCounts = lib.lookupFunction<Void Function(Pointer<_Model>, IntPtr, Double, Double),
        void Function(Pointer<_Model>, int, double, double)>('bf_line_counts', isLeaf: true);
    _prepare = lib.lookupFunction<IntPtr Function(Pointer<_Model>, IntPtr), int Function(Pointer<_Model>, int)>('bf_prepare',
        isLeaf: true);
    _rewrap = lib.lookupFunction<Void Function(Pointer<_Model>, Double, Double), void Function(Pointer<_Model>, double, double)>(
        'bf_rewrap', isLeaf: true);
    _lineStarts = lib.lookupFunction<Int32 Function(Pointer<_Model>, IntPtr, Double, Double, Pointer<Int32>, Int32),
        int Function(Pointer<_Model>, int, double, double, Pointer<Int32>, int)>('bf_line_starts', isLeaf: true);
    final bytes = alloc(sidecar.length);
    bytes.asTypedList(sidecar.length).setAll(0, sidecar);
    _m = lib.lookupFunction<_NewC, _NewD>('bf_model_new')(bytes, sidecar.length);
    release(bytes);
    if (_m == nullptr) throw const FormatException('not a BFW2 sidecar');
    _startsBuf = alloc(4 * 4096).cast<Int32>();
  }

  late final Pointer<_Model> _m;
  late final Pointer<Uint16> Function(Pointer<_Model>, int, int) _reserve;
  late final Pointer<Uint32> Function(Pointer<_Model>) _offsetsOf;
  late final Pointer<Int32> Function(Pointer<_Model>) _outOf;
  late final void Function(Pointer<_Model>, int, double, double) _lineCounts;
  late final int Function(Pointer<_Model>, int) _prepare;
  late final void Function(Pointer<_Model>, double, double) _rewrap;
  late final int Function(Pointer<_Model>, int, double, double, Pointer<Int32>, int) _lineStarts;
  late final Pointer<Int32> _startsBuf;

  // Views of the C buffers, refreshed only when they grow.
  int _unitsCap = -1, _nCap = -1;
  late Uint16List _text;
  late Uint32List _offsets;
  late Int32List _out;

  void _ensure(int units, int n) {
    if (units <= _unitsCap && n <= _nCap) return;
    _unitsCap = units > _unitsCap ? units * 2 : _unitsCap;
    _nCap = n > _nCap ? n * 2 : _nCap;
    _text = _reserve(_m, _unitsCap, _nCap).asTypedList(_unitsCap);
    _offsets = _offsetsOf(_m).asTypedList(_nCap + 1);
    _out = _outOf(_m).asTypedList(_nCap + 1);
  }

  /// Copies [paras] into the C buffer.
  void load(List<String> paras) {
    var units = 0;
    for (final p in paras) {
      units += p.length;
    }
    _ensure(units, paras.length);
    final text = _text, offs = _offsets;
    var o = 0;
    for (var i = 0; i < paras.length; i++) {
      offs[i] = o;
      final p = paras[i];
      for (var k = 0; k < p.length; k++) {
        text[o + k] = p.codeUnitAt(k);
      }
      o += p.length;
    }
    offs[paras.length] = o;
  }

  /// Line counts of the loaded paragraphs (-1: Flutter decides), in a view of the
  /// C output buffer.
  Int32List lineCounts(int n, double maxWidth, double scale) {
    _lineCounts(_m, n, maxWidth, scale);
    return _out;
  }

  /// One paragraph, one call: copy plus call.
  int lineCount(String p, double maxWidth, double scale) {
    _ensure(p.length, 1);
    final text = _text;
    for (var k = 0; k < p.length; k++) {
      text[k] = p.codeUnitAt(k);
    }
    _offsets[0] = 0;
    _offsets[1] = p.length;
    _lineCounts(_m, 1, maxWidth, scale);
    return _out[0];
  }

  /// Keeps records of the loaded paragraphs for [rewrap]; returns how many are covered.
  int prepare(int n) => _prepare(_m, n);

  Int32List rewrap(double maxWidth, double scale) {
    _rewrap(_m, maxWidth, scale);
    return _out;
  }

  /// Line starts of loaded paragraph [i], or null when Flutter must decide.
  List<int>? lineStarts(int i, double maxWidth, double scale) {
    final n = _lineStarts(_m, i, maxWidth, scale, _startsBuf, 4096);
    return n < 0 ? null : _startsBuf.asTypedList(n).toList();
  }
}

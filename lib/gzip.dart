// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

/// Implementatin largely based on https://github.com/brendan-duncan/archive.
/// Except here the InputStream is async, and we use functions rather than
/// methods and classes for most things.
library ccp4.gzip;

import 'dart:math';
import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

final _log = new Logger('ccp4.gzip');

/// Not enough data available in stream.
class NotEnoughData {
  final bool finalChunk;
  NotEnoughData(this.finalChunk);
}

/// Async generic stream reader. Can be connected to a Stream<List<T>>.
class ChunkedStreamReader<T> {
  final Stream<List<T>> _stream;
  final _buffer = new List<T>();
  Iterator _iterator;
  var _offset = 0;
  var _done = false;

  ChunkedStreamReader(this._stream) {
    _stream.listen((chunk) {
      _log.info('Received chunk of ${chunk.length} bytes');
      // Chunk is appended to buffer.
      _buffer.addAll(chunk);
    }, onDone: () {
      _done = true;
    });
  }

  /// Take next [n] elements in the buffer.
  List<T> take(int n) {
    assert(_iterator != null);

    // Iterate to next [n] elements.
    final data = new List<T>(n);
    for (var i = 0; i < data.length; i++) {
      if (!_iterator.moveNext()) {
        throw new NotEnoughData(_done);
      } else {
        _offset++;
        data[i] = _iterator.current;
      }
    }

    /* (_offset % 1000 == 0) {
      _log.info('Buffer length: ${_buffer.length}, offset: $_offset');
    }*/

    return data;
  }

  /// Shorthand for consuming only a single element.
  T single() => take(1).first;
}

/// Read null terminated string from given ChunkedStreamReader<int> [reader].
String readNullTerminatedString(ChunkedStreamReader<int> reader) {
  // Take single integers untill this integer is 0.
  final buffer = new List<int>();
  var value = reader.single();
  while (value != 0) {
    buffer.add(value);
    value = reader.single();
  }
  return new String.fromCharCodes(buffer);
}

/// Merge List<int> into single unsigned integer. Not the most efficent, but I
/// don't like redundancy.
int uint(List<int> bytes) {
  var value = 0;
  for (var i = 0; i < bytes.length; i++) {
    value |= bytes[bytes.length - i - 1] << (i * 8);
  }
  return value;
}

/// Function for bit reader to get next byte.
typedef int BitReaderNextByte();

/// Generic bit reader.
class BitReader {
  final BitReaderNextByte _nextByte;
  int _buffer = 0;
  int _length = 0;

  BitReader(this._nextByte);

  // Reset to 0.
  void reset() {
    _buffer = 0;
    _length = 0;
  }

  // Get [n] bits.
  int shift(int n, [bool deleteFromBuffer = true]) {
    // Worst case scenario is forcing the use of a bigint.
    assert(n <= 64 - 8);

    // While buffer is not large enough, add next byte to buffer.
    while (_length < n) {
      final octet = _nextByte();
      _buffer |= octet << _length;
      _length += 8;
    }

    // Get resulting bits.
    final result = _buffer & ((1 << n) - 1);
    if (deleteFromBuffer) {
      delete(n);
    }

    return result;
  }

  // Delete [n] bits from the buffer.
  void delete(int n) {
    assert(_length >= n);
    _buffer >>= n;
    _length -= n;
  }
}

/// Huffman table
class HuffmanTable {
  final Uint32List codeTable, lengthTable;
  final int minCodeLength, maxCodeLength;
  HuffmanTable(
      this.codeTable, this.lengthTable, this.minCodeLength, this.maxCodeLength);
}

HuffmanTable createHuffmanTableFromLengths(List<int> lengths) {
  final minCodeLength = lengths.reduce(min);
  final maxCodeLength = lengths.reduce(max);
  final tableSize = 1 << maxCodeLength;
  final codeTable = new Uint32List(tableSize);
  final lengthTable = new Uint32List(tableSize);

  for (var codeLength = 1, code = 0, skip = 2; codeLength <= maxCodeLength;) {
    for (var i = 0; i < lengths.length; ++i) {
      if (lengths[i] == codeLength) {
        var reversed = 0;
        var rtemp = code;
        for (int j = 0; j < codeLength; ++j) {
          reversed = (reversed << 1) | (rtemp & 1);
          rtemp >>= 1;
        }

        for (int j = reversed; j < tableSize; j += skip) {
          codeTable[j] = i;
          lengthTable[j] = codeLength;
        }

        code++;
      }
    }

    codeLength++;
    code <<= 1;
    skip <<= 1;
  }

  return new HuffmanTable(codeTable, lengthTable, minCodeLength, maxCodeLength);
}

/// Decompress GZIP data. Takes a stream of chunks (Stream<List<int>>) as
/// [input], and returns a stream of decoded chunks (one chunk per zlib block).
/// The returned stream is a single-subscription stream.
Stream<List<int>> decodeGzip(Stream<List<int>> input) {
  // Create input stream reader and output stream controller.
  final inputReader = new ChunkedStreamReader<int>(input);
  final outStream = new StreamController<List<int>>();

  // Keep re-trying.
  scheduleMicrotask(() async {
    var started = false;
    while (!started) {
      try {
        // Reset iterator.
        inputReader._iterator = inputReader._buffer.iterator;

        await _gzipStart(inputReader, outStream);
        started = true;
      } on NotEnoughData catch (e) {
        if (e.finalChunk) {
          outStream.addError(e);
        } else {
          // Wait for N ms to give the buffer time to catch up.
          const wait = 100;
          _log.info('Not enough data, pausing ${wait}ms');
          await new Future.delayed(
              new Duration(milliseconds: wait), () => true);

          continue;
        }
      } catch (e, stackTrace) {
        outStream.addError(e);
      }
    }
  });

  return outStream.stream;
}

Future<Null> _gzipStart(
    ChunkedStreamReader<int> input, StreamController<List<int>> output) async {
  // Some header constants
  const gzipSignature = 0x1f8b;
  const gzipDeflate = 8;
  const flagText = 1;
  const flagHcrc = 2;
  const flagExtra = 4;
  const flagName = 8;
  const flagComment = 16;

  // Decode header.
  final signature = uint(input.take(2));
  if (signature != gzipSignature) {
    throw new Exception('invalid GZip signature: $signature');
  }

  final compressionMethod = input.single();
  if (compressionMethod != gzipDeflate) {
    throw new Exception('invalid GZip compression method');
  }

  final flags = input.single();
  //final fileModTime = uint(input.take(4));
  //final extraFlags = input.single();
  //final osType = input.single();
  input.take(6);

  if (flags & flagExtra != 0) {
    final t = uint(input.take(2));
    input.take(t);
  }

  if (flags & flagName != 0) {
    readNullTerminatedString(input);
  }

  if (flags & flagComment != 0) {
    readNullTerminatedString(input);
  }

  if (flags & flagHcrc != 0) {
    input.take(2);
  }

  _log.info('Decoded header');

  // Inflate.
  await _zlibInflate(input, output);

  output.close();
}

Future<Null> _zlibInflate(
    ChunkedStreamReader<int> input, StreamController<List<int>> output) async {
  final bitReader = new BitReader(() => input.single());

  // Sliding window is up to 32K (32768);
  final slidingWindow = new List<int>();

  var finalBlock = false;
  var blockNumber = 0;
  while (!finalBlock) {
    // Trim sliding window.
    if (slidingWindow.length > _lz77WindowSize) {
      slidingWindow.removeRange(0, slidingWindow.length - _lz77WindowSize);
    }

    // Rewind bit reader so that its buffer holds 0-7 bits of the current byte.
    // This way we can nicely align with the byte frame once we arrive in an
    // uncompressed block.
    var offset = input._offset;
    while (bitReader._length > 8) {
      bitReader.delete(8);
      offset--;
    }

    // Store bit reader state.
    final bitReaderBuffer = bitReader._buffer;
    final bitReaderLength = bitReader._length;

    // Remove chunk reader offset.
    input._buffer.removeRange(0, offset);
    input._offset = 0;

    // Reset chunk reader iterator.
    input._iterator = input._buffer.iterator;

    // Try parse block with currenly buffered data.
    try {
      // Read block header.
      finalBlock = bitReader.shift(1) != 0;
      final blockType = bitReader.shift(2);

      _log.info('Block #$blockNumber BFINAL = $finalBlock, BTYPE = $blockType');

      // Block types
      const blockUncompressed = 0;
      const blockFixedHuffman = 1;
      const blockDynamicHuffman = 2;

      switch (blockType) {
        case blockUncompressed:
          bitReader.reset();
          final len = uint(input.take(2));
          final nlen = uint(input.take(2));

          // Check length.
          if (len != ~nlen) {
            throw new Exception('invalid block header (BLOCK_UNCOMPRESSED)');
          }

          // Get chunk and write to output stream and sliding window.
          final chunk = input.take(len);
          output.add(chunk);
          slidingWindow.addAll(chunk);

          break;

        case blockFixedHuffman:
          final chunk = _zlibHuffmanDecode(bitReader, slidingWindow,
              _fixedLiteralTable, _fixedDistanceTable);
          output.add(chunk);

          break;

        case blockDynamicHuffman:
          // Get Huffman table parameters (for lengths table, literal table,
          // distance table)
          final literalSize = (bitReader.shift(5)) + 257;
          final distanceSize = (bitReader.shift(5)) + 1;
          final lengthSize = (bitReader.shift(4)) + 4;

          // Create Huffman table for lengths.
          final lengthLengths = new Uint8List(_huffmanOrder.length);
          for (int i = 0; i < lengthSize; i++) {
            lengthLengths[_huffmanOrder[i]] = bitReader.shift(3);
          }
          final lengthTable = createHuffmanTableFromLengths(lengthLengths);

          // Decode dynamic Huffman tables for literals and distances.
          final literalTable = _zlibDecodeDynamicHuffmanTable(
              bitReader, literalSize, lengthTable);
          final distanceTable = _zlibDecodeDynamicHuffmanTable(
              bitReader, distanceSize, lengthTable);

          _log.info('Decoded dynamic Huffman table');

          // Decode chunk.
          final chunk = _zlibHuffmanDecode(
              bitReader, slidingWindow, literalTable, distanceTable);
          output.add(chunk);

          break;

        default:
          throw new Exception('illegal deflate BTYPE: $blockType');
      }

      blockNumber++;
    } on NotEnoughData catch (e) {
      if (!e.finalChunk) {
        // Reset bit reader state.
        bitReader._buffer = bitReaderBuffer;
        bitReader._length = bitReaderLength;

        // Reset chunk reader offset.
        input._offset = 0;

        // Wait for N ms to give the buffer time to catch up.
        // TODO: this parameter could be determined dynamically
        const wait = 10;
        _log.info('Not enough data, pausing ${wait}ms');
        await new Future.delayed(new Duration(milliseconds: wait), () => true);

        continue;
      } else {
        rethrow;
      }
    }

    _log.info('Processed block covering ${input._offset} bytes');
  }
}

/// Read next huffman code using bitreader.
int _readNextHuffmanCode(BitReader bitReader, HuffmanTable table) {
  // Get huffman table index.
  assert(table.maxCodeLength > 0);
  final idx = bitReader.shift(table.maxCodeLength, false);

  // Get length of associated element, and remove this from the bitreader.
  assert(table.lengthTable[idx] > 0);
  bitReader.delete(table.lengthTable[idx]);

  return table.codeTable[idx];
}

/// Decode Huffman table from [bitReader] using a Huffman [lengthTable] for the
/// lengths.
HuffmanTable _zlibDecodeDynamicHuffmanTable(
    BitReader bitReader, int size, HuffmanTable lengthTable) {
  final lengths = new Uint8List(size);
  var prev = 0;
  var i = 0;
  while (i < size) {
    final code = _readNextHuffmanCode(bitReader, lengthTable);
    switch (code) {
      case 16:
        // Repeat last code.
        var repeat = 3 + bitReader.shift(2);
        while (repeat-- > 0) {
          lengths[i++] = prev;
        }
        break;

      case 17:
        // Repeat 0s.
        var repeat = 3 + bitReader.shift(3);
        while (repeat-- > 0) {
          lengths[i++] = 0;
        }
        prev = 0;
        break;

      case 18:
        // Repeat more 0s.
        var repeat = 11 + bitReader.shift(7);
        while (repeat-- > 0) {
          lengths[i++] = 0;
        }
        prev = 0;
        break;

      default: // [0, 15]
        // Literal bitlength for this code.
        assert(code >= 0 && code <= 15);
        lengths[i++] = code;
        prev = code;
        break;
    }
  }

  return createHuffmanTableFromLengths(lengths);
}

List<int> _zlibHuffmanDecode(BitReader bitReader, List<int> slidingWindow,
    HuffmanTable literalTable, HuffmanTable distanceTable) {
  // Note: we add new bytes to the sliding window.
  final initialSWLength = slidingWindow.length;

  var endOfBlock = false;
  while (!endOfBlock) {
    final code = _readNextHuffmanCode(bitReader, literalTable);

    assert(code >= 0 && code <= 285);

    // [0, 255]: literal
    if (code < 256) {
      slidingWindow.add(code & 0xff);
      continue;
    }

    // 256: end of Huffman block
    else if (code == 256) {
      endOfBlock = true;
      continue;
    }

    // [257, 285]: lz77 (copy from sliding window)

    final lengthCode = code - 257;
    int copyLength = _huffmanlz77Length[lengthCode] +
        bitReader.shift(_huffmanlz77LengthExtraBitCount[lengthCode]);

    final distanceCode = _readNextHuffmanCode(bitReader, distanceTable);
    if (distanceCode >= 0 && distanceCode <= 29) {
      final int copyDistance = _huffmanlz77Distance[distanceCode] +
          bitReader.shift(_huffmanlz77DistanceExtraBitCount[distanceCode]);

      // lz77 decode
      while (copyLength > 0) {
        final size = min(copyLength, copyDistance);
        final startIndex = slidingWindow.length - copyDistance;
        final copyRange = slidingWindow.getRange(startIndex, startIndex + size);
        slidingWindow.addAll(copyRange);
        copyLength -= copyDistance;
      }
    } else {
      throw new Exception('illegal distance symbol');
    }
  }

  return slidingWindow.getRange(initialSWLength, slidingWindow.length).toList();
}

/// Fixed huffman length code table
const List<int> _huffmanFixedLiteralLengths = const [
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  //
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  //
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  //
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  //
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  //
  9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7, 7, 7, 7, 7, 7, 7,
  //
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8
];

final HuffmanTable _fixedLiteralTable =
    createHuffmanTableFromLengths(_huffmanFixedLiteralLengths);

/// Fixed huffman distance code table
const List<int> _huffmanFixedDistanceLengths = const [
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  //
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5
];
final HuffmanTable _fixedDistanceTable =
    createHuffmanTableFromLengths(_huffmanFixedDistanceLengths);

/// Max backward length for LZ77.
const int _lz77WindowSize = 32768;

/// Max copy length for LZ77.
const int _lz77MaxCopySize = 258;

/// Huffman order
const List<int> _huffmanOrder = const [
  //
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
];

/// Huffman length of lz77 code.
const List<int> _huffmanlz77Length = const [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];

/// Huffman length extra-bits table.
const List<int> _huffmanlz77LengthExtraBitCount = const [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
  //
  4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0
];

/// Huffman distance code table.
const List<int> _huffmanlz77Distance = const [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  //
  8193, 12289, 16385, 24577
];

/// Huffman distance extra-bits table.
const List<int> _huffmanlz77DistanceExtraBitCount = const [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
  //
  11, 11, 12, 12, 13, 13
];

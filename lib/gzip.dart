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

/// Async generic stream reader. Can be connected to a Stream<List<T>>.
class ChunkedStreamReader<T> {
  final Stream<List<T>> _stream;
  final _buffer = new List<T>();
  Future<bool> _nextChunk;

  ChunkedStreamReader(this._stream) {
    var nextChunkCompleter = new Completer<bool>();
    _nextChunk = nextChunkCompleter.future;
    _stream.listen((chunk) {
      // Chunk is appended to buffer.
      _buffer.addAll(chunk);
      nextChunkCompleter.complete(false);

      // Refresh chunk completer.
      nextChunkCompleter = new Completer<bool>();
      _nextChunk = nextChunkCompleter.future;
    }, onDone: () {
      nextChunkCompleter.complete(true);
    });
  }

  /// Take next [n] elements in the stream. If the stream closes in between, an
  /// exception is thrown.
  Future<List<T>> take(int n) async {
    // Remove [n] elements from the beginning of the buffer. If the buffer is
    // too short, we have to wait for a new chunk.
    while (_buffer.length < n) {
      // Await next chunk. If this is the end instead of a chunk, throw an error
      if (await _nextChunk) {
        throw new Exception('not enough data is available in the stream');
      }
    }

    // We have buffered enough data, now remove it from the buffer.
    final list = _buffer.getRange(0, n).toList();
    _buffer.removeRange(0, n);
    return list;
  }

  /// Shorthand for consuming only a single element.
  Future<T> single() async {
    return (await take(1)).first;
  }
}

/// Read null terminated string from given ChunkedStreamReader<int> [reader].
Future<String> readNullTerminatedString(ChunkedStreamReader<int> reader) async {
  // Take single integers untill this integer is 0.
  final buffer = new List<int>();
  var value = await reader.single();
  while (value != 0) {
    buffer.add(value);
    value = await reader.single();
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
typedef Future<int> BitReaderNextByte();

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
  Future<int> shift(int n, [bool deleteFromBuffer = true]) async {
    // Worst case scenario is forcing the use of a bigint.
    assert(n <= 64 - 8);

    // While buffer is not large enough, add next byte to buffer.
    while (_length < n) {
      final octet = await _nextByte();
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
  final inStream = new ChunkedStreamReader<int>(input);
  final outStream = new StreamController<List<int>>();

  // Start decoding.
  _gzipStart(inStream, outStream);

  return outStream.stream;
}

Future<Null> _gzipStart(
    ChunkedStreamReader<int> input, StreamController<List<int>> output) async {
  // Some header constants
  const gzipSignature = 0x8b1f;
  const gzipDeflate = 8;
  const flagText = 1;
  const flagHcrc = 2;
  const flagExtra = 4;
  const flagName = 8;
  const flagComment = 16;

  // Decode header.
  final signature = uint(await input.take(2));
  if (signature != gzipSignature) {
    throw new Exception('invalid GZip signature');
  }

  final compressionMethod = await input.single();
  if (compressionMethod != gzipDeflate) {
    throw new Exception('invalid GZip compression method');
  }

  final flags = await input.single();
  //final fileModTime = uint(await input.take(4));
  //final extraFlags = await input.single();
  //final osType = await input.single();
  await input.take(6);

  if (flags & flagExtra != 0) {
    final t = uint(await input.take(2));
    await input.take(t);
  }

  if (flags & flagName != 0) {
    await readNullTerminatedString(input);
  }

  if (flags & flagComment != 0) {
    await readNullTerminatedString(input);
  }

  if (flags & flagHcrc != 0) {
    await input.take(2);
  }

  // Inflate.
  await _zlibInflate(input, output);

  // TODO: verify
}

Future<Null> _zlibInflate(
    ChunkedStreamReader<int> input, StreamController<List<int>> output) async {
  final bitReader = new BitReader(() => input.single());

  // Sliding window is up to 32K (32768);
  final slidingWindow = new List<int>();

  var finalBlock = false;
  while (!finalBlock) {
    // Trim sliding window.
    if (slidingWindow.length > _lz77WindowSize) {
      slidingWindow.removeRange(0, slidingWindow.length - _lz77WindowSize);
    }

    // Read block header.
    finalBlock = (await bitReader.shift(1)) != 0;
    final blockType = await bitReader.shift(2);

    // Block types
    const blockUncompressed = 0;
    const blockFixedHuffman = 1;
    const blockDynamicHuffman = 2;

    switch (blockType) {
      case blockUncompressed:
        bitReader.reset();
        final len = uint(await input.take(2));
        final nlen = uint(await input.take(2));

        // Check length.
        if (len != ~nlen) {
          throw new Exception('invalid block header (BLOCK_UNCOMPRESSED)');
        }

        // Get chunk and write to output stream and sliding window.
        final chunk = await input.take(len);
        output.add(chunk);
        slidingWindow.addAll(chunk);

        break;

      case blockFixedHuffman:
        await _zlibInflateFixedHuffmanBlock(bitReader, output);
        break;

      case blockDynamicHuffman:
        await _zlibInflateDynamicHuffmanBlock(bitReader, output);
        break;

      default:
        throw new Exception('unrecognized zlib deflate block type: blockType');
    }

    // Rewind bit reader so that its buffer holds 0-7 bits of the current byte.
    // This way we can nicely align with the byte frame once we arrive in an
    // uncompressed block.
    while (bitReader._length > 8) {
      final byte = bitReader._buffer & 0xff;
      bitReader.delete(8);
      input._buffer.insert(0, byte);
    }
  }
}

/// Read next huffman code using bitreader.
Future<int> _readNextHuffmanCode(
    BitReader bitReader, HuffmanTable table) async {
  // Get huffman table index.
  final idx = await bitReader.shift(table.maxCodeLength, false);

  // Get length of associated element, and remove this from the bitreader.
  bitReader.delete(table.lengthTable[idx]);

  return table.codeTable[idx];
}

Future<List<int>> _zlibHuffmanDecode(
    BitReader bitReader,
    List<int> slidingWindow,
    HuffmanTable literalTable,
    HuffmanTable distanceTable) async {
  // Note: we add new bytes to the sliding window.
  final initialSWLength = slidingWindow.length;

  var endOfBlock = false;
  while (!endOfBlock) {
    final code = await _readNextHuffmanCode(bitReader, literalTable);

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
        await bitReader.shift(_huffmanlz77LengthExtraBitCount[lengthCode]);

    final distanceCode = await _readNextHuffmanCode(bitReader, distanceTable);
    if (distanceCode >= 0 && distanceCode <= 29) {
      final int copyDistance = _huffmanlz77Distance[distanceCode] +
          await bitReader
              .shift(_huffmanlz77DistanceExtraBitCount[distanceCode]);

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
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 15, 1
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

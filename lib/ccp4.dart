// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

library ccp4;

import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart';
import 'package:vector_math/vector_math.dart';

class Vector3i {
  final int x, y, z;

  Vector3i(this.x, this.y, this.z);

  @override
  String toString() => '<$x, $y, $z>';
}

class DensityMap<T> {
  final Future<bool> loaded;

  /// Data dimensions.
  Vector3i size, start, intervals, axes;

  /// Cell dimensions in Angstoms
  Vector3 cellSize;

  /// Cell angles in degrees
  Vector3 rotation;

  /// Minimum density value
  double aMin;

  /// Maximum density value
  double aMax;

  /// Mean density value
  double aMean;

  /// Density root-mean-square for mean
  double aRms;

  /// Space group number
  int spaceGroupNumber;

  /// Density data
  Float32List data;

  DensityMap(this.loaded);
}

/// Read CCP4 map from a sink
///
/// Immediately returns a density map where the parsed data will become
/// available. When all data is loaded successfully, [DensityMap.loaded] will
/// complete to true, if an error occurred it will complete to false.
///
///
/// See: http://www.ccp4.ac.uk/html/maplib.html#description
/// And: https://github.com/uglymol/uglymol/blob/master/src/elmap.js
DensityMap readCCP4Map(ByteBuffer buffer, bool expandSymmetry) {
  final loaded = new Completer<bool>();
  final map = new DensityMap(loaded.future);
  _readCCP4(map, buffer, expandSymmetry).then(loaded.complete);
  return map;
}

Future<bool> _readCCP4(
    DensityMap map, ByteBuffer buffer, bool expandSymmetry) async {
  if (buffer.lengthInBytes < 256 * 4) {
    // Header is 256 * 4 bytes.
    throw new Exception('file is too short');
  }

  // Create integer view on header.
  final h = new Int32List.view(buffer, 0, 256);

  // Word 53 should be 'MAP' to identify file.
  if (h[52] != 0x2050414d) {
    throw new Exception('not a CCP4 map');
  }

  // Read header parameters.
  map.size = new Vector3i(h[0], h[1], h[2]);
  final mode = h[3];
  if (mode != 0 && mode != 2) {
    throw new Exception('only mode 0 and 2 are supported');
  }
  final bytesPerVoxel = mode == 0 ? 1 : 4;

  map.start = new Vector3i(h[4], h[5], h[6]);
  map.intervals = new Vector3i(h[7], h[8], h[9]);
  map.axes = new Vector3i(h[16], h[17], h[18]);

  // Check data size.
  final nsymbt = h[23];
  if (4 * 256 + nsymbt + bytesPerVoxel * map.size.x * map.size.y * map.size.z !=
      buffer.lengthInBytes) {
    throw new Exception('data size does not match the header parameters');
  }

  // Create floating point view on entire buffer.
  final floats = new Float32List.view(buffer, 0, buffer.lengthInBytes >> 2);

  map.cellSize = new Vector3(floats[10], floats[11], floats[12]);
  map.rotation = new Vector3(floats[13], floats[14], floats[15]);

  map.aMin = floats[19];
  map.aMax = floats[20];
  map.aMean = floats[21];
  map.aRms = floats[54];
  // TODO: recompute mean and RMS?

  map.spaceGroupNumber = h[22];

  // TODO: skew transformation
  /* if (h[24] != 0) {
    final mat = new Matrix3.fromList(floats.sublist(25, 33));
    final trans = new Vector3(floats[34], floats[35], floats[36]);
  } */

  if (nsymbt % 4 != 0) {
    throw new UnsupportedError(
        'NSYMBT is not aligned with a 4 byte reading frame');
  }

  final dataByteOffset = 256 * 4 + nsymbt;
  if (mode == 0) {
    final int8view = new Int8List.view(buffer, dataByteOffset);
    map.data = new Float32List(map.size.x * map.size.y * map.size.z);
    map.data.setAll(0, int8view.map((i) => i.toDouble()));
  } else if (mode == 2) {
    map.data = new Float32List.view(buffer, dataByteOffset);
  }

  if (expandSymmetry && nsymbt > 0) {
    throw new UnimplementedError('symmetry expansion is not yet implemented');
  }

  return true;
}

/// Parse Symmetry Operation. Unable to find a spec. Based on uglymol.
Matrix4 parseSymmetryOperation(String str) {
  final ops = str.toLowerCase().replaceAll(new RegExp(r'\s+'), '').split(',');
  if (ops.length != 3) {
    throw new ArgumentError('Unexpected symmetry operation: $str');
  }

  final mat = new Matrix4.zero();
  for (var row = 0; row < 3; row++) {
    final terms = ops[row].split(new RegExp(r'(?=[+-])'));
    for (var i = 0; i < terms.length; i++) {
      final term = terms[i];
      final sign = term[0] == '-' ? -1 : 1;
      final m1 = new RegExp(r'^[+-]?([xyz])$').firstMatch(term);
      if (m1 != null) {
        final d = m1.group(1);
        final pos = d == 'x' ? 0 : d == 'y' ? 1 : 2;
        mat.setEntry(row, pos, sign.toDouble());
      } else {
        final m2 = new RegExp(r'^[+-]?(\d)\/(\d)$').firstMatch(term);
        if (m2 == null) {
          throw new Exception('failed to parse $term in $str');
        }

        final num1 = num.parse(m2.group(1));
        final num2 = num.parse(m2.group(2));
        mat.setEntry(row, 3, sign * num1 * num2);
      }
    }

    mat.setEntry(3, 3, 1.0); // TODO: ?
  }

  return mat;
}

/// Create 2D image from [map] slice.
Image createImageFromDensityMapSlice(DensityMap map, int axis, int slice) {
  assert(axis == 0 || axis == 1 || axis == 2);

  final imageData = new Uint8List(map.size.x * map.size.y * 4);

  var offset = 0;
  if (axis == 0) {
    offset = map.size.x * map.size.y * slice;
  } else if (axis == 1) {
    offset = slice * map.size.x;
  } else if (axis == 2) {
    offset = slice;
  }

  var imageI = 0, dataI = 0;
  while (imageI < imageData.length) {
    final density = map.data[offset + dataI];
    var value = ((density - map.aMin) / (map.aMax - map.aMin) * 255).round();
    imageData[imageI++] = value;
    imageData[imageI++] = value;
    imageData[imageI++] = value;
    imageData[imageI++] = 255;

    if (axis == 0) {
      dataI++;
    } else if (axis == 1) {
      dataI++;
      if (dataI % map.size.x == 0) {
        dataI += map.size.x * (map.size.y - 1);
      }
    } else if (axis == 2) {
      dataI += map.size.x;
    }
  }

  final image = new Image.fromBytes(map.size.x, map.size.y, imageData);

  // In all cases we iterate through the image from the bottom pixel row to the
  // top one.
  return flipHorizontal(image);
}

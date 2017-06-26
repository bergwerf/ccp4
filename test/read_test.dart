// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ccp4/ccp4.dart';
import 'package:image/image.dart';

void main() {
  test('Read CCP4 .map file with dart:io GZIP', () async {
    // Read example file.
    final emdbid = 3491;
    final file = new File('test/emd_$emdbid.map.gz');
    final bytes = await file.readAsBytes();
    final uncompressed = GZIP.decoder.convert(bytes);
    final buffer = (uncompressed as TypedData).buffer;
    final map = readCCP4Map(buffer, true);
    expect(await map.loaded, equals(true));

    // Export 3 slices as image.
    for (var i = 0; i < 3; i++) {
      final center = (map.size.x / 2).round();
      final slice = createImageFromDensityMapSlice(map, i, center);
      final pngData = new PngEncoder().encodeImage(slice);
      final pngFile = new File('test/emd_$emdbid_slice_$i.png');
      await pngFile.writeAsBytes(pngData);
    }
  }, timeout: new Timeout(new Duration(minutes: 10)));
}

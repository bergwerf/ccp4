// Copyright (c) 2017, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ccp4/gzip.dart';
import 'package:ccp4/ccp4.dart';
import 'package:image/image.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    print('${rec.level.name}: ${rec.time}: ${rec.message}');
  });

  test('Read CCP4 .map file with dart:io GZIP', () async {
    // Read example file.
    final emdbid = 8514;
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
      final pngFile = new File('test/emd_${emdbid}_slice_$i.png');
      await pngFile.writeAsBytes(pngData);
    }
  }, skip: true, timeout: new Timeout(new Duration(minutes: 10)));

  test('Read CCP4 .map file with async GZIP and http', () async {
    // Get file stream from EBI server.
    final emdbid = 8514;
    final client = new http.Client();
    final uri = Uri.parse('http://ftp.ebi.ac.uk/pub/databases/emdb'
        '/structures/EMD-$emdbid/map/emd_$emdbid.map.gz');
    final streamedResponse = await client.send(new http.Request('GET', uri));

    final stream = decodeGzip(streamedResponse.stream);
    final uncompressed = new List<int>();
    await stream.forEach((chunk) => uncompressed.addAll(chunk));
    final buffer = new Uint8List.fromList(uncompressed).buffer;

    final map = readCCP4Map(buffer, true);
    expect(await map.loaded, equals(true));

    // Export 3 slices as image.
    for (var i = 0; i < 3; i++) {
      final center = (map.size.x / 2).round();
      final slice = createImageFromDensityMapSlice(map, i, center);
      final pngData = new PngEncoder().encodeImage(slice);
      final pngFile = new File('test/emd_${emdbid}_slice_$i.png');
      await pngFile.writeAsBytes(pngData);
    }
  }, skip: false, timeout: new Timeout(new Duration(minutes: 10)));
}

// The pure-Dart half of talking to a puck: the compact track format, the CRC the puck checks tracks with,
// and the lock that keeps one thing at a time on the phone's Bluetooth.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeback/puck/puck_link.dart';
import 'package:wakeback/puck/wbt.dart';

void main() {
  // A track as firmware/puck/src/track.h writes it: header (puck 7), one key record, one delta, then a
  // record cut short (the puck lost power mid-write).
  final wbt = Uint8List.fromList([87, 66, 84, 49, 7, 0, 0, 0, 1, 0, 8, 136, 31, 154, 1, 0, 0, 32, 87, 250, 31, 224, 181, 52, 254, 169, 1, 155, 10, 133, 255, 15, 0, 2, 200, 0, 15, 0, 234, 255, 175, 1, 160, 10, 231, 3, 2, 1, 2, 3, 4, 5]);

  test('a .wbt track decodes to the CSV the dock writes', () {
    expect(Wbt.isWbt(wbt), isTrue);
    expect(Wbt.puckOf(wbt), 7);
    expect(Wbt.points(wbt), 2);
    expect(
      utf8.decode(Wbt.toCsv(wbt)!),
      't_ms,lat,lon,sog_kn,hdg,heel,pitch\n'
      '1761465600000,53.6500000,-3.0100000,4.25,272,-12.3,1.5\n'
      '1761465600200,53.6500015,-3.0100022,4.31,272,-12.5,1.5\n',
    );
  });

  test('something that is not a .wbt is left alone', () {
    final csv = Uint8List.fromList(utf8.encode('t_ms,lat,lon\n1,2,3\n'));
    expect(Wbt.isWbt(csv), isFalse);
    expect(Wbt.toCsv(csv), isNull);
    expect(Wbt.points(csv), 0);
  });

  test('CRC-32 matches the standard one, whole or in pieces', () {
    final all = utf8.encode('123456789');
    expect(Crc32.of(all), 0xCBF43926);
    expect(Crc32.of(all.sublist(4), Crc32.of(all.sublist(0, 4))), 0xCBF43926);
    expect(Crc32.of(const []), 0);
  });

  test('the Bluetooth link goes to one holder at a time, in the order asked', () async {
    final link = PuckLink();
    final order = <String>[];
    final first = await link.acquire();
    expect(link.isHeld, isTrue);
    expect(link.tryAcquire(), isNull);

    final second = link.acquire().then((release) {
      order.add('second');
      return release;
    });
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty); // still waiting

    order.add('first done');
    first();
    first(); // letting go twice is harmless
    final releaseSecond = await second;
    expect(order, ['first done', 'second']);
    expect(link.isHeld, isTrue);

    releaseSecond();
    expect(link.isHeld, isFalse);
    final third = link.tryAcquire();
    expect(third, isNotNull);
    third!();
    expect(link.isHeld, isFalse);
  });
}

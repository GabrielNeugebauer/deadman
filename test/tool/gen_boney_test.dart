import 'dart:io';

import 'package:deadman/ui/widgets/brand/boney_sprites.g.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/gen_boney.dart';

void main() {
  test('every pose matches its SVG, layer for layer', () {
    for (final (i, name) in poses.indexed) {
      final svg = File('$source/svg/boney-$name.svg').readAsStringSync();
      final layers = parseLayers(name, svg);
      final pose = BoneyPose.values[i];
      expect(pose.layers, hasLength(layers.length), reason: name);
      for (final (j, l) in layers.indexed) {
        expect(pose.layers[j].sprite.rows, l.rows, reason: '$name #$j');
        expect(pose.layers[j].argb, l.argb, reason: '$name #$j');
      }
    }
  });

  test('the idle loop matches boney-idle.gif, frame 0 being the front', () {
    final gif = decodeGif(File('$source/boney-idle.gif').readAsBytesSync());
    final front = BoneyPose.front.layers.single.sprite.rows;
    final frames = gridFrames(gif, front);
    expect(frames.map((f) => f.ms), [400, 400, 400, 800, 400]);
    for (final (i, f) in frames.indexed) {
      expect(boneyIdle[i].sprite.rows, f.rows, reason: 'frame $i');
      expect(boneyIdle[i].ms, f.ms);
    }
  });

  test('a GIF that is not the SVG front fails loudly', () {
    final front = [...BoneyPose.front.layers.single.sprite.rows];
    // Fill one eye socket.
    front[9] = front[9].replaceRange(11, 12, '#');
    final gif = decodeGif(File('$source/boney-idle.gif').readAsBytesSync());
    expect(() => gridFrames(gif, front), throwsFormatException);
  });
}

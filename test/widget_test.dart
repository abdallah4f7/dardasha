import 'package:chat/services/link_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects video links', () {
    expect(LinkPreview.youtubeId('https://youtu.be/dQw4w9WgXcQ?si=x'), 'dQw4w9WgXcQ');
    expect(LinkPreview.youtubeId('https://www.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(LinkPreview.youtubeId('https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(LinkPreview.kindOf('https://vm.tiktok.com/ZMabc/'), 'tiktok');
    expect(LinkPreview.tiktokId('https://www.tiktok.com/@user/video/7311111111111111111'), '7311111111111111111');
    expect(LinkPreview.kindOf('https://www.snapchat.com/spotlight/abc'), 'snapchat');
    expect(LinkPreview.firstUrl('شوف هذا https://youtu.be/dQw4w9WgXcQ 😂'), 'https://youtu.be/dQw4w9WgXcQ');
  });
}

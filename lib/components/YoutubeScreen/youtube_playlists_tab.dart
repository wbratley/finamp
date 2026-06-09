import 'package:flutter/material.dart';

import '../../models/finamp_models.dart';
import '../MusicScreen/music_screen_tab_view.dart';

class YoutubePlaylistsTab extends StatelessWidget {
  const YoutubePlaylistsTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MusicScreenTabView(
      tabContentType: TabContentType.playlists,
      isFavourite: false,
    );
  }
}

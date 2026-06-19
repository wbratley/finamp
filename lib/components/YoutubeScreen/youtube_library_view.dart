import 'package:flutter/material.dart';

import 'youtube_channels_tab.dart';
import 'youtube_videos_tab.dart';

class YoutubeLibraryView extends StatefulWidget {
  const YoutubeLibraryView({Key? key}) : super(key: key);

  @override
  State<YoutubeLibraryView> createState() => _YoutubeLibraryViewState();
}

class _YoutubeLibraryViewState extends State<YoutubeLibraryView>
    with TickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'CHANNELS'),
            Tab(text: 'VIDEOS'),
          ],
          isScrollable: true,
          tabAlignment: TabAlignment.start,
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              YoutubeChannelsTab(),
              YoutubeVideosTab(),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../components/AlbumScreen/song_list_tile.dart';
import '../components/error_snackbar.dart';
import '../components/now_playing_bar.dart';
import '../models/jellyfin_models.dart';
import '../services/finamp_user_helper.dart';
import '../services/jellyfin_api_helper.dart';

class YoutubeChannelScreenArguments {
  final String channelId;
  final String channelName;
  const YoutubeChannelScreenArguments({
    required this.channelId,
    required this.channelName,
  });
}

class YoutubeChannelScreen extends StatefulWidget {
  const YoutubeChannelScreen({Key? key}) : super(key: key);

  static const routeName = '/youtube/channel';

  @override
  State<YoutubeChannelScreen> createState() => _YoutubeChannelScreenState();
}

class _YoutubeChannelScreenState extends State<YoutubeChannelScreen> {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();

  bool _isLoading = true;
  List<BaseItemDto> _videos = [];

  late YoutubeChannelScreenArguments _args;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _args = ModalRoute.of(context)!.settings.arguments
        as YoutubeChannelScreenArguments;
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() => _isLoading = true);
    try {
      final all = await _jellyfinApiHelper.getItems(
        parentItem: _finampUserHelper.currentUser?.currentView,
        includeItemTypes: 'Video',
        sortBy: 'PremiereDate',
        sortOrder: 'Descending',
        isGenres: false,
        limit: 10000,
        startIndex: 0,
      );

      final filtered = (all ?? [])
          .where((v) => v.channelId == _args.channelId)
          .toList();

      setState(() {
        _isLoading = false;
        _videos = filtered;
      });
    } catch (e) {
      errorSnackbar(e, context);
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_args.channelName)),
      bottomNavigationBar: const NowPlayingBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : _videos.isEmpty
              ? const Center(child: Text('No videos found.'))
              : RefreshIndicator(
                  onRefresh: _loadVideos,
                  child: ListView.builder(
                    itemCount: _videos.length,
                    itemBuilder: (context, index) => SongListTile(
                      item: _videos[index],
                      isSong: true,
                    ),
                  ),
                ),
    );
  }
}

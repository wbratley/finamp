import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/jellyfin_models.dart';
import '../../screens/youtube_channel_screen.dart';
import '../../services/finamp_user_helper.dart';
import '../../services/jellyfin_api_helper.dart';
import '../album_image.dart';
import '../error_snackbar.dart';

class YoutubeChannelsTab extends StatefulWidget {
  const YoutubeChannelsTab({Key? key}) : super(key: key);

  @override
  State<YoutubeChannelsTab> createState() => _YoutubeChannelsTabState();
}

class _YoutubeChannelsTabState extends State<YoutubeChannelsTab>
    with AutomaticKeepAliveClientMixin {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();

  bool _isLoading = true;
  List<_ChannelEntry> _channels = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    setState(() => _isLoading = true);
    try {
      final videos = await _jellyfinApiHelper.getItems(
        parentItem: _finampUserHelper.currentUser?.currentView,
        includeItemTypes: 'Video',
        sortBy: 'SortName',
        sortOrder: 'Ascending',
        isGenres: false,
        limit: 10000,
        startIndex: 0,
      );

      if (videos == null || videos.isEmpty) {
        setState(() {
          _isLoading = false;
          _channels = [];
        });
        return;
      }

      // Derive unique channels; use the first video found as the thumbnail source
      final seen = <String>{};
      final channels = <_ChannelEntry>[];

      for (final video in videos) {
        final id = video.channelId ?? 'unknown';
        if (!seen.contains(id)) {
          seen.add(id);
          channels.add(_ChannelEntry(
            id: id,
            name: video.channelName ?? 'Unknown Channel',
            thumbnail: video,
          ));
        }
      }

      channels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      setState(() {
        _isLoading = false;
        _channels = channels;
      });
    } catch (e) {
      errorSnackbar(e, context);
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    if (_channels.isEmpty) {
      return const Center(child: Text('No channels found.'));
    }

    return RefreshIndicator(
      onRefresh: _loadChannels,
      child: ListView.separated(
        itemCount: _channels.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final channel = _channels[index];
          return ListTile(
            leading: AlbumImage(item: channel.thumbnail),
            title: Text(
              channel.name,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).pushNamed(
              YoutubeChannelScreen.routeName,
              arguments: YoutubeChannelScreenArguments(
                channelId: channel.id,
                channelName: channel.name,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChannelEntry {
  final String id;
  final String name;
  final BaseItemDto thumbnail;
  const _ChannelEntry({
    required this.id,
    required this.name,
    required this.thumbnail,
  });
}

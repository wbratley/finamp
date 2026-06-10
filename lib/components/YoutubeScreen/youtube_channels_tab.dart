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
  List<BaseItemDto> _channels = [];

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
      // Fetch only the direct child folders of the library root.
      // Pinchflat structure: Library/<Channel>/<Date Subfolder>/<video>
      // recursive: false gives us only the channel-level folders,
      // not the date subfolders nested inside them.
      final folders = await _jellyfinApiHelper.getItems(
        parentItem: _finampUserHelper.currentUser?.currentView,
        includeItemTypes: 'Folder',
        sortBy: 'SortName',
        sortOrder: 'Ascending',
        isGenres: false,
        recursive: false,
        limit: 10000,
        startIndex: 0,
      );

      setState(() {
        _isLoading = false;
        _channels = folders ?? [];
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
          final folder = _channels[index];
          return ListTile(
            leading: AlbumImage(item: folder),
            title: Text(
              folder.name ?? 'Unknown Channel',
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).pushNamed(
              YoutubeChannelScreen.routeName,
              arguments: YoutubeChannelScreenArguments(folder: folder),
            ),
          );
        },
      ),
    );
  }
}

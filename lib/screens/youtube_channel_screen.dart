import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../components/AlbumScreen/download_dialog.dart';
import '../components/AlbumScreen/song_list_tile.dart';
import '../components/confirmation_prompt_dialog.dart';
import '../components/error_snackbar.dart';
import '../components/now_playing_bar.dart';
import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import '../services/downloads_helper.dart';
import '../services/finamp_settings_helper.dart';
import '../services/finamp_user_helper.dart';
import '../services/jellyfin_api_helper.dart';

class YoutubeChannelScreenArguments {
  final BaseItemDto folder;
  const YoutubeChannelScreenArguments({required this.folder});
}

class YoutubeChannelScreen extends StatefulWidget {
  const YoutubeChannelScreen({Key? key}) : super(key: key);

  static const routeName = '/youtube/channel';

  @override
  State<YoutubeChannelScreen> createState() => _YoutubeChannelScreenState();
}

class _YoutubeChannelScreenState extends State<YoutubeChannelScreen> {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _downloadsHelper = GetIt.instance<DownloadsHelper>();
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
      // Fetch videos scoped to the channel folder directly — no filtering needed
      final videos = await _jellyfinApiHelper.getItems(
        parentItem: _args.folder,
        includeItemTypes: 'Video',
        sortBy: 'PremiereDate',
        sortOrder: 'Descending',
        isGenres: false,
        limit: 10000,
        startIndex: 0,
      );

      // Stamp channel name so SongListTile subtitle shows correctly
      final channelName = _args.folder.name;
      for (final video in videos ?? []) {
        video.channelName = channelName;
      }

      setState(() {
        _isLoading = false;
        _videos = videos ?? [];
      });
    } catch (e) {
      errorSnackbar(e, context);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _downloadChannel() async {
    final downloadLocation = await showDialog<DownloadLocation>(
      context: context,
      builder: (context) => DownloadDialog(
        parents: [_args.folder],
        items: [_videos],
        viewId: _finampUserHelper.currentUser!.currentViewId!,
      ),
    );

    if (downloadLocation == null || !mounted) return;

    await checkedAddDownloads(
      context,
      downloadLocation: downloadLocation,
      parents: [_args.folder],
      items: [_videos],
      viewId: _finampUserHelper.currentUser!.currentViewId!,
    );

    if (!mounted) return;
    setState(() {});
  }

  void _deleteChannelDownloads() {
    showDialog(
      context: context,
      builder: (context) => ConfirmationPromptDialog(
        promptText:
            'Are you sure you want to delete the downloaded videos for "${_args.folder.name}" from this device?',
        confirmButtonText: 'Delete',
        abortButtonText: 'Cancel',
        onConfirmed: () async {
          final downloadedParent =
              _downloadsHelper.getDownloadedParent(_args.folder.id);
          if (downloadedParent != null) {
            await _downloadsHelper.deleteParentAndChildDownloads(
              jellyfinItemIds:
                  downloadedParent.downloadedChildren.keys.toList(),
              deletedFor: _args.folder.id,
            );
          }
          if (!mounted) return;
          setState(() {});
        },
        onAborted: () {},
      ),
    );
  }

  Widget _buildDownloadButton() {
    if (FinampSettingsHelper.finampSettings.isOffline) {
      return const IconButton(
        icon: Icon(Icons.download),
        onPressed: null,
      );
    }

    final isDownloaded = _downloadsHelper.isAlbumDownloaded(_args.folder.id);

    return IconButton(
      tooltip: isDownloaded
          ? 'Delete downloaded videos'
          : 'Download all videos in this channel',
      icon: Icon(isDownloaded ? Icons.delete : Icons.download),
      onPressed: _videos.isEmpty
          ? null
          : () {
              if (isDownloaded) {
                _deleteChannelDownloads();
              } else {
                _downloadChannel();
              }
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_args.folder.name ?? 'Channel'),
        actions: [_buildDownloadButton()],
      ),
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

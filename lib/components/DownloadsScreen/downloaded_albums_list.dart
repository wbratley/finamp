import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/finamp_models.dart';
import '../../services/downloads_helper.dart';
import '../../models/jellyfin_models.dart';
import '../album_image.dart';
import '../confirmation_prompt_dialog.dart';
import 'item_media_source_info.dart';
import 'album_file_size.dart';

class DownloadedAlbumsList extends StatefulWidget {
  const DownloadedAlbumsList({Key? key}) : super(key: key);

  @override
  State<DownloadedAlbumsList> createState() => _DownloadedAlbumsListState();
}

class _DownloadedAlbumsListState extends State<DownloadedAlbumsList> {
  final DownloadsHelper downloadsHelper = GetIt.instance<DownloadsHelper>();

  final JellyfinApiHelper jellyfinApiHelper = JellyfinApiHelper();

  Future<void> deleteAlbum(
      BuildContext context, DownloadedParent downloadedParent) async {
    List<String> itemIds = [];
    for (BaseItemDto item in downloadedParent.downloadedChildren.values) {
      itemIds.add(item.id);
    }
    await downloadsHelper.deleteParentAndChildDownloads(
        jellyfinItemIds: itemIds, deletedFor: downloadedParent.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final Iterable<DownloadedParent> downloadedParents =
        downloadsHelper.downloadedParents;

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          DownloadedParent album = downloadedParents.elementAt(index);

          final deleteButton = IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => showDialog(
              context: context,
              builder: (context) => ConfirmationPromptDialog(
                promptText: AppLocalizations.of(context)!.deleteDownloadsPrompt(
                    album.item.name ?? "",
                    album.item.type == "Playlist" ? "playlist" : "album"),
                confirmButtonText: AppLocalizations.of(context)!
                    .deleteDownloadsConfirmButtonText,
                abortButtonText: AppLocalizations.of(context)!
                    .deleteDownloadsAbortButtonText,
                onConfirmed: () async {
                  await deleteAlbum(context, album);
                  setState(() {});
                },
                onAborted: () {},
              ),
            ),
          );

          // Items downloaded on their own (e.g. individual videos/songs, not
          // as part of an album or playlist) are stored as a DownloadedParent
          // whose only child is the item itself. Rendering those as an
          // ExpansionTile just reveals the same item again as a "child", so
          // show them as a flat row instead. This also covers downloads that
          // failed before any child was added, leaving an empty parent.
          final isStandaloneItem = album.downloadedChildren.isEmpty ||
              (album.downloadedChildren.length == 1 &&
                  album.downloadedChildren.containsKey(album.item.id));

          if (isStandaloneItem) {
            return ListTile(
              key: PageStorageKey(album.item.id),
              leading: AlbumImage(item: album.item),
              title: Text(album.item.name ?? "Unknown Name"),
              subtitle: album.downloadedChildren.isEmpty
                  ? const Text("Download failed")
                  : ItemMediaSourceInfo(songId: album.item.id),
              trailing: deleteButton,
            );
          }

          return ExpansionTile(
            key: PageStorageKey(album.item.id),
            leading: AlbumImage(item: album.item),
            title: Text(album.item.name ?? "Unknown Name"),
            trailing: deleteButton,
            subtitle: AlbumFileSize(
              downloadedParent: album,
            ),
            children: [
              DownloadedSongsInAlbumList(
                children: album.downloadedChildren.values,
                parent: album,
              )
            ],
          );
        },
        childCount: downloadedParents.length,
      ),
    );
  }
}

class DownloadedSongsInAlbumList extends StatefulWidget {
  const DownloadedSongsInAlbumList(
      {Key? key, required this.children, required this.parent})
      : super(key: key);

  final Iterable<BaseItemDto> children;
  final DownloadedParent parent;

  @override
  State<DownloadedSongsInAlbumList> createState() =>
      _DownloadedSongsInAlbumListState();
}

class _DownloadedSongsInAlbumListState
    extends State<DownloadedSongsInAlbumList> {
  final DownloadsHelper downloadsHelper = GetIt.instance<DownloadsHelper>();

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      //TODO use a list builder here
      for (final song in widget.children)
        ListTile(
          title: Text(song.name ?? "Unknown Name"),
          leading: AlbumImage(item: song),
          trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => showDialog(
                context: context,
                builder: (context) => ConfirmationPromptDialog(
                  promptText: AppLocalizations.of(context)!
                      .deleteDownloadsPrompt(
                          song.name ?? "",
                          "track"),
                  confirmButtonText: AppLocalizations.of(context)!
                      .deleteDownloadsConfirmButtonText,
                  abortButtonText: AppLocalizations.of(context)!
                      .deleteDownloadsAbortButtonText,
                  onConfirmed: () async {
                    await deleteSong(context, song);
                    setState(() {});
                  },
                  onAborted: () {},
                ),
              ),
          ),
          subtitle: ItemMediaSourceInfo(
            songId: song.id,
          ),
        )
    ]);
  }

  Future<void> deleteSong(BuildContext context, BaseItemDto itemDto) async {
    await downloadsHelper.removeChildFromParent(
      parentId: widget.parent.item.id,
      childIds: [itemDto.id],
    );
    await downloadsHelper.deleteSong(jellyfinItemId: itemDto.id);
  }
}

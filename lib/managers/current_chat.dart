import 'dart:async';
import 'dart:typed_data';

import 'package:assets_audio_player/assets_audio_player.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/layouts/conversation_view/conversation_view.dart';
import 'package:bluebubbles/layouts/widgets/message_widget/message_details_popup.dart';
import 'package:bluebubbles/managers/attachment_info_bloc.dart';
import 'package:bluebubbles/managers/new_message_manager.dart';
import 'package:bluebubbles/repository/models/attachment.dart';
import 'package:bluebubbles/repository/models/chat.dart';
import 'package:bluebubbles/repository/models/message.dart';
import 'package:flutter/material.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:video_player/video_player.dart';

/// Holds cached metadata for the currently opened chat
///
/// This allows us to get around passing data through the trees and we can just store it here
class CurrentChat {
  StreamController _stream = StreamController.broadcast();

  Stream get stream => _stream.stream;

  StreamController<Map<String, List<Attachment>>> _attachmentStream =
      StreamController.broadcast();

  Stream get attachmentStream => _attachmentStream.stream;

  Chat chat;
  Message myLastMessage;
  Message lastReadMessage;

  Map<String, Uint8List> imageData = {};
  Map<String, Metadata> urlPreviews = {};
  Map<String, VideoPlayerController> currentPlayingVideo = {};
  Map<String, AssetsAudioPlayer> audioPlayers = {};
  List<VideoPlayerController> videoControllersToDispose = [];
  List<Attachment> chatAttachments = [];
  List<Message> sentMessages = [];
  // bool showTypingIndicator = false;
  // Timer indicatorHideTimer;
  OverlayEntry entry;

  bool isAlive = false;

  Map<String, List<Attachment>> messageAttachments = {};

  double _timeStampOffset = 0.0;

  StreamController<double> timeStampOffsetStream =
      StreamController<double>.broadcast();

  StreamController<Map<String, Message>> messageMarkerStream =
      StreamController<Map<String, Message>>.broadcast();

  double get timeStampOffset => _timeStampOffset;
  set timeStampOffset(double value) {
    if (_timeStampOffset == value) return;
    _timeStampOffset = value;
    if (!timeStampOffsetStream.isClosed)
      timeStampOffsetStream.sink.add(_timeStampOffset);
  }

  CurrentChat(this.chat) {
    NewMessageManager().stream.listen((msgEvent) {
      if (messageMarkerStream.isClosed) return;

      // Ignore any events that don't have to do with the current chat
      if (msgEvent?.chatGuid != chat?.guid) return;

      // If it's the event we want
      if (msgEvent.type == NewMessageType.UPDATE ||
          msgEvent.type == NewMessageType.ADD) {
        tryUpdateMessageMarkers(msgEvent.event["message"]);
      }

      if (messageMarkerStream.isClosed) {
        messageMarkerStream.sink.add({
          "myLastMessage": this.myLastMessage,
          "lastReadMessage": this.lastReadMessage
        });
      }
    });
  }

  factory CurrentChat.getCurrentChat(Chat chat) {
    if (chat == null) return null;

    CurrentChat currentChat = AttachmentInfoBloc().getCurrentChat(chat.guid);
    if (currentChat == null) {
      currentChat = CurrentChat(chat);
      AttachmentInfoBloc().addCurrentChat(currentChat);
    }

    return currentChat;
  }

  static bool isActive(String chatGuid) =>
      AttachmentInfoBloc().getCurrentChat(chatGuid)?.isAlive ?? false;

  static CurrentChat get activeChat {
    if (AttachmentInfoBloc().chatData.isNotEmpty) {
      var res = AttachmentInfoBloc()
          .chatData
          .values
          .where((element) => element.isAlive);

      if (res.isNotEmpty) return res.first;

      return null;
    } else {
      return null;
    }
  }

  /// Initialize all the values for the currently open chat
  /// @param [chat] the chat object you are initializing for
  void init() {
    dispose();

    imageData = {};
    currentPlayingVideo = {};
    audioPlayers = {};
    urlPreviews = {};
    videoControllersToDispose = [];
    chatAttachments = [];
    sentMessages = [];
    entry = null;
    isAlive = true;
    _timeStampOffset = 0;
    timeStampOffsetStream = StreamController<double>.broadcast();
    // showTypingIndicator = false;
    // indicatorHideTimer = null;
    // checkTypingIndicator();
  }

  static CurrentChat of(BuildContext context) {
    if (context == null) return null;

    return context
            .findAncestorStateOfType<ConversationViewState>()
            ?.currentChat ??
        context
            .findAncestorStateOfType<MessageDetailsPopupState>()
            ?.currentChat ??
        null;
  }

  /// Fetch and store all of the attachments for a [message]
  /// @param [message] the message you want to fetch for
  List<Attachment> getAttachmentsForMessage(Message message) {
    // If we have already disposed, do nothing
    if (chat == null) return [];
    if (!messageAttachments.containsKey(message.guid)) {
      preloadMessageAttachments(specificMessages: [message]).then(
        (value) => _attachmentStream.sink.add(
          {message.guid: messageAttachments[message.guid]},
        ),
      );
      return [];
    }
    return messageAttachments[message.guid];
  }

  List<Attachment> updateExistingAttachments(NewMessageEvent event) {
    if (event.type != NewMessageType.UPDATE) return null;
    String oldGuid = event.event["oldGuid"];
    if (!messageAttachments.containsKey(oldGuid)) return [];
    Message message = event.event["message"];
    if (message.attachments.isEmpty) return [];

    messageAttachments.remove(oldGuid);
    messageAttachments[message.guid] = message.attachments;

    String newAttachmentGuid = message.attachments.first.guid;
    if (imageData.containsKey(oldGuid)) {
      Uint8List data = imageData.remove(oldGuid);
      imageData[newAttachmentGuid] = data;
    } else if (currentPlayingVideo.containsKey(oldGuid)) {
      VideoPlayerController data = currentPlayingVideo.remove(oldGuid);
      currentPlayingVideo[newAttachmentGuid] = data;
    } else if (audioPlayers.containsKey(oldGuid)) {
      AssetsAudioPlayer data = audioPlayers.remove(oldGuid);
      audioPlayers[newAttachmentGuid] = data;
    } else if (urlPreviews.containsKey(oldGuid)) {
      Metadata data = urlPreviews.remove(oldGuid);
      urlPreviews[newAttachmentGuid] = data;
    }
    return message.attachments;
  }

  Uint8List getImageData(Attachment attachment) {
    if (!imageData.containsKey(attachment.guid)) return null;
    return imageData[attachment.guid];
  }

  void saveImageData(Uint8List data, Attachment attachment) {
    imageData[attachment.guid] = data;
  }

  void clearImageData(Attachment attachment) {
    if (!imageData.containsKey(attachment.guid)) return;
    imageData.remove(attachment.guid);
  }

  Future<void> preloadMessageAttachments(
      {List<Message> specificMessages}) async {
    assert(chat != null);
    List<Message> messages = specificMessages != null
        ? specificMessages
        : await Chat.getMessagesSingleton(chat, limit: 25);
    for (Message message in messages) {
      if (message.hasAttachments) {
        List<Attachment> attachments = await message.fetchAttachments();
        messageAttachments[message.guid] = attachments;
      }
    }
  }

  // void checkTypingIndicator() {
  //   if (chat == null) return;
  //   SocketManager().sendMessage("get-typing-indicator", {"guid": chat.guid},
  //       (data) {
  //     if (data['status'] == 200) {
  //       if (data['data']['isTyping']) {
  //         displayTypingIndicator();
  //       } else {
  //         hideTypingIndicator();
  //       }
  //     } else {
  //       hideTypingIndicator();
  //     }
  //   });
  // }

  // void displayTypingIndicator() {
  //   showTypingIndicator = true;
  //   indicatorHideTimer = new Timer(Duration(seconds: 5), () {
  //     checkTypingIndicator();
  //   });
  //   _stream.sink.add(null);
  // }

  // void hideTypingIndicator() {
  //   indicatorHideTimer.cancel();
  //   indicatorHideTimer = null;
  //   showTypingIndicator = false;
  //   _stream.sink.add(null);
  // }

  /// Retreive all of the attachments associated with a chat
  Future<void> updateChatAttachments() async {
    chatAttachments = await Chat.getAttachments(chat);
  }

  void changeCurrentPlayingVideo(Map<String, VideoPlayerController> video) {
    if (!isNullOrEmpty(currentPlayingVideo)) {
      currentPlayingVideo.values.forEach((element) {
        videoControllersToDispose.add(element);
        element = null;
      });
    }
    currentPlayingVideo = video;
    _stream.sink.add(null);
  }

  void tryUpdateMessageMarkers(Message msg) {
    if (!msg.isFromMe) return;

    if (myLastMessage == null ||
        (myLastMessage?.dateCreated != null &&
            msg.dateCreated != null &&
            msg.dateCreated.millisecondsSinceEpoch >
                myLastMessage.dateCreated.millisecondsSinceEpoch)) {
      myLastMessage = msg;
    }

    if ((lastReadMessage == null && msg.dateRead != null) ||
        (lastReadMessage?.dateRead != null &&
            msg.dateRead != null &&
            msg.dateRead.millisecondsSinceEpoch >
                lastReadMessage.dateRead.millisecondsSinceEpoch)) {
      lastReadMessage = msg;
    }
  }

  /// Dispose all of the controllers and whatnot
  void dispose() {
    if (!isNullOrEmpty(currentPlayingVideo)) {
      currentPlayingVideo.values.forEach((element) {
        element.dispose();
      });
    }

    if (!isNullOrEmpty(audioPlayers)) {
      audioPlayers.values.forEach((element) {
        element.dispose();
      });
    }

    if (!timeStampOffsetStream.isClosed) timeStampOffsetStream.close();
    if (!messageMarkerStream.isClosed) messageMarkerStream.close();

    _timeStampOffset = 0;
    imageData = {};
    currentPlayingVideo = {};
    audioPlayers = {};
    urlPreviews = {};
    videoControllersToDispose = [];
    audioPlayers.forEach((key, value) async {
      await value?.dispose();
      audioPlayers.remove(key);
    });
    chatAttachments = [];
    sentMessages = [];
    isAlive = false;
    // showTypingIndicator = false;
    if (entry != null) entry.remove();
  }

  /// Dipose of the controllers which we no longer need
  void disposeControllers() {
    disposeVideoControllers();
    disposeAudioControllers();
  }

  void disposeVideoControllers() {
    videoControllersToDispose.forEach((element) {
      element.dispose();
    });
    videoControllersToDispose = [];
  }

  void disposeAudioControllers() {
    audioPlayers.forEach((guid, player) {
      player.dispose();
    });
    audioPlayers = {};
  }
}

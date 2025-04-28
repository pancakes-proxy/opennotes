// main.dart
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const OpenNotesApp());
}

class OpenNotesApp extends StatefulWidget {
  const OpenNotesApp({Key? key}) : super(key: key);

  @override
  State<OpenNotesApp> createState() => _OpenNotesAppState();
}

class _OpenNotesAppState extends State<OpenNotesApp> {
  List<String> _notes = [];
  bool _isLightTheme = true;
  bool _isSyncEnabled = false;
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  // Keys for persistence.
  final String _notesKey = 'notes';
  final String _themeKey = 'isLightTheme';
  final String _syncKey = 'syncEnabled';

  SyncService? _syncService;

  @override
  void initState() {
    super.initState();
    _loadNotesAndSettings();
  }

  Future<void> _loadNotesAndSettings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _notes = prefs.getStringList(_notesKey) ?? [];
      _isLightTheme = prefs.getBool(_themeKey) ?? true;
      _isSyncEnabled = prefs.getBool(_syncKey) ?? false;
    });
    if (_isSyncEnabled) {
      _startSync();
    }
  }

  Future<void> _saveNotes() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_notesKey, _notes);
  }

  Future<void> _saveTheme() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, _isLightTheme);
  }

  Future<void> _saveSyncPref() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncKey, _isSyncEnabled);
  }

  // Called when the sync service receives a note list from a peer.
  void _handleSyncReceived(List<String> mergedNotes) {
    // Merge with local notes (using a union to avoid duplicates).
    final currentSet = Set<String>.from(_notes);
    final mergedSet = Set<String>.from(mergedNotes);
    if (!setEquals(currentSet, mergedSet)) {
      setState(() {
        _notes = mergedSet.toList();
      });
      _saveNotes();
    }
  }

  // Start the sync service.
  Future<void> _startSync() async {
    if (_syncService != null) return;
    _syncService = SyncService(
      getLocalNotes: () => _notes,
      onSyncReceived: _handleSyncReceived,
    );
    await _syncService!.startService();
  }

  // Stop the sync service.
  Future<void> _stopSync() async {
    await _syncService?.stopService();
    _syncService = null;
  }

  // Opens the full-screen note editor. If [index] is null, a new note is created.
  void _addOrEditNote({int? index}) async {
    String initialText = index == null ? '' : _notes[index];
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NoteEditor(
          noteText: initialText,
          isEditing: index != null,
        ),
      ),
    );
    if (result != null && result is NoteEditorResult) {
      if (result.deleted && index != null) {
        _removeNote(index);
      } else if (result.noteText.trim().isNotEmpty) {
        setState(() {
          if (index == null) {
            _notes.insert(0, result.noteText.trim());
            _listKey.currentState?.insertItem(0);
          } else {
            _notes[index] = result.noteText.trim();
          }
        });
        _saveNotes();
      }
    }
  }

  // Remove a note with animation.
  void _removeNote(int index) {
    String removedNote = _notes.removeAt(index);
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _buildNoteCard(removedNote, animation, index),
      duration: const Duration(milliseconds: 300),
    );
    _saveNotes();
  }

  // Share a note via share_plus.
  void _shareNote(String noteText) {
    Share.share(noteText, subject: "My Note from OpenNotes");
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenNotes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        primarySwatch: Colors.blue,
        // Light mode: card with a slight black tint and shadow.
        cardColor: Colors.black.withOpacity(0.1),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        primarySwatch: Colors.blue,
        // Dark mode: card with a slight white tint.
        cardColor: Colors.white.withOpacity(0.1),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16),
        ),
      ),
      themeMode: _isLightTheme ? ThemeMode.light : ThemeMode.dark,
      home: Scaffold(
        appBar: AppBar(
          title: const Text("OpenNotes"),
          actions: [
            if (_notes.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _addOrEditNote(),
                tooltip: 'Add Note',
              ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettings,
              tooltip: 'Settings',
            ),
          ],
        ),
        body: _notes.isEmpty
            ? _buildEmptyState()
            : AnimatedList(
                key: _listKey,
                padding: const EdgeInsets.all(16),
                initialItemCount: _notes.length,
                itemBuilder: (context, index, animation) {
                  return _buildNoteCard(_notes[index], animation, index);
                },
              ),
        floatingActionButton: _notes.isEmpty
            ? FloatingActionButton(
                onPressed: () => _addOrEditNote(),
                tooltip: 'Add Note',
                child: const Icon(Icons.add),
              )
            : null,
      ),
    );
  }

  // Displayed when there are no notes.
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "No notes yet. Please add one!",
            style: TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => _addOrEditNote(),
            child: const Text("Add Note"),
          ),
        ],
      ),
    );
  }

  // Builds an animated card for each note with Markdown rendering (including embeds).
  Widget _buildNoteCard(
      String noteText, Animation<double> animation, int index) {
    final int elevation = _isLightTheme ? 4 : 0;
    return SizeTransition(
      sizeFactor: animation,
      child: Card(
        margin: const EdgeInsets.only(bottom: 16),
        elevation: elevation.toDouble(),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          onTap: () => _addOrEditNote(index: index),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          title: MarkdownBody(
            data: noteText,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
            // Add the embed custom syntax and builder.
            inlineSyntaxes: [EmbedSyntax()],
            builders: {'embed': EmbedBuilder()},
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.share),
                onPressed: () => _shareNote(noteText),
                tooltip: 'Share Note',
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => _removeNote(index),
                tooltip: 'Delete Note',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Shows the settings panel, including theme selection and sync toggle.
  void _showSettings() {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text("Theme:", style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 20),
                  DropdownButton<bool>(
                    value: _isLightTheme,
                    items: const [
                      DropdownMenuItem<bool>(
                        value: true,
                        child: Text("Light"),
                      ),
                      DropdownMenuItem<bool>(
                        value: false,
                        child: Text("Dark"),
                      ),
                    ],
                    onChanged: (bool? value) {
                      if (value != null) {
                        setState(() {
                          _isLightTheme = value;
                        });
                        _saveTheme();
                        Navigator.pop(context);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                      child: Text("Sync across network:",
                          style: TextStyle(fontSize: 16))),
                  Switch(
                    value: _isSyncEnabled,
                    onChanged: (bool value) async {
                      setState(() {
                        _isSyncEnabled = value;
                      });
                      await _saveSyncPref();
                      if (value) {
                        _startSync();
                      } else {
                        _stopSync();
                      }
                    },
                  )
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Helper to compare two sets.
bool setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  return a.difference(b).isEmpty;
}

/// -----------------------------------------------------------------
///
/// The SyncService starts a TCP server and UDP broadcaster to sync
/// notes across devices on the same network. It uses a simple JSON
/// protocol so that all connected OpenNotes apps exchange updated notes.
///
class SyncService {
  final List<String> Function() getLocalNotes;
  final Function(List<String> mergedNotes) onSyncReceived;
  bool _running = false;

  ServerSocket? _serverSocket;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;

  SyncService({
    required this.getLocalNotes,
    required this.onSyncReceived,
  });

  Future<void> startService() async {
    _running = true;

    // Start TCP server on port 4040.
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 4040);
    _serverSocket!.listen((Socket client) {
      final data = {'notes': getLocalNotes()};
      client.write(convert.jsonEncode(data));
      client.close();
    });

    // Bind a UDP socket for broadcast.
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4040);
    _udpSocket!.broadcastEnabled = true;
    _udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final datagram = _udpSocket!.receive();
        if (datagram != null) {
          final message = String.fromCharCodes(datagram.data);
          if (message.startsWith("OPENNOTES_SYNC")) {
            // Avoid connecting to self (loopback).
            if (datagram.address.address != InternetAddress.loopbackIPv4.address) {
              _connectToPeer(datagram.address, 4040);
            }
          }
        }
      }
    });

    // Every 5 seconds, broadcast our presence.
    _broadcastTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_running) {
        timer.cancel();
        return;
      }
      final data = "OPENNOTES_SYNC:4040";
      _udpSocket?.send(
          data.codeUnits, InternetAddress("255.255.255.255"), 4040);
    });
  }

  void _connectToPeer(InternetAddress address, int port) async {
    try {
      Socket socket =
          await Socket.connect(address, port, timeout: const Duration(seconds: 3));
      final StringBuffer buffer = StringBuffer();
      socket.listen((data) {
        buffer.write(String.fromCharCodes(data));
      }, onDone: () {
        try {
          final jsonData = convert.jsonDecode(buffer.toString());
          if (jsonData['notes'] is List) {
            List<dynamic> receivedNotes = jsonData['notes'];
            List<String> notesFromPeer =
                receivedNotes.map((e) => e.toString()).toList();
            List<String> currentNotes = getLocalNotes();
            List<String> merged = {...currentNotes, ...notesFromPeer}.toList();
            onSyncReceived(merged);
          }
        } catch (e) {
          // Parsing error: ignore
        }
        socket.destroy();
      });
    } catch (e) {
      // Connection error; ignore gracefully.
    }
  }

  Future<void> stopService() async {
    _running = false;
    _broadcastTimer?.cancel();
    await _serverSocket?.close();
    _udpSocket?.close();
  }
}

/// -----------------------------------------------------------------
///
/// Embed Support:
///
/// To support embeds, we define a custom inline syntax and builder
/// for our Markdown parser. When a note contains a tag of the form:
///
///   {{embed:https://example.com}}
///
/// It will be captured by [EmbedSyntax] and rendered using [EmbedBuilder].
///
class EmbedSyntax extends md.InlineSyntax {
  // Matches {{embed:some_url}}
  EmbedSyntax() : super(r'\{\{embed:([^\}]+)\}\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final url = match.group(1)?.trim() ?? '';
    final element = md.Element('embed', [md.Text(url)]);
    parser.addNode(element);
    return true;
  }
}

class EmbedBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final url = element.textContent;
    return GestureDetector(
      onTap: () async {
        final Uri uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blueAccent),
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Row(
          children: const [
            Icon(Icons.link, color: Colors.blueAccent),
            SizedBox(width: 8.0),
            Expanded(
              child: Text(
                // The URL will appear here.
                "",
                style: TextStyle(
                  color: Colors.blueAccent,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    // When building the embed, replace the text widget with the URL text.
    return Text(
      text.text,
      style: const TextStyle(
        color: Colors.blueAccent,
        decoration: TextDecoration.underline,
      ),
    );
  }
}

/// -----------------------------------------------------------------
///
/// Note Editor:
///
/// A full-screen note editor that supports both raw text entry (with
/// Unicode and Markdown) and a live Markdown preview. Users can embed
/// links using the special syntax shown above.
///
class NoteEditorResult {
  final String noteText;
  final bool deleted;
  NoteEditorResult({required this.noteText, this.deleted = false});
}

class NoteEditor extends StatefulWidget {
  final String noteText;
  final bool isEditing;
  const NoteEditor({Key? key, required this.noteText, this.isEditing = false})
      : super(key: key);

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.noteText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Confirm deletion with an AlertDialog.
  Future<bool> _confirmDeletion() async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text("Delete Note"),
              content:
                  const Text("Are you sure you want to delete this note?"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text("Delete"),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isEditing ? "Edit Note" : "New Note"),
          actions: [
            if (widget.isEditing)
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () async {
                  final bool confirmed = await _confirmDeletion();
                  if (confirmed) {
                    Navigator.pop(
                        context,
                        NoteEditorResult(
                          noteText: '',
                          deleted: true,
                        ));
                  }
                },
                tooltip: 'Delete Note',
              ),
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: () {
                Navigator.pop(
                    context,
                    NoteEditorResult(
                        noteText: _controller.text));
              },
              tooltip: 'Save Note',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: "Edit"),
              Tab(text: "Preview"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // Edit tab with a multi-line text field.
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(
                  hintText:
                      "Enter your note here (supports Markdown, Unicode & embeds)...",
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            // Preview tab that renders Markdown live (with embed support).
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, child) {
                  return Markdown(
                    data: value.text,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                    inlineSyntaxes: [EmbedSyntax()],
                    builders: {'embed': EmbedBuilder()},
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

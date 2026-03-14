import 'package:flutter/material.dart';

class LogPane extends StatefulWidget {
  const LogPane({
    required this.title,
    required this.lines,
    super.key,
  });

  final String title;
  final List<String> lines;

  @override
  State<LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<LogPane> {
  final ScrollController _scrollController = ScrollController();
  bool _pauseAutoScroll = false;

  @override
  void initState() {
    super.initState();
    if (!_pauseAutoScroll) {
      _scrollToBottom();
    }
  }

  @override
  void didUpdateWidget(covariant LogPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasNewLines = widget.lines.length > oldWidget.lines.length;
    if (hasNewLines && !_pauseAutoScroll) {
      _scrollToBottom();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final output = widget.lines.join('\n');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Checkbox(
                  value: _pauseAutoScroll,
                  onChanged: (value) {
                    setState(() {
                      _pauseAutoScroll = value ?? false;
                    });
                    if (!_pauseAutoScroll) {
                      _scrollToBottom();
                    }
                  },
                ),
                const Text('Pause auto-scroll'),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SelectableText(
                        output,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'Consolas',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

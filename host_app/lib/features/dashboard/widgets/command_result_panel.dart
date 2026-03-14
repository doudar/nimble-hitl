import 'package:flutter/material.dart';

class CommandResultPanel extends StatefulWidget {
  const CommandResultPanel({
    required this.results,
    super.key,
  });

  final List<String> results;

  @override
  State<CommandResultPanel> createState() => _CommandResultPanelState();
}

class _CommandResultPanelState extends State<CommandResultPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _pauseAutoScroll = false;

  @override
  void initState() {
    super.initState();
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(covariant CommandResultPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.results.length != oldWidget.results.length &&
        !_pauseAutoScroll) {
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
    final lines = widget.results.reversed.toList();
    final baseStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: 'Consolas');
    final passColor = Colors.green.shade700;
    final failColor = Theme.of(context).colorScheme.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: 140,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Command output stream',
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
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text.rich(
                        TextSpan(
                          children: lines.map((line) {
                            final Color? color;
                            if (line.contains('[PASS]')) {
                              color = passColor;
                            } else if (line.contains('[FAIL]')) {
                              color = failColor;
                            } else {
                              color = null;
                            }
                            return TextSpan(
                              text: '$line\n',
                              style: baseStyle?.copyWith(color: color),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

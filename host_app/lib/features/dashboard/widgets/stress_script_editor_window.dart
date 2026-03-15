import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/state/orchestrator_controller.dart';

class StressScriptEditorWindow extends StatefulWidget {
  const StressScriptEditorWindow({
    required this.controller,
    super.key,
  });

  final OrchestratorController controller;

  @override
  State<StressScriptEditorWindow> createState() =>
      _StressScriptEditorWindowState();
}

class _StressScriptEditorWindowState extends State<StressScriptEditorWindow> {
  static const double _nodeCardHeight = 84;
  static const double _nodeVerticalStep = 96;

  static const List<String> _commands = <String>[
    'wait',
    'handshake',
    'configureServer',
    'configureAdvertising',
    'startAdvertising',
    'stopAdvertising',
    'configureClient',
    'connectPeer',
    'discoverAttributes',
    'writeCharacteristic',
    'readCharacteristic',
    'subscribeCharacteristic',
    'notifyCharacteristic',
    'pollTelemetry',
    'captureDiagnostics',
    'setMtu',
    'setSecurity',
    'swapRole',
    'disconnectPeer',
  ];

  static const List<String> _targets = <String>['first', 'second', 'each'];
  static const List<String> _expectDevices = <String>[
    'same',
    'other',
    'first',
    'second',
    'all',
  ];
  static const List<String> _expectKinds = <String>[
    'none',
    'response',
    'event',
    'log',
    'telemetry',
  ];

  bool _busy = false;
  String _description = 'Stress script editor document';
  String _status = 'Ready';

  int _selectedId = -1;
  int _nextId = 1;

  List<_EditorNode> _firstTree = <_EditorNode>[];
  List<_EditorNode> _secondTree = <_EditorNode>[];

  @override
  void initState() {
    super.initState();
    _loadFromDisk();
  }

  List<_EditorNode> get _allNodes => <_EditorNode>[..._firstTree, ..._secondTree];

  _EditorNode? get _selectedNode {
    for (final node in _allNodes) {
      if (node.id == _selectedId) {
        return node;
      }
    }
    return null;
  }

  Future<void> _loadFromDisk() async {
    setState(() {
      _busy = true;
      _status = 'Loading stress script...';
    });

    try {
      final document = await widget.controller.loadStressScriptDocument();
      final description = (document['description'] ?? 'Stress script editor document').toString();

      final editor = document['editor'];
      List<_EditorNode> first;
      List<_EditorNode> second;

      if (editor is Map<String, dynamic> &&
          editor['firstTree'] is List &&
          editor['secondTree'] is List) {
        first = (editor['firstTree'] as List)
            .whereType<Map>()
            .map((raw) => _EditorNode.fromEditorJson(
                  Map<String, dynamic>.from(raw),
                ))
            .toList();
        second = (editor['secondTree'] as List)
            .whereType<Map>()
            .map((raw) => _EditorNode.fromEditorJson(
                  Map<String, dynamic>.from(raw),
                ))
            .toList();
      } else {
        final steps = (document['steps'] as List?) ?? const <dynamic>[];
        first = <_EditorNode>[];
        second = <_EditorNode>[];
        for (final raw in steps.whereType<Map>()) {
          final step = Map<String, dynamic>.from(raw);
          final node = _EditorNode.fromStressStep(step);
          if (node.target == 'second') {
            second.add(node);
          } else {
            first.add(node);
          }
        }
      }

      final normalized = _normalizeNodeIds(first, second);
      first = normalized.first;
      second = normalized.second;

      var maxId = 0;
      for (final node in <_EditorNode>[...first, ...second]) {
        if (node.id > maxId) {
          maxId = node.id;
        }
      }

      setState(() {
        _description = description;
        _firstTree = first;
        _secondTree = second;
        _nextId = maxId + 1;
        _selectedId = _allNodes.isEmpty ? -1 : _allNodes.first.id;
        _status = 'Loaded ${_allNodes.length} node(s).';
      });
    } catch (error) {
      setState(() {
        _status = 'Load failed: $error';
      });
      _showMessage('Failed to load stress script: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  ({List<_EditorNode> first, List<_EditorNode> second}) _normalizeNodeIds(
    List<_EditorNode> first,
    List<_EditorNode> second,
  ) {
    final idMap = <int, int>{};
    var nextId = 1;

    int allocate() {
      final id = nextId;
      nextId += 1;
      return id;
    }

    _EditorNode remapId(_EditorNode node) {
      final newId = allocate();
      idMap[node.id] = newId;
      return node.copyWith(id: newId);
    }

    final remappedFirst = first.map(remapId).toList();
    final remappedSecond = second.map(remapId).toList();

    int? resolveRef(int? ref) {
      if (ref == null) {
        return null;
      }
      return idMap[ref];
    }

    final normalizedFirst = remappedFirst
        .map(
          (node) => node.copyWith(
            communicationTargetId: resolveRef(node.communicationTargetId),
            onPassId: resolveRef(node.onPassId),
            onFailId: resolveRef(node.onFailId),
          ),
        )
        .toList();
    final normalizedSecond = remappedSecond
        .map(
          (node) => node.copyWith(
            communicationTargetId: resolveRef(node.communicationTargetId),
            onPassId: resolveRef(node.onPassId),
            onFailId: resolveRef(node.onFailId),
          ),
        )
        .toList();

    return (first: normalizedFirst, second: normalizedSecond);
  }

  Future<void> _saveToDisk() async {
    setState(() {
      _busy = true;
      _status = 'Saving stress script...';
    });

    try {
      final document = <String, dynamic>{
        'description': _description,
        'steps': _buildRuntimeSteps(),
        'editor': <String, dynamic>{
          'firstTree': _firstTree.map((node) => node.toEditorJson()).toList(),
          'secondTree': _secondTree.map((node) => node.toEditorJson()).toList(),
        },
      };

      await widget.controller.saveStressScriptDocument(document);
      setState(() {
        _status = 'Saved to ${widget.controller.stressScriptFilePath}';
      });
      _showMessage('Stress script saved.');
    } catch (error) {
      setState(() {
        _status = 'Save failed: $error';
      });
      _showMessage('Failed to save stress script: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _buildRuntimeSteps() {
    final steps = <Map<String, dynamic>>[];
    final maxCount = _firstTree.length > _secondTree.length
        ? _firstTree.length
        : _secondTree.length;

    for (var index = 0; index < maxCount; index += 1) {
      if (index < _firstTree.length) {
        steps.add(_firstTree[index].toStressStepJson());
      }
      if (index < _secondTree.length) {
        steps.add(_secondTree[index].toStressStepJson());
      }
    }

    return steps;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _addNode(String target) {
    final node = _EditorNode(
      id: _nextId,
      name: 'New step $_nextId',
      command: 'handshake',
      target: target,
      payloadJson: '{}',
      expectDevice: 'same',
      expectKind: 'response',
      expectType: 'handshake',
      messageContains: '',
      payloadContainsJson: '{}',
      timeoutMs: 3000,
      repeat: 1,
      delayMs: 80,
    );

    setState(() {
      _nextId += 1;
      if (target == 'second') {
        _secondTree = <_EditorNode>[..._secondTree, node];
      } else {
        _firstTree = <_EditorNode>[..._firstTree, node];
      }
      _selectedId = node.id;
    });
  }

  void _addWaitNode(String target) {
    final node = _EditorNode(
      id: _nextId,
      name: 'Wait $_nextId',
      command: 'wait',
      target: target,
      payloadJson: '{}',
      expectDevice: 'other',
      expectKind: 'none',
      expectType: '',
      messageContains: '',
      payloadContainsJson: '{}',
      timeoutMs: 3000,
      repeat: 1,
      delayMs: 500,
    );

    setState(() {
      _nextId += 1;
      if (target == 'second') {
        _secondTree = <_EditorNode>[..._secondTree, node];
      } else {
        _firstTree = <_EditorNode>[..._firstTree, node];
      }
      _selectedId = node.id;
    });
  }

  void _duplicateNode(_EditorNode source) {
    final clone = source.copyWith(
      id: _nextId,
      name: '${source.name} copy',
      communicationTargetId: null,
      onPassId: null,
      onFailId: null,
    );
    setState(() {
      _nextId += 1;
      if (clone.target == 'second') {
        _secondTree = <_EditorNode>[..._secondTree, clone];
      } else {
        _firstTree = <_EditorNode>[..._firstTree, clone];
      }
      _selectedId = clone.id;
    });
  }

  void _deleteNode(int id) {
    setState(() {
      _firstTree = _firstTree.where((node) => node.id != id).toList();
      _secondTree = _secondTree.where((node) => node.id != id).toList();

      _firstTree = _firstTree
          .map((node) => node.copyWith(
                communicationTargetId:
                    node.communicationTargetId == id ? null : node.communicationTargetId,
                onPassId: node.onPassId == id ? null : node.onPassId,
                onFailId: node.onFailId == id ? null : node.onFailId,
              ))
          .toList();
      _secondTree = _secondTree
          .map((node) => node.copyWith(
                communicationTargetId:
                    node.communicationTargetId == id ? null : node.communicationTargetId,
                onPassId: node.onPassId == id ? null : node.onPassId,
                onFailId: node.onFailId == id ? null : node.onFailId,
              ))
          .toList();

      if (_selectedId == id) {
        _selectedId = _allNodes.isEmpty ? -1 : _allNodes.first.id;
      }
    });
  }

  void _moveNode(String tree, int fromIndex, int toIndex) {
    setState(() {
      final list = tree == 'first' ? _firstTree.toList() : _secondTree.toList();
      if (fromIndex < 0 || fromIndex >= list.length) {
        return;
      }

      var targetIndex = toIndex;
      if (targetIndex < 0) {
        targetIndex = 0;
      }
      if (targetIndex > list.length) {
        targetIndex = list.length;
      }
      if (targetIndex > fromIndex) {
        targetIndex -= 1;
      }

      final item = list.removeAt(fromIndex);
      if (targetIndex < 0) {
        targetIndex = 0;
      }
      if (targetIndex > list.length) {
        targetIndex = list.length;
      }
      list.insert(targetIndex, item);

      if (tree == 'first') {
        _firstTree = list;
      } else {
        _secondTree = list;
      }
    });
  }

  void _updateSelected(_EditorNode Function(_EditorNode node) updater) {
    final selected = _selectedNode;
    if (selected == null) {
      return;
    }

    final updated = updater(selected);
    setState(() {
      _firstTree = _firstTree
          .map((node) => node.id == updated.id ? updated : node)
          .toList();
      _secondTree = _secondTree
          .map((node) => node.id == updated.id ? updated : node)
          .toList();
    });
  }

  List<DropdownMenuItem<int?>> _nodeDropdownItems({
    required bool includeNone,
    required bool oppositeUnitOnly,
  }) {
    final selected = _selectedNode;
    final baseNodes = oppositeUnitOnly && selected != null
        ? _allNodes.where((node) => node.target != selected.target).toList()
        : _allNodes;

    final items = <DropdownMenuItem<int?>>[];
    if (includeNone) {
      items.add(const DropdownMenuItem<int?>(value: null, child: Text('None')));
    }
    for (final node in baseNodes) {
      items.add(
        DropdownMenuItem<int?>(
          value: node.id,
          child: Text('${node.name} (#${node.id})'),
        ),
      );
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedNode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stress Script Editor'),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _loadFromDisk,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Load from disk',
          ),
          IconButton(
            onPressed: _busy ? null : _saveToDisk,
            icon: const Icon(Icons.save),
            tooltip: 'Save to disk',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            tooltip: 'Close editor',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.controller.stressScriptFilePath,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(_status),
                ],
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 420,
                  child: _buildInspector(selected),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _buildGraphArea(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspector(_EditorNode? selected) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _addNode('first'),
                icon: const Icon(Icons.add),
                label: const Text('Add Step A'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _addNode('second'),
                icon: const Icon(Icons.add),
                label: const Text('Add Step B'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _addWaitNode('first'),
                icon: const Icon(Icons.schedule),
                label: const Text('Add Wait A'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _addWaitNode('second'),
                icon: const Icon(Icons.schedule),
                label: const Text('Add Wait B'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: _description,
            decoration: const InputDecoration(labelText: 'Script description'),
            onFieldSubmitted: (value) {
              setState(() {
                _description = value;
              });
            },
          ),
          const SizedBox(height: 16),
          if (selected == null)
            const Expanded(
              child: Center(
                child: Text('Select a node to edit its menus and decision links.'),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Node #${selected.id}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: selected.name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      onFieldSubmitted: (value) {
                        _updateSelected((node) => node.copyWith(name: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selected.command,
                      decoration: const InputDecoration(labelText: 'Command'),
                      items: _commands
                          .map((command) => DropdownMenuItem<String>(
                                value: command,
                                child: Text(command),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _updateSelected((node) => node.copyWith(command: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selected.target,
                      decoration: const InputDecoration(labelText: 'Target unit'),
                      items: _targets
                          .map((target) => DropdownMenuItem<String>(
                                value: target,
                                child: Text(target),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _updateSelected((node) => node.copyWith(target: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextFormField(
                            initialValue: '${selected.repeat}',
                            decoration: const InputDecoration(labelText: 'Repeat'),
                            keyboardType: TextInputType.number,
                            onFieldSubmitted: (value) {
                              final parsed = int.tryParse(value) ?? selected.repeat;
                              _updateSelected(
                                (node) => node.copyWith(repeat: parsed < 1 ? 1 : parsed),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: '${selected.delayMs}',
                            decoration: const InputDecoration(labelText: 'Delay ms'),
                            keyboardType: TextInputType.number,
                            onFieldSubmitted: (value) {
                              final parsed = int.tryParse(value) ?? selected.delayMs;
                              _updateSelected(
                                (node) => node.copyWith(delayMs: parsed < 0 ? 0 : parsed),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selected.expectKind,
                      decoration: const InputDecoration(labelText: 'Expect kind'),
                      items: _expectKinds
                          .map((kind) => DropdownMenuItem<String>(
                                value: kind,
                                child: Text(kind),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _updateSelected((node) => node.copyWith(expectKind: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selected.expectDevice,
                      decoration: const InputDecoration(labelText: 'Expect device'),
                      items: _expectDevices
                          .map((device) => DropdownMenuItem<String>(
                                value: device,
                                child: Text(device),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        _updateSelected((node) => node.copyWith(expectDevice: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: selected.expectType,
                      decoration:
                          const InputDecoration(labelText: 'Expect type'),
                      onFieldSubmitted: (value) {
                        _updateSelected((node) => node.copyWith(expectType: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: selected.messageContains,
                      decoration: const InputDecoration(
                        labelText: 'Message contains',
                      ),
                      onFieldSubmitted: (value) {
                        _updateSelected((node) => node.copyWith(messageContains: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: '${selected.timeoutMs}',
                      decoration:
                          const InputDecoration(labelText: 'Expect timeout ms'),
                      keyboardType: TextInputType.number,
                      onFieldSubmitted: (value) {
                        final parsed = int.tryParse(value) ?? selected.timeoutMs;
                        _updateSelected(
                          (node) => node.copyWith(timeoutMs: parsed < 100 ? 100 : parsed),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: selected.payloadContainsJson,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Expect payload contains JSON',
                        alignLabelWithHint: true,
                      ),
                      onFieldSubmitted: (value) {
                        _updateSelected(
                          (node) => node.copyWith(payloadContainsJson: value),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int?>(
                      initialValue: selected.communicationTargetId,
                      decoration: const InputDecoration(
                          labelText: 'Communicates with (cross-unit arrow)'),
                      items: _nodeDropdownItems(
                        includeNone: true,
                        oppositeUnitOnly: true,
                      ),
                      onChanged: (value) {
                        _updateSelected(
                          (node) => node.copyWith(communicationTargetId: value),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int?>(
                      initialValue: selected.onPassId,
                      decoration:
                          const InputDecoration(labelText: 'On pass goto'),
                      items: _nodeDropdownItems(
                        includeNone: true,
                        oppositeUnitOnly: false,
                      ),
                      onChanged: (value) {
                        _updateSelected((node) => node.copyWith(onPassId: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int?>(
                      initialValue: selected.onFailId,
                      decoration:
                          const InputDecoration(labelText: 'On fail goto'),
                      items: _nodeDropdownItems(
                        includeNone: true,
                        oppositeUnitOnly: false,
                      ),
                      onChanged: (value) {
                        _updateSelected((node) => node.copyWith(onFailId: value));
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: selected.payloadJson,
                      minLines: 4,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Payload JSON',
                        alignLabelWithHint: true,
                      ),
                      onFieldSubmitted: (value) {
                        _updateSelected((node) => node.copyWith(payloadJson: value));
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: () => _duplicateNode(selected),
                          icon: const Icon(Icons.copy),
                          label: const Text('Duplicate'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _deleteNode(selected.id),
                          icon: const Icon(Icons.delete),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGraphArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final leftX = constraints.maxWidth * 0.25;
        final rightX = constraints.maxWidth * 0.75;

        final positions = <int, Offset>{};
        const baseY = 88.0;
        for (var i = 0; i < _firstTree.length; i += 1) {
          positions[_firstTree[i].id] =
              Offset(leftX, baseY + i * _nodeVerticalStep);
        }
        for (var i = 0; i < _secondTree.length; i += 1) {
          positions[_secondTree[i].id] =
              Offset(rightX, baseY + i * _nodeVerticalStep);
        }

        return Stack(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _buildTreeCard(
                    tree: 'first',
                    title: 'Unit A Tree',
                    nodes: _firstTree,
                  ),
                ),
                Expanded(
                  child: _buildTreeCard(
                    tree: 'second',
                    title: 'Unit B Tree',
                    nodes: _secondTree,
                  ),
                ),
              ],
            ),
            IgnorePointer(
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _LinkPainter(
                  nodes: _allNodes,
                  positions: positions,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTreeCard({
    required String tree,
    required String title,
    required List<_EditorNode> nodes,
  }) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        child: Column(
          children: <Widget>[
            ListTile(
              title: Text(title),
              subtitle: Text('${nodes.length} node(s)'),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: <Widget>[
                  for (var index = 0; index < nodes.length; index += 1) ...<Widget>[
                    _buildDropZone(tree: tree, insertIndex: index),
                    _buildDraggableNodeCard(
                      tree: tree,
                      node: nodes[index],
                      index: index,
                    ),
                  ],
                  _buildDropZone(tree: tree, insertIndex: nodes.length),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropZone({
    required String tree,
    required int insertIndex,
  }) {
    return DragTarget<_DraggedNode>(
      onWillAcceptWithDetails: (details) => details.data.tree == tree,
      onAcceptWithDetails: (details) {
        _moveNode(tree, details.data.index, insertIndex);
      },
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: active ? 28 : 18,
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: active
                ? Border.all(color: Theme.of(context).colorScheme.primary)
                : null,
          ),
          alignment: Alignment.center,
          child: active
              ? Text(
                  'Drop here',
                  style: Theme.of(context).textTheme.labelSmall,
                )
              : null,
        );
      },
    );
  }

  Widget _buildDraggableNodeCard({
    required String tree,
    required _EditorNode node,
    required int index,
  }) {
    final selected = node.id == _selectedId;
    final isWaitNode = node.command == 'wait';
    final summarySubtitle = isWaitNode
        ? _describeWaitNode(node)
        : '${node.command} • ${node.target}';
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          node.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(
          summarySubtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: <Widget>[
            if (node.communicationTargetId != null)
              const Chip(
                label: Text('link'),
                visualDensity: VisualDensity.compact,
              ),
            if (node.onPassId != null)
              const Chip(
                label: Text('pass'),
                visualDensity: VisualDensity.compact,
              ),
            if (node.onFailId != null)
              const Chip(
                label: Text('fail'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );

    final feedbackCard = SizedBox(
      width: 320,
      height: _nodeCardHeight,
      child: Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: summary,
        ),
      ),
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(child: summary),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'duplicate') {
                _duplicateNode(node);
              }
              if (value == 'delete') {
                _deleteNode(node.id);
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'duplicate',
                child: Text('Duplicate'),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Text('Delete'),
              ),
            ],
          ),
          Draggable<_DraggedNode>(
            data: _DraggedNode(tree: tree, index: index),
            feedback: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: feedbackCard,
            ),
            childWhenDragging: const Opacity(
              opacity: 0.35,
              child: Icon(Icons.drag_handle),
            ),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );

    final card = SizedBox(
      height: _nodeCardHeight,
      child: Card(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : isWaitNode
                ? Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                : null,
        child: InkWell(
          onTap: () {
            setState(() {
              _selectedId = node.id;
            });
          },
          child: content,
        ),
      ),
    );

    return Container(
      key: ValueKey<int>(node.id),
      margin: const EdgeInsets.only(bottom: 8),
      child: card,
    );
  }

  String _describeWaitNode(_EditorNode node) {
    final waitTarget = node.expectKind == 'none'
        ? 'delay ${node.delayMs} ms'
        : 'wait for ${node.expectKind} from ${node.expectDevice}';
    final typeSuffix = node.expectType.isEmpty ? '' : ' • ${node.expectType}';
    return 'wait • $waitTarget$typeSuffix';
  }
}

class _DraggedNode {
  const _DraggedNode({required this.tree, required this.index});

  final String tree;
  final int index;
}

class _EditorNode {
  static const Object _noChange = Object();

  const _EditorNode({
    required this.id,
    required this.name,
    required this.command,
    required this.target,
    required this.payloadJson,
    required this.expectDevice,
    required this.expectKind,
    required this.expectType,
    required this.messageContains,
    required this.payloadContainsJson,
    required this.timeoutMs,
    required this.repeat,
    required this.delayMs,
    this.communicationTargetId,
    this.onPassId,
    this.onFailId,
  });

  final int id;
  final String name;
  final String command;
  final String target;
  final String payloadJson;
  final String expectDevice;
  final String expectKind;
  final String expectType;
  final String messageContains;
  final String payloadContainsJson;
  final int timeoutMs;
  final int repeat;
  final int delayMs;
  final int? communicationTargetId;
  final int? onPassId;
  final int? onFailId;

  factory _EditorNode.fromEditorJson(Map<String, dynamic> json) {
    return _EditorNode(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? 'step').toString(),
      command: (json['command'] ?? 'wait').toString(),
      target: (json['target'] ?? 'first').toString(),
      payloadJson: (json['payloadJson'] ?? '{}').toString(),
      expectDevice: (json['expectDevice'] ?? 'same').toString(),
      expectKind: (json['expectKind'] ?? 'response').toString(),
      expectType: (json['expectType'] ?? '').toString(),
      messageContains: (json['messageContains'] ?? '').toString(),
      payloadContainsJson: (json['payloadContainsJson'] ?? '{}').toString(),
      timeoutMs: (json['timeoutMs'] as num?)?.toInt() ?? 3000,
      repeat: (json['repeat'] as num?)?.toInt() ?? 1,
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 80,
      communicationTargetId: (json['communicationTargetId'] as num?)?.toInt(),
      onPassId: (json['onPassId'] as num?)?.toInt(),
      onFailId: (json['onFailId'] as num?)?.toInt(),
    );
  }

  factory _EditorNode.fromStressStep(Map<String, dynamic> json) {
    final id = (json['id'] as num?)?.toInt() ?? DateTime.now().microsecondsSinceEpoch;
    final expectation = json['expect'] as Map?;
    final payload = json['payload'] as Map?;
    final payloadContains = expectation?['payloadContains'] as Map?;
    return _EditorNode(
      id: id,
      name: (json['name'] ?? json['command'] ?? 'step').toString(),
      command: ((json['command'] ?? '').toString().isEmpty)
          ? 'wait'
          : (json['command'] ?? 'handshake').toString(),
      target: (json['target'] ?? 'first').toString(),
      payloadJson: const JsonEncoder.withIndent('  ')
          .convert(Map<String, dynamic>.from(payload ?? const <String, dynamic>{})),
      expectDevice: (expectation?['device'] ?? 'same').toString(),
      expectKind: (expectation?['kind'] ?? 'response').toString(),
      expectType: (expectation?['type'] ?? '').toString(),
      messageContains: (expectation?['messageContains'] ?? '').toString(),
      payloadContainsJson: const JsonEncoder.withIndent('  ')
          .convert(Map<String, dynamic>.from(payloadContains ?? const <String, dynamic>{})),
      timeoutMs: (expectation?['timeoutMs'] as num?)?.toInt() ?? 3000,
      repeat: (json['repeat'] as num?)?.toInt() ?? 1,
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 80,
      communicationTargetId: (json['linkTo'] as num?)?.toInt(),
      onPassId: (json['onPass'] as num?)?.toInt(),
      onFailId: (json['onFail'] as num?)?.toInt(),
    );
  }

  _EditorNode copyWith({
    int? id,
    String? name,
    String? command,
    String? target,
    String? payloadJson,
    String? expectDevice,
    String? expectKind,
    String? expectType,
    String? messageContains,
    String? payloadContainsJson,
    int? timeoutMs,
    int? repeat,
    int? delayMs,
    Object? communicationTargetId = _noChange,
    Object? onPassId = _noChange,
    Object? onFailId = _noChange,
  }) {
    return _EditorNode(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      target: target ?? this.target,
      payloadJson: payloadJson ?? this.payloadJson,
      expectDevice: expectDevice ?? this.expectDevice,
      expectKind: expectKind ?? this.expectKind,
      expectType: expectType ?? this.expectType,
      messageContains: messageContains ?? this.messageContains,
      payloadContainsJson: payloadContainsJson ?? this.payloadContainsJson,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      repeat: repeat ?? this.repeat,
      delayMs: delayMs ?? this.delayMs,
      communicationTargetId: communicationTargetId == _noChange
          ? this.communicationTargetId
          : communicationTargetId as int?,
      onPassId: onPassId == _noChange ? this.onPassId : onPassId as int?,
      onFailId: onFailId == _noChange ? this.onFailId : onFailId as int?,
    );
  }

  Map<String, dynamic> toEditorJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'command': command,
      'target': target,
      'payloadJson': payloadJson,
      'expectDevice': expectDevice,
      'expectKind': expectKind,
      'expectType': expectType,
      'messageContains': messageContains,
      'payloadContainsJson': payloadContainsJson,
      'timeoutMs': timeoutMs,
      'repeat': repeat,
      'delayMs': delayMs,
      'communicationTargetId': communicationTargetId,
      'onPassId': onPassId,
      'onFailId': onFailId,
    };
  }

  Map<String, dynamic> toStressStepJson() {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(payloadJson);
      payload = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } catch (_) {
      payload = <String, dynamic>{};
    }

    Map<String, dynamic> payloadContains;
    try {
      final decoded = jsonDecode(payloadContainsJson);
      payloadContains = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } catch (_) {
      payloadContains = <String, dynamic>{};
    }

    final step = <String, dynamic>{
      'id': id,
      'name': name,
      'target': target,
      'payload': payload,
      'repeat': repeat,
      'delayMs': delayMs,
    };

    if (command != 'wait' && command.isNotEmpty) {
      step['command'] = command;
    }

    if (expectKind != 'none' || expectType.isNotEmpty) {
      step['expect'] = <String, dynamic>{
        'device': expectDevice,
        if (expectKind != 'none') 'kind': expectKind,
        if (expectType.isNotEmpty) 'type': expectType,
        if (messageContains.isNotEmpty) 'messageContains': messageContains,
        if (payloadContains.isNotEmpty) 'payloadContains': payloadContains,
        'timeoutMs': timeoutMs,
      };
    }

    if (communicationTargetId != null) {
      step['linkTo'] = communicationTargetId;
    }
    if (onPassId != null) {
      step['onPass'] = onPassId;
    }
    if (onFailId != null) {
      step['onFail'] = onFailId;
    }

    return step;
  }
}

class _LinkPainter extends CustomPainter {
  const _LinkPainter({
    required this.nodes,
    required this.positions,
  });

  final List<_EditorNode> nodes;
  final Map<int, Offset> positions;

  @override
  void paint(Canvas canvas, Size size) {
    final communicationPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.65)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final passPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.75)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final failPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.75)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (final node in nodes) {
      final from = positions[node.id];
      if (from == null) {
        continue;
      }

      if (node.communicationTargetId != null) {
        final to = positions[node.communicationTargetId!];
        if (to != null) {
          _drawArrow(canvas, from, to, communicationPaint);
        }
      }

      if (node.onPassId != null) {
        final to = positions[node.onPassId!];
        if (to != null) {
          _drawArrow(canvas, from.translate(0, -8), to.translate(0, -8), passPaint);
        }
      }

      if (node.onFailId != null) {
        final to = positions[node.onFailId!];
        if (to != null) {
          _drawArrow(canvas, from.translate(0, 8), to.translate(0, 8), failPaint);
        }
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    final centerYOffset = _StressScriptEditorWindowState._nodeCardHeight / 2;
    final p0 = Offset(from.dx, from.dy + centerYOffset);
    final p3 = Offset(to.dx, to.dy + centerYOffset);
    final controlDelta = (p3.dx - p0.dx).abs() * 0.35;
    final p1 = Offset(p0.dx + controlDelta, p0.dy);
    final p2 = Offset(p3.dx - controlDelta, p3.dy);

    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);
    canvas.drawPath(path, paint);

    final direction = (p3 - p2);
    final length = direction.distance;
    if (length <= 0.001) {
      return;
    }
    final unit = direction / length;
    final normal = Offset(-unit.dy, unit.dx);

    const arrowLength = 10.0;
    const arrowWidth = 5.0;
    final tip = p3;
    final left = tip - unit * arrowLength + normal * arrowWidth;
    final right = tip - unit * arrowLength - normal * arrowWidth;

    final arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();

    canvas.drawPath(
      arrow,
      Paint()
        ..color = paint.color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _LinkPainter oldDelegate) {
    return oldDelegate.nodes != nodes || oldDelegate.positions != positions;
  }
}

<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages).
-->

[![pub package](https://img.shields.io/pub/v/accessible_range_slider?color=green&include_prereleases&style=plastic)](https://pub.dev/packages/accessible_range_slider)

<img src="https://github.com/SilentCatD/accessible_range_slider/blob/main/assets/example.png?raw=true" width="200px">

## Getting started

First import the widget

```dart
import 'package:accessible_range_slider/accessible_range_slider.dart';
```

## Features

When implementing accessibility, enabling keyboard navigation for interactive elements is crucial.

However, due to a current limitation in the implementation, the framework does not support interacting
with a RangeSlider using the keyboard or receiving focus.

The root of the problem lies in the makeshift implementation of accessibility, currently using 
LeafRenderObjectWidget and creating a custom semantic boundary to support screen readers.

This poses a challenge since the slider cannot properly receive focus because there are no child 
widgets to receive focus.

To address this limitation, this package rewrites the internal implementation of RangeSlider to use 
SlottedMultiChildRenderObjectWidget. By splitting each thumb into its own node, the slider can now 
handle focus, screen reader actions, and keyboard interactions effectively.

## Usage

```dart
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  RangeValues _values = const RangeValues(0, 1);

  void _rangeValuesChanged(RangeValues values) {
    setState(() {
      _values = values;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: AccessibleRangeSlider(
          values: _values,
          onChanged: _rangeValuesChanged,
        ),
      ),
    );
  }
}
```
Just replace the original `RangeSlider` with `AccessibleRangeSlider` and you're good to go

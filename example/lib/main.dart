import 'package:accessible_range_slider/accessible_range_slider.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  RangeValues _values = const RangeValues(0, 1);
  double _value = 0;

  void _updateValueChanged(double value) {
    setState(() {
      _value = value;
    });
  }

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: _value,
              onChanged: _updateValueChanged,
            ),
            Slider(
              value: _value,
              onChanged: _updateValueChanged,
            ),
            Slider(
              value: _value,
              onChanged: _updateValueChanged,
            ),
            AccessibleRangeSlider(
              values: _values,
              onChanged: _rangeValuesChanged,
            ),
            AccessibleRangeSlider(
              values: _values,
              onChanged: _rangeValuesChanged,
            ),
            Slider(
              value: _value,
              onChanged: _updateValueChanged,
            ),
            AccessibleRangeSlider(
              values: _values,
              onChanged: _rangeValuesChanged,
            ),
            AccessibleRangeSlider(
              values: _values,
              onChanged: _rangeValuesChanged,
            ),
          ],
        ),
      ),
    );
  }
}

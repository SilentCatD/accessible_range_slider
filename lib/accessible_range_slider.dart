library accessible_range_slider;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter/services.dart';

class AccessibleRangeSlider extends StatefulWidget {
  AccessibleRangeSlider({
    super.key,
    required this.values,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.labels,
    this.activeColor,
    this.inactiveColor,
    this.overlayColor,
    this.mouseCursor,
    this.semanticFormatterCallback,
  })  : assert(min <= max),
        assert(values.start <= values.end),
        assert(values.start >= min && values.start <= max),
        assert(values.end >= min && values.end <= max),
        assert(divisions == null || divisions > 0);

  final RangeValues values;
  final ValueChanged<RangeValues>? onChanged;
  final ValueChanged<RangeValues>? onChangeStart;
  final ValueChanged<RangeValues>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final RangeLabels? labels;
  final Color? activeColor;
  final Color? inactiveColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final WidgetStateProperty<MouseCursor?>? mouseCursor;
  final SemanticFormatterCallback? semanticFormatterCallback;

  static const double _minTouchTargetWidth = kMinInteractiveDimension;

  @override
  State<AccessibleRangeSlider> createState() => _AccessibleRangeSliderState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('valueStart', values.start));
    properties.add(DoubleProperty('valueEnd', values.end));
    properties.add(ObjectFlagProperty<ValueChanged<RangeValues>>(
        'onChanged', onChanged,
        ifNull: 'disabled'));
    properties.add(ObjectFlagProperty<ValueChanged<RangeValues>>.has(
        'onChangeStart', onChangeStart));
    properties.add(ObjectFlagProperty<ValueChanged<RangeValues>>.has(
        'onChangeEnd', onChangeEnd));
    properties.add(DoubleProperty('min', min));
    properties.add(DoubleProperty('max', max));
    properties.add(IntProperty('divisions', divisions));
    properties.add(StringProperty('labelStart', labels?.start));
    properties.add(StringProperty('labelEnd', labels?.end));
    properties.add(ColorProperty('activeColor', activeColor));
    properties.add(ColorProperty('inactiveColor', inactiveColor));
    properties.add(ObjectFlagProperty<ValueChanged<double>>.has(
        'semanticFormatterCallback', semanticFormatterCallback));
  }
}

class _AccessibleRangeSliderState extends State<AccessibleRangeSlider>
    with TickerProviderStateMixin {
  final _renderSliderKey = GlobalKey();

  static const Duration enableAnimationDuration = Duration(milliseconds: 75);
  static const Duration valueIndicatorAnimationDuration =
      Duration(milliseconds: 100);

  // Animation controller that is run when the overlay (a.k.a radial reaction)
  // changes visibility in response to user interaction.
  late AnimationController overlayController;

  // Animation controller that is run when the value indicators change visibility.
  late AnimationController valueIndicatorController;

  // Animation controller that is run when enabling/disabling the slider.
  late AnimationController enableController;

  // Animation controllers that are run when transitioning between one value
  // and the next on a discrete slider.
  late AnimationController startPositionController;
  late AnimationController endPositionController;
  Timer? interactionTimer;

  // Value Indicator paint Animation that appears on the Overlay.
  PaintRangeValueIndicator? paintTopValueIndicator;
  PaintRangeValueIndicator? paintBottomValueIndicator;

  bool get _enabled => widget.onChanged != null;

  bool _dragging = false;

  bool _hovering = false;

  void _handleHoverChanged(bool hovering) {
    if (hovering != _hovering) {
      setState(() {
        _hovering = hovering;
      });
    }
  }

  final ValueNotifier<double> _thumbDelta = ValueNotifier(0.0);
  final ValueNotifier<Thumb?> _lastThumbSelection = ValueNotifier(null);

  void _updateThumbDelta(double value) {
    _thumbDelta.value = value;
  }

  void _updateLastThumbSelection(Thumb? value) {
    _lastThumbSelection.value = value;
  }

  final _startThumbFocusNode = FocusNode();
  final _endThumbFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    overlayController = AnimationController(
      duration: kRadialReactionDuration,
      vsync: this,
    );
    valueIndicatorController = AnimationController(
      duration: valueIndicatorAnimationDuration,
      vsync: this,
    );
    enableController = AnimationController(
      duration: enableAnimationDuration,
      vsync: this,
      value: _enabled ? 1.0 : 0.0,
    );
    startPositionController = AnimationController(
      duration: Duration.zero,
      vsync: this,
      value: _unlerp(widget.values.start),
    );
    endPositionController = AnimationController(
      duration: Duration.zero,
      vsync: this,
      value: _unlerp(widget.values.end),
    );
  }

  @override
  void didUpdateWidget(AccessibleRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onChanged == widget.onChanged) {
      return;
    }
    final bool wasEnabled = oldWidget.onChanged != null;
    final bool isEnabled = _enabled;
    if (wasEnabled != isEnabled) {
      if (isEnabled) {
        enableController.forward();
      } else {
        enableController.reverse();
      }
    }
  }

  @override
  void dispose() {
    interactionTimer?.cancel();
    overlayController.dispose();
    valueIndicatorController.dispose();
    enableController.dispose();
    startPositionController.dispose();
    endPositionController.dispose();
    overlayEntry?.remove();
    overlayEntry?.dispose();
    overlayEntry = null;
    _thumbDelta.dispose();
    _startThumbFocusNode.dispose();
    _endThumbFocusNode.dispose();
    super.dispose();
  }

  void _handleChanged(RangeValues values) {
    assert(_enabled);
    final RangeValues lerpValues = _lerpRangeValues(values);
    if (lerpValues != widget.values) {
      widget.onChanged!(lerpValues);
    }
  }

  void _handleDragStart(RangeValues values) {
    assert(widget.onChangeStart != null);
    _dragging = true;
    widget.onChangeStart!(_lerpRangeValues(values));
  }

  void _handleDragEnd(RangeValues values) {
    assert(widget.onChangeEnd != null);
    _dragging = false;
    widget.onChangeEnd!(_lerpRangeValues(values));
  }

  // Returns a number between min and max, proportional to value, which must
  // be between 0.0 and 1.0.
  double _lerp(double value) => ui.lerpDouble(widget.min, widget.max, value)!;

  // Returns a new range value with the start and end lerped.
  RangeValues _lerpRangeValues(RangeValues values) {
    return RangeValues(_lerp(values.start), _lerp(values.end));
  }

  // Returns a number between 0.0 and 1.0, given a value between min and max.
  double _unlerp(double value) {
    assert(value <= widget.max);
    assert(value >= widget.min);
    return widget.max > widget.min
        ? (value - widget.min) / (widget.max - widget.min)
        : 0.0;
  }

  // Returns a new range value with the start and end unlerped.
  RangeValues _unlerpRangeValues(RangeValues values) {
    return RangeValues(_unlerp(values.start), _unlerp(values.end));
  }

  // Finds closest thumb. If the thumbs are close to each other, no thumb is
  // immediately selected while the drag displacement is zero. If the first
  // non-zero displacement is negative, then the left thumb is selected, and if its
  // positive, then the right thumb is selected.
  Thumb? _defaultRangeThumbSelector(
    TextDirection textDirection,
    RangeValues values,
    double tapValue,
    Size thumbSize,
    Size trackSize,
    double dx, // The horizontal delta or displacement of the drag update.
  ) {
    final double touchRadius =
        math.max(thumbSize.width, AccessibleRangeSlider._minTouchTargetWidth) /
            2;
    final bool inStartTouchTarget =
        (tapValue - values.start).abs() * trackSize.width < touchRadius;
    final bool inEndTouchTarget =
        (tapValue - values.end).abs() * trackSize.width < touchRadius;

    // Use dx if the thumb touch targets overlap. If dx is 0 and the drag
    // position is in both touch targets, no thumb is selected because it is
    // ambiguous to which thumb should be selected. If the dx is non-zero, the
    // thumb selection is determined by the direction of the dx. The left thumb
    // is chosen for negative dx, and the right thumb is chosen for positive dx.
    if (inStartTouchTarget && inEndTouchTarget) {
      final (bool towardsStart, bool towardsEnd) = switch (textDirection) {
        TextDirection.ltr => (dx < 0, dx > 0),
        TextDirection.rtl => (dx > 0, dx < 0),
      };
      if (towardsStart) {
        return Thumb.start;
      }
      if (towardsEnd) {
        return Thumb.end;
      }
    } else {
      // Snap position on the track if its in the inactive range.
      if (tapValue < values.start || inStartTouchTarget) {
        return Thumb.start;
      }
      if (tapValue > values.end || inEndTouchTarget) {
        return Thumb.end;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMaterial(context));
    assert(debugCheckHasMediaQuery(context));

    final ThemeData theme = Theme.of(context);
    SliderThemeData sliderTheme = SliderTheme.of(context);

    // If the widget has active or inactive colors specified, then we plug them
    // in to the slider theme as best we can. If the developer wants more
    // control than that, then they need to use a SliderTheme. The default
    // colors come from the ThemeData.colorScheme. These colors, along with
    // the default shapes and text styles are aligned to the Material
    // Guidelines.

    const double defaultTrackHeight = 4;
    const RangeSliderTrackShape defaultTrackShape =
        RoundedRectRangeSliderTrackShape();
    const RangeSliderTickMarkShape defaultTickMarkShape =
        RoundRangeSliderTickMarkShape();
    const SliderComponentShape defaultOverlayShape = RoundSliderOverlayShape();
    const RangeSliderThumbShape defaultThumbShape =
        RoundRangeSliderThumbShape();
    const RangeSliderValueIndicatorShape defaultValueIndicatorShape =
        RectangularRangeSliderValueIndicatorShape();
    const ShowValueIndicator defaultShowValueIndicator =
        ShowValueIndicator.onlyForDiscrete;
    const double defaultMinThumbSeparation = 8;

    final Set<WidgetState> states = <WidgetState>{
      if (!_enabled) WidgetState.disabled,
      if (_hovering) WidgetState.hovered,
      if (_dragging) WidgetState.dragged,
    };

    // The value indicator's color is not the same as the thumb and active track
    // (which can be defined by activeColor) if the
    // RectangularSliderValueIndicatorShape is used. In all other cases, the
    // value indicator is assumed to be the same as the active color.
    final RangeSliderValueIndicatorShape valueIndicatorShape =
        sliderTheme.rangeValueIndicatorShape ?? defaultValueIndicatorShape;
    final Color valueIndicatorColor;
    if (valueIndicatorShape is RectangularRangeSliderValueIndicatorShape) {
      valueIndicatorColor = sliderTheme.valueIndicatorColor ??
          Color.alphaBlend(theme.colorScheme.onSurface.withOpacity(0.60),
              theme.colorScheme.surface.withOpacity(0.90));
    } else {
      valueIndicatorColor = widget.activeColor ??
          sliderTheme.valueIndicatorColor ??
          theme.colorScheme.primary;
    }

    Color? effectiveOverlayColor() {
      return widget.overlayColor?.resolve(states) ??
          widget.activeColor?.withOpacity(0.12) ??
          WidgetStateProperty.resolveAs<Color?>(
              sliderTheme.overlayColor, states) ??
          theme.colorScheme.primary.withOpacity(0.12);
    }

    sliderTheme = sliderTheme.copyWith(
      trackHeight: sliderTheme.trackHeight ?? defaultTrackHeight,
      activeTrackColor: widget.activeColor ??
          sliderTheme.activeTrackColor ??
          theme.colorScheme.primary,
      inactiveTrackColor: widget.inactiveColor ??
          sliderTheme.inactiveTrackColor ??
          theme.colorScheme.primary.withOpacity(0.24),
      disabledActiveTrackColor: sliderTheme.disabledActiveTrackColor ??
          theme.colorScheme.onSurface.withOpacity(0.32),
      disabledInactiveTrackColor: sliderTheme.disabledInactiveTrackColor ??
          theme.colorScheme.onSurface.withOpacity(0.12),
      activeTickMarkColor: widget.inactiveColor ??
          sliderTheme.activeTickMarkColor ??
          theme.colorScheme.onPrimary.withOpacity(0.54),
      inactiveTickMarkColor: widget.activeColor ??
          sliderTheme.inactiveTickMarkColor ??
          theme.colorScheme.primary.withOpacity(0.54),
      disabledActiveTickMarkColor: sliderTheme.disabledActiveTickMarkColor ??
          theme.colorScheme.onPrimary.withOpacity(0.12),
      disabledInactiveTickMarkColor:
          sliderTheme.disabledInactiveTickMarkColor ??
              theme.colorScheme.onSurface.withOpacity(0.12),
      thumbColor: widget.activeColor ??
          sliderTheme.thumbColor ??
          theme.colorScheme.primary,
      overlappingShapeStrokeColor:
          sliderTheme.overlappingShapeStrokeColor ?? theme.colorScheme.surface,
      disabledThumbColor: sliderTheme.disabledThumbColor ??
          Color.alphaBlend(theme.colorScheme.onSurface.withOpacity(.38),
              theme.colorScheme.surface),
      overlayColor: effectiveOverlayColor(),
      valueIndicatorColor: valueIndicatorColor,
      rangeTrackShape: sliderTheme.rangeTrackShape ?? defaultTrackShape,
      rangeTickMarkShape:
          sliderTheme.rangeTickMarkShape ?? defaultTickMarkShape,
      rangeThumbShape: sliderTheme.rangeThumbShape ?? defaultThumbShape,
      overlayShape: sliderTheme.overlayShape ?? defaultOverlayShape,
      rangeValueIndicatorShape: valueIndicatorShape,
      showValueIndicator:
          sliderTheme.showValueIndicator ?? defaultShowValueIndicator,
      valueIndicatorTextStyle: sliderTheme.valueIndicatorTextStyle ??
          theme.textTheme.bodyLarge!.copyWith(
            color: theme.colorScheme.onPrimary,
          ),
      minThumbSeparation:
          sliderTheme.minThumbSeparation ?? defaultMinThumbSeparation,
      thumbSelector: sliderTheme.thumbSelector ?? _defaultRangeThumbSelector,
    );
    final MouseCursor effectiveMouseCursor =
        widget.mouseCursor?.resolve(states) ??
            sliderTheme.mouseCursor?.resolve(states) ??
            WidgetStateMouseCursor.clickable.resolve(states);

    // This size is used as the max bounds for the painting of the value
    // indicators. It must be kept in sync with the function with the same name
    // in slider.dart.
    Size screenSize() => MediaQuery.sizeOf(context);

    final double fontSize =
        sliderTheme.valueIndicatorTextStyle?.fontSize ?? kDefaultFontSize;
    final double fontSizeToScale =
        fontSize == 0.0 ? kDefaultFontSize : fontSize;
    final double effectiveTextScale =
        MediaQuery.textScalerOf(context).scale(fontSizeToScale) /
            fontSizeToScale;

    final onChanged =
        _enabled && (widget.max > widget.min) ? _handleChanged : null;
    return FocusableActionDetector(
      enabled: _enabled,
      includeFocusSemantics: true,
      onShowHoverHighlight: _handleHoverChanged,
      mouseCursor: effectiveMouseCursor,
      child: CompositedTransformTarget(
        link: _layerLink,
        child: _RangeSliderRenderObjectWidget(
          key: _renderSliderKey,
          values: _unlerpRangeValues(widget.values),
          divisions: widget.divisions,
          labels: widget.labels,
          sliderTheme: sliderTheme,
          textScaleFactor: effectiveTextScale,
          screenSize: screenSize(),
          onChanged: onChanged,
          onChangeStart: widget.onChangeStart != null ? _handleDragStart : null,
          onChangeEnd: widget.onChangeEnd != null ? _handleDragEnd : null,
          state: this,
          hovering: _hovering,
          endThumb: _AccessibleThumb(
            values: _unlerpRangeValues(widget.values),
            divisions: widget.divisions,
            focusNode: _endThumbFocusNode,
            sliderState: this,
            thumb: Thumb.end,
            sliderTheme: sliderTheme,
            onChanged: onChanged,
            renderSliderKey: _renderSliderKey,
            targetPlatform: Theme.of(context).platform,
            semanticFormatterCallback: widget.semanticFormatterCallback,
          ),
          startThumb: _AccessibleThumb(
            values: _unlerpRangeValues(widget.values),
            divisions: widget.divisions,
            focusNode: _startThumbFocusNode,
            sliderState: this,
            thumb: Thumb.start,
            sliderTheme: sliderTheme,
            onChanged: onChanged,
            renderSliderKey: _renderSliderKey,
            targetPlatform: Theme.of(context).platform,
            semanticFormatterCallback: widget.semanticFormatterCallback,
          ),
        ),
      ),
    );
  }

  final LayerLink _layerLink = LayerLink();

  OverlayEntry? overlayEntry;

  void showValueIndicator() {
    if (overlayEntry == null) {
      overlayEntry = OverlayEntry(
        builder: (BuildContext context) {
          return CompositedTransformFollower(
            link: _layerLink,
            child: _ValueIndicatorRenderObjectWidget(
              state: this,
            ),
          );
        },
      );
      Overlay.of(context, debugRequiredFor: widget).insert(overlayEntry!);
    }
  }
}

class _RangeSliderRenderObjectWidget
    extends SlottedMultiChildRenderObjectWidget<Thumb, RenderBox> {
  const _RangeSliderRenderObjectWidget({
    super.key,
    required this.values,
    required this.divisions,
    required this.labels,
    required this.sliderTheme,
    required this.textScaleFactor,
    required this.screenSize,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
    required this.state,
    required this.hovering,
    required this.endThumb,
    required this.startThumb,
  });

  final RangeValues values;
  final int? divisions;
  final RangeLabels? labels;
  final SliderThemeData sliderTheme;
  final double textScaleFactor;
  final Size screenSize;
  final ValueChanged<RangeValues>? onChanged;
  final ValueChanged<RangeValues>? onChangeStart;
  final ValueChanged<RangeValues>? onChangeEnd;
  final _AccessibleRangeSliderState state;
  final bool hovering;
  final Widget startThumb;
  final Widget endThumb;

  @override
  _RenderRangeSlider createRenderObject(BuildContext context) {
    return _RenderRangeSlider(
      values: values,
      divisions: divisions,
      labels: labels,
      sliderTheme: sliderTheme,
      theme: Theme.of(context),
      textScaleFactor: textScaleFactor,
      screenSize: screenSize,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      state: state,
      textDirection: Directionality.of(context),
      hovering: hovering,
      gestureSettings: MediaQuery.gestureSettingsOf(context),
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderRangeSlider renderObject) {
    renderObject
      // We should update the `divisions` ahead of `values`, because the `values`
      // setter dependent on the `divisions`.
      ..divisions = divisions
      ..values = values
      ..labels = labels
      ..sliderTheme = sliderTheme
      ..theme = Theme.of(context)
      ..textScaleFactor = textScaleFactor
      ..screenSize = screenSize
      ..onChanged = onChanged
      ..onChangeStart = onChangeStart
      ..onChangeEnd = onChangeEnd
      ..textDirection = Directionality.of(context)
      ..hovering = hovering
      ..gestureSettings = MediaQuery.gestureSettingsOf(context);
  }

  @override
  Widget? childForSlot(Thumb slot) {
    return switch (slot) {
      Thumb.start => startThumb,
      Thumb.end => endThumb,
    };
  }

  @override
  Iterable<Thumb> get slots => Thumb.values;
}

class _RenderRangeSlider extends RenderBox
    with
        SlottedContainerRenderObjectMixin<Thumb, RenderBox>,
        RelayoutWhenSystemFontsChangeMixin {
  _RenderRangeSlider({
    required RangeValues values,
    required int? divisions,
    required RangeLabels? labels,
    required SliderThemeData sliderTheme,
    required ThemeData? theme,
    required double textScaleFactor,
    required Size screenSize,
    required ValueChanged<RangeValues>? onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
    required _AccessibleRangeSliderState state,
    required TextDirection textDirection,
    required bool hovering,
    required DeviceGestureSettings gestureSettings,
  })  : assert(values.start >= 0.0 && values.start <= 1.0),
        assert(values.end >= 0.0 && values.end <= 1.0),
        _labels = labels,
        _values = values,
        _divisions = divisions,
        _sliderTheme = sliderTheme,
        _theme = theme,
        _textScaleFactor = textScaleFactor,
        _screenSize = screenSize,
        _onChanged = onChanged,
        _state = state,
        _textDirection = textDirection,
        _hovering = hovering {
    _updateLabelPainters();
    final GestureArenaTeam team = GestureArenaTeam();
    _drag = HorizontalDragGestureRecognizer()
      ..team = team
      ..onStart = _handleDragStart
      ..onUpdate = _handleDragUpdate
      ..onEnd = _handleDragEnd
      ..onCancel = _handleDragCancel
      ..gestureSettings = gestureSettings;
    _tap = TapGestureRecognizer()
      ..team = team
      ..onTapDown = _handleTapDown
      ..onTapUp = _handleTapUp
      ..gestureSettings = gestureSettings;
    _overlayAnimation = CurvedAnimation(
      parent: _state.overlayController,
      curve: Curves.fastOutSlowIn,
    );
    _valueIndicatorAnimation = CurvedAnimation(
      parent: _state.valueIndicatorController,
      curve: Curves.fastOutSlowIn,
    )..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.dismissed) {
          _state.overlayEntry?.remove();
          _state.overlayEntry?.dispose();
          _state.overlayEntry = null;
        }
      });
    _enableAnimation = CurvedAnimation(
      parent: _state.enableController,
      curve: Curves.easeInOut,
    );
  }

  // Keep track of the last selected thumb so they can be drawn in the
  // right order.
  Thumb? get _lastThumbSelection => _state._lastThumbSelection.value;

  set _lastThumbSelection(Thumb? value) =>
      _state._updateLastThumbSelection(value);

  static const Duration _positionAnimationDuration = Duration(milliseconds: 75);

  // This value is the touch target, 48, multiplied by 3.
  static const double _minPreferredTrackWidth = 144.0;

  // Compute the largest width and height needed to paint the slider shapes,
  // other than the track shape. It is assumed that these shapes are vertically
  // centered on the track.
  double get _maxSliderPartWidth =>
      _sliderPartSizes.map((Size size) => size.width).reduce(math.max);

  double get _maxSliderPartHeight =>
      _sliderPartSizes.map((Size size) => size.height).reduce(math.max);

  List<Size> get _sliderPartSizes => <Size>[
        _sliderTheme.overlayShape!.getPreferredSize(isEnabled, isDiscrete),
        _sliderTheme.rangeThumbShape!.getPreferredSize(isEnabled, isDiscrete),
        _sliderTheme.rangeTickMarkShape!
            .getPreferredSize(isEnabled: isEnabled, sliderTheme: sliderTheme),
      ];

  double? get _minPreferredTrackHeight => _sliderTheme.trackHeight;

  // This rect is used in gesture calculations, where the gesture coordinates
  // are relative to the sliders origin. Therefore, the offset is passed as
  // (0,0).
  Rect get _trackRect => _sliderTheme.rangeTrackShape!.getPreferredRect(
        parentBox: this,
        sliderTheme: _sliderTheme,
        isDiscrete: false,
      );

  static const Duration _minimumInteractionTime = Duration(milliseconds: 500);

  final _AccessibleRangeSliderState _state;
  late CurvedAnimation _overlayAnimation;
  late CurvedAnimation _valueIndicatorAnimation;
  late CurvedAnimation _enableAnimation;
  final TextPainter _startLabelPainter = TextPainter();
  final TextPainter _endLabelPainter = TextPainter();
  late HorizontalDragGestureRecognizer _drag;
  late TapGestureRecognizer _tap;
  bool _active = false;
  late RangeValues _newValues;
  Offset _startThumbCenter = Offset.zero;
  Offset _endThumbCenter = Offset.zero;
  Rect? overlayStartRect;
  Rect? overlayEndRect;

  bool get isEnabled => onChanged != null;

  bool get isDiscrete => divisions != null && divisions! > 0;

  double get _minThumbSeparationValue =>
      isDiscrete ? 0 : sliderTheme.minThumbSeparation! / _trackRect.width;

  RangeValues get values => _values;
  RangeValues _values;

  set values(RangeValues newValues) {
    assert(newValues.start >= 0.0 && newValues.start <= 1.0);
    assert(newValues.end >= 0.0 && newValues.end <= 1.0);
    assert(newValues.start <= newValues.end);
    final RangeValues convertedValues = isDiscrete
        ? _discretizeRangeValues(newValues, isDiscrete, divisions)
        : newValues;
    if (convertedValues == _values) {
      return;
    }
    _values = convertedValues;
    if (isDiscrete) {
      // Reset the duration to match the distance that we're traveling, so that
      // whatever the distance, we still do it in _positionAnimationDuration,
      // and if we get re-targeted in the middle, it still takes that long to
      // get to the new location.
      final double startDistance =
          (_values.start - _state.startPositionController.value).abs();
      _state.startPositionController.duration = startDistance != 0.0
          ? _positionAnimationDuration * (1.0 / startDistance)
          : Duration.zero;
      _state.startPositionController
          .animateTo(_values.start, curve: Curves.easeInOut);
      final double endDistance =
          (_values.end - _state.endPositionController.value).abs();
      _state.endPositionController.duration = endDistance != 0.0
          ? _positionAnimationDuration * (1.0 / endDistance)
          : Duration.zero;
      _state.endPositionController
          .animateTo(_values.end, curve: Curves.easeInOut);
    } else {
      _state.startPositionController.value = convertedValues.start;
      _state.endPositionController.value = convertedValues.end;
    }
    markNeedsSemanticsUpdate();
  }

  DeviceGestureSettings? get gestureSettings => _drag.gestureSettings;

  set gestureSettings(DeviceGestureSettings? gestureSettings) {
    _drag.gestureSettings = gestureSettings;
    _tap.gestureSettings = gestureSettings;
  }

  int? get divisions => _divisions;
  int? _divisions;

  set divisions(int? value) {
    if (value == _divisions) {
      return;
    }
    _divisions = value;
    markNeedsPaint();
  }

  RangeLabels? get labels => _labels;
  RangeLabels? _labels;

  set labels(RangeLabels? labels) {
    if (labels == _labels) {
      return;
    }
    _labels = labels;
    _updateLabelPainters();
  }

  SliderThemeData get sliderTheme => _sliderTheme;
  SliderThemeData _sliderTheme;

  set sliderTheme(SliderThemeData value) {
    if (value == _sliderTheme) {
      return;
    }
    _sliderTheme = value;
    markNeedsPaint();
  }

  ThemeData? get theme => _theme;
  ThemeData? _theme;

  set theme(ThemeData? value) {
    if (value == _theme) {
      return;
    }
    _theme = value;
    markNeedsPaint();
  }

  double get textScaleFactor => _textScaleFactor;
  double _textScaleFactor;

  set textScaleFactor(double value) {
    if (value == _textScaleFactor) {
      return;
    }
    _textScaleFactor = value;
    _updateLabelPainters();
  }

  Size get screenSize => _screenSize;
  Size _screenSize;

  set screenSize(Size value) {
    if (value == screenSize) {
      return;
    }
    _screenSize = value;
    markNeedsPaint();
  }

  ValueChanged<RangeValues>? get onChanged => _onChanged;
  ValueChanged<RangeValues>? _onChanged;

  set onChanged(ValueChanged<RangeValues>? value) {
    if (value == _onChanged) {
      return;
    }
    final bool wasEnabled = isEnabled;
    _onChanged = value;
    if (wasEnabled != isEnabled) {
      markNeedsPaint();
      markNeedsSemanticsUpdate();
    }
  }

  ValueChanged<RangeValues>? onChangeStart;
  ValueChanged<RangeValues>? onChangeEnd;

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) {
      return;
    }
    _textDirection = value;
    _updateLabelPainters();
  }

  /// True if this slider is being hovered over by a pointer.
  bool get hovering => _hovering;
  bool _hovering;

  set hovering(bool value) {
    if (value == _hovering) {
      return;
    }
    _hovering = value;
    _updateForHover(_hovering);
  }

  /// True if the slider is interactive and the start thumb is being
  /// hovered over by a pointer.
  bool _hoveringStartThumb = false;

  bool get hoveringStartThumb => _hoveringStartThumb;

  set hoveringStartThumb(bool value) {
    if (value == _hoveringStartThumb) {
      return;
    }
    _hoveringStartThumb = value;
    _updateForHover(_hovering);
  }

  /// True if the slider is interactive and the end thumb is being
  /// hovered over by a pointer.
  bool _hoveringEndThumb = false;

  bool get hoveringEndThumb => _hoveringEndThumb;

  set hoveringEndThumb(bool value) {
    if (value == _hoveringEndThumb) {
      return;
    }
    _hoveringEndThumb = value;
    _updateForHover(_hovering);
  }

  bool _focusingStartThumb = false;

  bool get focusingStartThumb => _focusingStartThumb;

  set focusingStartThumb(bool value) {
    if (_focusingStartThumb == value) {
      return;
    }
    _focusingStartThumb = value;
    _updateForFocus();
  }

  bool _focusingEndThumb = false;

  bool get focusingEndThumb => _focusingEndThumb;

  set focusingEndThumb(bool value) {
    if (_focusingEndThumb == value) {
      return;
    }
    _focusingEndThumb = value;
    _updateForFocus();
  }

  void _updateForFocus() {
    if (!isEnabled) {
      return;
    }
    if (focusingStartThumb || focusingEndThumb) {
      _state.overlayController.forward();
    } else {
      _state.overlayController.reverse();
    }
  }

  void _onFocusChanged() {
    if (!isEnabled) {
      return;
    }
    focusingStartThumb = _state._startThumbFocusNode.hasPrimaryFocus;
    focusingEndThumb = _state._endThumbFocusNode.hasPrimaryFocus;
    if (focusingStartThumb) {
      _lastThumbSelection = Thumb.start;
    } else if (focusingEndThumb) {
      _lastThumbSelection = Thumb.end;
    } else {
      _lastThumbSelection = null;
    }
    markNeedsPaint();
  }

  void _updateForHover(bool hovered) {
    // Only show overlay when pointer is hovering the thumb.
    if (hovered && (hoveringStartThumb || hoveringEndThumb)) {
      _state.overlayController.forward();
    } else {
      _state.overlayController.reverse();
    }
  }

  bool get showValueIndicator {
    return switch (_sliderTheme.showValueIndicator!) {
      ShowValueIndicator.onlyForDiscrete => isDiscrete,
      ShowValueIndicator.onlyForContinuous => !isDiscrete,
      ShowValueIndicator.always => true,
      ShowValueIndicator.never => false,
    };
  }

  Size get _thumbSize =>
      _sliderTheme.rangeThumbShape!.getPreferredSize(isEnabled, isDiscrete);

  void _updateLabelPainters() {
    _updateLabelPainter(Thumb.start);
    _updateLabelPainter(Thumb.end);
  }

  void _updateLabelPainter(Thumb thumb) {
    final RangeLabels? labels = this.labels;
    if (labels == null) {
      return;
    }

    final (String text, TextPainter labelPainter) = switch (thumb) {
      Thumb.start => (labels.start, _startLabelPainter),
      Thumb.end => (labels.end, _endLabelPainter),
    };

    labelPainter
      ..text = TextSpan(
        style: _sliderTheme.valueIndicatorTextStyle,
        text: text,
      )
      ..textDirection = textDirection
      ..textScaler = TextScaler.linear(textScaleFactor)
      ..layout();
    // Changing the textDirection can result in the layout changing, because the
    // bidi algorithm might line up the glyphs differently which can result in
    // different ligatures, different shapes, etc. So we always markNeedsLayout.
    markNeedsLayout();
  }

  RenderBox? get _startThumb => childForSlot(Thumb.start);

  RenderBox? get _endThumb => childForSlot(Thumb.end);

  @override
  void systemFontsDidChange() {
    super.systemFontsDidChange();
    _startLabelPainter.markNeedsLayout();
    _endLabelPainter.markNeedsLayout();
    _updateLabelPainters();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _overlayAnimation.addListener(markNeedsPaint);
    _valueIndicatorAnimation.addListener(markNeedsPaint);
    _enableAnimation.addListener(markNeedsPaint);
    _state.startPositionController.addListener(markNeedsLayout);
    _state.endPositionController.addListener(markNeedsLayout);
    _state.startPositionController.addListener(_updateThumbDelta);
    _state.endPositionController.addListener(_updateThumbDelta);
    _state._startThumbFocusNode.addListener(_onFocusChanged);
    _state._endThumbFocusNode.addListener(_onFocusChanged);
  }

  void _updateThumbDelta() {
    _updateThumbCenters();
    final double thumbDelta = (_endThumbCenter.dx - _startThumbCenter.dx).abs();
    _state._updateThumbDelta(thumbDelta);
  }

  @override
  void detach() {
    _overlayAnimation.removeListener(markNeedsPaint);
    _valueIndicatorAnimation.removeListener(markNeedsPaint);
    _enableAnimation.removeListener(markNeedsPaint);
    _state.startPositionController.removeListener(markNeedsLayout);
    _state.endPositionController.removeListener(markNeedsLayout);
    _state.startPositionController.removeListener(_updateThumbDelta);
    _state.endPositionController.removeListener(_updateThumbDelta);
    _state._startThumbFocusNode.removeListener(_onFocusChanged);
    _state._endThumbFocusNode.removeListener(_onFocusChanged);
    super.detach();
  }

  @override
  void dispose() {
    _drag.dispose();
    _tap.dispose();
    _startLabelPainter.dispose();
    _endLabelPainter.dispose();
    _enableAnimation.dispose();
    _valueIndicatorAnimation.dispose();
    _overlayAnimation.dispose();
    super.dispose();
  }

  double _getValueFromVisualPosition(double visualPosition) {
    return switch (textDirection) {
      TextDirection.rtl => 1.0 - visualPosition,
      TextDirection.ltr => visualPosition,
    };
  }

  double _getValueFromGlobalPosition(Offset globalPosition) {
    final double visualPosition =
        (globalToLocal(globalPosition).dx - _trackRect.left) / _trackRect.width;
    return _getValueFromVisualPosition(visualPosition);
  }

  void _startInteraction(Offset globalPosition) {
    if (_active) {
      return;
    }

    _state.showValueIndicator();
    final double tapValue =
        clampDouble(_getValueFromGlobalPosition(globalPosition), 0.0, 1.0);
    _lastThumbSelection = sliderTheme.thumbSelector!(
        textDirection, values, tapValue, _thumbSize, size, 0);

    if (_lastThumbSelection != null) {
      _active = true;
      // We supply the *current* values as the start locations, so that if we have
      // a tap, it consists of a call to onChangeStart with the previous value and
      // a call to onChangeEnd with the new value.
      final RangeValues currentValues =
          _discretizeRangeValues(values, isDiscrete, divisions);
      if (_lastThumbSelection == Thumb.start) {
        _newValues = RangeValues(tapValue, currentValues.end);
      } else if (_lastThumbSelection == Thumb.end) {
        _newValues = RangeValues(currentValues.start, tapValue);
      }
      _updateLabelPainter(_lastThumbSelection!);

      onChangeStart?.call(currentValues);

      onChanged!(_discretizeRangeValues(_newValues, isDiscrete, divisions));

      _state.overlayController.forward();
      if (showValueIndicator) {
        _state.valueIndicatorController.forward();
        _state.interactionTimer?.cancel();
        _state.interactionTimer =
            Timer(_minimumInteractionTime * timeDilation, () {
          _state.interactionTimer = null;
          if (!_active &&
              _state.valueIndicatorController.status ==
                  AnimationStatus.completed) {
            _state.valueIndicatorController.reverse();
          }
        });
      }
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_state.mounted) {
      return;
    }

    final double dragValue =
        _getValueFromGlobalPosition(details.globalPosition);

    // If no selection has been made yet, test for thumb selection again now
    // that the value of dx can be non-zero. If this is the first selection of
    // the interaction, then onChangeStart must be called.
    bool shouldCallOnChangeStart = false;
    if (_lastThumbSelection == null) {
      _lastThumbSelection = sliderTheme.thumbSelector!(
          textDirection, values, dragValue, _thumbSize, size, details.delta.dx);
      if (_lastThumbSelection != null) {
        shouldCallOnChangeStart = true;
        _active = true;
        _state.overlayController.forward();
        if (showValueIndicator) {
          _state.valueIndicatorController.forward();
        }
      }
    }

    if (isEnabled && _lastThumbSelection != null) {
      final RangeValues currentValues =
          _discretizeRangeValues(values, isDiscrete, divisions);
      if (onChangeStart != null && shouldCallOnChangeStart) {
        onChangeStart!(currentValues);
      }
      final double currentDragValue =
          _discretize(dragValue, isDiscrete, divisions);

      if (_lastThumbSelection == Thumb.start) {
        _newValues = RangeValues(
            math.min(
                currentDragValue, currentValues.end - _minThumbSeparationValue),
            currentValues.end);
      } else if (_lastThumbSelection == Thumb.end) {
        _newValues = RangeValues(
            currentValues.start,
            math.max(currentDragValue,
                currentValues.start + _minThumbSeparationValue));
      }
      onChanged!(_newValues);
    }
  }

  void _endInteraction() {
    if (!_state.mounted) {
      return;
    }

    if (showValueIndicator && _state.interactionTimer == null) {
      _state.valueIndicatorController.reverse();
    }

    if (_active && _state.mounted && _lastThumbSelection != null) {
      final RangeValues discreteValues =
          _discretizeRangeValues(_newValues, isDiscrete, divisions);
      onChangeEnd?.call(discreteValues);
      _active = false;
    }
    _state.overlayController.reverse();
  }

  void _handleDragStart(DragStartDetails details) {
    _startInteraction(details.globalPosition);
  }

  void _handleDragEnd(DragEndDetails details) {
    _endInteraction();
  }

  void _handleDragCancel() {
    _endInteraction();
  }

  void _handleTapDown(TapDownDetails details) {
    _startInteraction(details.globalPosition);
  }

  void _handleTapUp(TapUpDetails details) {
    _endInteraction();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    assert(debugHandleEvent(event, entry));
    if (event is PointerDownEvent && isEnabled) {
      // We need to add the drag first so that it has priority.
      _drag.addPointer(event);
      _tap.addPointer(event);
    }
    if (isEnabled) {
      if (overlayStartRect != null) {
        hoveringStartThumb = overlayStartRect!.contains(event.localPosition);
      }
      if (overlayEndRect != null) {
        hoveringEndThumb = overlayEndRect!.contains(event.localPosition);
      }
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _minPreferredTrackWidth + _maxSliderPartWidth;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _minPreferredTrackWidth + _maxSliderPartWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(_minPreferredTrackHeight!, _maxSliderPartHeight);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(_minPreferredTrackHeight!, _maxSliderPartHeight);

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return Size(
      constraints.hasBoundedWidth
          ? constraints.maxWidth
          : _minPreferredTrackWidth + _maxSliderPartWidth,
      constraints.hasBoundedHeight
          ? constraints.maxHeight
          : math.max(_minPreferredTrackHeight!, _maxSliderPartHeight),
    );
  }

  Rect _calcTrackRect({Offset offset = Offset.zero}) {
    final Rect trackRect = _sliderTheme.rangeTrackShape!.getPreferredRect(
      parentBox: this,
      offset: Offset.zero,
      sliderTheme: _sliderTheme,
      isDiscrete: isDiscrete,
    );
    return trackRect;
  }

  (double, double) _calcVisualPosition() {
    final double startValue = _state.startPositionController.value;
    final double endValue = _state.endPositionController.value;
    final (double startVisualPosition, double endVisualPosition) =
        switch (textDirection) {
      TextDirection.rtl => (1.0 - startValue, 1.0 - endValue),
      TextDirection.ltr => (startValue, endValue),
    };
    return (startVisualPosition, endVisualPosition);
  }

  (Offset, Offset) _updateThumbCenters() {
    final (double startVisualPosition, double endVisualPosition) =
        _calcVisualPosition();
    final Rect trackRect = _calcTrackRect();
    _startThumbCenter = Offset(
        trackRect.left + startVisualPosition * trackRect.width,
        trackRect.center.dy);
    _endThumbCenter = Offset(
        trackRect.left + endVisualPosition * trackRect.width,
        trackRect.center.dy);
    return (_startThumbCenter, _endThumbCenter);
  }

  @override
  void performLayout() {
    _updateThumbCenters();
    if (_startThumb != null) {
      _startThumb!.layout(
        constraints,
        parentUsesSize: true,
      );
      final childSize = _startThumb!.size;
      (_startThumb!.parentData! as BoxParentData).offset = _startThumbCenter -
          Offset(
            childSize.width / 2,
            childSize.height / 2,
          );
    }
    if (_endThumb != null) {
      _endThumb!.layout(
        constraints,
        parentUsesSize: true,
      );
      final childSize = _endThumb!.size;
      (_endThumb!.parentData! as BoxParentData).offset = _endThumbCenter -
          Offset(
            childSize.width / 2,
            childSize.height / 2,
          );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    void paintChild(RenderBox child, PaintingContext context, Offset offset) {
      final childParentData = child.parentData as BoxParentData;
      context.paintChild(child, childParentData.offset + offset);
    }

    final double startValue = _state.startPositionController.value;
    final double endValue = _state.endPositionController.value;

    // The visual position is the position of the thumb from 0 to 1 from left
    // to right. In left to right, this is the same as the value, but it is
    // reversed for right to left text.
    final Rect trackRect = _calcTrackRect(offset: offset);
    if (isEnabled) {
      final Size overlaySize =
          sliderTheme.overlayShape!.getPreferredSize(isEnabled, false);
      overlayStartRect = Rect.fromCircle(
          center: _startThumbCenter, radius: overlaySize.width / 2.0);
      overlayEndRect = Rect.fromCircle(
          center: _endThumbCenter, radius: overlaySize.width / 2.0);
    }

    _sliderTheme.rangeTrackShape!.paint(
      context,
      offset,
      parentBox: this,
      sliderTheme: _sliderTheme,
      enableAnimation: _enableAnimation,
      textDirection: _textDirection,
      startThumbCenter: _startThumbCenter,
      endThumbCenter: _endThumbCenter,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
    );

    final bool startThumbSelected = _lastThumbSelection == Thumb.start;
    final bool endThumbSelected = _lastThumbSelection == Thumb.end;
    final Size resolvedscreenSize = screenSize.isEmpty ? size : screenSize;

    if (!_overlayAnimation.isDismissed) {
      if (startThumbSelected || (hoveringStartThumb && hovering)) {
        _sliderTheme.overlayShape!.paint(
          context,
          _startThumbCenter,
          activationAnimation: _overlayAnimation,
          enableAnimation: _enableAnimation,
          isDiscrete: isDiscrete,
          labelPainter: _startLabelPainter,
          parentBox: this,
          sliderTheme: _sliderTheme,
          textDirection: _textDirection,
          value: startValue,
          textScaleFactor: _textScaleFactor,
          sizeWithOverflow: resolvedscreenSize,
        );
      }
      if (endThumbSelected || (hoveringEndThumb && hovering)) {
        _sliderTheme.overlayShape!.paint(
          context,
          _endThumbCenter,
          activationAnimation: _overlayAnimation,
          enableAnimation: _enableAnimation,
          isDiscrete: isDiscrete,
          labelPainter: _endLabelPainter,
          parentBox: this,
          sliderTheme: _sliderTheme,
          textDirection: _textDirection,
          value: endValue,
          textScaleFactor: _textScaleFactor,
          sizeWithOverflow: resolvedscreenSize,
        );
      }
    }

    if (isDiscrete) {
      final double tickMarkWidth = _sliderTheme.rangeTickMarkShape!
          .getPreferredSize(
            isEnabled: isEnabled,
            sliderTheme: _sliderTheme,
          )
          .width;
      final double padding = trackRect.height;
      final double adjustedTrackWidth = trackRect.width - padding;
      // If the tick marks would be too dense, don't bother painting them.
      if (adjustedTrackWidth / divisions! >= 3.0 * tickMarkWidth) {
        final double dy = trackRect.center.dy;
        for (int i = 0; i <= divisions!; i++) {
          final double value = i / divisions!;
          // The ticks are mapped to be within the track, so the tick mark width
          // must be subtracted from the track width.
          final double dx =
              trackRect.left + value * adjustedTrackWidth + padding / 2;
          final Offset tickMarkOffset = Offset(dx, dy);
          _sliderTheme.rangeTickMarkShape!.paint(
            context,
            tickMarkOffset,
            parentBox: this,
            sliderTheme: _sliderTheme,
            enableAnimation: _enableAnimation,
            textDirection: _textDirection,
            startThumbCenter: _startThumbCenter,
            endThumbCenter: _endThumbCenter,
            isEnabled: isEnabled,
          );
        }
      }
    }

    final double thumbDelta = _state._thumbDelta.value;

    final bool isLastThumbStart = _lastThumbSelection == Thumb.start;
    final Thumb bottomThumb = isLastThumbStart ? Thumb.end : Thumb.start;
    final Thumb topThumb = isLastThumbStart ? Thumb.start : Thumb.end;
    final Offset bottomThumbCenter =
        isLastThumbStart ? _endThumbCenter : _startThumbCenter;
    final Offset topThumbCenter =
        isLastThumbStart ? _startThumbCenter : _endThumbCenter;
    final TextPainter bottomLabelPainter =
        isLastThumbStart ? _endLabelPainter : _startLabelPainter;
    final TextPainter topLabelPainter =
        isLastThumbStart ? _startLabelPainter : _endLabelPainter;

    final bottomThumbChild = switch (bottomThumb) {
      Thumb.start => _startThumb,
      Thumb.end => _endThumb,
    };

    final topThumbChild = switch (topThumb) {
      Thumb.start => _startThumb,
      Thumb.end => _endThumb,
    };

    final double bottomValue = isLastThumbStart ? endValue : startValue;
    final double topValue = isLastThumbStart ? startValue : endValue;
    final bool shouldPaintValueIndicators = isEnabled &&
        labels != null &&
        !_valueIndicatorAnimation.isDismissed &&
        showValueIndicator;

    if (shouldPaintValueIndicators) {
      _state.paintBottomValueIndicator =
          (PaintingContext context, Offset offset) {
        if (attached) {
          _sliderTheme.rangeValueIndicatorShape!.paint(
            context,
            bottomThumbCenter,
            activationAnimation: _valueIndicatorAnimation,
            enableAnimation: _enableAnimation,
            isDiscrete: isDiscrete,
            isOnTop: false,
            labelPainter: bottomLabelPainter,
            parentBox: this,
            sliderTheme: _sliderTheme,
            textDirection: _textDirection,
            thumb: bottomThumb,
            value: bottomValue,
            textScaleFactor: textScaleFactor,
            sizeWithOverflow: resolvedscreenSize,
          );
        }
      };
    }

    if (bottomThumbChild != null) {
      paintChild(
        bottomThumbChild,
        context,
        offset,
      );
    }

    if (shouldPaintValueIndicators) {
      final double startOffset =
          sliderTheme.rangeValueIndicatorShape!.getHorizontalShift(
        parentBox: this,
        center: _startThumbCenter,
        labelPainter: _startLabelPainter,
        activationAnimation: _valueIndicatorAnimation,
        textScaleFactor: textScaleFactor,
        sizeWithOverflow: resolvedscreenSize,
      );
      final double endOffset =
          sliderTheme.rangeValueIndicatorShape!.getHorizontalShift(
        parentBox: this,
        center: _endThumbCenter,
        labelPainter: _endLabelPainter,
        activationAnimation: _valueIndicatorAnimation,
        textScaleFactor: textScaleFactor,
        sizeWithOverflow: resolvedscreenSize,
      );
      final double startHalfWidth = sliderTheme.rangeValueIndicatorShape!
              .getPreferredSize(
                isEnabled,
                isDiscrete,
                labelPainter: _startLabelPainter,
                textScaleFactor: textScaleFactor,
              )
              .width /
          2;
      final double endHalfWidth = sliderTheme.rangeValueIndicatorShape!
              .getPreferredSize(
                isEnabled,
                isDiscrete,
                labelPainter: _endLabelPainter,
                textScaleFactor: textScaleFactor,
              )
              .width /
          2;
      final double innerOverflow = startHalfWidth +
          endHalfWidth +
          switch (textDirection) {
            TextDirection.ltr => startOffset - endOffset,
            TextDirection.rtl => endOffset - startOffset,
          };

      _state.paintTopValueIndicator = (PaintingContext context, Offset offset) {
        if (attached) {
          _sliderTheme.rangeValueIndicatorShape!.paint(
            context,
            topThumbCenter,
            activationAnimation: _valueIndicatorAnimation,
            enableAnimation: _enableAnimation,
            isDiscrete: isDiscrete,
            isOnTop: thumbDelta < innerOverflow,
            labelPainter: topLabelPainter,
            parentBox: this,
            sliderTheme: _sliderTheme,
            textDirection: _textDirection,
            thumb: topThumb,
            value: topValue,
            textScaleFactor: textScaleFactor,
            sizeWithOverflow: resolvedscreenSize,
          );
        }
      };
    }

    if (topThumbChild != null) {
      paintChild(
        topThumbChild,
        context,
        offset,
      );
    }
  }
}

class _ValueIndicatorRenderObjectWidget extends LeafRenderObjectWidget {
  const _ValueIndicatorRenderObjectWidget({
    required this.state,
  });

  final _AccessibleRangeSliderState state;

  @override
  _RenderValueIndicator createRenderObject(BuildContext context) {
    return _RenderValueIndicator(
      state: state,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderValueIndicator renderObject) {
    renderObject._state = state;
  }
}

class _RenderValueIndicator extends RenderBox
    with RelayoutWhenSystemFontsChangeMixin {
  _RenderValueIndicator({
    required _AccessibleRangeSliderState state,
  }) : _state = state {
    _valueIndicatorAnimation = CurvedAnimation(
      parent: _state.valueIndicatorController,
      curve: Curves.fastOutSlowIn,
    );
  }

  late Animation<double> _valueIndicatorAnimation;
  late _AccessibleRangeSliderState _state;

  @override
  bool get sizedByParent => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _valueIndicatorAnimation.addListener(markNeedsPaint);
    _state.startPositionController.addListener(markNeedsPaint);
    _state.endPositionController.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _valueIndicatorAnimation.removeListener(markNeedsPaint);
    _state.startPositionController.removeListener(markNeedsPaint);
    _state.endPositionController.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _state.paintBottomValueIndicator?.call(context, offset);
    _state.paintTopValueIndicator?.call(context, offset);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return constraints.smallest;
  }
}

class _ThumbWidget extends LeafRenderObjectWidget {
  const _ThumbWidget({
    required this.sliderTheme,
    required this.thumb,
    required this.onChanged,
    required this.divisions,
    required this.state,
  });

  final SliderThemeData sliderTheme;
  final Thumb thumb;
  final ValueChanged<RangeValues>? onChanged;
  final int? divisions;
  final _AccessibleRangeSliderState state;

  @override
  void updateRenderObject(
      BuildContext context, _RenderThumbWidget renderObject) {
    renderObject
      ..sliderTheme = sliderTheme
      ..textDirection = Directionality.of(context)
      ..onChanged = onChanged;
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderThumbWidget(
      thumb: thumb,
      sliderTheme: sliderTheme,
      state: state,
      textDirection: Directionality.of(context),
      platform: Theme.of(context).platform,
      onChanged: onChanged,
    );
  }
}

class _RenderThumbWidget extends RenderBox {
  _RenderThumbWidget({
    required this.thumb,
    required SliderThemeData sliderTheme,
    required _AccessibleRangeSliderState state,
    required TextDirection textDirection,
    required TargetPlatform platform,
    required ValueChanged<RangeValues>? onChanged,
  })  : _state = state,
        _sliderTheme = sliderTheme,
        _onChanged = onChanged,
        _textDirection = textDirection {
    _overlayAnimation = CurvedAnimation(
      parent: _state.overlayController,
      curve: Curves.fastOutSlowIn,
    );
    _enableAnimation = CurvedAnimation(
      parent: _state.enableController,
      curve: Curves.easeInOut,
    );
    _lastThumbSelected = _state._lastThumbSelection;
    _thumbDelta = _state._thumbDelta;
  }

  late CurvedAnimation _overlayAnimation;
  late CurvedAnimation _enableAnimation;

  late ValueListenable<Thumb?> _lastThumbSelected;
  late ValueListenable<double> _thumbDelta;

  final _AccessibleRangeSliderState _state;
  final Thumb thumb;

  bool get isEnabled => onChanged != null;

  bool get isDiscrete => divisions != null && divisions! > 0;

  int? get divisions => _divisions;
  int? _divisions;

  set divisions(int? value) {
    if (value == _divisions) {
      return;
    }
    _divisions = value;
    markNeedsLayout();
  }

  SliderThemeData _sliderTheme;

  SliderThemeData get sliderTheme => _sliderTheme;

  set sliderTheme(SliderThemeData value) {
    if (value == _sliderTheme) {
      return;
    }
    _sliderTheme = value;
    markNeedsLayout();
  }

  Size get _thumbSize =>
      _sliderTheme.rangeThumbShape!.getPreferredSize(isEnabled, isDiscrete);

  ValueChanged<RangeValues>? get onChanged => _onChanged;
  ValueChanged<RangeValues>? _onChanged;

  set onChanged(ValueChanged<RangeValues>? value) {
    if (value == _onChanged) {
      return;
    }
    final bool wasEnabled = isEnabled;
    _onChanged = value;
    if (wasEnabled != isEnabled) {
      markNeedsLayout();
    }
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) {
      return;
    }
    _textDirection = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _overlayAnimation.addListener(markNeedsPaint);
    _enableAnimation.addListener(markNeedsPaint);
    _thumbDelta.addListener(markNeedsPaint);
    _lastThumbSelected.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _thumbDelta.removeListener(markNeedsPaint);
    _lastThumbSelected.removeListener(markNeedsPaint);
    _overlayAnimation.removeListener(markNeedsPaint);
    _enableAnimation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _enableAnimation.dispose();
    _overlayAnimation.dispose();
    super.dispose();
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    return math.max(kMinInteractiveDimension, _thumbSize.height);
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return math.max(kMinInteractiveDimension, _thumbSize.height);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    return math.max(kMinInteractiveDimension, _thumbSize.width);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    return math.max(kMinInteractiveDimension, _thumbSize.width);
  }

  @override
  ui.Size computeDryLayout(covariant BoxConstraints constraints) {
    return ui.Size(getMaxIntrinsicWidth(constraints.maxHeight),
        getMaxIntrinsicHeight(constraints.maxWidth));
  }

  @override
  void performLayout() {
    size = getDryLayout(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final center = offset + Offset(size.width / 2, size.height / 2);
    final thumbDelta = _thumbDelta.value;
    final lastThumbSelected = _lastThumbSelected.value;
    _sliderTheme.rangeThumbShape!.paint(
      context,
      center,
      activationAnimation: _overlayAnimation,
      enableAnimation: _enableAnimation,
      isDiscrete: isDiscrete,
      isOnTop: lastThumbSelected == thumb &&
          thumbDelta <
              sliderTheme.rangeThumbShape!
                  .getPreferredSize(isEnabled, isDiscrete)
                  .width,
      textDirection: textDirection,
      sliderTheme: _sliderTheme,
      thumb: thumb,
      isPressed: thumb == lastThumbSelected && lastThumbSelected != null,
    );
  }
}

double _discretize(double value, bool isDiscrete, int? divisions) {
  double result = clampDouble(value, 0.0, 1.0);
  if (isDiscrete) {
    result = (result * divisions!).round() / divisions;
  }
  return result;
}

RangeValues _discretizeRangeValues(
    RangeValues values, bool isDiscrete, int? divisions) {
  return RangeValues(_discretize(values.start, isDiscrete, divisions),
      _discretize(values.end, isDiscrete, divisions));
}

class _AccessibleThumb extends StatefulWidget {
  const _AccessibleThumb({
    required this.values,
    required this.divisions,
    required this.focusNode,
    required this.sliderState,
    required this.thumb,
    required this.sliderTheme,
    required this.onChanged,
    required this.renderSliderKey,
    required this.targetPlatform,
    required this.semanticFormatterCallback,
  });

  final RangeValues values;
  final int? divisions;
  final FocusNode focusNode;
  final _AccessibleRangeSliderState sliderState;
  final Thumb thumb;
  final SliderThemeData sliderTheme;
  final ValueChanged<RangeValues>? onChanged;
  final GlobalKey renderSliderKey;
  final TargetPlatform targetPlatform;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  State<_AccessibleThumb> createState() => _AccessibleThumbState();
}

class _AccessibleThumbState extends State<_AccessibleThumb> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateMinThumb();
    });
    _actionMap = <Type, Action<Intent>>{
      _AdjustSliderIntent: CallbackAction<_AdjustSliderIntent>(
        onInvoke: _actionHandler,
      ),
    };
  }

  @override
  void didUpdateWidget(covariant _AccessibleThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMinThumb();
  }

  void _updateMinThumb() {
    setState(() {
      _minThumbSeparationValue = (widget.renderSliderKey.currentContext
                  ?.findRenderObject() as _RenderRangeSlider?)
              ?._minThumbSeparationValue ??
          0.0;
    });
  }

  void _actionHandler(_AdjustSliderIntent intent) {
    final TextDirection directionality = Directionality.of(context);
    final bool shouldIncrease = switch (intent.type) {
      _SliderAdjustmentType.up => true,
      _SliderAdjustmentType.down => false,
      _SliderAdjustmentType.left => directionality == TextDirection.rtl,
      _SliderAdjustmentType.right => directionality == TextDirection.ltr,
    };

    if (shouldIncrease) {
      _increaseAction();
    } else {
      _decreaseAction();
    }
    final (semanticValues, _, _) = _resolveSemanticsLabels();
    SemanticsService.announce(semanticValues, Directionality.of(context));
  }

  static const Map<ShortcutActivator, Intent> _traditionalNavShortcutMap =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): _AdjustSliderIntent.up(),
    SingleActivator(LogicalKeyboardKey.arrowDown): _AdjustSliderIntent.down(),
    SingleActivator(LogicalKeyboardKey.arrowLeft): _AdjustSliderIntent.left(),
    SingleActivator(LogicalKeyboardKey.arrowRight): _AdjustSliderIntent.right(),
  };

  // Keyboard mapping for a focused slider when using directional navigation.
  // The vertical inputs are not handled to allow navigating out of the slider.
  static const Map<ShortcutActivator, Intent> _directionalNavShortcutMap =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowLeft): _AdjustSliderIntent.left(),
    SingleActivator(LogicalKeyboardKey.arrowRight): _AdjustSliderIntent.right(),
  };

  late Map<Type, Action<Intent>> _actionMap;

  RangeValues get _convertedValues {
    final oldValues = widget.values;
    final RangeValues convertedValues = isDiscrete
        ? _discretizeRangeValues(oldValues, isDiscrete, widget.divisions)
        : oldValues;
    return convertedValues;
  }

  bool get isDiscrete => widget.divisions != null && widget.divisions! > 0;

  double get minThumbSeparationValue => _minThumbSeparationValue;
  double _minThumbSeparationValue = 0.0;

  bool get isEnabled => widget.onChanged != null;

  double get _semanticActionUnit =>
      widget.divisions != null ? 1.0 / widget.divisions! : _adjustmentUnit;

  void _increaseStartAction() {
    if (isEnabled) {
      widget
          .onChanged!(RangeValues(_increasedStartValue, _convertedValues.end));
    }
  }

  void _decreaseStartAction() {
    if (isEnabled) {
      widget
          .onChanged!(RangeValues(_decreasedStartValue, _convertedValues.end));
    }
  }

  void _increaseEndAction() {
    if (isEnabled) {
      widget
          .onChanged!(RangeValues(_convertedValues.start, _increasedEndValue));
    }
  }

  void _decreaseEndAction() {
    if (isEnabled) {
      widget
          .onChanged!(RangeValues(_convertedValues.start, _decreasedEndValue));
    }
  }

  double get _increasedStartValue {
    // Due to floating-point operations, this value can actually be greater than
    // expected (e.g. 0.4 + 0.2 = 0.600000000001), so we limit to 2 decimal points.
    final double increasedStartValue = double.parse(
        (_convertedValues.start + _semanticActionUnit).toStringAsFixed(2));
    return increasedStartValue <=
            _convertedValues.end - _minThumbSeparationValue
        ? increasedStartValue
        : _convertedValues.start;
  }

  double get _decreasedStartValue {
    return clampDouble(_convertedValues.start - _semanticActionUnit, 0.0, 1.0);
  }

  double get _increasedEndValue {
    return clampDouble(_convertedValues.end + _semanticActionUnit, 0.0, 1.0);
  }

  double get _decreasedEndValue {
    final double decreasedEndValue = _convertedValues.end - _semanticActionUnit;
    return decreasedEndValue >=
            _convertedValues.start + _minThumbSeparationValue
        ? decreasedEndValue
        : _convertedValues.end;
  }

  double get _adjustmentUnit {
    switch (widget.targetPlatform) {
      case TargetPlatform.iOS:
        // Matches iOS implementation of material slider.
        return 0.1;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        // Matches Android implementation of material slider.
        return 0.05;
    }
  }

  void _increaseAction() {
    switch (widget.thumb) {
      case Thumb.start:
        _increaseStartAction();
      case Thumb.end:
        _increaseEndAction();
    }
  }

  void _decreaseAction() {
    switch (widget.thumb) {
      case Thumb.start:
        _decreaseStartAction();
      case Thumb.end:
        _decreaseEndAction();
    }
  }

  late Map<ShortcutActivator, Intent> shortcutMap =
      switch (MediaQuery.navigationModeOf(context)) {
    NavigationMode.directional => _directionalNavShortcutMap,
    NavigationMode.traditional => _traditionalNavShortcutMap,
  };

  (String, String, String) _resolveSemanticsLabels() {
    String semanticValues;
    String semanticIncreasedValues;
    String semanticDecreasedValues;
    final value = widget.thumb == Thumb.start
        ? _convertedValues.start
        : _convertedValues.end;
    final increaseValue =
        widget.thumb == Thumb.start ? _increasedStartValue : _increasedEndValue;
    final decreaseValue =
        widget.thumb == Thumb.start ? _decreasedStartValue : _decreasedEndValue;
    if (widget.semanticFormatterCallback != null) {
      semanticValues =
          widget.semanticFormatterCallback!(widget.sliderState._lerp(
        value,
      ));
      semanticIncreasedValues = widget
          .semanticFormatterCallback!(widget.sliderState._lerp(increaseValue));
      semanticDecreasedValues = widget
          .semanticFormatterCallback!(widget.sliderState._lerp(decreaseValue));
    } else {
      semanticValues = '${(value * 100).round()}%';
      semanticIncreasedValues = '${(increaseValue * 100).round()}%';
      semanticDecreasedValues = '${(decreaseValue * 100).round()}%';
    }
    return (semanticValues, semanticIncreasedValues, semanticDecreasedValues);
  }

  @override
  Widget build(BuildContext context) {
    final (semanticValues, decreasedValues, increasedValues) =
        _resolveSemanticsLabels();
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      shortcuts: shortcutMap,
      actions: _actionMap,
      child: Semantics(
        slider: true,
        enabled: isEnabled,
        textDirection: Directionality.of(context),
        onIncrease: !isEnabled ? null : _increaseAction,
        onDecrease: !isEnabled ? null : _decreaseAction,
        value: semanticValues,
        decreasedValue: decreasedValues,
        increasedValue: increasedValues,
        child: _ThumbWidget(
          sliderTheme: widget.sliderTheme,
          thumb: widget.thumb,
          onChanged: widget.onChanged,
          divisions: widget.divisions,
          state: widget.sliderState,
        ),
      ),
    );
  }
}

class _AdjustSliderIntent extends Intent {
  const _AdjustSliderIntent({
    required this.type,
  });

  const _AdjustSliderIntent.right() : type = _SliderAdjustmentType.right;

  const _AdjustSliderIntent.left() : type = _SliderAdjustmentType.left;

  const _AdjustSliderIntent.up() : type = _SliderAdjustmentType.up;

  const _AdjustSliderIntent.down() : type = _SliderAdjustmentType.down;

  final _SliderAdjustmentType type;
}

enum _SliderAdjustmentType {
  right,
  left,
  up,
  down,
}

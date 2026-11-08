import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:solar_family_monitor/domain/models/solar_reading.dart';

/// Gráfica Dinámica e Interactiva basada en `fl_chart`.
/// Soporta:
/// - Acercar / Alejar (Zoom con gestos de pellizco sobre la gráfica y botones +/-).
/// - Desplazamiento horizontal suave (Paneo) cuando se hace zoom.
/// - Tocar cualquier punto de la curva para inspeccionar el valor numérico exacto
///   y la marca de tiempo exacta (`HH:mm:ss` o `dd/MM HH:mm`).
class InteractiveSolarChart extends StatefulWidget {
  const InteractiveSolarChart({
    super.key,
    required this.title,
    required this.subtitle,
    required this.unit,
    required this.readings,
    required this.valueSelector,
    required this.lineColor,
    required this.gradientColor,
    this.minY,
    this.maxY,
    this.thresholdY,
    this.thresholdLabel,
    this.showSecondsInTooltip = false,
  });

  final String title;
  final String subtitle;
  final String unit;
  final List<SolarReading> readings;
  final double Function(SolarReading) valueSelector;
  final Color lineColor;
  final Color gradientColor;
  final double? minY;
  final double? maxY;
  final double? thresholdY;
  final String? thresholdLabel;
  final bool showSecondsInTooltip;

  @override
  State<InteractiveSolarChart> createState() => _InteractiveSolarChartState();
}

class _InteractiveSolarChartState extends State<InteractiveSolarChart> {
  /// Nivel de zoom: 1.0 = vista completa (100% de los puntos), hasta 6.0x de aumento.
  double _zoomLevel = 1.0;
  double _baseZoomOnScaleStart = 1.0;

  /// Posición relativa de desplazamiento horizontal [0.0 .. 1.0]
  /// 1.0 significa anclado al extremo más reciente (derecha).
  double _panNormalizedOffset = 1.0;

  /// Punto seleccionado al tocar la gráfica para mostrar detalle fijo en cabecera
  SolarReading? _selectedReading;

  void _zoomIn() {
    setState(() {
      _zoomLevel = (_zoomLevel * 1.4).clamp(1.0, 6.0);
    });
  }

  void _zoomOut() {
    setState(() {
      _zoomLevel = (_zoomLevel / 1.4).clamp(1.0, 6.0);
    });
  }

  void _resetZoom() {
    setState(() {
      _zoomLevel = 1.0;
      _panNormalizedOffset = 1.0;
      _selectedReading = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final allPoints = widget.readings;
    if (allPoints.isEmpty) {
      return const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // Calcular ventana visible según el nivel de zoom y paneo
    final totalCount = allPoints.length;
    final visibleCount =
        math.max(8, (totalCount / _zoomLevel).round()).clamp(1, totalCount);
    final maxStartIndex = math.max(0, totalCount - visibleCount);
    final startIndex =
        (maxStartIndex * _panNormalizedOffset).round().clamp(0, maxStartIndex);
    final endIndex = (startIndex + visibleCount).clamp(0, totalCount);

    final visibleReadings = allPoints.sublist(startIndex, endIndex);

    final spots = <FlSpot>[];
    double computedMinY = widget.minY ?? double.infinity;
    double computedMaxY = widget.maxY ?? double.negativeInfinity;

    for (int i = 0; i < visibleReadings.length; i++) {
      final yVal = widget.valueSelector(visibleReadings[i]);
      spots.add(FlSpot(i.toDouble(), yVal));
      if (widget.minY == null && yVal < computedMinY) computedMinY = yVal;
      if (widget.maxY == null && yVal > computedMaxY) computedMaxY = yVal;
    }

    if (computedMinY == double.infinity) computedMinY = 0;
    if (computedMaxY == double.negativeInfinity || computedMaxY <= computedMinY) {
      computedMaxY = computedMinY + 100;
    }

    // Añadir margen vertical superior del 12% para que la curva no toque el borde
    final effectiveMinY = widget.minY ?? math.max(0.0, computedMinY * 0.9);
    final effectiveMaxY = widget.maxY ?? (computedMaxY * 1.15 + 10.0);

    final timeFormatter = widget.showSecondsInTooltip
        ? DateFormat('HH:mm:ss')
        : DateFormat('dd/MM HH:mm');
    final axisTimeFormatter = widget.showSecondsInTooltip
        ? DateFormat('HH:mm:ss')
        : DateFormat('HH:mm');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161F30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: widget.lineColor.withOpacity(0.25),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera con título y controles de Zoom
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              // Controles de Zoom (+/- y Reset)
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0D131F),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Alejar (Zoom -)',
                      icon: const Icon(Icons.remove, size: 18, color: Colors.white70),
                      onPressed: _zoomLevel > 1.0 ? _zoomOut : null,
                    ),
                    GestureDetector(
                      onTap: _resetZoom,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${_zoomLevel.toStringAsFixed(1)}x',
                          style: TextStyle(
                            color: _zoomLevel > 1.0
                                ? widget.lineColor
                                : Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Acercar (Zoom +)',
                      icon: const Icon(Icons.add, size: 18, color: Colors.white70),
                      onPressed: _zoomLevel < 6.0 ? _zoomIn : null,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Píldora informativa del punto exacto inspeccionado o último valor
          _buildInspectedPointBanner(visibleReadings.last, timeFormatter),

          const SizedBox(height: 14),

          // Lienzo interactivo con soporte de gestos de pellizco (Pinch-to-Zoom) y toque
          GestureDetector(
            onScaleStart: (details) {
              _baseZoomOnScaleStart = _zoomLevel;
            },
            onScaleUpdate: (details) {
              setState(() {
                // Zoom por pellizco de 2 dedos
                if ((details.scale - 1.0).abs() > 0.02) {
                  _zoomLevel =
                      (_baseZoomOnScaleStart * details.scale).clamp(1.0, 6.0);
                }
                // Desplazamiento horizontal cuando hay zoom activo
                if (_zoomLevel > 1.05 && details.focalPointDelta.dx.abs() > 0.5) {
                  final deltaRatio = details.focalPointDelta.dx / 250.0;
                  _panNormalizedOffset =
                      (_panNormalizedOffset - deltaRatio).clamp(0.0, 1.0);
                }
              });
            },
            child: SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(1, visibleReadings.length - 1).toDouble(),
                  minY: effectiveMinY,
                  maxY: effectiveMaxY,
                  clipData: const FlClipData.all(),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval:
                        math.max(1.0, (effectiveMaxY - effectiveMinY) / 4.0),
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: Colors.white.withOpacity(0.07),
                      strokeWidth: 1,
                    ),
                    getDrawingVerticalLine: (value) => FlLine(
                      color: Colors.white.withOpacity(0.05),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 46,
                        getTitlesWidget: (value, meta) {
                          if (value == meta.min || value == meta.max) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            '${value.toInt()}${widget.unit}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10,
                            ),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: math.max(
                          1.0,
                          (visibleReadings.length / 4).floorToDouble(),
                        ),
                        getTitlesWidget: (value, meta) {
                          final idx = value.round();
                          if (idx < 0 || idx >= visibleReadings.length) {
                            return const SizedBox.shrink();
                          }
                          final dt = visibleReadings[idx].timestamp;
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              axisTimeFormatter.format(dt),
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.white12),
                  ),
                  extraLinesData: widget.thresholdY != null
                      ? ExtraLinesData(
                          horizontalLines: [
                            HorizontalLine(
                              y: widget.thresholdY!,
                              color: const Color(0xFFFF1744).withOpacity(0.8),
                              strokeWidth: 1.5,
                              dashArray: [6, 4],
                              label: HorizontalLineLabel(
                                show: true,
                                alignment: Alignment.topRight,
                                style: const TextStyle(
                                  color: Color(0xFFFF5252),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                labelResolver: (_) =>
                                    widget.thresholdLabel ??
                                    'Umbral Crítico (${widget.thresholdY!.toInt()}${widget.unit})',
                              ),
                            ),
                          ],
                        )
                      : null,
                  lineTouchData: LineTouchData(
                    enabled: true,
                    handleBuiltInTouches: true,
                    touchCallback:
                        (FlTouchEvent event, LineTouchResponse? response) {
                      if (response?.lineBarSpots != null &&
                          response!.lineBarSpots!.isNotEmpty) {
                        final spotIdx =
                            response.lineBarSpots!.first.x.round();
                        if (spotIdx >= 0 && spotIdx < visibleReadings.length) {
                          setState(() {
                            _selectedReading = visibleReadings[spotIdx];
                          });
                        }
                      }
                    },
                    getTouchedSpotIndicator:
                        (LineChartBarData barData, List<int> spotIndexes) {
                      return spotIndexes.map((index) {
                        return TouchedSpotIndicatorData(
                          FlLine(
                            color: Colors.white70,
                            strokeWidth: 1.5,
                            dashArray: [4, 4],
                          ),
                          FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, barData, index) =>
                                FlDotCirclePainter(
                              radius: 6,
                              color: widget.lineColor,
                              strokeWidth: 2.5,
                              strokeColor: Colors.white,
                            ),
                          ),
                        );
                      }).toList();
                    },
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) =>
                          const Color(0xFF0B101B).withOpacity(0.95),
                      tooltipRoundedRadius: 10,
                      tooltipBorder: BorderSide(color: widget.lineColor),
                      getTooltipItems: (List<LineBarSpot> touchedSpots) {
                        return touchedSpots.map((barSpot) {
                          final idx = barSpot.x.round();
                          final reading =
                              (idx >= 0 && idx < visibleReadings.length)
                                  ? visibleReadings[idx]
                                  : visibleReadings.last;
                          final exactTime =
                              timeFormatter.format(reading.timestamp);
                          final exactVal =
                              widget.valueSelector(reading).toStringAsFixed(1);
                          return LineTooltipItem(
                            '$exactVal ${widget.unit}\n',
                            TextStyle(
                              color: widget.lineColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                            children: [
                              TextSpan(
                                text: '🕒 $exactTime\n',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.normal,
                                  fontSize: 11,
                                ),
                              ),
                              TextSpan(
                                text:
                                    '⚡ ${reading.batteryVoltage.toStringAsFixed(1)}V • ${reading.status.displayName}',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontWeight: FontWeight.normal,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          );
                        }).toList();
                      },
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      curveSmoothness: 0.25,
                      color: widget.lineColor,
                      barWidth: 3.0,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: _zoomLevel >= 2.5,
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            widget.gradientColor.withOpacity(0.38),
                            widget.gradientColor.withOpacity(0.02),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Barra deslizante inferior cuando hay Zoom activo para recorrer la historia fácilmente
          if (_zoomLevel > 1.05) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.swipe, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                const Text(
                  'Deslizar ventana de tiempo:',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: _panNormalizedOffset,
                      activeColor: widget.lineColor,
                      inactiveColor: Colors.white12,
                      onChanged: (val) {
                        setState(() {
                          _panNormalizedOffset = val;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInspectedPointBanner(
    SolarReading fallbackLatest,
    DateFormat formatter,
  ) {
    final target = _selectedReading ?? fallbackLatest;
    final isSelected = _selectedReading != null;
    final val = widget.valueSelector(target).toStringAsFixed(1);
    final timeStr = formatter.format(target.timestamp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D131F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? widget.lineColor.withOpacity(0.6)
              : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSelected ? Icons.touch_app : Icons.bolt,
            size: 16,
            color: widget.lineColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isSelected
                  ? 'Punto seleccionado ($timeStr):'
                  : 'Lectura actual ($timeStr):',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Text(
            '$val ${widget.unit}',
            style: TextStyle(
              color: widget.lineColor,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          if (isSelected) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _selectedReading = null),
              child: const Icon(Icons.close, size: 16, color: Colors.white54),
            ),
          ],
        ],
      ),
    );
  }
}

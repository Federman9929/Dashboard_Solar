import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:solar_family_monitor/domain/models/solar_reading.dart';

class ChartTimeRangePreset {
  const ChartTimeRangePreset({
    required this.shortLabel,
    required this.fullLabel,
    required this.duration,
    required this.showSeconds,
    required this.bucketMs,
  });

  final String shortLabel;
  final String fullLabel;
  final Duration duration;
  final bool showSeconds;
  final int bucketMs;
}

const List<ChartTimeRangePreset> kChartTimeRangePresets = [
  ChartTimeRangePreset(
    shortLabel: '1m',
    fullLabel: '1 minuto',
    duration: Duration(minutes: 1),
    showSeconds: true,
    bucketMs: 1000, // 1s por cubeta fija
  ),
  ChartTimeRangePreset(
    shortLabel: '10m',
    fullLabel: '10 minutos',
    duration: Duration(minutes: 10),
    showSeconds: true,
    bucketMs: 10000, // 10s por cubeta fija
  ),
  ChartTimeRangePreset(
    shortLabel: '30m',
    fullLabel: '30 minutos',
    duration: Duration(minutes: 30),
    showSeconds: false,
    bucketMs: 30000, // 30s por cubeta fija
  ),
  ChartTimeRangePreset(
    shortLabel: '1h',
    fullLabel: '1 hora',
    duration: Duration(hours: 1),
    showSeconds: false,
    bucketMs: 60000, // 1 min por cubeta fija
  ),
  ChartTimeRangePreset(
    shortLabel: '6h',
    fullLabel: '6 horas',
    duration: Duration(hours: 6),
    showSeconds: false,
    bucketMs: 300000, // 5 min por cubeta fija
  ),
  ChartTimeRangePreset(
    shortLabel: '24h',
    fullLabel: '24 horas',
    duration: Duration(hours: 24),
    showSeconds: false,
    bucketMs: 900000, // 15 min por cubeta fija
  ),
];

class _ChartBucketPoint {
  const _ChartBucketPoint({
    required this.reading,
    required this.smoothedY,
  });

  final SolarReading reading;
  final double smoothedY;
}

/// Gráfica Dinámica, Suave e Inmutable basada en `fl_chart`.
/// - Ancla las muestras a cubetas fijas de tiempo (`epochMs ~/ bucketMs`)
///   para que los registros del pasado jamás cambien ni bailen cuando entra
///   una nueva lectura cada segundo.
/// - Aplica suavizado causal + splines con `preventCurveOverShooting: true`.
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
    this.initialRangeIndex = 1, // Por defecto 10 minutos
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
  final int initialRangeIndex;

  @override
  State<InteractiveSolarChart> createState() => _InteractiveSolarChartState();
}

class _InteractiveSolarChartState extends State<InteractiveSolarChart> {
  late int _selectedRangeIndex;
  SolarReading? _selectedReading;

  @override
  void initState() {
    super.initState();
    _selectedRangeIndex =
        widget.initialRangeIndex.clamp(0, kChartTimeRangePresets.length - 1);
  }

  void _selectRange(int index) {
    setState(() {
      _selectedRangeIndex = index.clamp(0, kChartTimeRangePresets.length - 1);
      _selectedReading = null;
    });
  }

  List<_ChartBucketPoint> _buildImmutableSmoothSeries(
    List<SolarReading> allPoints,
    ChartTimeRangePreset preset,
  ) {
    if (allPoints.isEmpty) return const [];

    final latestMs = allPoints.last.epochMs;
    final cutoffMs = latestMs - preset.duration.inMilliseconds;

    final filtered = <SolarReading>[];
    SolarReading? lastBeforeCutoff;

    for (final r in allPoints) {
      if (r.epochMs < cutoffMs) {
        lastBeforeCutoff = r;
      } else {
        filtered.add(r);
      }
    }

    if (lastBeforeCutoff != null &&
        (filtered.isEmpty ||
            (filtered.first.epochMs - cutoffMs) > preset.bucketMs)) {
      filtered.insert(
        0,
        SolarReading(
          timestamp: DateTime.fromMillisecondsSinceEpoch(cutoffMs),
          epochMs: cutoffMs,
          batteryVoltage: lastBeforeCutoff.batteryVoltage,
          batterySoc: lastBeforeCutoff.batterySoc,
          pvPowerW: lastBeforeCutoff.pvPowerW,
          batteryPowerW: lastBeforeCutoff.batteryPowerW,
          batteryChargeW: lastBeforeCutoff.batteryChargeW,
          batteryDischargeW: lastBeforeCutoff.batteryDischargeW,
          loadPowerW: lastBeforeCutoff.loadPowerW,
          status: lastBeforeCutoff.status,
          isCritical: lastBeforeCutoff.isCritical,
          sourceMode: lastBeforeCutoff.sourceMode,
        ),
      );
    }

    if (filtered.isEmpty) {
      final last = allPoints.last;
      final val = widget.valueSelector(last);
      return [
        _ChartBucketPoint(reading: last, smoothedY: val),
      ];
    }

    // Agrupar por cubeta fija de tiempo (`epochMs ~/ bucketMs`).
    // Cada cubeta histórica cerrada tiene SIEMPRE el mismo ID y los mismos puntos,
    // por lo que jamás se modifica cuando llegan nuevas lecturas en el presente.
    final bucketMs = preset.bucketMs;
    final bucketReadings = <SolarReading>[];
    final bucketRawY = <double>[];

    int? currentBucketId;
    double sumY = 0.0;
    int countInBucket = 0;
    SolarReading? representative;

    for (final r in filtered) {
      final bId = r.epochMs ~/ bucketMs;
      final y = widget.valueSelector(r);
      if (currentBucketId == null || bId != currentBucketId) {
        if (representative != null && countInBucket > 0) {
          bucketReadings.add(representative);
          bucketRawY.add(sumY / countInBucket);
        }
        currentBucketId = bId;
        sumY = y;
        countInBucket = 1;
        representative = r;
      } else {
        sumY += y;
        countInBucket++;
        representative = r;
      }
    }
    if (representative != null && countInBucket > 0) {
      bucketReadings.add(representative);
      bucketRawY.add(sumY / countInBucket);
    }

    // Si solo hay 1 punto en la ventana (ej. recién abierta la app en modo 1m),
    // anclar el inicio de la ventana con el mismo nivel para dibujar una línea limpia
    if (bucketReadings.length == 1) {
      final only = bucketReadings.first;
      final anchor = SolarReading(
        timestamp: DateTime.fromMillisecondsSinceEpoch(cutoffMs),
        epochMs: cutoffMs,
        batteryVoltage: only.batteryVoltage,
        batterySoc: only.batterySoc,
        pvPowerW: only.pvPowerW,
        batteryPowerW: only.batteryPowerW,
        batteryChargeW: only.batteryChargeW,
        batteryDischargeW: only.batteryDischargeW,
        loadPowerW: only.loadPowerW,
        status: only.status,
        isCritical: only.isCritical,
        sourceMode: only.sourceMode,
      );
      bucketReadings.insert(0, anchor);
      bucketRawY.insert(0, bucketRawY.first);
    }

    // Filtro causal de media móvil ponderada (3 puntos hacia atrás):
    // Suaviza la curva sin usar puntos futuros, garantizando que ningún punto
    // pasado cambie su valor cuando se añade un punto nuevo a la derecha.
    final result = <_ChartBucketPoint>[];
    for (int i = 0; i < bucketReadings.length; i++) {
      double smoothY;
      if (i == 0) {
        smoothY = bucketRawY[0];
      } else if (i == 1) {
        smoothY = bucketRawY[0] * 0.35 + bucketRawY[1] * 0.65;
      } else {
        smoothY = bucketRawY[i - 2] * 0.20 +
            bucketRawY[i - 1] * 0.35 +
            bucketRawY[i] * 0.45;
      }
      result.add(
        _ChartBucketPoint(
          reading: bucketReadings[i],
          smoothedY: double.parse(smoothY.toStringAsFixed(1)),
        ),
      );
    }

    return result;
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

    final preset = kChartTimeRangePresets[_selectedRangeIndex];
    final series = _buildImmutableSmoothSeries(allPoints, preset);

    final firstEpochMs = series.first.reading.epochMs;
    final lastEpochMs = math.max(
      firstEpochMs + 1000,
      series.last.reading.epochMs,
    );

    final spots = <FlSpot>[];
    double computedMinY = widget.minY ?? double.infinity;
    double computedMaxY = widget.maxY ?? double.negativeInfinity;

    for (int i = 0; i < series.length; i++) {
      final pt = series[i];
      // Usar coordenada X basada en el tiempo real (segundos desde el inicio de la ventana)
      // para que cada punto histórico conserve su posición temporal real.
      final xSec = (pt.reading.epochMs - firstEpochMs) / 1000.0;
      final yVal = pt.smoothedY;
      spots.add(FlSpot(xSec, yVal));
      if (widget.minY == null && yVal < computedMinY) computedMinY = yVal;
      if (widget.maxY == null && yVal > computedMaxY) computedMaxY = yVal;
    }

    if (computedMinY == double.infinity) computedMinY = 0;
    if (computedMaxY == double.negativeInfinity ||
        computedMaxY <= computedMinY) {
      computedMaxY = computedMinY + 100;
    }

    final effectiveMinY = widget.minY ?? math.max(0.0, computedMinY * 0.88);
    final effectiveMaxY = widget.maxY ?? (computedMaxY * 1.15 + 15.0);
    final maxXSec = math.max(1.0, (lastEpochMs - firstEpochMs) / 1000.0);

    final timeFormatter = preset.showSeconds
        ? DateFormat('HH:mm:ss')
        : DateFormat('dd/MM HH:mm');
    final axisTimeFormatter =
        preset.showSeconds ? DateFormat('HH:mm:ss') : DateFormat('HH:mm');

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
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera con título y etiqueta del rango activo
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
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Ventana: Últimos ${preset.fullLabel}',
                      style: TextStyle(
                        color: widget.lineColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Botones rápidos de rango: 1m | 10m | 30m | 1h | 6h | 24h
          Row(
            children: List.generate(kChartTimeRangePresets.length, (idx) {
              final item = kChartTimeRangePresets[idx];
              final isSelected = idx == _selectedRangeIndex;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: idx < kChartTimeRangePresets.length - 1 ? 6 : 0,
                  ),
                  child: InkWell(
                    onTap: () => _selectRange(idx),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? widget.lineColor.withOpacity(0.22)
                            : const Color(0xFF0D131F),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              isSelected ? widget.lineColor : Colors.white12,
                          width: isSelected ? 1.3 : 1.0,
                        ),
                      ),
                      child: Text(
                        item.shortLabel,
                        style: TextStyle(
                          color: isSelected ? widget.lineColor : Colors.white70,
                          fontSize: 11,
                          fontWeight:
                              isSelected ? FontWeight.w900 : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),

          const SizedBox(height: 10),

          // Píldora informativa del punto exacto inspeccionado o último valor
          _buildInspectedPointBanner(series.last.reading, timeFormatter),

          const SizedBox(height: 14),

          SizedBox(
            height: 210,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: maxXSec,
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
                      reservedSize: 44,
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
                      reservedSize: 26,
                      interval: math.max(1.0, maxXSec / 3.5),
                      getTitlesWidget: (value, meta) {
                        if (value < 0 || value > maxXSec) {
                          return const SizedBox.shrink();
                        }
                        final epochAtTick =
                            firstEpochMs + (value * 1000.0).round();
                        final dt =
                            DateTime.fromMillisecondsSinceEpoch(epochAtTick);
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            axisTimeFormatter.format(dt),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 9,
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
                                  'Umbral (${widget.thresholdY!.toInt()}${widget.unit})',
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
                      final spotIndex =
                          response.lineBarSpots!.first.spotIndex;
                      if (spotIndex >= 0 && spotIndex < series.length) {
                        setState(() {
                          _selectedReading = series[spotIndex].reading;
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
                            radius: 5,
                            color: widget.lineColor,
                            strokeWidth: 2,
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
                        final idx = barSpot.spotIndex;
                        final pt = (idx >= 0 && idx < series.length)
                            ? series[idx]
                            : series.last;
                        final reading = pt.reading;
                        final exactTime =
                            timeFormatter.format(reading.timestamp);
                        final exactVal = pt.smoothedY.toStringAsFixed(1);
                        return LineTooltipItem(
                          '$exactVal ${widget.unit}\n',
                          TextStyle(
                            color: widget.lineColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
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
                                  '⚡ ${reading.batteryVoltage.toStringAsFixed(2)}V • ${reading.status.displayName}',
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
                    curveSmoothness: 0.32,
                    preventCurveOverShooting: true,
                    color: widget.lineColor,
                    barWidth: 3.0,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          widget.gradientColor.withOpacity(0.32),
                          widget.gradientColor.withOpacity(0.02),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              duration: Duration.zero,
            ),
          ),

          const SizedBox(height: 8),

          // Deslizador suave de escala de tiempo (1m <-> 24h)
          Row(
            children: [
              const Icon(
                Icons.schedule_rounded,
                size: 15,
                color: Colors.white54,
              ),
              const SizedBox(width: 6),
              const Text(
                '1m',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: _selectedRangeIndex.toDouble(),
                    min: 0,
                    max: (kChartTimeRangePresets.length - 1).toDouble(),
                    divisions: kChartTimeRangePresets.length - 1,
                    label: preset.fullLabel,
                    activeColor: widget.lineColor,
                    inactiveColor: Colors.white12,
                    onChanged: (val) => _selectRange(val.round()),
                  ),
                ),
              ),
              const Text(
                '24h',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0D131F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              isSelected ? widget.lineColor.withOpacity(0.6) : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSelected ? Icons.touch_app : Icons.bolt,
            size: 15,
            color: widget.lineColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isSelected
                  ? 'Punto seleccionado ($timeStr):'
                  : 'Lectura actual ($timeStr):',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
          Text(
            '$val ${widget.unit}',
            style: TextStyle(
              color: widget.lineColor,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          if (isSelected) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _selectedReading = null),
              child: const Icon(Icons.close, size: 15, color: Colors.white54),
            ),
          ],
        ],
      ),
    );
  }
}

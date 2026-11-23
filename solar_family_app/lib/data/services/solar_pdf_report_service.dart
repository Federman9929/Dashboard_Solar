import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../domain/models/solar_energy_stats.dart';
import '../../domain/models/solar_reading.dart';

class _TimeSlotBucket {
  _TimeSlotBucket(this.label);

  final String label;
  double pvKwh = 0.0;
  double loadKwh = 0.0;
  double maxPvW = 0.0;
  double maxLoadW = 0.0;
  double minSoc = 100.0;
  double maxSoc = 0.0;
  bool hasSamples = false;
}

/// Genera informes PDF completos con tarjetas KPI, gráficas vectoriales y tablas
/// horarias / diarias para los periodos Día, Semana y Mes.
class SolarPdfReportService {
  static final _copFmt = NumberFormat('#,##0', 'es_CO');

  static String _fmtCop(double val) => '\$${_copFmt.format(val.round())} COP';

  static Future<File> generateAndSavePdf({
    required String periodName,
    required SolarEnergyStatsBundle stats,
    required SolarReading? currentReading,
    required String autonomyText,
    required double criticalThreshold,
    required List<SolarReading> timeline,
  }) async {
    final bytes = await buildPdfBytes(
      periodName: periodName,
      stats: stats,
      currentReading: currentReading,
      autonomyText: autonomyText,
      criticalThreshold: criticalThreshold,
      timeline: timeline,
    );
    final dir = await getTemporaryDirectory();
    final slug = periodName.toLowerCase().replaceAll('í', 'i');
    final dateTag = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final file = File('${dir.path}/Informe_Solar_${slug}_$dateTag.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<Uint8List> buildPdfBytes({
    required String periodName,
    required SolarEnergyStatsBundle stats,
    required SolarReading? currentReading,
    required String autonomyText,
    required double criticalThreshold,
    required List<SolarReading> timeline,
  }) async {
    final pdf = pw.Document(
      title: 'Informe Solar Familiar - $periodName',
      author: 'Monitor Solar Familiar',
    );

    final periodStat = switch (periodName) {
      'Día' => stats.day,
      'Semana' => stats.week,
      _ => stats.month,
    };
    final double savingsCop = periodStat.loadEnergyKwh * stats.tariffCop;
    final String generatedStr =
        DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    final bool isDay = periodName == 'Día';
    final todayReadings = _filterTodayReadings(timeline);
    final daySlots = _buildDayTimeSlots(todayReadings);
    final periodDays = _selectPeriodDays(stats.dailyBreakdown, periodName);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(26),
        footer: (ctx) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              top: pw.BorderSide(color: PdfColors.grey300, width: 0.6),
            ),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Monitor Solar Familiar | Tarifa base: ${_fmtCop(stats.tariffCop)}/kWh sobre consumo atendido',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey600,
                ),
              ),
              pw.Text(
                'Página ${ctx.pageNumber} de ${ctx.pagesCount}',
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: PdfColors.grey600,
                ),
              ),
            ],
          ),
        ),
        build: (ctx) => [
          _buildHeader(
            periodName: periodName,
            generatedStr: generatedStr,
            tariffCop: stats.tariffCop,
            startTime: periodStat.solarStartTime,
          ),
          pw.SizedBox(height: 14),
          _buildKpiRow(
            savingsCop: savingsCop,
            loadKwh: periodStat.loadEnergyKwh,
            pvKwh: periodStat.pvEnergyKwh,
            coveragePct: periodStat.solarCoveragePercent,
            currentReading: currentReading,
            autonomyText: autonomyText,
          ),
          pw.SizedBox(height: 16),
          if (isDay) ...[
            _buildSectionTitle(
              '1. Curva de Potencia: Generación Solar (W) vs Consumo Casa (W)',
            ),
            pw.SizedBox(height: 6),
            _buildDayPowerChart(todayReadings),
            pw.SizedBox(height: 14),
            _buildSectionTitle(
              '2. Evolución del Nivel de Batería (SOC %) | Umbral ${criticalThreshold.toStringAsFixed(0)}%',
            ),
            pw.SizedBox(height: 6),
            _buildDaySocChart(todayReadings, criticalThreshold),
            pw.SizedBox(height: 16),
            _buildSectionTitle('3. Desglose Detallado por Franjas Horarias (Hoy)'),
            pw.SizedBox(height: 6),
            _buildDaySlotsTable(daySlots, periodStat, stats.tariffCop),
          ] else ...[
            _buildSectionTitle(
              '1. Energía Diaria: Solar Producida vs Consumo Casa (kWh)',
            ),
            pw.SizedBox(height: 6),
            _buildMultiDayEnergyBarChart(periodDays),
            pw.SizedBox(height: 14),
            _buildSectionTitle('2. Ahorro Económico Diario (\$ COP)'),
            pw.SizedBox(height: 6),
            _buildMultiDaySavingsBarChart(periodDays),
            pw.SizedBox(height: 16),
            _buildSectionTitle('3. Tabla Comparativa Día por Día ($periodName)'),
            pw.SizedBox(height: 6),
            _buildMultiDayTable(periodDays, periodStat, stats.tariffCop),
          ],
        ],
      ),
    );

    return pdf.save();
  }

  static pw.Widget _buildHeader({
    required String periodName,
    required String generatedStr,
    required double tariffCop,
    required String startTime,
  }) {
    final startLabel = startTime.isNotEmpty ? ' | Inicio solar: $startTime' : '';
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#0F172A'),
        borderRadius: pw.BorderRadius.circular(10),
        border: pw.Border.all(color: PdfColor.fromHex('#00C853'), width: 1.2),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'INFORME DE RENDIMIENTO SOLAR',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 15,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'Monitor Solar Familiar | Generado: $generatedStr$startLabel',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#CBD5E1'),
                  fontSize: 9,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Tarifa aplicada: ${_fmtCop(tariffCop)} / kWh',
                style: pw.TextStyle(
                  color: PdfColor.fromHex('#69F0AE'),
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#00E676'),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              'PERIODO: ${periodName.toUpperCase()}',
              style: pw.TextStyle(
                color: PdfColor.fromHex('#0B101B'),
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildKpiRow({
    required double savingsCop,
    required double loadKwh,
    required double pvKwh,
    required double coveragePct,
    required SolarReading? currentReading,
    required String autonomyText,
  }) {
    final battText = currentReading != null
        ? '${currentReading.batterySoc.toStringAsFixed(1)}% (${currentReading.batteryVoltage.toStringAsFixed(1)}V)'
        : '--';
    return pw.Row(
      children: [
        pw.Expanded(
          child: _buildKpiCard(
            title: 'AHORRO ECONÓMICO',
            value: _fmtCop(savingsCop),
            subtitle: 'Sobre consumo atendido',
            accentHex: '#059669',
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: _buildKpiCard(
            title: 'CONSUMO CASA',
            value: '${loadKwh.toStringAsFixed(2)} kWh',
            subtitle: 'Cobertura: ${coveragePct.toStringAsFixed(0)}%',
            accentHex: '#0284C7',
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: _buildKpiCard(
            title: 'GENERACIÓN SOLAR',
            value: '${pvKwh.toStringAsFixed(2)} kWh',
            subtitle: 'Energía producida PV',
            accentHex: '#D97706',
          ),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: _buildKpiCard(
            title: 'BATERÍA ACTUAL',
            value: battText,
            subtitle: autonomyText,
            accentHex: '#4F46E5',
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtitle,
    required String accentHex,
  }) {
    final accent = PdfColor.fromHex(accentHex);
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#F8FAFC'),
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              color: PdfColor.fromHex('#64748B'),
              fontSize: 7.5,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            value,
            style: pw.TextStyle(
              color: accent,
              fontSize: 12.5,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            subtitle,
            style: pw.TextStyle(
              color: PdfColor.fromHex('#475569'),
              fontSize: 7.5,
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildSectionTitle(String text) {
    return pw.Text(
      text,
      style: pw.TextStyle(
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromHex('#0F172A'),
      ),
    );
  }

  static List<SolarReading> _filterTodayReadings(List<SolarReading> timeline) {
    final now = DateTime.now();
    final midnightMs =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final today = timeline.where((r) => r.epochMs >= midnightMs).toList();
    if (today.length >= 2) return today;
    return timeline;
  }

  static List<SolarReading> _downsampleReadings(
    List<SolarReading> readings,
    int maxPoints,
  ) {
    if (readings.length <= maxPoints) return readings;
    final step = readings.length / maxPoints;
    final sampled = <SolarReading>[];
    for (int i = 0; i < maxPoints; i++) {
      final idx = (i * step).floor().clamp(0, readings.length - 1);
      sampled.add(readings[idx]);
    }
    if (sampled.last.epochMs != readings.last.epochMs) {
      sampled.add(readings.last);
    }
    return sampled;
  }

  static pw.Widget _buildDayPowerChart(List<SolarReading> rawReadings) {
    final pts = _downsampleReadings(rawReadings, 80);
    if (pts.length < 2) {
      return _buildEmptyChartBox('Sin suficientes lecturas de potencia hoy');
    }

    double maxW = 500.0;
    for (final r in pts) {
      maxW = math.max(maxW, math.max(r.pvPowerW, r.loadPowerW));
    }
    maxW = (maxW / 500.0).ceil() * 500.0;

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.8),
      ),
      child: pw.Column(
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              _legendDot('#D97706', 'Solar PV (W)'),
              pw.SizedBox(width: 12),
              _legendDot('#0284C7', 'Consumo Casa (W)'),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.SizedBox(
            height: 115,
            width: double.infinity,
            child: pw.CustomPaint(
              painter: (canvas, size) {
                final leftPad = 34.0;
                final bottomPad = 14.0;
                final plotW = size.x - leftPad - 6;
                final plotH = size.y - bottomPad - 4;

                // Grilla horizontal
                canvas
                  ..setStrokeColor(PdfColor.fromHex('#E2E8F0'))
                  ..setLineWidth(0.5);
                for (int i = 0; i <= 4; i++) {
                  final y = bottomPad + (plotH * i / 4.0);
                  canvas
                    ..moveTo(leftPad, y)
                    ..lineTo(leftPad + plotW, y)
                    ..strokePath();
                }

                void drawSeries(
                  double Function(SolarReading r) selector,
                  PdfColor color,
                ) {
                  canvas
                    ..setStrokeColor(color)
                    ..setLineWidth(1.4);
                  for (int i = 0; i < pts.length; i++) {
                    final x = leftPad + (plotW * i / (pts.length - 1));
                    final y = bottomPad +
                        (selector(pts[i]).clamp(0.0, maxW) / maxW) * plotH;
                    if (i == 0) {
                      canvas.moveTo(x, y);
                    } else {
                      canvas.lineTo(x, y);
                    }
                  }
                  canvas.strokePath();
                }

                drawSeries((r) => r.loadPowerW, PdfColor.fromHex('#0284C7'));
                drawSeries((r) => r.pvPowerW, PdfColor.fromHex('#D97706'));
              },
            ),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '0 W - ${maxW.toStringAsFixed(0)} W | ${DateFormat('HH:mm').format(pts.first.timestamp)}',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.Text(
                DateFormat('HH:mm').format(pts[pts.length ~/ 2].timestamp),
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.Text(
                DateFormat('HH:mm').format(pts.last.timestamp),
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildDaySocChart(
    List<SolarReading> rawReadings,
    double threshold,
  ) {
    final pts = _downsampleReadings(rawReadings, 80);
    if (pts.length < 2) {
      return _buildEmptyChartBox('Sin suficientes lecturas de batería hoy');
    }

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.8),
      ),
      child: pw.Column(
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              _legendDot('#059669', 'Batería SOC (%)'),
              pw.SizedBox(width: 12),
              _legendDot('#DC2626', 'Umbral (${threshold.toStringAsFixed(0)}%)'),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.SizedBox(
            height: 95,
            width: double.infinity,
            child: pw.CustomPaint(
              painter: (canvas, size) {
                final leftPad = 34.0;
                final bottomPad = 10.0;
                final plotW = size.x - leftPad - 6;
                final plotH = size.y - bottomPad - 4;

                canvas
                  ..setStrokeColor(PdfColor.fromHex('#E2E8F0'))
                  ..setLineWidth(0.5);
                for (int i = 0; i <= 4; i++) {
                  final y = bottomPad + (plotH * i / 4.0);
                  canvas
                    ..moveTo(leftPad, y)
                    ..lineTo(leftPad + plotW, y)
                    ..strokePath();
                }

                // Línea umbral
                final thY = bottomPad + (threshold.clamp(0.0, 100.0) / 100.0) * plotH;
                canvas
                  ..setStrokeColor(PdfColor.fromHex('#DC2626'))
                  ..setLineWidth(0.9)
                  ..setLineDashPattern([4, 3])
                  ..moveTo(leftPad, thY)
                  ..lineTo(leftPad + plotW, thY)
                  ..strokePath()
                  ..setLineDashPattern([]);

                // Curva SOC
                canvas
                  ..setStrokeColor(PdfColor.fromHex('#059669'))
                  ..setLineWidth(1.6);
                for (int i = 0; i < pts.length; i++) {
                  final x = leftPad + (plotW * i / (pts.length - 1));
                  final y = bottomPad +
                      (pts[i].batterySoc.clamp(0.0, 100.0) / 100.0) * plotH;
                  if (i == 0) {
                    canvas.moveTo(x, y);
                  } else {
                    canvas.lineTo(x, y);
                  }
                }
                canvas.strokePath();
              },
            ),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '0% - 100% | ${DateFormat('HH:mm').format(pts.first.timestamp)}',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.Text(
                DateFormat('HH:mm').format(pts.last.timestamp),
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static List<SolarDailyStat> _selectPeriodDays(
    List<SolarDailyStat> allDays,
    String periodName,
  ) {
    if (allDays.isEmpty) return const [];
    if (periodName == 'Semana') {
      return allDays.length > 7
          ? allDays.sublist(allDays.length - 7)
          : allDays;
    }
    final monthPrefix = DateFormat('yyyy-MM').format(DateTime.now());
    final currentMonth =
        allDays.where((d) => d.dateStr.startsWith(monthPrefix)).toList();
    return currentMonth.isNotEmpty ? currentMonth : allDays;
  }

  static pw.Widget _buildMultiDayEnergyBarChart(List<SolarDailyStat> days) {
    if (days.isEmpty) {
      return _buildEmptyChartBox('Aún no hay historial diario acumulado');
    }
    double maxKwh = 2.0;
    for (final d in days) {
      maxKwh = math.max(maxKwh, math.max(d.pvEnergyKwh, d.loadEnergyKwh));
    }
    maxKwh = (maxKwh / 2.0).ceil() * 2.0;

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.8),
      ),
      child: pw.Column(
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              _legendDot('#D97706', 'Solar Producida (kWh)'),
              pw.SizedBox(width: 12),
              _legendDot('#0284C7', 'Consumo Casa (kWh)'),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.SizedBox(
            height: 115,
            width: double.infinity,
            child: pw.CustomPaint(
              painter: (canvas, size) {
                final leftPad = 24.0;
                final bottomPad = 8.0;
                final plotW = size.x - leftPad - 6;
                final plotH = size.y - bottomPad - 4;

                canvas
                  ..setStrokeColor(PdfColor.fromHex('#E2E8F0'))
                  ..setLineWidth(0.5);
                for (int i = 0; i <= 4; i++) {
                  final y = bottomPad + (plotH * i / 4.0);
                  canvas
                    ..moveTo(leftPad, y)
                    ..lineTo(leftPad + plotW, y)
                    ..strokePath();
                }

                final groupW = plotW / days.length;
                final barW = math.min(12.0, groupW * 0.34);

                for (int i = 0; i < days.length; i++) {
                  final d = days[i];
                  final cx = leftPad + (i + 0.5) * groupW;
                  final pvH = (d.pvEnergyKwh.clamp(0.0, maxKwh) / maxKwh) * plotH;
                  final loadH =
                      (d.loadEnergyKwh.clamp(0.0, maxKwh) / maxKwh) * plotH;

                  if (pvH > 0.5) {
                    canvas
                      ..setFillColor(PdfColor.fromHex('#D97706'))
                      ..drawRect(cx - barW - 1, bottomPad, barW, pvH)
                      ..fillPath();
                  }
                  if (loadH > 0.5) {
                    canvas
                      ..setFillColor(PdfColor.fromHex('#0284C7'))
                      ..drawRect(cx + 1, bottomPad, barW, loadH)
                      ..fillPath();
                  }
                }
              },
            ),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Escala: 0 - ${maxKwh.toStringAsFixed(0)} kWh',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.Text(
                '${_shortDate(days.first.dateStr)} a ${_shortDate(days.last.dateStr)} (${days.length} días)',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildMultiDaySavingsBarChart(List<SolarDailyStat> days) {
    if (days.isEmpty) {
      return _buildEmptyChartBox('Sin datos diarios de ahorro');
    }
    double maxSav = 1000.0;
    for (final d in days) {
      maxSav = math.max(maxSav, d.savingsCop);
    }

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.8),
      ),
      child: pw.Column(
        children: [
          pw.SizedBox(
            height: 85,
            width: double.infinity,
            child: pw.CustomPaint(
              painter: (canvas, size) {
                final leftPad = 24.0;
                final bottomPad = 8.0;
                final plotW = size.x - leftPad - 6;
                final plotH = size.y - bottomPad - 4;

                canvas
                  ..setStrokeColor(PdfColor.fromHex('#E2E8F0'))
                  ..setLineWidth(0.5);
                for (int i = 0; i <= 3; i++) {
                  final y = bottomPad + (plotH * i / 3.0);
                  canvas
                    ..moveTo(leftPad, y)
                    ..lineTo(leftPad + plotW, y)
                    ..strokePath();
                }

                final groupW = plotW / days.length;
                final barW = math.min(18.0, groupW * 0.55);

                for (int i = 0; i < days.length; i++) {
                  final d = days[i];
                  final cx = leftPad + (i + 0.5) * groupW;
                  final h = (d.savingsCop.clamp(0.0, maxSav) / maxSav) * plotH;
                  if (h > 0.5) {
                    canvas
                      ..setFillColor(PdfColor.fromHex('#059669'))
                      ..drawRect(cx - barW / 2, bottomPad, barW, h)
                      ..fillPath();
                  }
                }
              },
            ),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Máximo diario: ${_fmtCop(maxSav)}',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
              pw.Text(
                '${_shortDate(days.first.dateStr)} a ${_shortDate(days.last.dateStr)}',
                style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static List<_TimeSlotBucket> _buildDayTimeSlots(List<SolarReading> readings) {
    final slots = List.generate(8, (i) {
      final h1 = (i * 3).toString().padLeft(2, '0');
      final h2 = ((i + 1) * 3).toString().padLeft(2, '0');
      return _TimeSlotBucket('$h1:00-$h2:00');
    });

    for (int i = 0; i < readings.length; i++) {
      final r = readings[i];
      final slotIdx = (r.timestamp.hour ~/ 3).clamp(0, 7);
      final b = slots[slotIdx];
      b.hasSamples = true;
      b.maxPvW = math.max(b.maxPvW, r.pvPowerW);
      b.maxLoadW = math.max(b.maxLoadW, r.loadPowerW);
      if (r.batterySoc > 0) {
        b.minSoc = math.min(b.minSoc, r.batterySoc);
        b.maxSoc = math.max(b.maxSoc, r.batterySoc);
      }
      if (i > 0) {
        final prev = readings[i - 1];
        final dtS = ((r.epochMs - prev.epochMs) / 1000.0).clamp(0.0, 600.0);
        final dtH = dtS / 3600.0;
        b.pvKwh += ((prev.pvPowerW + r.pvPowerW) / 2.0) * dtH / 1000.0;
        b.loadKwh += ((prev.loadPowerW + r.loadPowerW) / 2.0) * dtH / 1000.0;
      }
    }
    return slots;
  }

  static pw.Widget _buildDaySlotsTable(
    List<_TimeSlotBucket> slots,
    SolarEnergyPeriodStats dayTotal,
    double tariffCop,
  ) {
    final rows = <List<String>>[];
    for (final s in slots) {
      if (!s.hasSamples) continue;
      final socRange = s.minSoc <= s.maxSoc
          ? '${s.minSoc.toStringAsFixed(0)}-${s.maxSoc.toStringAsFixed(0)}%'
          : '--';
      rows.add([
        s.label,
        '${s.maxPvW.toStringAsFixed(0)} W',
        '${s.maxLoadW.toStringAsFixed(0)} W',
        socRange,
        s.pvKwh.toStringAsFixed(2),
        s.loadKwh.toStringAsFixed(2),
        _fmtCop(s.loadKwh * tariffCop),
      ]);
    }
    rows.add([
      'TOTAL DÍA',
      '-',
      '-',
      '-',
      dayTotal.pvEnergyKwh.toStringAsFixed(2),
      dayTotal.loadEnergyKwh.toStringAsFixed(2),
      _fmtCop(dayTotal.loadEnergyKwh * tariffCop),
    ]);

    return pw.TableHelper.fromTextArray(
      headers: [
        'Franja',
        'Pico PV',
        'Pico Casa',
        'SOC',
        'Solar (kWh)',
        'Casa (kWh)',
        'Ahorro COP',
      ],
      data: rows,
      headerStyle: pw.TextStyle(
        fontSize: 8.5,
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
      ),
      headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#0F172A')),
      cellStyle: const pw.TextStyle(fontSize: 8),
      oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
      border: pw.TableBorder.all(color: PdfColor.fromHex('#CBD5E1'), width: 0.5),
      cellAlignment: pw.Alignment.center,
    );
  }

  static pw.Widget _buildMultiDayTable(
    List<SolarDailyStat> days,
    SolarEnergyPeriodStats totalStat,
    double tariffCop,
  ) {
    final rows = days
        .map(
          (d) => [
            _shortDate(d.dateStr),
            d.solarStartTime.isEmpty ? '-' : d.solarStartTime,
            d.pvEnergyKwh.toStringAsFixed(2),
            d.loadEnergyKwh.toStringAsFixed(2),
            '${d.solarCoveragePercent.toStringAsFixed(0)}%',
            '${d.minSoc.toStringAsFixed(0)}-${d.maxSoc.toStringAsFixed(0)}%',
            _fmtCop(d.loadEnergyKwh * tariffCop),
          ],
        )
        .toList();

    rows.add([
      'TOTAL (${days.length} d)',
      '-',
      totalStat.pvEnergyKwh.toStringAsFixed(2),
      totalStat.loadEnergyKwh.toStringAsFixed(2),
      '${totalStat.solarCoveragePercent.toStringAsFixed(0)}%',
      '-',
      _fmtCop(totalStat.loadEnergyKwh * tariffCop),
    ]);

    return pw.TableHelper.fromTextArray(
      headers: [
        'Fecha',
        'Inicio',
        'Solar (kWh)',
        'Casa (kWh)',
        'Cob. %',
        'SOC Mín-Máx',
        'Ahorro COP',
      ],
      data: rows,
      headerStyle: pw.TextStyle(
        fontSize: 8.5,
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
      ),
      headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#0F172A')),
      cellStyle: const pw.TextStyle(fontSize: 8),
      oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
      border: pw.TableBorder.all(color: PdfColor.fromHex('#CBD5E1'), width: 0.5),
      cellAlignment: pw.Alignment.center,
    );
  }

  static pw.Widget _legendDot(String hex, String label) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(
          width: 7,
          height: 7,
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex(hex),
            shape: pw.BoxShape.circle,
          ),
        ),
        pw.SizedBox(width: 4),
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 8,
            color: PdfColor.fromHex('#334155'),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildEmptyChartBox(String message) {
    return pw.Container(
      height: 60,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#F8FAFC'),
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
      ),
      child: pw.Text(
        message,
        style: pw.TextStyle(color: PdfColor.fromHex('#64748B'), fontSize: 9),
      ),
    );
  }

  static String _shortDate(String iso) {
    if (iso.length < 10) return iso;
    return '${iso.substring(8, 10)}/${iso.substring(5, 7)}';
  }
}

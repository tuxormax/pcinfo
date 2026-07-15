import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../version.dart';
import '../models/hardware.dart';
import '../services/hardware_service.dart';
import '../theme.dart';
import '../utils/format.dart';
import '../utils/report.dart';
import 'widgets/spec_card.dart';

class DashboardPage extends StatefulWidget {
  final HardwareService service;
  const DashboardPage({super.key, required this.service});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<HardwareInfo> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.service.load();
  }

  void _refresh() {
    setState(() => _future = widget.service.load());
  }

  // Estado cuando el backend no responde: NO se muestran datos de ejemplo, sino
  // un aviso claro con "Reintentar". El backend corre como servicio; si no está,
  // este mensaje evita confundir datos falsos con los del equipo.
  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.textMid, size: 48),
            const SizedBox(height: 16),
            const Text(
              'No se pudo leer el hardware',
              style: TextStyle(
                color: AppColors.textHi,
                fontSize: kFont + 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'El servicio de PCInfo no está respondiendo.\n'
              'Verifica que el servicio "PCInfoBackend" esté en ejecución.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<HardwareInfo>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              );
            }
            if (snap.hasError) {
              return _errorState();
            }
            return _content(snap.data!);
          },
        ),
      ),
      bottomNavigationBar: _footer(),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Text(
            '$appName v$appVersion Rev $appRevision',
            style: const TextStyle(
              color: AppColors.textMid,
              fontSize: kFont,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          _dot(),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              '$appCopyright  ·  $appEmail  ·  Licencia $appLicense',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLow, fontSize: kFont),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot() => Container(
        width: 4,
        height: 4,
        decoration: const BoxDecoration(
          color: AppColors.textLow,
          shape: BoxShape.circle,
        ),
      );

  Widget _content(HardwareInfo hw) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _topBar(hw),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: LayoutBuilder(
              builder: (context, c) {
                const gap = 18.0;
                // 2 columnas si hay espacio; si no, 1.
                final twoCols = c.maxWidth > 720;
                final gpuCards = _gpuCardList(hw.gpu);
                if (!twoCols) {
                  // Una sola columna: todas las fichas con el mismo gap (una por
                  // GPU intercaladas antes de Almacenamiento).
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _systemCard(hw.system),
                      const SizedBox(height: gap),
                      _cpuCard(hw.cpu),
                      const SizedBox(height: gap),
                      _boardCard(hw.board),
                      const SizedBox(height: gap),
                      _ramCard(hw.memory),
                      for (final gc in gpuCards) ...[
                        const SizedBox(height: gap),
                        gc,
                      ],
                      const SizedBox(height: gap),
                      _disksCard(hw.disks),
                    ],
                  );
                }
                // Masonry real: cada ficha se coloca en la columna más corta,
                // así no quedan huecos por diferencia de altura.
                final cards = [
                  _systemCard(hw.system),
                  _cpuCard(hw.cpu),
                  _boardCard(hw.board),
                  _ramCard(hw.memory),
                  ...gpuCards,
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MasonryGridView.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: cards.length,
                      itemBuilder: (context, i) => cards[i],
                    ),
                    const SizedBox(height: gap),
                    _disksCard(hw.disks),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _topBar(HardwareInfo hw) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 18, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_rounded, color: AppColors.accent, size: 26),
          const SizedBox(width: 10),
          const Text(
            'PCInfo',
            style: TextStyle(
              color: AppColors.textHi,
              fontSize: kFont,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              children: [
                Flexible(child: _chip(Icons.dns_rounded, hw.system.hostname)),
                const SizedBox(width: 8),
                Flexible(child: _chip(Icons.terminal_rounded, hw.system.distro)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _saveButton(hw),
          const SizedBox(width: 8),
          _refreshButton(),
        ],
      ),
    );
  }

  Widget _saveButton(HardwareInfo hw) {
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _onSave(hw),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.save_alt_rounded, size: 16, color: AppColors.textMid),
              SizedBox(width: 6),
              Text('Guardar',
                  style: TextStyle(
                      color: AppColors.textMid,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onSave(HardwareInfo hw) async {
    try {
      final path = await saveReport(hw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.surfaceAlt,
        content: Text('Reporte guardado en: $path',
            style: const TextStyle(color: AppColors.textHi, fontSize: kFont)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.surfaceAlt,
        content: Text('No se pudo guardar el reporte: $e',
            style: const TextStyle(color: Color(0xFFF2768D), fontSize: kFont)),
      ));
    }
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textMid),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style:
                    const TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
        ],
      ),
    );
  }

  Widget _refreshButton() {
    return Material(
      color: AppColors.accentDim.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: _refresh,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh_rounded, size: 16, color: AppColors.accent),
              SizedBox(width: 6),
              Text('Refrescar',
                  style: TextStyle(
                      color: AppColors.accent,
                      fontSize: kFont,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Tarjetas por categoría ----

  Widget _systemCard(SystemInfo s) {
    return SpecCard(
      icon: Icons.computer_rounded,
      accent: AppColors.system,
      title: 'Sistema operativo',
      rows: [
        SpecRow('Sistema', s.distro),
        SpecRow('Nombre del equipo', s.hostname),
        SpecRow('Kernel', s.kernel),
        SpecRow('Arquitectura', s.arch),
        if (s.desktop.isNotEmpty) SpecRow('Escritorio', s.desktop),
      ],
    );
  }

  Widget _cpuCard(CpuInfo c) {
    return SpecCard(
      icon: Icons.developer_board_rounded,
      accent: AppColors.cpu,
      title: 'Procesador (CPU)',
      rows: [
        SpecRow('Fabricante', cleanVendor(c.vendor)),
        SpecRow('Modelo', c.model),
        SpecRow('Núcleos', '${c.cores}'),
        SpecRow('Hilos', '${c.threads}'),
        SpecRow('Frecuencia base', formatMhz(c.baseMhz)),
        // La máxima (turbo) no está disponible en todas las plataformas (Windows
        // no la expone) → solo se muestra si el backend la reportó.
        if (c.maxMhz > 0) SpecRow('Frecuencia máxima', formatMhz(c.maxMhz)),
      ],
    );
  }

  Widget _boardCard(BoardInfo b) {
    return SpecCard(
      icon: Icons.dashboard_customize_rounded,
      accent: AppColors.board,
      title: 'Tarjeta madre',
      rows: [
        SpecRow('Fabricante', b.vendor),
        SpecRow('Modelo', b.product),
        // Tamaño y Versión solo si el hardware los reporta (muchas placas no
        // exponen el form factor en DMI, y algunas ponen versiones basura).
        if (b.formFactor.isNotEmpty) SpecRow('Tamaño', b.formFactor),
        if (b.version.isNotEmpty) SpecRow('Versión', b.version),
        SpecRow('BIOS', '${b.biosVendor} ${b.biosVersion}'.trim()),
        SpecRow('Fecha BIOS', b.biosDate),
      ],
    );
  }

  Widget _ramCard(MemoryInfo m) {
    final rows = <SpecRow>[
      SpecRow('Total', formatBytes(m.totalBytes)),
      SpecRow('Montaje', m.soldered ? 'Soldada (no ampliable)' : 'Ranuras (ampliable)'),
    ];
    if (m.totalSlots > 0) {
      final libres = m.freeSlots;
      rows.add(SpecRow('Ranuras',
          '${m.modules.length} de ${m.totalSlots} ocupadas'));
      rows.add(SpecRow('Ranuras libres', '$libres'));
    } else {
      rows.add(SpecRow('Módulos', '${m.modules.length}'));
    }
    if (m.maxCapacityBytes > 0) {
      rows.add(SpecRow('Capacidad máx.', formatBytes(m.maxCapacityBytes)));
    }
    return SpecCard(
      icon: Icons.memory_rounded,
      accent: AppColors.ram,
      title: 'Memoria RAM',
      rows: rows,
      footer: _slotsList(m),
    );
  }

  /// Una ficha POR tarjeta gráfica: si hay 1, 2 o N GPU, se crea una ficha por
  /// cada una (no una sola ficha con GPU 1 / GPU 2). Si no hay ninguna, una
  /// ficha de "No detectada".
  List<Widget> _gpuCardList(GpuInfo g) {
    if (g.cards.isEmpty) {
      return const [
        SpecCard(
          icon: Icons.videogame_asset_rounded,
          accent: AppColors.gpu,
          title: 'Tarjeta gráfica (GPU)',
          rows: [SpecRow('Estado', 'No detectada')],
        ),
      ];
    }
    final multi = g.cards.length > 1;
    return [
      for (final (i, card) in g.cards.indexed)
        SpecCard(
          icon: Icons.videogame_asset_rounded,
          accent: AppColors.gpu,
          // Con varias GPU se numera y se indica integrada/dedicada en el título.
          title: multi
              ? 'Tarjeta gráfica ${i + 1} · ${_gpuKind(card)}'
              : 'Tarjeta gráfica (GPU)',
          rows: [
            SpecRow('Fabricante', cleanVendor(card.vendor)),
            SpecRow('Modelo', card.product),
            SpecRow('Tipo', _gpuKind(card)),
            if (card.memoryBytes > 0)
              SpecRow('VRAM', formatBytes(card.memoryBytes)),
            SpecRow('Driver', card.driver),
          ],
        ),
    ];
  }

  /// Heurística para distinguir GPU integrada (del CPU) de dedicada. Se normaliza
  /// el modelo quitando "(tm)"/"(r)" para que "AMD Radeon(TM) Graphics" (el iGPU
  /// de los Ryzen) cuente como integrada y no como dedicada.
  String _gpuKind(GpuCard card) {
    final v = card.vendor.toLowerCase();
    final p = card.product
        .toLowerCase()
        .replaceAll('(tm)', '')
        .replaceAll('(r)', '');
    final integrada = v.contains('intel') ||
        p.contains('uhd') ||
        p.contains('iris') ||
        p.contains('vega') ||
        p.contains('radeon graphics') ||
        p.contains('raphael') ||
        p.contains('cezanne') ||
        p.contains('renoir') ||
        p.contains('phoenix') ||
        p.contains('rembrandt') ||
        p.contains('hawk point');
    return integrada ? 'Integrada' : 'Dedicada';
  }

  Widget _disksCard(List<DiskInfo> disks) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.disk.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.storage_rounded,
                    color: AppColors.disk, size: 21),
              ),
              const SizedBox(width: 12),
              const Text(
                'Almacenamiento',
                style: TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (disks.isEmpty)
            const Text('No se detectaron discos',
                style: TextStyle(color: AppColors.textMid, fontSize: kFont))
          else
            ...disks.map(_diskRow),
        ],
      ),
    );
  }

  Widget _diskRow(DiskInfo d) {
    final isSsd = d.type.toLowerCase().contains('ssd') ||
        d.bus.toLowerCase() == 'nvme';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isSsd ? Icons.bolt_rounded : Icons.album_rounded,
                  size: 20, color: AppColors.disk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.model,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textHi,
                              fontSize: kFont,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _typeBadge(d.type),
                        const SizedBox(width: 8),
                        _healthBadge(d),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${d.name}   ·   Serie: ${d.serial}   ·   Bus: ${d.bus.toUpperCase()}',
                      style: const TextStyle(
                          color: AppColors.textLow, fontSize: kFont),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                formatDiskCap(d.sizeBytes),
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (d.hasUsage) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 12),
            _diskUsage(d),
          ],
          if (d.smartAvailable) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 12),
            _diskMetrics(d),
          ],
        ],
      ),
    );
  }

  /// Uso del sistema de archivos: Capacidad / Ocupado / Disponible (GB y %)
  /// más una barra visual del porcentaje ocupado.
  Widget _diskUsage(DiskInfo d) {
    final usedPct = d.usedPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _metric('Capacidad', formatDiskCap(d.sizeBytes)),
            _metric('Ocupado',
                '${formatGB(d.usedBytes)}  (${usedPct.round()}%)'),
            _metric('Disponible',
                '${formatGB(d.availBytes)}  (${d.availPercent.round()}%)'),
          ],
        ),
        const SizedBox(height: 10),
        _usageBar(usedPct),
      ],
    );
  }

  Widget _usageBar(double usedPct) {
    final value = (usedPct / 100).clamp(0.0, 1.0);
    // Verde si hay espacio; ámbar al llenarse; rojo casi lleno.
    final color = usedPct >= 90
        ? const Color(0xFFF2768D)
        : usedPct >= 75
            ? const Color(0xFFE3A84B)
            : AppColors.disk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            backgroundColor: AppColors.bg,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text('${usedPct.round()}% usado',
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
      ],
    );
  }

  Widget _diskMetrics(DiskInfo d) {
    final items = <Widget>[];
    if (d.writtenBytes > 0) {
      items.add(_metric('Escrituras totales', formatBytes(d.writtenBytes)));
    }
    if (d.readBytes > 0) {
      items.add(_metric('Lecturas totales', formatBytes(d.readBytes)));
    }
    if (d.lifePercentUsed >= 0) {
      items.add(_metric('Vida restante', '${100 - d.lifePercentUsed}%'));
    }
    items.add(_metric('Horas encendido', '${d.powerOnHours} h'));
    items.add(_metric('Ciclos de encendido', '${d.powerCycles}'));
    items.add(_metric('Sectores reasignados', '${d.reallocatedSectors}',
        warn: d.reallocatedSectors > 0));
    return Wrap(spacing: 28, runSpacing: 12, children: items);
  }

  Widget _metric(String label, String value, {bool warn = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(color: AppColors.textLow, fontSize: kFont)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: warn ? const Color(0xFFE3A84B) : AppColors.textHi,
                fontSize: kFont,
                fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _typeBadge(String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.disk.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.disk.withValues(alpha: 0.30)),
      ),
      child: Text(type,
          style: const TextStyle(color: AppColors.disk, fontSize: kFont)),
    );
  }

  Widget _healthBadge(DiskInfo d) {
    final h = d.healthStatus;
    late final Color c;
    late final String label;
    late final IconData icon;
    switch (h) {
      case DiskHealth.good:
        c = const Color(0xFF3FB950);
        label = 'SALUDABLE';
        icon = Icons.check_circle_rounded;
        break;
      case DiskHealth.warning:
        c = const Color(0xFFE3A84B);
        label = 'ADVERTENCIA';
        icon = Icons.warning_amber_rounded;
        break;
      case DiskHealth.fail:
        c = const Color(0xFFF2768D);
        label = 'PELIGRO';
        icon = Icons.error_rounded;
        break;
      case DiskHealth.unknown:
        c = AppColors.textLow;
        label = 'SIN SMART';
        icon = Icons.help_outline_rounded;
        break;
    }
    // Si hay problemas, la etiqueta es clicable y abre el modal explicativo.
    final clickable = d.issues.isNotEmpty;
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: c, fontSize: kFont, fontWeight: FontWeight.w600)),
          if (clickable) ...[
            const SizedBox(width: 4),
            Icon(Icons.info_outline_rounded, size: 12, color: c),
          ],
        ],
      ),
    );
    if (!clickable) return badge;
    return Tooltip(
      message: 'Ver ${d.issues.length} problema(s) detectado(s)',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _showDiskIssues(d),
          child: badge,
        ),
      ),
    );
  }

  /// Modal con la lista de problemas del disco: cada uno con su severidad, qué
  /// significa y la consecuencia. Se abre al tocar la etiqueta de salud.
  void _showDiskIssues(DiskInfo d) {
    final fail = d.healthStatus == DiskHealth.fail;
    final headColor =
        fail ? const Color(0xFFF2768D) : const Color(0xFFE3A84B);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado.
              Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
                decoration: BoxDecoration(
                  color: headColor.withValues(alpha: 0.12),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                ),
                child: Row(
                  children: [
                    Icon(
                        fail
                            ? Icons.error_rounded
                            : Icons.warning_amber_rounded,
                        color: headColor,
                        size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fail
                                ? 'Disco en peligro'
                                : 'Disco con advertencias',
                            style: TextStyle(
                                color: headColor,
                                fontSize: kFont + 3,
                                fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.model,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textMid, fontSize: kFont),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: AppColors.textMid, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              // Aviso general.
              if (fail)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Text(
                    'Este disco muestra daños. NO es fiable: respalda tus datos '
                    'y considera reemplazarlo.',
                    style:
                        TextStyle(color: AppColors.textHi, fontSize: kFont),
                  ),
                ),
              // Lista de problemas.
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final iss in d.issues) _issueTile(iss),
                    ],
                  ),
                ),
              ),
              // Pie.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cerrar'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _issueTile(DiskIssue iss) {
    final danger = iss.severity == 'fail';
    final c = danger ? const Color(0xFFF2768D) : const Color(0xFFE3A84B);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
              danger
                  ? Icons.error_rounded
                  : Icons.warning_amber_rounded,
              size: 18,
              color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(iss.title,
                          style: TextStyle(
                              color: AppColors.textHi,
                              fontSize: kFont,
                              fontWeight: FontWeight.w700)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(danger ? 'PELIGRO' : 'ADVERTENCIA',
                          style: TextStyle(
                              color: c,
                              fontSize: kFont - 2,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(iss.detail,
                    style: const TextStyle(
                        color: AppColors.textMid,
                        fontSize: kFont,
                        height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Auxiliares ----

  Widget _slotsList(MemoryInfo m) {
    if (m.modules.isEmpty && m.freeSlots <= 0) return const SizedBox.shrink();
    final rows = <Widget>[];
    // Ranuras ocupadas.
    for (final mod in m.modules) {
      final ff = mod.formFactor.isEmpty ? '' : '  ·  ${mod.formFactor}';
      rows.add(_slotTile(
        icon: Icons.sd_card_rounded,
        iconColor: AppColors.ram,
        left: '${mod.location}$ff',
        right:
            '${formatBytes(mod.sizeBytes)}  ${mod.type} ${mod.speedMhz > 0 ? "${mod.speedMhz}MHz" : ""}'
                .trim(),
        rightColor: AppColors.textHi,
      ));
    }
    // Ranuras libres (placeholder por cada una).
    final libres = m.freeSlots;
    for (var i = 0; i < libres; i++) {
      rows.add(_slotTile(
        icon: Icons.crop_square_rounded,
        iconColor: AppColors.textLow,
        left: 'Ranura libre',
        right: 'Vacía',
        rightColor: AppColors.textLow,
        dimmed: true,
      ));
    }
    return Column(children: rows);
  }

  Widget _slotTile({
    required IconData icon,
    required Color iconColor,
    required String left,
    required String right,
    required Color rightColor,
    bool dimmed = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: dimmed ? AppColors.bg : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: dimmed
                ? AppColors.border.withValues(alpha: 0.5)
                : AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 9),
          Expanded(
            child: Text(left,
                style:
                    TextStyle(color: AppColors.textMid, fontSize: kFont)),
          ),
          Text(right,
              style: TextStyle(
                  color: rightColor,
                  fontSize: kFont,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../theme.dart';

/// Una fila etiqueta → valor dentro de una tarjeta.
class SpecRow {
  final String label;
  final String value;
  final bool mono; // valor en fuente monoespaciada (datos técnicos)
  const SpecRow(this.label, this.value, {this.mono = false});
}

/// Tarjeta de categoría de hardware: encabezado con icono + título y una
/// lista de filas etiqueta/valor. Acepta contenido extra (chips, módulos).
class SpecCard extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final List<SpecRow> rows;
  final Widget? footer;

  const SpecCard({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    required this.rows,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const SizedBox(height: 14),
          ...rows.map(_buildRow),
          if (footer != null) ...[
            const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: accent, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: kFont,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  height: 1.2,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      color: AppColors.textLow,
                      fontSize: kFont,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRow(SpecRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 155,
            child: Text(
              r.label,
              style: const TextStyle(color: AppColors.textMid, fontSize: kFont),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              r.value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.textHi,
                fontSize: kFont,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

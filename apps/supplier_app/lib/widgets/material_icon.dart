import 'package:flutter/material.dart';

import 'app_icon.dart';

/// Presentation only: explicit category takes precedence over the material name.
/// Unknown categories stay generic instead of guessing from a brand or model.
IconData materialIconFor({String? category, String? name}) {
  final explicit = category?.trim() ?? '';
  final source = (explicit.isNotEmpty ? explicit : name ?? '').toLowerCase();
  for (final (terms, icon) in _materialKinds) {
    if (terms.any(source.contains)) return icon;
  }
  return Icons.inventory_2_outlined;
}

// Specific equipment precedes general terms (e.g. heat pump before water pump).
const _materialKinds = <(List<String>, IconData)>[
  (['换热器', '热交换器'], Icons.heat_pump_outlined),
  (['压缩机', '空压机'], Icons.compress_outlined),
  (['水泵', '离心泵', '潜水泵', '增压泵', '计量泵', '泵类'], Icons.water_drop_outlined),
  (['阀门', '球阀', '闸阀', '蝶阀', '止回阀', '调节阀', '阀类'], Icons.tune_outlined),
  (['法兰'], Icons.trip_origin),
  (['管件', '弯头', '三通', '异径管', '管接头'], Icons.route_outlined),
  (['管道', '钢管', '水管', '塑料管', '管材'], Icons.plumbing_outlined),
  (['电机', '电动机'], Icons.electric_bolt_outlined),
  (['控制柜', '配电柜', '配电箱', '控制箱'], Icons.developer_board_outlined),
  (['电缆', '电线'], Icons.cable_outlined),
  (['仪表', '传感器', '变送器', '压力表', '流量计', '温度计'], Icons.speed_outlined),
  (['紧固件', '螺栓', '螺母', '螺钉'], Icons.hardware_outlined),
  (['轴承'], Icons.settings_input_component_outlined),
  (['钢材', '钢板', '型钢', '角钢', '槽钢'], Icons.view_agenda_outlined),
  (['储罐', '水箱', '储槽'], Icons.propane_tank_outlined),
  (['过滤器', '滤芯'], Icons.filter_alt_outlined),
  (['风机', '风扇'], Icons.air_outlined),
  (['密封件', '密封圈', '密封垫', '垫片'], Icons.layers_outlined),
];

/// Monochrome geometry inherits the same foreground in either color scheme.
class MaterialIcon extends StatelessWidget {
  const MaterialIcon({
    super.key,
    this.category,
    this.name,
    this.size = 20,
    this.color,
  });

  final String? category;
  final String? name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AppIcon(
      materialIconFor(category: category, name: name),
      size: size,
      color: color,
    ),
  );
}

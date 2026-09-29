import 'package:supplier_core/supplier_core.dart';

// The evaluation set of design §12: the requirement column of
// docs/test-doc/设备具体选型品牌型号.xlsx, labelled by hand clause by clause.

typedef Want = (String, String, Map<String, Object?>);

Want w(String p, String op, Map<String, Object?> v) => (p, op, v);
Map<String, Object?> ex(String s) =>
    parseParamText(specProperty('prot.ex')!, s)!;

final _domestic = w('gen.brand_origin', 'eq', {'v': 'domestic'});
final _ip65 = w('prot.ip', 'ip_ge', {
  'codes': ['IP65'],
});
final _exT4 = w('prot.ex', 'ex_ge', ex('Ex d IIB T4'));
final _cableControl = [
  [
    w('cable.use', 'eq', {'v': 'control'}),
    w('cable.flame', 'ge', {'v': 'ZR'}),
  ],
  <Want>[],
];
final _cablePower = [
  [
    w('cable.flame', 'ge', {'v': 'ZR'}),
  ],
  <Want>[],
];
final _auxiliary = [<Want>[], <Want>[]];
final _alarm = [
  [
    w('env.op_temp', 'covers', {'min': '-20', 'max': '40', 'u': 'Cel'}),
    w('env.op_rh', 'covers', {'min': null, 'max': '95', 'u': '%RH'}),
  ],
  [
    w('alarm.light', 'eq', {'v': 'LED'}),
    w('alarm.flash', 'eq', {'v': 'strobe'}),
  ],
  [
    w('alarm.spl', 'ge', {'v': '90', 'u': 'dB(A)'}),
    w('alarm.voice', 'is', {'v': true}),
    w('alarm.programmable', 'is', {'v': true}),
  ],
];

final sample = <(String, String, List<List<Want>>)>[
  (
    '数据分流装置',
    '要求国产品牌。直接安装在西门子PLC的DP接口方式获取数据，并通过以太网分流转发。输入接口：DB9，9.6-1.5Mbps；输出接口：RJ45，10Mbit/s。',
    [
      [_domestic],
      [],
      [],
      [
        w('gw.north_ports', 'all', {
          'vs': ['Ethernet'],
        }),
      ],
    ],
  ),
  (
    '网关',
    '要求国产品牌，工业级设计，支持7×24小时连续运行；支持Modbus TCP、OPC DA/UA、Siemens S7、TCP/UDP自定义协议、HTTP/HTTPS等协议，配套网线等设备。',
    [
      [
        _domestic,
        w('gen.industrial', 'is', {'v': true}),
      ],
      [
        w('io.protocol', 'all', {
          'vs': [
            'Modbus TCP',
            'OPC DA',
            'OPC UA',
            'Siemens S7',
            'TCP/UDP',
            'HTTP',
            'HTTPS',
          ],
        }),
      ],
    ],
  ),
  (
    '温湿度传感器',
    '具体传感器主要技术指标：\n'
        '（1）测量范围，温度-20℃~+80℃；相对湿度：0%~+100%RH。\n'
        '（2）测量精度要求：温度优于±0.3℃，相对湿度优于±3%。\n'
        '（3）分辨率：温度不低于0.1℃，相对湿度不低于0.1%。\n'
        '（4）输出信号4-20mA或RS485标准工业信号，与温湿度监控系统控制器或采集器适配。\n'
        '（5）防护等级不低于IP65。\n'
        '（6）防爆等级不低于EX d IIBT4 Gb。',
    [
      [
        w('th.temp_range', 'covers', {'min': '-20', 'max': '80', 'u': 'Cel'}),
        w('th.rh_range', 'covers', {'min': '0', 'max': '100', 'u': '%RH'}),
      ],
      [
        w('th.temp_accuracy', 'le', {'v': '0.3', 'u': 'Cel'}),
        w('th.rh_accuracy', 'le', {'v': '3', 'u': '%RH'}),
      ],
      [
        w('th.temp_resolution', 'le', {'v': '0.1', 'u': 'Cel'}),
        w('th.rh_resolution', 'le', {'v': '0.1', 'u': '%RH'}),
      ],
      [
        w('io.output', 'any', {
          'vs': ['4-20mA', 'RS485'],
        }),
      ],
      [_ip65],
      [w('prot.ex', 'ex_ge', ex('Ex d IIB T4 Gb'))],
    ],
  ),
  (
    '温湿度监测系统控制器或采集器',
    '1）通过控制器或采集器实现至少23路温湿度传感器的数据实时采集，同时具备通过的网络通讯功能，能将采集的数据实时上传至上位机软件。\n'
        '2）选用的控制器或采集器，优先选用国产品牌，配套相应的通讯线缆及配件等。\n'
        '3）现场安装满足相关标准规范。\n'
        '4）配套上位机软件。',
    [
      [
        w('gw.channels', 'ge', {'v': '23'}),
      ],
      [_domestic],
      [],
      [],
    ],
  ),
  ('控制信号链路', '控制电缆采用阻燃型控制屏蔽线；\n线缆长度约3000米（以现场实际距离为准）', _cableControl),
  ('供电链路', '电缆采用阻燃型电缆；\n线缆长度约50米（以现场实际距离为准）', _cablePower),
  ('辅材', '主要包括镀锌钢管，线槽，连接软管等。镀锌钢管厚度不小于2.5mm，长度约200米（以现场实际距离为准）。', _auxiliary),
  (
    '气体浓度检测探头（毒气）',
    '气体浓度检测探头主要技术指标：\n'
        '（1）量程：0～100ppm；\n'
        '（2）分辨率：0.1ppm；\n'
        '（3）响应时间：≤30秒；\n'
        '（4）恢复时间：≤30秒；\n'
        '（5）防护等级：IP65；\n'
        '（6）防爆等级：不低于ExdIIBT4。',
    [
      [
        w('gas.range', 'covers', {'min': '0', 'max': '100', 'u': 'ppm'}),
      ],
      [
        w('gas.resolution', 'le', {'v': '0.1', 'u': 'ppm'}),
      ],
      [
        w('gas.t90', 'le', {'v': '30', 'u': 's'}),
      ],
      [
        w('gas.recovery', 'le', {'v': '30', 'u': 's'}),
      ],
      [_ip65],
      [_exT4],
    ],
  ),
  (
    '氧浓度检测探头',
    '气体浓度检测探头主要技术指标：\n'
        '（1）量程：0～100%O2；\n'
        '（2）分辨率：0.1%O2；\n'
        '（3）测量精度：不低于±1%FS；\n'
        '（4）响应时间：≤30秒；\n'
        '（5）恢复时间：≤60秒；\n'
        '（6）防护等级：IP65；\n'
        '（7）输出和电气接口：具备标准的工业通讯接口，4-20mA或RS485；\n'
        '（8）环境适配：温度-10℃～45℃，相对湿度10%～95%，无冷凝。\n'
        '（9）防爆等级：不低于ExdIIBT4。',
    [
      [
        w('gas.range', 'covers', {'min': '0', 'max': '100', 'u': '%VOL'}),
      ],
      [
        w('gas.resolution', 'le', {'v': '0.1', 'u': '%VOL'}),
      ],
      [
        w('gas.accuracy', 'le', {'v': '1', 'basis': 'FS'}),
      ],
      [
        w('gas.t90', 'le', {'v': '30', 'u': 's'}),
      ],
      [
        w('gas.recovery', 'le', {'v': '60', 'u': 's'}),
      ],
      [_ip65],
      [
        w('io.output', 'any', {
          'vs': ['4-20mA', 'RS485'],
        }),
      ],
      [
        w('env.op_temp', 'covers', {'min': '-10', 'max': '45', 'u': 'Cel'}),
        w('env.op_rh', 'covers', {'min': '10', 'max': '95', 'u': '%RH'}),
      ],
      [_exT4],
    ],
  ),
  (
    '气体浓度监测控制系统',
    '1）控制系统核心PLC为国产自主可控产品，PLC芯片、通讯芯片、AI/AO、DI/DO等带芯片模块均采用国产芯片。\n'
        '2）系统IO控制点必须严格按要求配置，AI/AO、DI/DO控制点要求均有20%的余量，便于未来系统扩展。\n'
        '3）控制系统PLC、上位机的全套软件开发过程必须符合软件工程规范并通过第三方软件测评。\n'
        '4）配套开发PLC、上位机软件。',
    [
      [
        _domestic,
        w('plc.chips_domestic', 'is', {'v': true}),
      ],
      [],
      [],
      [],
    ],
  ),
  ('控制信号链路', '控制电缆采用阻燃型控制屏蔽线；\n线缆长度约4000米（以现场实际距离为准）', _cableControl),
  ('供电链路', '电缆采用阻燃型电缆；\n线缆长度约400米（以现场实际距离为准）', _cablePower),
  ('辅材', '主要包括镀锌钢管，线槽，连接软管等。镀锌钢管厚度不小于2.5mm，长度约400米（以现场实际距离为准）。', _auxiliary),
  (
    '声光报警器（防爆）',
    '声光报警器工作环境为-20℃-+40℃，相对湿度≤95%；光源采用LED光源，频闪发光方式；声级不小于90dB，支持多种语音播报，具备二次开发功能\n'
        '防爆等级：不低于ExdIIBT4。',
    [
      ..._alarm,
      [_exT4],
    ],
  ),
  (
    '工控机',
    'CPU：八核及以上，主频2.3GHz及以上；内存：DDR4 16GB 2666MHz及以上；显卡：独立显卡，2GB以上，不少于3路高清输出信号；《军用关键软硬件自主可控产品目录》（最新版）选取；配套正版授权操作系统，常用办公软件',
    [
      [
        w('cpu.cores', 'ge', {'v': '8'}),
        w('cpu.base_freq', 'ge', {'v': '2.3', 'u': 'GHz'}),
      ],
      [
        w('mem.type', 'ge', {'v': 'DDR4'}),
        w('mem.total', 'ge', {'v': '16', 'u': 'GiB'}),
        w('mem.speed', 'ge', {'v': '2666', 'u': 'MT/s'}),
      ],
      [
        w('gpu.discrete', 'is', {'v': true}),
        w('gpu.mem', 'ge', {'v': '2', 'u': 'GiB'}),
        w('gpu.outputs', 'ge', {'v': '3'}),
      ],
      [
        w('comp.catalog', 'listed', {
          'entries': [
            {
              'name': '军用关键软硬件自主可控产品目录',
              'batch': null,
              'level': null,
              'valid_until': null,
            },
          ],
        }),
      ],
      [
        w('sw.licensed', 'is', {'v': true}),
      ],
    ],
  ),
  (
    '显示器',
    '长宽比优先选择16:9，尺寸不小于27英寸（要求显示器与现有操作台适配），最佳固有分辨率不小于2K，响应时间小于1ms，刷新频率大于等于60HZ，内置电源，HDMI接口',
    [
      [
        w('disp.aspect', 'eq', {'v': '16:9'}),
        w('disp.size', 'ge', {'v': '27', 'u': '[in_i]'}),
        w('disp.res', 'ge', {'v': 'QHD'}),
        w('disp.response', 'lt', {'v': '1', 'u': 'ms'}),
        w('disp.refresh', 'ge', {'v': '60', 'u': 'Hz'}),
        w('disp.psu_internal', 'is', {'v': true}),
        w('disp.ports', 'all', {
          'vs': ['HDMI'],
        }),
      ],
    ],
  ),
  (
    '声光报警器',
    '声光报警器工作环境为-20℃-+40℃，相对湿度≤95%；光源采用LED光源，频闪发光方式；声级不小于90dB，支持多种语音播报，具备二次开发功能',
    _alarm,
  ),
  (
    '软件开发',
    '总体要求：软件系统采用B/S架构，整体采用分层架构+模块化设计，全面适配国产化软硬件生态环境，在国产主流浏览器上运行。\n'
        '主要功能要求：主要包括环境监测各分系统监视、综合值班显示、中央空调监控、物资出入库管理等配置项；\n'
        '分系统监视应用至少应具备：参数界面显示（工艺流程显示）、数据存储、历史数据查询、报表打印、曲线展示、报警提示、系统管理等功能；\n'
        '空调监控系统具备的功能与分系统监视功能要求一致，在此基础上增加参数设置功能，同时要求在控制操作时具备二次确认功能。\n'
        '综合值班显示至少应具备：各系统（气体监测、空调、温湿度监控等）综合态势显示、视频监控显示控制、网络通信状态监视、预警报警信息显示处理、关键数据实时曲线显示等功能；\n'
        '物资出入库管理系统至少需具备：入库管理、出库管理、库存管理、库房配置、用户管理等功能。\n'
        '主要性能要求：软件连续正常工作时间大于72h；数据据和图形显示刷新周期不大于2s；集中监控上位机在运行软件时，CPU平均占用率低于50%，内存余量不低于60%',
    [
      [
        w('sw.arch', 'eq', {'v': 'BS'}),
      ],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
      [],
    ],
  ),
];

String sampleKey(String p, String op, Map<String, Object?> v) {
  final prop = specProperty(p)!;
  return '$p $op ${normalizeParamValue(prop, v)}';
}

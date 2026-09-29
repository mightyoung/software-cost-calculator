/// Built-in parameter dictionary: typed properties and class templates for
/// the equipment the team buys. Structure follows IEC 61360 / ECLASS / ETIM
/// (see docs/design/2026-09-29-spec-matching-design.md). Codes never change
/// once released; team-defined codes start with "x.".
library;

/// Bumped whenever built-in properties or classes change.
const specDictionaryVersion = 1;

/// ETIM value types (A alphanumeric, L logical, N numeric, R range) plus
/// tolerance, multi-select, free text and three compound values.
enum ParamType {
  num,
  range,
  tol,
  enumOne,
  enumMany,
  bool,
  text,
  ip,
  ex,
  catalog,
}

/// Which way is better. Accuracy and response time are [lower]; "不低于" on
/// such a property means "no worse than", i.e. ≤.
enum Order { higher, lower, none }

class EnumValue {
  const EnumValue(this.code, this.label, {this.aliases = const [], this.rank});
  final String code, label;
  final List<String> aliases;

  /// Position in an ordered list (DDR3 < DDR4 < DDR5); null when unordered.
  final int? rank;
}

class SpecProperty {
  const SpecProperty(
    this.code,
    this.label,
    this.type, {
    this.aliases = const [],
    this.kind,
    this.unit,
    this.unitLabel,
    this.order = Order.none,
    this.values = const [],
    this.restrictive = false,
    this.help,
  });
  final String code, label;
  final ParamType type;
  final List<String> aliases;

  /// Quantity kind code ([quantityKinds]) for num / range / tol with units.
  final String? kind;

  /// Default unit code within [kind].
  final String? unit;

  /// Display word for counted things without a unit ("核", "路").
  final String? unitLabel;
  final Order order;
  final List<EnumValue> values;

  /// Only listed values allowed (ECLASS restrictive value list).
  final bool restrictive;
  final String? help;

  bool get ordered => values.any((v) => v.rank != null);

  EnumValue? value(String code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

class ClassParam {
  const ClassParam(this.property, {this.key = false});
  final String property;

  /// Key parameter: counts toward completeness (ISO 22745 identification
  /// guide).
  final bool key;
}

class ParamBlock {
  const ParamBlock(this.label, this.params);
  final String label;
  final List<ClassParam> params;
}

class SpecClass {
  const SpecClass(
    this.code,
    this.label, {
    this.aliases = const [],
    this.parent,
    this.blocks = const [],
    this.refs = const {},
    this.help,
  });
  final String code, label;

  /// Synonyms used to recognize the class from names (ETIM synonyms).
  final List<String> aliases;
  final String? parent;
  final List<ParamBlock> blocks;

  /// Optional references to public classifications, e.g. {'etim': 'EC010378'}.
  final Map<String, String> refs;
  final String? help;
}

// ---------------------------------------------------------------- values --

const _origin = [
  EnumValue('domestic', '国产', aliases: ['国内', '国产品牌', '自主品牌']),
  EnumValue('joint', '合资'),
  EnumValue('imported', '进口', aliases: ['国外', '进口品牌', '外资']),
];

const _signals = [
  EnumValue(
    '4-20mA',
    '4-20mA',
    aliases: ['4~20mA', '4～20mA', '4-20ma', '4至20mA'],
  ),
  EnumValue('0-10V', '0-10V', aliases: ['0~10V', '0～10V']),
  EnumValue('0-5V', '0-5V', aliases: ['0~5V', '0～5V']),
  EnumValue('RS485', 'RS485', aliases: ['RS-485', '485', 'EIA-485']),
  EnumValue('RS232', 'RS232', aliases: ['RS-232', '232']),
  EnumValue('CAN', 'CAN', aliases: ['CAN总线', 'CANbus']),
  EnumValue(
    'PROFIBUS-DP',
    'PROFIBUS-DP',
    aliases: ['DP', 'Profibus', 'PROFIBUS'],
  ),
  EnumValue('Ethernet', '以太网', aliases: ['RJ45', '网口', '以太网口', 'LAN']),
  EnumValue('fiber', '光口', aliases: ['光纤', 'SFP']),
  EnumValue('4G', '4G', aliases: ['LTE', '4G全网通']),
  EnumValue('5G', '5G'),
  EnumValue('WiFi', 'WiFi', aliases: ['Wi-Fi', 'WLAN', '无线局域网']),
  EnumValue('LoRa', 'LoRa'),
  EnumValue('relay', '继电器', aliases: ['继电器输出', '开关量']),
];

const _protocols = [
  EnumValue('Modbus RTU', 'Modbus RTU', aliases: ['ModbusRTU', 'Modbus-RTU']),
  EnumValue('Modbus TCP', 'Modbus TCP', aliases: ['ModbusTCP', 'Modbus-TCP']),
  EnumValue('OPC UA', 'OPC UA', aliases: ['OPCUA', 'OPC-UA']),
  EnumValue('OPC DA', 'OPC DA', aliases: ['OPCDA', 'OPC-DA']),
  EnumValue('MQTT', 'MQTT'),
  EnumValue('HTTP', 'HTTP'),
  EnumValue('HTTPS', 'HTTPS'),
  EnumValue('Siemens S7', 'Siemens S7', aliases: ['S7', '西门子S7', 'S7协议']),
  EnumValue('PROFINET', 'PROFINET', aliases: ['Profinet']),
  EnumValue('BACnet', 'BACnet'),
  EnumValue('SNMP', 'SNMP'),
  EnumValue('TCP/UDP', 'TCP/UDP 自定义', aliases: ['TCP', 'UDP', 'TCP/UDP']),
  EnumValue('IEC 104', 'IEC 60870-5-104', aliases: ['104规约', 'IEC104']),
];

const _videoPorts = [
  EnumValue('HDMI', 'HDMI'),
  EnumValue('DP', 'DisplayPort', aliases: ['DisplayPort', 'DP口']),
  EnumValue('VGA', 'VGA'),
  EnumValue('DVI', 'DVI'),
  EnumValue('USB-C', 'USB-C', aliases: ['Type-C', 'TypeC']),
];

const _power = [
  EnumValue('AC220V', 'AC 220V', aliases: ['220V', 'AC220', '交流220V', '市电']),
  EnumValue('DC24V', 'DC 24V', aliases: ['24V', 'DC24', '直流24V', '24VDC']),
  EnumValue('DC12V', 'DC 12V', aliases: ['12V', 'DC12', '直流12V', '12VDC']),
  EnumValue('PoE', 'PoE', aliases: ['POE']),
  EnumValue('battery', '电池', aliases: ['锂电池', '电池供电']),
];

const _shield = [
  EnumValue('none', '无屏蔽'),
  EnumValue('P', '铜丝编织屏蔽', aliases: ['编织屏蔽']),
  EnumValue('P2', '铜带屏蔽'),
  EnumValue('P3', '铝塑复合带屏蔽', aliases: ['铝箔屏蔽']),
];

const _insulation = [
  EnumValue('V', '聚氯乙烯', aliases: ['PVC']),
  EnumValue('YJ', '交联聚乙烯', aliases: ['XLPE']),
  EnumValue('Y', '聚乙烯', aliases: ['PE']),
  EnumValue('X', '橡胶'),
  EnumValue('F', '氟塑料'),
];

// ------------------------------------------------------------ properties --

const specProperties = <SpecProperty>[
  // General, shared by many classes.
  SpecProperty(
    'gen.brand_origin',
    '品牌属地',
    ParamType.enumOne,
    aliases: ['国产品牌', '品牌'],
    values: _origin,
    restrictive: true,
    help: '对应"要求国产品牌"',
  ),
  SpecProperty(
    'gen.industrial',
    '工业级',
    ParamType.bool,
    aliases: ['工业级设计', '7×24小时', '连续运行'],
  ),
  SpecProperty(
    'env.op_temp',
    '工作温度',
    ParamType.range,
    aliases: ['工作环境温度', '使用温度', '环境温度', '工作环境'],
    kind: 'temperature',
    unit: 'Cel',
  ),
  SpecProperty(
    'env.op_rh',
    '工作湿度',
    ParamType.range,
    aliases: ['工作环境湿度', '相对湿度', '环境湿度'],
    kind: 'humidity',
    unit: '%RH',
  ),
  SpecProperty(
    'prot.ip',
    '防护等级',
    ParamType.ip,
    aliases: ['IP等级', '外壳防护等级', 'IP防护等级', '防护'],
    order: Order.higher,
  ),
  SpecProperty(
    'prot.ex',
    '防爆标志',
    ParamType.ex,
    aliases: ['防爆等级', '防爆标识', '防爆', '防爆型式'],
    order: Order.higher,
  ),
  SpecProperty(
    'comp.catalog',
    '目录收录',
    ParamType.catalog,
    aliases: ['自主可控', '安全可靠', '信创', '产品目录', '入围目录'],
    help: '目录名、批次、等级、有效期；不同目录不能互相替代',
  ),
  SpecProperty(
    'pwr.supply',
    '供电',
    ParamType.enumMany,
    aliases: ['电源', '供电方式', '工作电压'],
    values: _power,
  ),

  // Computer: processor.
  SpecProperty(
    'cpu.arch',
    '指令集架构',
    ParamType.enumOne,
    aliases: ['架构', 'CPU架构', '处理器架构'],
    restrictive: true,
    values: [
      EnumValue('x86-64', 'x86-64', aliases: ['x86', 'X86', 'x86_64', 'AMD64']),
      EnumValue('ARM64', 'ARM64', aliases: ['ARM', 'arm', 'aarch64', 'ARMv8']),
      EnumValue('LoongArch', 'LoongArch', aliases: ['龙架构', 'loongarch']),
      EnumValue('SW64', 'SW64', aliases: ['申威架构', 'sw64']),
      EnumValue('MIPS', 'MIPS', aliases: ['mips']),
    ],
  ),
  SpecProperty(
    'cpu.vendor',
    '处理器厂商',
    ParamType.enumOne,
    aliases: ['CPU品牌', '处理器品牌'],
    values: [
      EnumValue('hygon', '海光', aliases: ['Hygon']),
      EnumValue('zhaoxin', '兆芯', aliases: ['Zhaoxin']),
      EnumValue('kunpeng', '鲲鹏', aliases: ['华为鲲鹏', 'Kunpeng']),
      EnumValue('phytium', '飞腾', aliases: ['Phytium']),
      EnumValue('loongson', '龙芯', aliases: ['Loongson']),
      EnumValue('sunway', '申威', aliases: ['Sunway']),
      EnumValue('intel', 'Intel', aliases: ['英特尔']),
      EnumValue('amd', 'AMD'),
    ],
  ),
  SpecProperty('cpu.model', '处理器型号', ParamType.text, aliases: ['CPU型号']),
  SpecProperty(
    'cpu.sockets',
    '处理器路数',
    ParamType.num,
    aliases: ['CPU数量', '路数'],
    unitLabel: '路',
    order: Order.higher,
  ),
  SpecProperty(
    'cpu.cores',
    '物理核数',
    ParamType.num,
    aliases: ['核数', '核心数', '物理核', 'CPU核数'],
    unitLabel: '核',
    order: Order.higher,
    help: '每颗处理器的物理核数；"八核"即 8',
  ),
  SpecProperty(
    'cpu.threads',
    '线程数',
    ParamType.num,
    aliases: ['线程'],
    unitLabel: '线程',
    order: Order.higher,
  ),
  SpecProperty(
    'cpu.base_freq',
    '基础主频',
    ParamType.num,
    aliases: ['主频', 'CPU主频', '基频', '基础频率'],
    kind: 'frequency',
    unit: 'GHz',
    order: Order.higher,
    help: '要求只写"主频"时默认指基础主频',
  ),
  SpecProperty(
    'cpu.boost_freq',
    '最高睿频',
    ParamType.num,
    aliases: ['睿频', '最大频率', '加速频率'],
    kind: 'frequency',
    unit: 'GHz',
    order: Order.higher,
  ),

  // Computer: memory, storage, graphics, network, chassis, software.
  SpecProperty(
    'mem.type',
    '内存类型',
    ParamType.enumOne,
    aliases: ['内存规格'],
    order: Order.higher,
    restrictive: true,
    values: [
      EnumValue('DDR3', 'DDR3', aliases: ['ddr3'], rank: 3),
      EnumValue('DDR4', 'DDR4', aliases: ['ddr4'], rank: 4),
      EnumValue('DDR5', 'DDR5', aliases: ['ddr5'], rank: 5),
    ],
    help: '代际不同的内存不一定兼容，较新一代判为"待确认"',
  ),
  SpecProperty(
    'mem.speed',
    '内存频率',
    ParamType.num,
    aliases: ['内存速率'],
    kind: 'transfer_rate',
    unit: 'MT/s',
    order: Order.higher,
  ),
  SpecProperty(
    'mem.total',
    '内存总容量',
    ParamType.num,
    aliases: ['内存', '内存容量', '配置内存'],
    kind: 'mem_capacity',
    unit: 'GiB',
    order: Order.higher,
  ),
  SpecProperty(
    'mem.dimm_size',
    '单条内存容量',
    ParamType.num,
    aliases: ['单条容量'],
    kind: 'mem_capacity',
    unit: 'GiB',
    order: Order.higher,
  ),
  SpecProperty(
    'mem.dimm_count',
    '内存条数',
    ParamType.num,
    aliases: ['条数'],
    unitLabel: '条',
    order: Order.higher,
  ),
  SpecProperty(
    'mem.max',
    '最大支持内存',
    ParamType.num,
    aliases: ['最大内存', '最大扩展'],
    kind: 'mem_capacity',
    unit: 'GiB',
    order: Order.higher,
  ),
  SpecProperty(
    'mem.slots',
    '内存插槽数',
    ParamType.num,
    aliases: ['内存插槽'],
    unitLabel: '个',
    order: Order.higher,
  ),
  SpecProperty(
    'disk.total',
    '硬盘总容量',
    ParamType.num,
    aliases: ['硬盘', '硬盘容量', '存储容量'],
    kind: 'disk_capacity',
    unit: 'GB',
    order: Order.higher,
  ),
  SpecProperty(
    'disk.type',
    '硬盘类型',
    ParamType.enumMany,
    values: [
      EnumValue('SSD', 'SSD', aliases: ['固态', '固态硬盘']),
      EnumValue('HDD', 'HDD', aliases: ['机械', '机械硬盘']),
      EnumValue('NVMe', 'NVMe', aliases: ['nvme', 'M.2 NVMe']),
    ],
  ),
  SpecProperty(
    'disk.bays',
    '硬盘位',
    ParamType.num,
    aliases: ['盘位'],
    unitLabel: '个',
    order: Order.higher,
  ),
  SpecProperty(
    'disk.raid',
    'RAID 级别',
    ParamType.enumMany,
    aliases: ['RAID'],
    values: [
      EnumValue('0', 'RAID 0', aliases: ['RAID0']),
      EnumValue('1', 'RAID 1', aliases: ['RAID1']),
      EnumValue('5', 'RAID 5', aliases: ['RAID5']),
      EnumValue('6', 'RAID 6', aliases: ['RAID6']),
      EnumValue('10', 'RAID 10', aliases: ['RAID10', 'RAID1+0']),
    ],
  ),
  SpecProperty('gpu.discrete', '独立显卡', ParamType.bool, aliases: ['独显']),
  SpecProperty(
    'gpu.mem',
    '显存',
    ParamType.num,
    aliases: ['显卡显存', '显存容量'],
    kind: 'mem_capacity',
    unit: 'GiB',
    order: Order.higher,
  ),
  SpecProperty(
    'gpu.outputs',
    '显示输出路数',
    ParamType.num,
    aliases: ['输出路数', '高清输出', '显示输出'],
    unitLabel: '路',
    order: Order.higher,
  ),
  SpecProperty(
    'gpu.ports',
    '显示接口',
    ParamType.enumMany,
    aliases: ['视频接口'],
    values: _videoPorts,
  ),
  SpecProperty(
    'nic.ports',
    '网口数',
    ParamType.num,
    aliases: ['网口', '网卡数量'],
    unitLabel: '口',
    order: Order.higher,
  ),
  SpecProperty(
    'nic.speed',
    '网口速率',
    ParamType.num,
    aliases: ['网卡速率', '网络速率'],
    kind: 'data_rate',
    unit: 'Gbit/s',
    order: Order.higher,
  ),
  SpecProperty('psu.redundant', '冗余电源', ParamType.bool, aliases: ['双电源']),
  SpecProperty(
    'form.factor',
    '形态',
    ParamType.enumOne,
    aliases: ['机箱', '外形', '规格形态'],
    values: [
      EnumValue('tower', '塔式'),
      EnumValue('1U', '1U 机架式', aliases: ['1U']),
      EnumValue('2U', '2U 机架式', aliases: ['2U']),
      EnumValue('4U', '4U 机架式', aliases: ['4U']),
      EnumValue('wall', '壁挂式', aliases: ['壁挂']),
      EnumValue('embedded', '嵌入式'),
      EnumValue('desktop', '台式'),
      EnumValue('aio', '一体机'),
    ],
  ),
  SpecProperty(
    'os.name',
    '操作系统',
    ParamType.enumOne,
    aliases: ['预装系统', 'OS'],
    values: [
      EnumValue('kylin', '银河麒麟', aliases: ['麒麟', 'Kylin']),
      EnumValue('uos', '统信 UOS', aliases: ['统信', 'UOS']),
      EnumValue('nfs', '中科方德', aliases: ['方德']),
      EnumValue('openeuler', 'openEuler', aliases: ['欧拉']),
      EnumValue('windows', 'Windows'),
      EnumValue('linux', '其他 Linux', aliases: ['Linux']),
    ],
  ),
  SpecProperty('sw.licensed', '正版授权', ParamType.bool, aliases: ['正版', '授权']),

  // Display.
  SpecProperty(
    'disp.size',
    '屏幕尺寸',
    ParamType.num,
    aliases: ['尺寸', '屏幕'],
    kind: 'display_size',
    unit: '[in_i]',
    order: Order.higher,
  ),
  SpecProperty(
    'disp.aspect',
    '长宽比',
    ParamType.enumOne,
    aliases: ['屏幕比例', '宽高比'],
    values: [
      EnumValue('16:9', '16:9'),
      EnumValue('16:10', '16:10'),
      EnumValue('21:9', '21:9'),
      EnumValue('4:3', '4:3'),
    ],
  ),
  SpecProperty(
    'disp.res',
    '分辨率',
    ParamType.enumOne,
    aliases: ['固有分辨率', '最佳分辨率', '显示分辨率'],
    restrictive: true,
    order: Order.higher,
    values: [
      EnumValue(
        'HD',
        'HD 1280×720',
        aliases: ['720P', '1280×720', '1280x720'],
        rank: 1,
      ),
      EnumValue(
        'FHD',
        'FHD 1920×1080',
        aliases: ['1080P', '全高清', '1920×1080', '1920x1080'],
        rank: 2,
      ),
      EnumValue(
        'QHD',
        'QHD 2560×1440',
        aliases: ['1440P', '2560×1440', '2560x1440'],
        rank: 3,
      ),
      EnumValue(
        '4K',
        '4K 3840×2160',
        aliases: ['UHD', '3840×2160', '3840x2160'],
        rank: 4,
      ),
    ],
    help: '"2K"可能指 1920×1080 或 2560×1440，请写具体像素',
  ),
  SpecProperty(
    'disp.refresh',
    '刷新率',
    ParamType.num,
    aliases: ['刷新频率'],
    kind: 'frequency',
    unit: 'Hz',
    order: Order.higher,
  ),
  SpecProperty(
    'disp.response',
    '响应时间',
    ParamType.num,
    aliases: ['灰阶响应'],
    kind: 'time',
    unit: 'ms',
    order: Order.lower,
  ),
  SpecProperty(
    'disp.ports',
    '显示器接口',
    ParamType.enumMany,
    aliases: ['接口'],
    values: _videoPorts,
  ),
  SpecProperty('disp.psu_internal', '内置电源', ParamType.bool),

  // Temperature / humidity sensors.
  SpecProperty(
    'th.temp_range',
    '温度测量范围',
    ParamType.range,
    aliases: ['温度范围', '温度量程', '测量范围'],
    kind: 'temperature',
    unit: 'Cel',
  ),
  SpecProperty(
    'th.rh_range',
    '湿度测量范围',
    ParamType.range,
    aliases: ['湿度范围', '湿度量程'],
    kind: 'humidity',
    unit: '%RH',
  ),
  SpecProperty(
    'th.temp_accuracy',
    '温度精度',
    ParamType.tol,
    aliases: ['温度测量精度', '测温精度'],
    kind: 'temp_diff',
    unit: 'Cel',
    order: Order.lower,
  ),
  SpecProperty(
    'th.rh_accuracy',
    '湿度精度',
    ParamType.tol,
    aliases: ['湿度测量精度'],
    kind: 'humidity',
    unit: '%RH',
    order: Order.lower,
  ),
  SpecProperty(
    'th.temp_resolution',
    '温度分辨率',
    ParamType.num,
    aliases: ['温度分辨力'],
    kind: 'temp_diff',
    unit: 'Cel',
    order: Order.lower,
    help: '越小越好；"不低于 0.1℃"即 ≤ 0.1℃',
  ),
  SpecProperty(
    'th.rh_resolution',
    '湿度分辨率',
    ParamType.num,
    aliases: ['湿度分辨力'],
    kind: 'humidity',
    unit: '%RH',
    order: Order.lower,
  ),

  // Signals and protocols.
  SpecProperty(
    'io.output',
    '输出信号',
    ParamType.enumMany,
    aliases: ['输出', '通信接口', '信号输出', '接口'],
    values: _signals,
  ),
  SpecProperty(
    'io.protocol',
    '通信协议',
    ParamType.enumMany,
    aliases: ['协议', '支持协议'],
    values: _protocols,
  ),

  // Gas detectors.
  SpecProperty(
    'gas.target',
    '检测气体',
    ParamType.enumMany,
    aliases: ['检测对象', '气体种类', '监测气体'],
    values: [
      EnumValue('O2', '氧气', aliases: ['氧', 'O₂', '氧浓度']),
      EnumValue('CO', '一氧化碳'),
      EnumValue('CO2', '二氧化碳', aliases: ['CO₂']),
      EnumValue('H2S', '硫化氢', aliases: ['H₂S']),
      EnumValue('CH4', '甲烷', aliases: ['CH₄']),
      EnumValue('EX', '可燃气体', aliases: ['可燃', '可燃性气体']),
      EnumValue('NH3', '氨气', aliases: ['氨', 'NH₃']),
      EnumValue('Cl2', '氯气', aliases: ['Cl₂']),
      EnumValue('NO2', '二氧化氮', aliases: ['NO₂']),
      EnumValue('SO2', '二氧化硫', aliases: ['SO₂']),
      EnumValue('H2', '氢气', aliases: ['H₂']),
      EnumValue('UDMH', '偏二甲肼', aliases: ['C2H8N2', '燃烧剂']),
      EnumValue('N2O4', '四氧化二氮', aliases: ['氧化剂']),
    ],
  ),
  SpecProperty(
    'gas.principle',
    '检测原理',
    ParamType.enumOne,
    aliases: ['原理', '传感器类型'],
    values: [
      EnumValue('electrochemical', '电化学'),
      EnumValue('catalytic', '催化燃烧'),
      EnumValue('infrared', '红外', aliases: ['NDIR', '非分散红外']),
      EnumValue('pid', 'PID 光离子化', aliases: ['PID', '光离子化']),
      EnumValue('semiconductor', '半导体'),
      EnumValue('thermal', '热导'),
    ],
  ),
  SpecProperty(
    'gas.range',
    '量程',
    ParamType.range,
    aliases: ['测量范围', '检测范围', '测量量程'],
    kind: 'gas_concentration',
    unit: 'ppm',
  ),
  SpecProperty(
    'gas.resolution',
    '分辨率',
    ParamType.num,
    aliases: ['分辨力'],
    kind: 'gas_concentration',
    unit: 'ppm',
    order: Order.lower,
  ),
  SpecProperty(
    'gas.accuracy',
    '精度',
    ParamType.tol,
    aliases: ['测量精度', '示值误差'],
    kind: 'gas_concentration',
    unit: 'ppm',
    order: Order.lower,
  ),
  SpecProperty(
    'gas.t90',
    '响应时间',
    ParamType.num,
    aliases: ['T90', '响应时间T90'],
    kind: 'time',
    unit: 's',
    order: Order.lower,
  ),
  SpecProperty(
    'gas.recovery',
    '恢复时间',
    ParamType.num,
    kind: 'time',
    unit: 's',
    order: Order.lower,
  ),

  // Gateways and data collectors.
  SpecProperty(
    'gw.south_ports',
    '下行接口',
    ParamType.enumMany,
    aliases: ['采集接口', '输入接口', '现场接口'],
    values: _signals,
  ),
  SpecProperty(
    'gw.north_ports',
    '上行接口',
    ParamType.enumMany,
    aliases: ['输出接口', '上传接口'],
    values: _signals,
  ),
  SpecProperty(
    'gw.channels',
    '采集通道数',
    ParamType.num,
    aliases: ['通道数', '采集点数', '路数'],
    unitLabel: '路',
    order: Order.higher,
  ),
  SpecProperty(
    'gw.baud',
    '串口速率范围',
    ParamType.range,
    aliases: ['波特率', '通信速率'],
    kind: 'data_rate',
    unit: 'bit/s',
  ),

  // PLC.
  SpecProperty(
    'plc.di',
    '数字量输入点数',
    ParamType.num,
    aliases: ['DI', 'DI点数'],
    unitLabel: '点',
    order: Order.higher,
  ),
  SpecProperty(
    'plc.do',
    '数字量输出点数',
    ParamType.num,
    aliases: ['DO', 'DO点数'],
    unitLabel: '点',
    order: Order.higher,
  ),
  SpecProperty(
    'plc.ai',
    '模拟量输入点数',
    ParamType.num,
    aliases: ['AI', 'AI点数'],
    unitLabel: '点',
    order: Order.higher,
  ),
  SpecProperty(
    'plc.ao',
    '模拟量输出点数',
    ParamType.num,
    aliases: ['AO', 'AO点数'],
    unitLabel: '点',
    order: Order.higher,
  ),
  SpecProperty(
    'plc.chips_domestic',
    '主要芯片国产',
    ParamType.bool,
    aliases: ['国产芯片'],
  ),

  // Audible and visual alarms.
  SpecProperty(
    'alarm.spl',
    '声级',
    ParamType.num,
    aliases: ['声压级', '报警音量', '声强'],
    kind: 'sound_level',
    unit: 'dB(A)',
    order: Order.higher,
  ),
  SpecProperty(
    'alarm.light',
    '光源',
    ParamType.enumOne,
    values: [
      EnumValue('LED', 'LED'),
      EnumValue('xenon', '氙灯', aliases: ['氙气灯']),
      EnumValue('halogen', '卤素灯'),
    ],
  ),
  SpecProperty(
    'alarm.flash',
    '发光方式',
    ParamType.enumOne,
    values: [
      EnumValue('strobe', '频闪', aliases: ['闪光']),
      EnumValue('steady', '常亮'),
      EnumValue('rotating', '旋转'),
    ],
  ),
  SpecProperty('alarm.voice', '语音播报', ParamType.bool, aliases: ['语音']),
  SpecProperty(
    'alarm.programmable',
    '支持二次开发',
    ParamType.bool,
    aliases: ['二次开发'],
  ),

  // Cables.
  SpecProperty(
    'cable.use',
    '电缆用途',
    ParamType.enumOne,
    values: [
      EnumValue('control', '控制电缆', aliases: ['控制']),
      EnumValue('power', '电力电缆', aliases: ['电力', '动力电缆']),
      EnumValue('signal', '信号电缆', aliases: ['信号']),
      EnumValue('computer', '计算机电缆', aliases: ['DJ', '计算机']),
      EnumValue('flexible', '软电缆', aliases: ['软线', '护套软线']),
    ],
  ),
  SpecProperty(
    'cable.cores',
    '芯数',
    ParamType.num,
    unitLabel: '芯',
    order: Order.none,
  ),
  SpecProperty(
    'cable.csa',
    '截面',
    ParamType.num,
    aliases: ['截面积', '线径', '导体截面'],
    kind: 'cross_section',
    unit: 'mm2',
    order: Order.higher,
  ),
  SpecProperty(
    'cable.conductor',
    '导体',
    ParamType.enumOne,
    values: [
      EnumValue('Cu', '铜', aliases: ['铜芯', '铜导体']),
      EnumValue('Al', '铝', aliases: ['铝芯']),
    ],
  ),
  SpecProperty(
    'cable.insulation',
    '绝缘',
    ParamType.enumOne,
    values: _insulation,
  ),
  SpecProperty('cable.sheath', '护套', ParamType.enumOne, values: _insulation),
  SpecProperty('cable.shield', '屏蔽', ParamType.enumOne, values: _shield),
  SpecProperty(
    'cable.flame',
    '阻燃等级',
    ParamType.enumOne,
    order: Order.higher,
    restrictive: true,
    values: [
      EnumValue('none', '非阻燃', rank: 0),
      EnumValue('ZR', 'ZR 阻燃（旧标）', aliases: ['阻燃'], rank: 1),
      EnumValue('ZC', 'ZC', aliases: ['阻燃C类', 'C类'], rank: 1),
      EnumValue('ZB', 'ZB', aliases: ['阻燃B类', 'B类'], rank: 2),
      EnumValue('ZA', 'ZA', aliases: ['阻燃A类', 'A类'], rank: 3),
    ],
    help: 'GB/T 19666；ZR 为旧写法，按 C 类对待',
  ),
  SpecProperty(
    'cable.fire_resistant',
    '耐火',
    ParamType.bool,
    aliases: ['NH', '耐火电缆'],
  ),

  // Software services.
  SpecProperty(
    'sw.arch',
    '软件架构',
    ParamType.enumOne,
    values: [
      EnumValue('BS', 'B/S', aliases: ['B/S架构', 'BS']),
      EnumValue('CS', 'C/S', aliases: ['C/S架构', 'CS']),
    ],
  ),
  SpecProperty(
    'sw.third_party_test',
    '含第三方测评',
    ParamType.bool,
    aliases: ['第三方测评', '软件测评'],
  ),
];

// --------------------------------------------------------------- classes --

const _environment = ParamBlock('环境与防护', [
  ClassParam('env.op_temp'),
  ClassParam('env.op_rh'),
  ClassParam('prot.ip'),
  ClassParam('prot.ex'),
]);

const specClasses = <SpecClass>[
  SpecClass(
    'computer',
    '计算机',
    aliases: ['计算机', '主机', '电脑'],
    blocks: [
      ParamBlock('处理器', [
        ClassParam('cpu.arch', key: true),
        ClassParam('cpu.vendor'),
        ClassParam('cpu.model'),
        ClassParam('cpu.cores', key: true),
        ClassParam('cpu.threads'),
        ClassParam('cpu.base_freq', key: true),
        ClassParam('cpu.boost_freq'),
      ]),
      ParamBlock('内存', [
        ClassParam('mem.type', key: true),
        ClassParam('mem.total', key: true),
        ClassParam('mem.speed'),
        ClassParam('mem.dimm_size'),
        ClassParam('mem.dimm_count'),
        ClassParam('mem.max'),
      ]),
      ParamBlock('存储', [
        ClassParam('disk.total', key: true),
        ClassParam('disk.type'),
      ]),
      ParamBlock('图形与显示', [
        ClassParam('gpu.discrete'),
        ClassParam('gpu.mem'),
        ClassParam('gpu.outputs'),
        ClassParam('gpu.ports'),
      ]),
      ParamBlock('网络', [ClassParam('nic.ports'), ClassParam('nic.speed')]),
      ParamBlock('软件与合规', [
        ClassParam('os.name'),
        ClassParam('sw.licensed'),
        ClassParam('comp.catalog'),
        ClassParam('gen.brand_origin'),
      ]),
    ],
  ),
  SpecClass(
    'computer.server',
    '服务器',
    parent: 'computer',
    aliases: ['服务器', '机架式服务器', '塔式服务器', '存储服务器'],
    blocks: [
      ParamBlock('服务器', [
        ClassParam('cpu.sockets'),
        ClassParam('mem.slots'),
        ClassParam('disk.bays'),
        ClassParam('disk.raid'),
        ClassParam('psu.redundant'),
        ClassParam('form.factor', key: true),
      ]),
    ],
  ),
  SpecClass(
    'computer.ipc',
    '工控机',
    parent: 'computer',
    aliases: ['工控机', '工业计算机', '工业控制计算机', 'IPC', '工业电脑'],
    blocks: [
      ParamBlock('结构与环境', [
        ClassParam('form.factor'),
        ClassParam('pwr.supply'),
        ClassParam('env.op_temp'),
      ]),
    ],
  ),
  SpecClass(
    'computer.pc',
    '台式计算机',
    parent: 'computer',
    aliases: ['台式机', '台式计算机', 'PC', '办公电脑', '工作站'],
  ),
  SpecClass(
    'display.monitor',
    '显示器',
    aliases: ['显示器', '液晶显示器', '监视器', '显示屏'],
    blocks: [
      ParamBlock('显示', [
        ClassParam('disp.size', key: true),
        ClassParam('disp.res', key: true),
        ClassParam('disp.aspect'),
        ClassParam('disp.refresh'),
        ClassParam('disp.response'),
        ClassParam('disp.ports', key: true),
        ClassParam('disp.psu_internal'),
      ]),
      ParamBlock('其他', [ClassParam('gen.brand_origin')]),
    ],
  ),
  SpecClass(
    'sensor.th',
    '温湿度传感器',
    aliases: ['温湿度传感器', '温湿度变送器', '温湿度探头', '温湿度计', '温度传感器', '温度变送器'],
    blocks: [
      ParamBlock('测量', [
        ClassParam('th.temp_range', key: true),
        ClassParam('th.rh_range', key: true),
        ClassParam('th.temp_accuracy', key: true),
        ClassParam('th.rh_accuracy', key: true),
        ClassParam('th.temp_resolution'),
        ClassParam('th.rh_resolution'),
      ]),
      ParamBlock('信号与通信', [
        ClassParam('io.output', key: true),
        ClassParam('io.protocol'),
        ClassParam('pwr.supply'),
      ]),
      _environment,
    ],
  ),
  SpecClass(
    'sensor.gas',
    '气体检测探头',
    aliases: [
      '气体检测探头',
      '气体探测器',
      '气体检测仪',
      '气体浓度检测探头',
      '可燃气体探测器',
      '有毒气体探测器',
      '氧浓度检测探头',
      '氧气探测器',
      '气体报警器',
    ],
    refs: {'etim': 'EC010378'},
    help: 'ETIM EC010378 为便携式气体检测仪，本类以固定式探头为主，仅作近似参考',
    blocks: [
      ParamBlock('检测', [
        ClassParam('gas.target', key: true),
        ClassParam('gas.principle'),
        ClassParam('gas.range', key: true),
        ClassParam('gas.resolution'),
        ClassParam('gas.accuracy', key: true),
        ClassParam('gas.t90', key: true),
        ClassParam('gas.recovery'),
      ]),
      ParamBlock('信号与通信', [
        ClassParam('io.output', key: true),
        ClassParam('io.protocol'),
        ClassParam('pwr.supply'),
      ]),
      ParamBlock('环境与防护', [
        ClassParam('prot.ex', key: true),
        ClassParam('prot.ip'),
        ClassParam('env.op_temp'),
        ClassParam('env.op_rh'),
      ]),
    ],
  ),
  SpecClass(
    'comm.gateway',
    '网关 / 数据采集器',
    aliases: ['网关', '数据采集器', '采集器', '协议转换器', '通讯管理机', '数据分流装置', '物联网网关'],
    blocks: [
      ParamBlock('接口与协议', [
        ClassParam('gw.south_ports', key: true),
        ClassParam('gw.north_ports'),
        ClassParam('io.protocol', key: true),
        ClassParam('gw.channels'),
        ClassParam('gw.baud'),
      ]),
      ParamBlock('其他', [
        ClassParam('gen.industrial'),
        ClassParam('gen.brand_origin'),
        ClassParam('pwr.supply'),
        ClassParam('env.op_temp'),
      ]),
    ],
  ),
  SpecClass(
    'control.plc',
    'PLC 控制系统',
    aliases: ['PLC', '可编程控制器', '控制系统', 'PLC控制系统'],
    blocks: [
      ParamBlock('I/O', [
        ClassParam('plc.di', key: true),
        ClassParam('plc.do', key: true),
        ClassParam('plc.ai', key: true),
        ClassParam('plc.ao', key: true),
      ]),
      ParamBlock('其他', [
        ClassParam('io.protocol'),
        ClassParam('plc.chips_domestic'),
        ClassParam('gen.brand_origin'),
        ClassParam('comp.catalog'),
      ]),
    ],
  ),
  SpecClass(
    'alarm.av',
    '声光报警器',
    aliases: ['声光报警器', '声光报警', '报警器', '警报器'],
    blocks: [
      ParamBlock('报警', [
        ClassParam('alarm.spl', key: true),
        ClassParam('alarm.light'),
        ClassParam('alarm.flash'),
        ClassParam('alarm.voice'),
        ClassParam('alarm.programmable'),
      ]),
      _environment,
    ],
  ),
  SpecClass(
    'cable',
    '电缆',
    aliases: ['电缆', '控制电缆', '电力电缆', '信号电缆', '软电缆', '线缆'],
    blocks: [
      ParamBlock('电缆', [
        ClassParam('cable.use', key: true),
        ClassParam('cable.cores', key: true),
        ClassParam('cable.csa', key: true),
        ClassParam('cable.conductor'),
        ClassParam('cable.insulation'),
        ClassParam('cable.sheath'),
        ClassParam('cable.shield'),
        ClassParam('cable.flame', key: true),
        ClassParam('cable.fire_resistant'),
      ]),
    ],
  ),
  SpecClass(
    'service.software',
    '软件开发服务',
    aliases: ['软件开发', '软件', '应用软件', '系统开发'],
    help: '方案和功能描述不适合参数化匹配，按文字条款人工判断',
    blocks: [
      ParamBlock('软件', [
        ClassParam('sw.arch'),
        ClassParam('sw.third_party_test'),
      ]),
    ],
  ),
];

final _propertyByCode = {for (final p in specProperties) p.code: p};
final _classByCode = {for (final c in specClasses) c.code: c};

SpecProperty? specProperty(String code) => _propertyByCode[code];
SpecClass? specClass(String code) => _classByCode[code];

/// Parameters of [classCode] including inherited ones, parents first, each
/// property once.
List<ClassParam> classParams(String classCode) {
  final chain = <SpecClass>[];
  for (
    SpecClass? c = specClass(classCode);
    c != null;
    c = c.parent == null ? null : specClass(c.parent!)
  ) {
    chain.insert(0, c);
  }
  final seen = <String>{};
  return [
    for (final c in chain)
      for (final b in c.blocks)
        for (final p in b.params)
          if (seen.add(p.property)) p,
  ];
}

/// Blocks of [classCode] including inherited ones, parents first.
List<ParamBlock> classBlocks(String classCode) {
  final chain = <SpecClass>[];
  for (
    SpecClass? c = specClass(classCode);
    c != null;
    c = c.parent == null ? null : specClass(c.parent!)
  ) {
    chain.insert(0, c);
  }
  return [for (final c in chain) ...c.blocks];
}

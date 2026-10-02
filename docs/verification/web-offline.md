# A14 Web 离线资源与版本切换

2026-09-23—24，Chrome 153.0.8010.53，独立临时 profile、localhost、当前 Flutter release 产物。Android/Windows 按用户要求 DEFERRED。

## 实现与构建

使用 `apps/supplier_app/tool/build_web_offline.py` 构建并封装发布目录。脚本先验证必需运行文件及字体引用，再生成 SHA-256 资源清单与 release ID；自定义 Service Worker 在安装时逐项校验并缓存应用、平台脚本、Drift worker、SQLite WASM、CanvasKit、字体及许可证。关键运行路径若未列入清单会返回 503，不能透传网络文件。失败安装删除该未完成代的缓存，不影响已激活版本。缓存按 registration scope 隔离。

首次启动等待 Service Worker 控制并核对 release ID 后才加载平台端口与 Dart。升级不调用 skipWaiting/clients.claim，旧页面全部关闭后新版才激活。缺少单个缓存资源时，只允许在线下载与当前清单摘要相同的资源进行修复；断网或错误版本返回 503。业务 OPFS、IndexedDB 与备份不参与缓存清理。

本地 Noto Sans SC 字体覆盖中文与拉丁字符，原始字体及 SIL OFL 1.1 许可证一并发布；出处、固定 commit 与 SHA-256 见 [字体说明](../../apps/supplier_app/web/fonts/README.md)。CanvasKit 和 fallback URL 均为同源路径。

## 已通过的限定范围

- [基线报告](../../artifacts/development/web-offline-gate.json)：原始构建没有管理型离线缓存，清除普通 HTTP 缓存后离线启动失败。普通 HTTP 缓存尚在时曾可重开，不将其误记为版本化缓存能力。
- [修复后报告](../../artifacts/development/web-offline-fixed-gate.json)：真实浏览器进程关闭重开、断网、清空 HTTP 缓存后应用可用；worker 字节被替换或 WASM 损坏时，在 Dart/数据库初始化前拒绝启动。
- [升级报告](../../artifacts/development/web-offline-upgrade.json)：旧版本 A 在线运行时发布 B；B 的混合资源安装失败后 A 仍可用；修正 B 后保持 waiting。旧标签与同时新开的第二标签继续取得 A 的 index/bootstrap/main/platform/worker/sqlite/CanvasKit 摘要。关闭所有旧客户端并重开后取得 B 的一致摘要。
- 同一报告覆盖缓存单资源丢失：离线 503、在线错误摘要 503、在线正确摘要修复。不同部署缓存及 OPFS 哨兵保留。
- 同一报告通过真实 Flutter 业务导入 UI 创建一条报价（仅系统文件选择器以真实 XLSX File 注入），升级后及 HTTP 缓存清空后的离线页面仍显示“界面验收产品 / 界面验收供应商 / CNY 32.123456”。导入前备份 locator、444 字节及 SHA-256 升级前后与离线时完全一致。这是小样本空库导入前备份，不是大库备份证据。
- [离线中文截图](../../artifacts/development/web-offline-business-chinese.png) 已人工视觉检查，中文记录、导航和拉丁金额可读；不以语义树文本替代实际字形证明。
- `python3 -m unittest discover -s tool -p test_build_web_offline.py`：5/5，通过资源摘要、确定性重复封装、worker 变更产生新版本、未知 bootstrap、缺失/空关键文件与未列入清单请求拒绝检查。生成的 bootstrap/SW 经 `node --check` 通过。修复后发布版本的离线、篡改、升级与回执恢复报告均重新跑过并为 PASS。
- [回执恢复报告](../../artifacts/development/web-offline-receipt-recovery.json)：从实际文件任务记录取得任务编号，升级后以及清空 HTTP 缓存的离线重开后，均通过 Flutter UI 恢复同一个持久成功回执。原始、升级后和离线回执 ID 完全相同，备份摘要也保持相同。测试使用真实指针激活输入框并等待 Flutter 输入监听器就绪；早期只读 `document.body.innerText` 的[失败记录](../../artifacts/development/web-offline-receipt-gap.json)是遗漏画布 `SelectableText` 的测试假阴性。
- [正式交换适配器回归](../../artifacts/development/web-offline-exchange-regression/web-exchange-smoke.json)：`web_exchange_test.py` PASS，真实 OPFS XLSX/ZIP 业务与完整同步、取消/损坏无回执、浏览器进程重开后的备份 locator 可读及同回执重试均通过。该脚本独立编译正式 Dart 适配器探针，不加载 packaged Flutter UI/SW。

## 未覆盖与复现

A14 整体仍为 PARTIAL。没有据此证明所有浏览器、unsafe/inMemory 最终降级 UI、worker 总内存/泄漏、主动清库后无备份恢复或三端环路。上述回执验证只覆盖小样本、注入文件选择器的 Chrome UI。

从仓库根目录运行：

```sh
python3 apps/supplier_app/tool/build_web_offline.py --package-only
OFFLINE_REPORT=web-offline-fixed-gate.json python3 apps/supplier_app/tool/web_offline_gate.py
python3 apps/supplier_app/tool/web_offline_gate.py --upgrade
# 同时验证升级、离线重开及原回执 UI 恢复
python3 apps/supplier_app/tool/web_offline_gate.py --upgrade --receipt-recovery
```

技术依据：[Flutter Web FAQ](https://docs.flutter.dev/platform-integration/web/faq) 说明当前默认不再生成缓存型 Service Worker；[Flutter 初始化](https://docs.flutter.dev/platform-integration/web/initialization) 提供自定义 bootstrap 与本地 CanvasKit/fontFallbackBaseUrl；[MDN 生命周期](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers) 说明安装、等待、激活与缓存版本的关系。

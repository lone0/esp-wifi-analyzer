# wifi-analyzer(ESP-Mosaico,Pascal)

Waveshare WiFi Analyzer(C 版位于 `/mnt/storage/wifi_analyzer`)的 Pascal 重实现。
图表栅格化 = 纯 Pascal 五原语(chartdraw,已在 esp-units `examples/charts` 与
pycairo 参考逐像素对齐);业务在本仓库,esp-units.pas 为 submodule
(业务侧 L1 绑定在 `src/`)。

## 布局

| 路径 | 内容 |
|---|---|
| `src/chartdraw.pas` | 5 个栅格原语(FillRect/BlendPixel/StrokeColumn/Line2/DashedVLine),ARGB8888 |
| `src/chartsmodel.pas` | app.py 两视图转录,数据源参数化(扫描快照喂数) |
| `src/apstore.pas` | AP 注册表:64 AP × 96 样本环、互斥锁、revision 门控、最强排序快照 |
| `src/c_wifi.pas` | app 侧 L1:esp_wifi 扫描 API + NVS + esp_timer;记录布局=编译探针常量(见下) |
| `src/wifi_cfg_shim.c` | C shim:`WIFI_INIT_CONFIG_DEFAULT`、nvs 的 3 个 C++ 符号、LVGL 触摸反馈 |
| `src/scanner.pas` | Pascal 扫描任务:STA-only、无 netif、CN 信道 12/13、阻塞扫描 ~600ms 间隔;**不绑核**(FreeRTOS 自行调度) |
| `src/appui.pas` | LVGL chrome:状态条、触摸反馈 + 480×436 画布 + 250ms revision 门控 tick |
| `src/wifi_analyzer.pas` | 主程序:canvas 缓冲 → WiFi 初始化 → 准备线程 → boardlvgl.Start → UI → ScannerStart → 挂起 |
| `partitions.csv` | 4 MiB factory app 分区;NVS 和 PHY 偏移不变 |
| `esp-units.pas/` | submodule(钉在含 charts 里程碑/c_lvgl canvas 扩展的提交) |
| `main/` | IDF C 锚点:仅决定构建树产出哪些归档;`app_main.c` 不进 Pascal 镜像 |

## 构建顺序

```sh
# 1) IDF 构建(产出归档树;首次需 set-target/bmgr,见下)
. /mnt/storage/esp-idf-v6.1/export.sh
idf.py --preview build

# 2) Pascal 构建(自定义目标;工具链路径全部来自环境)
. /mnt/storage/fpc-cross/esp-cfg/env-6.1.sh && esp-env-esp32s31
idf.py --preview pas          # → src/wifi_analyzer.{elf,bin}
```

环境变量(无硬编码路径):`ESP_FPC_ROOT`/`ESP_TOOLCHAIN_BIN`/`ESP32_SDK_PROJECT`
由 `esp-env-esp32s31` 设置(pas 目标内部再把 SDK 工程指回本工程);`ESP_IDF_PATH`
用于定位 per-chip vendor blob(libcoexist.a)。

`pas` 目标检查生成的镜像是否放得进 factory 分区。IDF 的默认
`SINGLE_APP_LARGE` 仅 1500 KiB,不足以容纳 WiFi + LVGL 镜像,不能用于本程序。
本工程使用 `partitions.csv` 中的 4 MiB 分区;安装新分区表后才能启动。
FreeRTOS 必须提供至少 2 个 TLS 指针槽;`fthreads` 使用槽 1,槽 0 留给
ESP-IDF pthread/lwIP。应用不会调用全局 `esp_board_manager_init()`:
`boardlvgl` 仅初始化 display_lcd、lcd_touch 和可选 brightness。

首次自举:`idf.py --preview set-target esp32s31 && idf.py --preview bmgr -b esp_mosaico`,
然后 build(gen_bmgr_codes 生成后已列进 main 的 REQUIRES)。

## 烧录(Mosaico 纪律)

```sh
esptool --chip esp32s31 --no-stub --port /dev/serial/by-id/<mosaico-port> \
  write-flash 0x8000 build/partition_table/partition-table.bin \
              0x10000 src/wifi_analyzer.bin
```

- **--no-stub 必须**(stub 上传在本链路必死);
- 端口一律走 by-id(应用态=`...Device_1C2904D08824`,download 态=
  `usb-Espressif_ESP32-S31_1c:29:04:d0:88:24`;两个名字不同,均含 eFuse MAC);
- 串口抓取用 raw-fd,勿碰 DTR/RTS(usb_hs_console 的自动下载复位);
- 串口纪律:Mosaico 之外(ttyACM1 / CH340 / 其它 Espressif 板)严禁操作。
- 上述分段写入保留 NVS/PHY 数据;不要用填充合并镜像覆盖
  `0x9000..0xffff`。此命令假定当前 bootloader 与本 SDK 工程兼容。

## 绑定探针(布局事实的来源)

`c_wifi.pas` 里的尺寸/偏移常量来自**编译探针**(用本工程 compile_commands 的
原始编译命令编一个 `sizeof/offsetof` 探针文件,nm/objdump 读值),不是手算:

```
sizeof(wifi_ap_record_t)=92  bssid@0 ssid@6 primary@39 rssi@44 authmode@48
sizeof(wifi_scan_config_t)=44 show_hidden@9
```

IDF/板包升级后重跑探针即可复核。

## 链接闭包(已固化进 idf.py pas)

display_lvgl 池 + 板包运行时整链(button/camera/video/codec/bq27220/i2c_bus/sccb、
ledc/i2s/cam/ppa/spi 驱动 + esp_hal_* periph_signal 表 + esp_pm)+ WiFi 栈
(esp_wifi、vendor pp/net80211/core/espnow/mesh/phy、esp_coex + **按路径的
libcoexist.a**、nvs_flash、esp_event、log)。L1 单元通过 `{$linklib}` 把普通归档
放进 FPC 的后对象 group；`gen_bmgr_codes` 的 board runtime/factory 和 6 个
active subtype registration 对象由 CMake 按对象显式链接,避免 whole-archive
提前选中 BMGR 的弱 fallback。nvs 的 C++ 侧只缺 3 个 libstdc++ 符号,
**不链 multilib libstdc++**,由
  `wifi_cfg_shim.c` 以 asm 名提供(转发 malloc/free,分配落在 idfheap 同堆)。

## 结构决定(记录在案)

- **圆角屏**:画布 (0,44)-(480,480),图表自身边距让坐标轴和标签避开圆角;
- **不阻塞 UI**:图表绘制 ~10ms 级、整画布 blit 实测 ~40ms,revision 门控使
  全量重绘按扫描节奏(~0.5Hz)而非 tick 节奏;未来视图超预算就按水平条带分步;
- **核调度**:扫描任务通过 fthreads 的 BeginThread 创建且不绑核;待真机 profiling 再决定是否钉核;
- **submodule**:app 侧新 L1(c_wifi、lv_timer/event-user-data 等外部声明)
  留在 src/。

## 后续(未做)

- width_mhz 目前统一 20(wifi_bandwidth_t 映射待做);
- 历史视图只画最强 AP(app.py 的单 BSSID 语义);多 AP 选择/切换待做;
- 波段切换(2.4/5/6GHz)、点击信道聚焦虚线——app.py 有、本轮未接。

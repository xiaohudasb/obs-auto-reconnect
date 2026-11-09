# OBS Auto Reconnect

[![OBS](https://img.shields.io/badge/OBS-28%2B-302E31?style=flat-square&logo=obsstudio&logoColor=white)](https://obsproject.com/)
[![Platform](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?style=flat-square&logo=windows11&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

OBS Studio 的 Lua 脚本：USB 视频采集设备（UVC 摄像头）拔掉再插回后，自动恢复画面，不用重新添加来源。

适用于 DJI Osmo Action 6 这类闲置时会断电、重新接入后 OBS 不会自动刷新的相机。

## 功能

- 自动检测采集设备重新接入
- 精确匹配 OBS 来源里绑定的设备（VID / PID / 实例号），换 USB 口也能识别
- 模拟「在属性里把设备切走再切回来」，强制 DirectShow 重新打开设备
- 提供「立即重连一次」按钮，手动触发
- 检测间隔可配置，默认每秒检查一次

## 环境要求

- Windows 10 / 11
- OBS Studio 28 或更高（在 33.0.1 上测试通过）
- 来源类型必须为「视频采集设备」（`dshow_input`）

## 安装

1. 下载 [`auto_reconnect.lua`](auto_reconnect.lua)
2. OBS → 工具 → 脚本 → 左下角 `+` → 选择该文件
3. 在脚本设置里选择「视频采集源」，确认「启用自动重连」已勾选

## 设置项

| 设置 | 说明 | 默认值 |
| --- | --- | --- |
| 视频采集源 | OBS 来源列表里的摄像头来源；找不到时会自动使用第一个视频采集源 | 视频采集设备 2 |
| 备用设备名关键字 | 读不到设备 ID 时，用设备名关键字匹配 | Osmo |
| 检查间隔 | 设备枚举间隔（秒） | 1 |
| 启用自动重连 | 总开关 | 开 |
| 立即重连一次 | 手动触发一次重连 | — |

## 工作原理

1. 每秒通过 Windows SetupAPI 枚举当前接入的摄像头设备；
2. 读取 OBS 来源里保存的 `video_device_id`，解析出 VID / PID / 实例号，与系统设备精确匹配；
3. 设备从「不存在」变为「存在」时，把 `video_device_id` 置空并更新来源，400 ms 后再写回原设备 ID。
   这等价于在来源属性里把设备切到别的、再切回来，从而强制 DirectShow 重新打开设备。

## 注意事项

- 重连瞬间会黑屏约 0.4–1 秒，属于正常现象；
- 仅支持 Windows，依赖 SetupAPI 与 LuaJIT FFI；
- 自动检测无效时，先查看 OBS 的「脚本日志」，确认设备是否被枚举到；
- 相机长时间不用时，建议在 OBS 里停用来源，而不是直接拔线。

## License

[MIT](LICENSE)
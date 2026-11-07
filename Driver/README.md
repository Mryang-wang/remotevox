# T1SiriInput 音频驱动

此目录包含随 RemoteVox 安装包分发的 T1SiriInput Core Audio HAL 驱动的对应源码。上游为 BlackHole v0.7.1，提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`。 [查看上游版本](https://github.com/ExistentialAudio/BlackHole/tree/e2b22aaaba4e507a097131704bf96dabc004d9cf)

T1 版本将可见音频设备的传输类型设为 USB 兼容，使用两声道和独立的 T1SiriInput 名称及标识。驱动仍由 macOS 作为软件音频设备加载。

从仓库根目录运行 `./package.sh` 可编译驱动并生成安装包。该脚本列出了编译选项与所用 macOS 框架。

驱动源码按 [GNU GPL v3](LICENSE) 提供。BlackHole 名称及标识属于 Existential Audio。

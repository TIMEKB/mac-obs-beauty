# 第三方组件与发布边界

本仓库开源的是 OBS 兼容性桥接、停靠界面、安装与部署工具。美颜算法本身来自用户安装的原软件，不作为本仓库的开源算法发布。

| 组件 | 用途 | 本仓库 / Release 中的处理 |
| --- | --- | --- |
| 本项目原创源码 | OBS 插件、面板、ABI 适配、安装器与工具 | 以 GPL-2.0-or-later 发布，见 LICENSE |
| OBS Studio / libobs / frontend API | 视频处理与插件宿主 | 使用用户已安装的 OBS；不重新打包 OBS 库。OBS 许可见其官方发行包与[源码](https://github.com/obsproject/obs-studio) |
| Qt | OBS 停靠窗口 | 使用 OBS 自带 Qt，许可文本随对应 OBS/Qt 发行版本提供；不在插件中另发一套 Qt |
| Apple 系统框架 | 原生界面、WebKit 面板与图像处理桥接 | 由 macOS 提供，不纳入本项目源码许可 |
| Mac 直播伴侣的 EffectSDK 和依赖库 | 本地美颜算法 | 从用户已安装的官方应用加载，不随公开包重新分发 |
| 供应商 Composer 节点、模型、图标、妆容、滤镜与 LUT | 运行效果与面板素材 | 按兼容性清单在用户本机准备和校验；不随 GitHub 源码或公开安装包重新分发 |

## 适配基线

- Apple Silicon，macOS 13 或更高版本。
- OBS 32.2.1，arm64。
- 官方 Mac 直播伴侣 10.0.0 / 10.0.4；原库按安装包中的兼容性清单与哈希校验。

兼容性依赖 ABI 和资源版本。供应商应用、服务或资源变化后，需要重新验证；下载成功或初始化返回成功，不能代替实际图像处理验收。

插件在首次加载原库前核对安装清单中的 SHA-256；官方应用更新使原库哈希变化时，停止使用该库并保留原画。

## 数据与运行资源

安装器只准备插件所需的官方应用运行库及固定资源。不要把账号状态、Cookie、令牌、个人资料、授权文件、私人照片或完整原应用复制进本仓库或 Release。

供应商服务上可以取得的文件不因此变为 GPL 或本项目原创内容。仓库中记录接口名、资源标识、校验值和兼容性信息，不授予原软件或素材的其他权利。

Wink、FaceBetter、其 SDK 和素材、虚拟摄像头改名均不在本轮公开发行范围内。

## 源码许可

本项目原创源码采用 **GNU General Public License version 2 or any later version（GPL-2.0-or-later）**，完整文本见 [LICENSE](LICENSE)。供应商二进制、模型和素材保留各自权利，不被此许可证重新许可。

OBS 当前公共模块头使用 GPLv2 或更高版本，官方来源：[obs-module.h](https://github.com/obsproject/obs-studio/blob/master/libobs/obs-module.h)。

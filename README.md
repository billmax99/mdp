# MD+ — 微信里收到的文档，都能舒服地看

![版本](https://img.shields.io/badge/version-2.4.1-blue) ![平台](https://img.shields.io/badge/platform-Android%207.0%2B-green) ![许可](https://img.shields.io/badge/license-MIT-orange) ![离线](https://img.shields.io/badge/%E7%A6%BB%E7%BA%BF-%E9%9B%B6%E6%9D%83%E9%99%90-brightgreen)

MD+ 是一款极简的安卓本地文档阅读器：在微信里长按文件 → "用其他应用打开"，剩下的交给它。
完全离线运行（无网络权限）、不索取任何敏感权限、无广告无内购， iOS 风格界面，单手可用。

- GitHub（主仓库）：<https://github.com/billmax99/mdp>
- Gitee（镜像）：<https://gitee.com/bill_zzx/mdp>

## 功能特性

- **五种格式**：Markdown（完整渲染）/ TXT / PDF / EPUB（含插图）/ DOCX
- **标注**：长按选词即可划线（蓝色波浪线）或高亮（黄色色块），自动保存，面板可按类型筛选、跳转、删除
- **全文搜索**：命中高亮，n/m 计数，上下箭头逐条跳转
- **目录导航**：Markdown 标题 / EPUB 章节一键直达
- **阅读位置记忆**：重开文件自动回到上次看到的地方
- **六种阅读主题**：浅色 / 深色 / 纸白 / 淡暖 / 绿豆沙 / 淡青，可跟随系统深浅色
- **字号调节**（14–28）自动记忆；最近列表左滑删除（可撤销）

## 支持的格式

| 格式 | 说明 |
|------|------|
| `.md` `.markdown` `.mdown` | 完整 Markdown 渲染（标题/表格/代码块/引用等） |
| `.txt` | 纯文本（UTF-8，自动兜底识别） |
| `.pdf` | 双指缩放、滚动翻页；深色模式自动压暗白页护眼 |
| `.epub` | 按章节阅读，插图完整显示；DRM 加密电子书不支持 |
| `.docx` | 提取正文段落阅读（排版不保留） |

暂不支持 `.doc` / `.mobi` / `.azw3` 等老格式（无可靠解析库），建议先转为 docx / epub。

## 下载

| 渠道 | 地址 |
|------|------|
| GitHub Releases（推荐） | <https://github.com/billmax99/mdp/releases> |
| Gitee 发行版（镜像） | <https://gitee.com/bill_zzx/mdp/releases> |

- **arm64 包**（现代手机推荐，约 25 MB）与**全架构通用包**任选；
- 与旧版调试签名不同，首次安装正式版需先卸载旧版（注意备份标注数据）。

## 从源码构建

```bash
flutter pub get
flutter test                 # 三个测试文件应全部通过
flutter build apk --release  # 通用包；--target-platform android-arm64 可出精简包
```

版本号三件套需同步维护：`pubspec.yaml` 的 `version`、`lib/build_info.dart` 的 `appVersion`/`buildDate`。

## 隐私与权限

本应用 **未申请任何 Android 系统权限**（含网络权限），技术上不存在联网与数据上传；
文件访问仅通过系统标准选择器（SAF）与"用其他应用打开"机制进行。详见：

| 文档 | 在线地址（GitHub Pages / Gitee Pages 镜像） |
|------|------|
| 隐私政策 | <https://billmax99.github.io/mdp/privacy.html> · <https://bill_zzx.gitee.io/mdp/privacy.html> |
| 用户服务协议 | <https://billmax99.github.io/mdp/agreement.html> · <https://billmax99.gitee.io/mdp/agreement.html> |
| 权限使用说明 | <https://billmax99.github.io/mdp/permissions.html> · <https://bill_zzx.gitee.io/mdp/permissions.html> |
| 版权声明 | <https://billmax99.github.io/mdp/copyright.html> · <https://bill_zzx.gitee.io/mdp/copyright.html> |

源文件位于仓库 `publish/` 目录，随应用版本一并维护。

## 开源许可

- 本应用源代码以 **[MIT License](LICENSE)** 开源，Copyright (c) 2026 bill_zzx（GitHub：[@billmax99](https://github.com/billmax99)）。
- 使用的第三方组件（Flutter、pdfrx、markdown、archive、file_picker 等）版权归各自作者所有，
  完整清单见[开源许可声明](publish/开源许可声明.md)。

## 赞助

如果 MD+ 帮到了你，欢迎请开发者喝杯咖啡 ☕ 或给猫主子添点猫粮 🐱 —— 完全自愿，感谢支持！

| 微信 | 支付宝 |
|------|--------|
| ![微信收款码](docs/sponsor/wechat.png) | ![支付宝收款码](docs/sponsor/alipay.png) |

> 截图请使用手机自带截图功能保存识别。

## 相关文档

- [使用说明](使用说明.md) —— 安装、微信跳转、标注操作详解，含完整版本历史
- [程序编码说明](程序编码说明.md) —— 代码结构与实现说明
- [发布检查清单](publish/发布检查清单.md) / [应用市场发布资料](publish/应用市场发布资料.md)

---

MD+ v2.4.1 · © 2026 bill_zzx · [MIT](LICENSE)

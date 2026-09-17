# 赞助赞赏码说明

本目录存放 README 赞助区引用的赞赏码图片，两栏均为**微信赞赏码**：

- `wechat_luckin.png` — 小额档：赞助一杯瑞幸
- `wechat_other.png` — 其它档：赞助一杯其它

当前为**占位图**（由 `tool/make_sponsor_placeholders.py` 生成）。
获取真实赞赏码后：原图存为对应 `*_raw.png`，跑 `python tool/watermark_sponsor.py`
生成带"MD+ 官方赞赏码"横幅的水印图（覆盖上述文件名），提交即可，
README 与 Pages 引用的文件名不变、无需改动。

> 微信：我 → 服务 → 收付款 → 赞赏码（生成时可设置金额）。
> 若微信端只能保留一张赞赏码，两栏可共用同一张码图，金额由赞赏者自选。

建议导出 PNG/JPG，尺寸不小于 400×400。`*_raw.png` 已 gitignore，不入库。

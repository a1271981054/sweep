# 第三方声明

本项目的扫描引擎（Swift 包 `MacCleanKit`）来自第三方开源项目，以 BSD 3-Clause 许可分发，源码以 vendored 形式放在 `vendor/MacSai/`。

```
BSD 3-Clause License

Copyright (c) 2026, Mac Sai Contributors
All rights reserved.
```

完整许可文本见 `vendor/MacSai/LICENSE`。

## 对上游代码的修改

为把本项目作为独立产品发布，`scripts/vendor-scrub.sh` 对 `vendor/MacSai/Sources/MacCleanKit/` 做了**机械替换**：将字符串字面量与注释中的上游名称替换为本项目名称（`Mac Sai` / `MacSai` → `Sweep`）。替换不改变任何逻辑。

后果需要明确：

- `vendor/` 下的代码是**修改版**，不再是上游原样副本；BSD-3 允许此类修改，本声明即为变更说明；
- 上游的自更新地址、User-Agent 等常量因此指向不存在的目标——这些代码路径 sweep 从不调用（本项目只使用扫描与分类 API）；
- 重新拉取上游源码后，需要重新运行 `scripts/vendor-scrub.sh`。

## 分发范围与裁剪

`vendor/engine/` 只保留编译所需的 `Sources/MacCleanKit/` 与上游 `LICENSE`；上游的 GUI、菜单栏、测试、官网、构建脚本与 Git 历史**未随本项目分发**，`Package.swift` 也相应裁剪为只声明引擎库目标。这是为了让分发内容与许可证要求一致，并避免把与本项目无关的第三方界面带到他人机器上。

## 使用范围

- 本项目只调用其公开 API（`JunkCategory`、`ScanTarget`、`DuplicateDetection`、`CleanHistory` 等），未修改上游代码；
- 上游版权与许可声明随源码一并保留，符合 BSD-3 的保留要求；
- 本项目与上游项目、其作者无隶属或背书关系，也不使用其名称或标识作为自身品牌。

若用于再分发，请保留本文件与 `vendor/MacSai/LICENSE`。

# BigBrother is watching you :)

BigBrother 是一款 macOS 菜单栏应用，帮助你查看 App 何时使用了屏幕、麦克风、摄像头、位置、剪贴板及其他受保护的内容。

默认不申请通知权限；开启通知时才向 macOS 申请。导出记录时通过系统保存窗口选择位置，不需要完全磁盘访问权限。

“记录”页每批加载 50 条，点击底部“加载更多”查看更早的记录。修改搜索或筛选条件会从第一批重新加载；自动刷新保留已加载的条数。分页只影响界面展示，不改变记录保存和导出范围。

界面采用简洁的列表与系统控件，颜色主要用于状态和需留意的记录。记录类别说明、图标颜色说明及记录范围可展开查看；这些展示调整不改变采集与风险判定。

## 构建与运行

需要 macOS 13 或更高版本，以及 Xcode 命令行工具。

在项目目录运行：

```bash
make
```

应用会生成在 `dist/BigBrother.app`。构建并启动：

```bash
make run
```

生成可分发的磁盘映像：

```bash
make dmg
```

DMG 文件会生成在 `dist/BigBrother-<commit号>.dmg`，其中 commit 号与应用内记录的 Git commit ID 一致。

默认使用本地签名。正式分发时可指定开发者签名身份：

```bash
make dmg CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

或者运行 `make sign-dmg`：会自动使用唯一的 Developer ID Application 身份；如果有多个，会在同一次运行中提示选择。此目标会对应用和 DMG 都进行签名，并验证 DMG 签名。

公开分发还需完成 Apple 公证。

清理构建产物：

```bash
make clean
```

用日志文件运行命令行自检：

```bash
make test LOGS="/path/to/log.txt"
```

运行权限事件与存储回归测试：

```bash
make test-storage
```

排查定位记录时可以只跑定位通道（定位不走 TCC，单独一条管线）：

```bash
dist/BigBrother.app/Contents/MacOS/BigBrother --locscan <日志文件>…
```

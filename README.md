# 风扇控制 · iFeng 1.1.0

macOS 菜单栏风扇管理工具，功能定位与 Macs Fan Control / smcFanControl 同级。

- 中文名：**风扇控制**　英文名：**iFeng**
- 适配：Intel Mac（本包按 MacBook Pro 2011 A1278 13" + macOS 13.7.8 + OCLP 环境编写，其余 Intel 机型同样适用）
- 界面：全中文

---

## 一、功能

### 状态栏常驻

菜单栏直接显示「最高温度」（可选同时显示转速），点击展开面板。图标 + 温度文本，不占 Dock。

### 四种控制模式

| 模式 | 行为 |
|---|---|
| 自动 | 只读不写，风扇完全由系统固件控制 |
| **恒温** | 你设定一个**目标温度**，程序按温度误差自动增减转速，把温度压向目标值 |
| 曲线 | 按你自定义的「温度 → 转速」节点表线性插值调速 |
| 手动 | 固定转速，与温度无关 |

### 恒温模式（目标温度）

- 目标温度 45 – 90 °C 可调
- 控制律：误差 ±1.5 °C 死区内不动作；超出后按比例增减，单周期最高 +450 / −350 RPM，2 秒一个周期
- 面板实时显示「当前温度偏差」与控制方向提示（升温中，加速 / 已达标，减速 / 稳定）

### 曲线模式（不同温度自定义风扇速度）

- **鼠标直接拖动**：折线图上的每个圆点都可以拖，左右改温度、上下改转速，拖动时实时显示当前数值
- 默认 6 个节点，可依据机型硬件 `F0Mn / F0Mx` 自动生成
- 节点表亦可精调：每行增减温度（30 – 105 °C）与转速（步进 100 RPM）
- 节点间线性插值；节点数量 2 – 任意，可增删
- 红色虚线为当前温度位置，随传感器实时移动

### 转速平滑过渡（参考 SimpMusic crossfade 的做法）

- 独立**开关**，关闭时转速一步到位（原行为）
- 开启后按设定的**过渡速率**分步逼近目标：0.25 秒走一小步，界面顶部显示「过渡中」标签
- 速率可调 **100 – 1500 RPM/秒**，并给出「慢 250 / 标准 500 / 快 1000」三个预设
- 面板显示「满量程约 N 秒」，直观判断快慢
- 平滑只作用于升降过程，目标本身仍由恒温闭环/曲线决定，两者互不干扰

### 自动更新（后台下载，下好再提示）

- 启动 5 秒后静默检查 GitHub Release，之后每 6 小时一次
- 发现新版本**自动在后台下载并解压校验**（版本号、可执行文件都要对得上），全程不打扰
- 下载完成才提示：菜单栏面板出现绿色「可更新」角标，「设置」里显示「新版本 x.y.z 已下载」
- 点「重启并安装」后自替换并自动重启；已下载的包会留存，下次启动仍可提示
- 「设置」里可关闭自动下载，改为手动「检查更新」

### 安全机制

- 目标转速一律夹取到硬件真实范围 `[F0Mn, F0Mx]`
- 温度 ≥ 95 °C 无条件全速
- 退出 / Cmd-Q / SIGTERM / 注销 → 自动写 `F0Md=0` 交还固件
- 仅在目标变化 ≥ 60 RPM 或超过 25 秒未写入时才重写 SMC（避免高频写）

---

## 二、构建与分发方式

成品由 **GitHub Actions 的 macOS runner** 编译（`.github/workflows/build.yml`，`runs-on: macos-15`），产出 Intel + Apple Silicon 通用二进制，与你 Mac 上的环境无关。

公开仓库的 macOS runner 不计费，每次 push 到 `main` 自动出包；打 `v*` tag 会自动创建 Release 并附上 zip —— 应用内的「检查更新」正是查这个 Release。

本地也可以自行编译（需要 Xcode 或命令行工具），见「方式 B」。

---

## 三、安装

### 方式 A：直接安装成品包（推荐）

1. 下载 **`iFeng-1.1.0.zip`**（CI 产出的通用二进制，Intel / Apple Silicon 均可运行）
2. 双击解压，把 `风扇控制.app` 拖进「应用程序」
3. 首次启动：右键点图标 →「打开」（应用为 ad-hoc 签名，需绕过 Gatekeeper 一次）
4. 点菜单栏图标 →「设置」→ **「一键启用风扇写入」**，输入一次管理员密码

第 4 步之前只能读温度；完成后即可写转速。全程不需要打开终端。

> 解压请用系统自带的「归档实用工具」或 `ditto -x -k`，第三方解压工具可能丢失可执行权限。

### 方式 B：从源码构建（可选）

```
cd ~/Downloads/ifeng-1.1.0
xattr -dr com.apple.quarantine .
bash build.sh               # 编译，自动产出 dist/iFeng-1.1.0.zip
./build/fanctl diag         # 验证 SMC 可读（关键一步）
sudo bash install.sh        # 安装（或用方式 A 的第 3、4 步）
```

跨架构构建：`UNIVERSAL=1 bash build.sh`。

`fanctl diag` 应打印风扇数量、`F0Tg` 类型、CPU/GPU 温度。这一步能过，说明硬件层没问题。

### 卸载

```
sudo bash uninstall.sh
```

### 打包成 zip 分发

`build.sh` 编译完成后自动产出 **`dist/iFeng-1.1.0.zip`**，用 `ditto` 打包（保留可执行权限、符号链接与扩展属性），拷到另一台 Mac 解压即可直接双击运行。

App 内已内嵌 `fanctl`，目标机器无需再单独安装辅助工具 —— 打开后点「一键启用风扇写入」即可。

---

## 四、命令行工具 fanctl

```
fanctl list               # JSON：风扇 + 温度
fanctl diag               # 自检
fanctl set 0 3500         # 风扇 0 固定 3500 RPM
fanctl auto all           # 全部交还系统
fanctl read TC0P          # 读单个 SMC 键
fanctl watch              # 终端实时刷新（Ctrl-C 退出）
```

---

## 五、实现要点

1. **SMC 访问**：`src/fanctl.c` 用 `IOServiceGetMatchingService("AppleSMC")` + `IOConnectCallStructMethod` 直读直写；`SMCKeyData_t` 与 Apple 开源 AppleSMC 完全对齐，并用 `_Static_assert(sizeof == 80)` 在编译期锁死结构布局。
2. **写入协议**：先 `SMC_CMD_READ_KEYINFO`（index 9）取键的真实 `dataType / dataSize`，再 `SMC_CMD_WRITE_BYTES`（index 6）按类型编码（`fpe2` / `flt` / `ui8` / `ui16` / `sp78`），不硬编码，因此跨年份机型通用。
3. **强制模式**：先写 `F0Tg` 再写 `F0Md=1`，避免目标值切换瞬间跳变；恢复时写 `F0Md=0`。
4. **最小权限**：GUI 是普通用户进程，所有特权操作走 setuid 的 `/usr/local/bin/fanctl`。
5. **状态栏**：SwiftUI `MenuBarExtra` + `LSUIElement=1`，纯菜单栏应用，无 Dock 图标。

---

## 六、排错

| 现象 | 原因 / 处理 |
|---|---|
| `fanctl diag` 报「无法连接 AppleSMC」 | 极少见。OCLP 不修改 SMC（SMC 是硬件固件，不受 root patch 影响），先确认是 Intel Mac |
| 面板温度显示 `--` | 传感器键名与机型不匹配。`fanctl read TC0P` 逐个试，把有效键名补进 `src/fanctl.c` 的 `gTempKeys` 后重编译 |
| 设了转速但风扇不动 | 用 `fanctl read F0Md` 确认强制位写入成功；确认 `F0Tg` 类型被正确识别（`fanctl diag` 会打印） |
| 提示权限不足 | setuid 位丢失：`sudo chmod u+s /usr/local/bin/fanctl` |
| 硬盘位温度异常 | 换装 860 EVO 后原硬盘温度传感器无有效数据，`list` 已过滤异常值，属正常 |
| 界面渲染略有延迟 | 2011 款无 Metal，Ventura 走兼容渲染路径，属系统层面现象，不影响功能 |
| 强制结束进程后风扇不回落 | 代码没有机会收尾。重新打开 App → 设置 → 恢复系统自动 |

---

## 七、目录结构

```
fanctrl/
├── build.sh              构建（clang + swiftc）
├── install.sh            安装（setuid helper + /Applications）
├── uninstall.sh          卸载
├── Info.plist            CFBundleName=风扇控制, Executable=iFeng, LSUIElement=1
├── src/
│   ├── fanctl.c          SMC 读写 + 命令行
│   ├── App.swift         菜单栏入口 + 退出交还控制
│   ├── Fanctl.swift      fanctl 调用层 / LaunchAgent
│   ├── FanModel.swift    模式状态机、恒温闭环、曲线插值、节流
│   └── ContentView.swift 三页面板（控制 / 曲线 / 设置）
└── README.md
```

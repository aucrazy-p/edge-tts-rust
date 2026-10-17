# tts-server-rust（仓库：aucrazy-p/edge-tts-rust）

轻量自托管 Edge TTS 服务（Rust 版），专为 [legado_NG](https://github.com/gedoor/legado)（阅读 3.0）的「自托管 Edge TTS」引擎设计。

- **Rust + axum + edge-tts-rust**：空闲内存仅约 10–30 MB，可在 128 MB 小鸡上运行。
- **39 音色下拉不变**：1:1 对齐 legado_NG 内置引擎的 GET 契约，阅读里现有引擎配置**一行都不用改**。
- **流式首字节低延迟**：Edge 每合成一段音频立即推流（长章节不必等整段合成完）。
- **指数退避重试 + 可配置超时**：晚高峰跨境丢包时自动重试，不再一次失败就 502。
- **LRU 缓存**：相同音色+文本秒回，省流量。

## 为什么不直接用 Python 版 / enximi

| 方案 | 内存 | 39 音色下拉 | 流式 | 重试/超时 |
|------|------|------------|------|-----------|
| Python server.py | 高（venv+Flask） | ✅ | ✅ | ❌ |
| enximi（通用 HTTP TTS 导入） | 极低 | ❌（每导入仅 1 个写死音色） | ❌（整段缓冲） | ✅ |
| **tts-server-rust（本仓库）** | **极低** | **✅** | **✅** | **✅** |

> 本仓库集合了前两者优点：Rust 的轻量 + Python 版的 39 音色/流式 + enximi 的重试/超时。

## 安装 / 管理（含交互菜单）

在服务器上执行（自动检测架构，从 GitHub Releases 下载预编译二进制）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh)
```

交互运行会弹出管理菜单（与上回 tts-server 菜单一致）：

```
====== tts-server-rust 管理菜单 ======
 1) 安装 install
 2) 卸载 uninstall
 3) 启动 start
 4) 停止 stop
 5) 状态 status
 6) 查看日志 logs
 7) 更新 update
 8) 更改端口 change-port
 9) 对外访问配置 setup-caddy
 0) 退出
========================================
请选择 [0-9]:
```

- **首次安装**会依次询问：访问令牌（留空随机生成）、监听端口（默认 8080，部分小鸡仅开放 80/443 需填已开放端口）、反向代理域名（留空=不反代，直接用 `IP:端口+token`）。
- **更新（菜单 7）** 会沿用已有配置重新拉取最新二进制，不再重复询问。
- 菜单 8「更改端口」可随时改监听端口并自动重启生效（若启用反代会同步 Caddy 端口）。
- 菜单 9「对外访问配置」用 Caddy 反代 + 自动申请 HTTPS（个人使用也可不选，直接 IP:端口+token）。

也可直接传子命令（无需菜单）：

```bash
bash install.sh install        # 安装
bash install.sh uninstall      # 卸载
bash install.sh start          # 启动服务
bash install.sh stop           # 停止服务
bash install.sh status         # 查看状态（含服务地址）
bash install.sh logs           # 查看日志
bash install.sh update         # 更新
bash install.sh change-port    # 更改端口
bash install.sh setup-caddy    # 对外访问配置
bash install.sh menu           # 直接进入菜单
```

非交互（一键）示例：

```bash
PORT=8080 TTS_TOKEN=你的令牌 DOMAIN=tts.example.com bash install.sh
# 不反代：
PORT=8080 TTS_TOKEN=你的令牌 bash install.sh
```

> 注：交互读取统一走 `/dev/tty`，因此 `curl | bash` 场景下菜单也能正常输入，不会像旧版那样直接跳过。

## 手动部署（GitHub 预编译二进制）

1. 到 [Releases](https://github.com/aucrazy-p/edge-tts-rust/releases) 下载对应架构：
   - `tts-server-rust-linux-x86_64`
   - `tts-server-rust-linux-aarch64`
   - `tts-server-rust-windows-x86_64.exe`
2. 上传到服务器，`chmod +x` 后运行：
   ```bash
   export TTS_TOKEN="你的长随机令牌"
   ./tts-server-rust
   ```
   > 二进制本身不带参数解析，配置全部走环境变量（见下）。监听端口用 `PORT` 环境变量。
3. **不使用反代**（个人使用最简单）：直接开放防火墙端口，legado_NG 服务地址填 `http://服务器IP:端口?token=令牌` 即可。
4. 若要用 HTTPS/域名，再用 Caddy/Nginx 反代到 443（Cloudflare 建议走**灰云直连**以降低延迟）。

## 从源码构建 / 本地运行

```bash
cargo run --release
# 或
cargo build --release && ./target/release/tts-server-rust
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TTS_TOKEN` | 空（关闭鉴权） | 访问令牌，与 legado_NG 引擎「访问令牌」一致；支持 `?token=` 与 `Authorization: Bearer` |
| `HOST` | `0.0.0.0` | 绑定地址 |
| `PORT` | `8080` | 监听端口 |
| `DEFAULT_VOICE` | `zh-CN-XiaoxiaoNeural` | 未指定 voice 时的默认音色 |
| `FIRST_BYTE_TIMEOUT_MS` | `10000` | 单次尝试获取首字节音频的超时 |
| `TOTAL_TIMEOUT_MS` | `60000` | 包含重试在内的总超时预算 |
| `RETRY_MAX_ATTEMPTS` | `3` | 首字节失败的重试次数（指数退避） |
| `RETRY_BACKOFF_MS` | `1000` | 首次重试的基础退避（每次翻倍） |
| `CACHE_MAX_ITEMS` | `600` | LRU 缓存条目上限 |

晚高峰卡顿调优示例：

```bash
export TTS_TOKEN="xxxx"
export FIRST_BYTE_TIMEOUT_MS=20000
export TOTAL_TIMEOUT_MS=120000
export RETRY_MAX_ATTEMPTS=4
./tts-server-rust
```

## 接口契约（与 Python 版完全一致）

```
GET /                             状态页（HTML）
GET /voices?token=...             {"voices":[...39...]}   legado_NG 拉音色列表
GET /tts?text=&voice=&speed=&pitch=&volume=&style=&token=   audio/mpeg（流式）
```

`style` 参数会被接收但忽略（edge-tts 7.x 起不再支持自定义 SSML 风格注入），与 Python 版行为一致。

## 部署到 128 MB 香港小鸡的建议

- 直接跑静态二进制，**不要套 Docker**（dockerd 自身就吃 30–50 MB）。
- 走 Cloudflare 灰云（DNS-only）直连 HK IP，沈阳→香港延迟远低于跨太平洋到美国。
- 不反代、直接用 IP:端口+token 对个人使用完全够用，省去 HTTPS/域名配置。

# tts-server-rust

自托管 Edge TTS 服务（Rust 版），给 [legado_NG](https://github.com/gedoor/legado)（阅读 3.0）的「自托管 Edge TTS」引擎用。

- 空闲内存约 10–30 MB，128 MB 小鸡够用
- `/voices` 动态同步微软实时音色列表，阅读里能直接选
- 边合成边推流，首字节快
- 首字节超时自动重试（指数退避）
- LRU 缓存，同音色同文本秒回

## 安装

服务器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh)
```

会自动识别架构，从 GitHub Releases 下载预编译二进制并注册 systemd 服务。交互运行会出菜单：

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

首次安装只问三件事：

1. **访问令牌** —— 留空则随机生成，不允许为空
2. **监听端口** —— 留空 = 随机 30000–59999 高位端口；小鸡只放行 80/443 就填对应端口
3. **反代域名** —— 留空 = 不反代，直接用 `IP:端口?token=`

菜单 7 更新会沿用已有配置，不再重复询问；菜单 8 改端口并自动重启生效；菜单 9 用 Caddy 反代并自动申请 HTTPS（个人自用可以不选）。

## 一键非交互安装

```bash
# 全自动：随机令牌 + 随机高位端口
bash install.sh

# 指定端口
PORT=38641 TTS_TOKEN=你的令牌 bash install.sh

# 需要 HTTPS 再给域名
PORT=38641 TTS_TOKEN=你的令牌 DOMAIN=tts.example.com bash install.sh
```

## 子命令

```bash
bash install.sh install        # 安装
bash install.sh update         # 更新
bash install.sh uninstall      # 卸载
bash install.sh start          # 启动
bash install.sh stop           # 停止
bash install.sh status         # 状态（含服务地址）
bash install.sh logs           # 日志
bash install.sh change-port    # 改端口
bash install.sh setup-caddy    # 对外访问配置
bash install.sh menu           # 进菜单
```

## 阅读里怎么填

引擎类型选「自托管 Edge TTS」，服务地址填：

```
http://服务器IP:端口?token=你的令牌
```

## 环境变量

二进制本身不带参数解析，配置全部走环境变量。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TTS_TOKEN` | 空（关闭鉴权） | 访问令牌，支持 `?token=` 与 `Authorization: Bearer`。为空即完全不鉴权，安装脚本会强制生成 |
| `HOST` | `0.0.0.0` | 绑定地址 |
| `PORT` | `8080` | 监听端口（安装脚本会注入 30000–59999 的随机高位端口） |
| `DEFAULT_VOICE` | `zh-CN-XiaoxiaoNeural` | 未指定 voice 时的默认音色 |
| `FIRST_BYTE_TIMEOUT_MS` | `10000` | 单次尝试拿首字节音频的超时 |
| `TOTAL_TIMEOUT_MS` | `60000` | 含重试的总超时预算 |
| `RETRY_MAX_ATTEMPTS` | `3` | 首字节失败的重试次数 |
| `RETRY_BACKOFF_MS` | `1000` | 首次重试基础退避，每次翻倍 |
| `CACHE_MAX_ITEMS` | `600` | LRU 缓存条目上限 |

晚高峰卡顿可调大超时：

```bash
export TTS_TOKEN="xxxx"
export FIRST_BYTE_TIMEOUT_MS=20000
export TOTAL_TIMEOUT_MS=120000
export RETRY_MAX_ATTEMPTS=4
./tts-server-rust
```

## 接口

```
GET /                                   状态页（HTML）
GET /voices?token=...                   {"voices":[...]}  阅读拉音色列表
GET /tts?text=&voice=&speed=&pitch=&volume=&style=&token=   audio/mpeg（流式）
```

`style` 参数会被接收但忽略（edge-tts 7.x 起不支持自定义 SSML 风格注入）。

## 手动部署

1. 到 [Releases](https://github.com/aucrazy-p/edge-tts-rust/releases) 下载对应架构：
   `tts-server-rust-linux-x86_64` / `tts-server-rust-linux-aarch64` / `tts-server-rust-windows-x86_64.exe`
2. `chmod +x` 后直接跑：

   ```bash
   export TTS_TOKEN="你的长随机令牌"
   export PORT=38641
   ./tts-server-rust
   ```

3. 不用反代就开放防火墙端口，阅读里填 `http://IP:端口?token=令牌`。要 HTTPS 再用 Caddy/Nginx 反代（Cloudflare 建议灰云直连，延迟更低）。

从源码构建：

```bash
cargo run --release
```

## 安全

- 配置文件 `/etc/tts-server-rust.conf` 权限 `600`，内含明文令牌。
- `TTS_TOKEN` 为空时服务端完全跳过鉴权，所以安装、启动时都会强制生成。
- 端口默认随机高位只是降低被扫描概率，**不是安全边界**——真正的防线是足够长的随机令牌。
- 令牌通过 URL query 传递（阅读的调用方式），会被沿途代理/日志记录，公网环境请配 HTTPS 或仅自己使用。
- 升级到修复版需重跑安装脚本（沿用原令牌与原端口）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh) update
```

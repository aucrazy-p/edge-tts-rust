# tts-server-rust

自托管 Edge TTS 服务（Rust 版），给 [legado_NG](https://github.com/gedoor/legado)（阅读 3.0）的「自托管 Edge TTS」引擎用。

- 空闲内存约 10–30 MB，128 MB 小鸡够用
- `/voices` 动态同步微软实时音色列表，阅读里能直接选
- 默认只保留**普通话**发音人，方言与港澳台自动剔除（`VOICE_SCOPE` 可切回全部中文）
- 音色名显示中文（晓晓 / 云希 / 云扬），按适合朗读的顺序排，童声靠后
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

更新（菜单 7 / `update`）会先停止正在运行的旧服务再替换二进制，装完显式 `systemctl restart`，因此端口、令牌、反代配置都保持原样，不需要重新填写。这一步是必须的：Linux 上二进制被原地替换后，运行中的进程仍持有旧 inode，不重启就一直跑旧版本。若中途失败（下载断、校验不过、端口被别的进程占用），脚本会把你原来那个服务重新拉起来，不会留下停摆状态。

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

## 音色范围

微软 Edge 免费朗读通道的中文音色本来就不多（实时列表 322 个音色里中文只有 14 个），默认只列**适合朗读的普通话**：

| 音色 | 定位 |
|------|------|
| 晓晓 | 少女感-温柔旁白（默认） |
| 晓亦 | 少女-活泼甜亮 |
| 云希 | 青年男声-阳光叙事 |
| 云间 | 低沉男声-热血解说 |
| 云扬 | 青年男声-专业播报 |
| 云夏 | 男童/少年-高亮稚嫩（童声，排在最后） |

被默认剔除的 8 个：粤语（HiuGaai / HiuMaan / WanLung）、台配（晓宸 / 晓语 / 云喆）、方言（辽宁晓北、陕西晓妮）。

想连它们一起列出，改成全部中文：

```bash
VOICE_SCOPE=all-zh
```

改完重启服务，`/voices` 缓存 24 小时，想立刻生效就重启进程（缓存存在内存里）。

> 说明：Edge 免费通道只支持 `prosody`（语速/音调/音量），**不支持 `<mstts:express-as>` 情绪风格**，所以音色不会随情节变情绪。要情绪得上 Azure 正式接口。

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
| `VOICE_SCOPE` | `mandarin` | 音色范围。`mandarin` 只列普通话（Edge 免费通道实际只有 6 个）；`all-zh` 连方言（辽宁晓北、陕西晓妮）和港澳台（粤语、台配）一起列出 |

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

## 依赖与版本升级

Edge 的通信协议、`Sec-MS-GEC` 签名和 WebM 封装由第三方库
[`edge-tts-rust`](https://crates.io/crates/edge-tts-rust)（上游 [Initsnow/edge-tts-rust](https://github.com/Initsnow/edge-tts-rust)）负责，
本项目在 `Cargo.toml` 里按精确版本锁定，保证构建产物可复现。

微软偶尔会调整签名算法，上游通常几天内跟进。为免手动盯版本，
`.github/workflows/upstream-sync.yml` 每天 09:17（北京时间）自动检查一次 crates.io：

1. 发现新版本 → 改写 `Cargo.toml` 并 `cargo update`，刷新 `Cargo.lock`
2. 先跑 `cargo build --release` 编译验证，**通过才提交**（避免把编不过的代码推上 main）
3. 提交后打新 tag（项目版本号在当前最大 `v*` tag 的 patch 位 +1，与依赖版本是两套编号）
4. 复用 `release.yml` 完成三平台构建并发布 Release

之后在服务器上执行 `bash install.sh update` 即可换上。

也可在 Actions 页面手动运行 **Sync Upstream Dependency**：`target_version` 留空表示自动检测，
填具体版本号则强制升到该版本（会跳过版本高低校验，便于验证整条链路）。

手动发版方式不变：打一个 `v*` tag 即可，`release.yml` 两种触发方式都支持。

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

## 排障

**更新后地址变了 / 端口被换掉了**（旧版安装脚本的问题，`update` 已修复）

旧版更新时不先停服务，`port_in_use` 把"自己"当成占用者，于是随机换了个端口并写进配置。恢复方法：

```bash
cat /etc/tts-server-rust.conf          # 看当前 PORT 是多少
bash install.sh stop
pkill -f tts-server-rust               # 干掉可能残留的旧进程
ss -lntp | grep tts-server-rust        # 确认为空
bash install.sh change-port            # 改回原来的端口（配了反代时自动同步 Caddy）
bash install.sh update                 # 用新版脚本重装
```

**更新后仍在跑旧版本**（同样已修复）：二进制被原地替换，但旧进程持有旧 inode。手动兜底就是一句 `systemctl restart tts-server-rust`。

**合成全部 403**：微软改了 `Sec-MS-GEC` 签名算法，依赖库没跟上。查 crates.io 有无新版；有就等自动同步工作流升级发版，没有才需要自己 fork 那个 crate 打补丁。

**`/voices` 只剩几条或显示拼音名**：拉的是旧二进制，`bash install.sh update` 一下即可。

## 安全

- 配置文件 `/etc/tts-server-rust.conf` 权限 `600`，内含明文令牌。
- `TTS_TOKEN` 为空时服务端完全跳过鉴权，所以安装、启动时都会强制生成。
- 端口默认随机高位只是降低被扫描概率，**不是安全边界**——真正的防线是足够长的随机令牌。
- 令牌通过 URL query 传递（阅读的调用方式），会被沿途代理/日志记录，公网环境请配 HTTPS 或仅自己使用。
- 升级到修复版需重跑安装脚本（沿用原令牌与原端口）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/edge-tts-rust/main/install.sh) update
```

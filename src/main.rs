//! tts-server-rust — 轻量自托管 Edge TTS 服务（Rust 版）
//!
//! 目标：用 Rust（axum + edge-tts-rust）重写原本的 Python 版 TTS-SERVER，
//! 1:1 对齐 legado_NG 内置「自托管 Edge TTS」引擎的 GET 契约，
//! 因此阅读里现有的引擎配置（self-hosted-edge-tts.json）**一行都不用改**，
//! 39 个音色下拉照旧。同时吸收两个方案的优点：
//!   - server.py 的【流式首字节低延迟】+【LRU 缓存】
//!   - enximi 的【指数退避重试】+【可配置超时】+【极低内存占用】
//!
//! 接口契约（与 Python 版完全一致）：
//!   GET /          -> 状态页（HTML）
//!   GET /voices?token=...        -> {"voices":[...39...]}（legado_NG 拉音色列表）
//!   GET /tts?text=&voice=&speed=&pitch=&volume=&style=&token= -> audio/mpeg（整段缓冲，带 Content-Length）

use std::num::NonZeroUsize;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, header},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use edge_tts_rust::{Boundary, EdgeTtsClient, EventStream, SpeakOptions, SynthesisEvent};
use futures::StreamExt;
use lru::LruCache;
use serde::Deserialize;
use tokio::sync::Mutex;
use tracing::info;
use tracing_subscriber::filter::LevelFilter;

// ----------------------------- 配置读取 -----------------------------

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    match std::env::var(key) {
        Ok(v) => v.trim().parse().unwrap_or(default),
        Err(_) => default,
    }
}

// ----------------------------- 应用状态 -----------------------------

struct AppState {
    client: EdgeTtsClient,
    token: String,
    default_voice: String,
    cache: Arc<Mutex<LruCache<String, Vec<u8>>>>,
    first_byte_timeout: Duration,
    total_timeout: Duration,
    retry_max_attempts: u32,
    retry_backoff: Duration,
    voices_json: &'static str,
    voice_count: usize,
}

impl Clone for AppState {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            token: self.token.clone(),
            default_voice: self.default_voice.clone(),
            cache: self.cache.clone(),
            first_byte_timeout: self.first_byte_timeout,
            total_timeout: self.total_timeout,
            retry_max_attempts: self.retry_max_attempts,
            retry_backoff: self.retry_backoff,
            voices_json: self.voices_json,
            voice_count: self.voice_count,
        }
    }
}

// ----------------------------- 请求参数 -----------------------------

#[derive(Deserialize)]
struct TtsQuery {
    text: Option<String>,
    voice: Option<String>,
    speed: Option<i32>,
    pitch: Option<i32>,
    volume: Option<i32>,
    style: Option<String>,
    token: Option<String>,
}

#[derive(Deserialize)]
struct TokenQuery {
    token: Option<String>,
}

// ----------------------------- 鉴权 -----------------------------

/// 支持两种方式：URL 上的 ?token=...（legado_NG 内置引擎走这个）或 Authorization: Bearer。
/// 未设置 TTS_TOKEN 时关闭鉴权。
fn check_token(token: &str, q: Option<&str>, headers: &HeaderMap) -> bool {
    if token.is_empty() {
        return true;
    }
    if let Some(t) = q {
        if t == token {
            return true;
        }
    }
    if let Some(h) = headers.get(header::AUTHORIZATION) {
        if let Ok(s) = h.to_str() {
            if s == format!("Bearer {token}") {
                return true;
            }
        }
    }
    false
}

fn unauthorized() -> Response {
    Response::builder()
        .status(401)
        .body(Body::from("unauthorized"))
        .unwrap()
}

// ----------------------------- 参数映射（必须对齐 server.py） -----------------------------

/// legado_NG 传入 speed/pitch/volume 为 0-100（默认 50），映射成 Edge 的 SSML 单位：
///   rate  = (speed-50)*1.5   -> -75% ~ +75%
///   pitch = (pitch-50)       -> -50Hz ~ +50Hz
///   vol   = (volume-50)*2    -> -100% ~ +100%
/// style 在 edge-tts 7.x 后无法注入（需 SSML），与 server.py 一致：接收但忽略。
fn map_units(speed: i32, pitch: i32, volume: i32) -> (String, String, String) {
    let speed = speed.clamp(0, 100);
    let pitch = pitch.clamp(0, 100);
    let volume = volume.clamp(0, 100);
    let rate = ((speed - 50) as f32 * 1.5).round() as i32;
    let pt = (pitch - 50) as i32;
    let vol = ((volume - 50) as f32 * 2.0).round() as i32;
    (
        format!("{rate:+}%"),
        format!("{pt:+}Hz"),
        format!("{vol:+}%"),
    )
}

// ----------------------------- 合成（含重试：先抢到首包再流式） -----------------------------

/// 在总超时预算内重试；每次尝试去拿“第一个音频块”，拿到后才开始往客户端推流，
/// 这样既能享受流式低首字节延迟，又能在首包失败前安全重试（避免推送半截音频）。
async fn acquire(
    state: &AppState,
    text: String,
    opts: SpeakOptions,
) -> Result<(Vec<u8>, EventStream), String> {
    let deadline = Instant::now() + state.total_timeout;
    let mut last_err = "unknown upstream error".to_string();
    for attempt in 1..=state.retry_max_attempts {
        let mut s = match state.client.stream(text.clone(), opts.clone()).await {
            Ok(s) => s,
            Err(e) => {
                last_err = e.to_string();
                sleep_backoff(state, attempt, deadline).await;
                continue;
            }
        };
        // 首字节超时不超过总预算剩余
        let fb = state
            .first_byte_timeout
            .min(deadline.checked_duration_since(Instant::now()).unwrap_or_default());
        let got = tokio::time::timeout(fb, async {
            loop {
                match s.next().await {
                    Some(Ok(SynthesisEvent::Audio(b))) => return Ok(b),
                    Some(Ok(_)) => continue, // 边界事件，跳过
                    Some(Err(e)) => return Err(e.to_string()),
                    None => return Err("stream ended before any audio".to_string()),
                }
            }
        })
        .await;
        match got {
            Ok(Ok(b)) => return Ok((b.to_vec(), s)),
            Ok(Err(e)) => last_err = e,
            Err(_) => last_err = "first-byte timeout".to_string(),
        }
        sleep_backoff(state, attempt, deadline).await;
    }
    Err(last_err)
}

async fn sleep_backoff(state: &AppState, attempt: u32, deadline: Instant) {
    if attempt < state.retry_max_attempts {
        let shift = attempt.saturating_sub(1);
        let mult = 1u32.checked_shl(shift).unwrap_or(u32::MAX);
        let backoff = state.retry_backoff.saturating_mul(mult);
        let remain = deadline.checked_duration_since(Instant::now()).unwrap_or_default();
        tokio::time::sleep(backoff.min(remain)).await;
    }
}

// ----------------------------- 路由处理 -----------------------------

async fn index_handler(Query(q): Query<TokenQuery>, State(state): State<AppState>) -> impl IntoResponse {
    let ok = check_token(&state.token, q.token.as_deref(), &HeaderMap::new());
    index_html(state.voice_count, ok, q.token.as_deref(), &state.token)
}

async fn voices_handler(
    Query(q): Query<TokenQuery>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    if !check_token(&state.token, q.token.as_deref(), &headers) {
        return unauthorized();
    }
    let body = format!(r#"{{"voices":{}}}"#, state.voices_json);
    ([(header::CONTENT_TYPE, "application/json; charset=utf-8")], body).into_response()
}

async fn tts_handler(
    Query(q): Query<TtsQuery>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    if !check_token(&state.token, q.token.as_deref(), &headers) {
        return unauthorized();
    }

    let text = match q.text.clone() {
        Some(t) if !t.trim().is_empty() => t,
        _ => return Response::builder().status(400).body(Body::from("missing text")).unwrap(),
    };

    let voice = q.voice.clone().unwrap_or_else(|| state.default_voice.clone());
    let (rate, pitch, volume) = map_units(
        q.speed.unwrap_or(50),
        q.pitch.unwrap_or(50),
        q.volume.unwrap_or(50),
    );

    // 缓存键：与 server.py 完全一致（voice|speed|pitch|volume|style|text）
    let key = format!(
        "{}|{}|{}|{}|{}|{}",
        voice,
        q.speed.unwrap_or(50),
        q.pitch.unwrap_or(50),
        q.volume.unwrap_or(50),
        q.style.clone().unwrap_or_default(),
        text
    );

    // 缓存命中：相同参数相同文本直接秒回（完整音频，带 Content-Length）
    if let Some(audio) = state.cache.lock().await.get(&key) {
        info!("cache hit ({} bytes)", audio.len());
        return ([
            (header::CONTENT_TYPE, "audio/mpeg".to_string()),
            (header::CONTENT_LENGTH, audio.len().to_string()),
        ], Body::from(audio.clone()))
            .into_response();
    }

    let mut opts = SpeakOptions::default();
    opts.voice = voice.clone();
    opts.rate = rate;
    opts.pitch = pitch;
    opts.volume = volume;
    opts.boundary = Boundary::Sentence;
    // 强制输出 MP3，与对外声明的 Content-Type: audio/mpeg 对齐。
    // edge-tts-rust 0.1.7 默认 output_format = "webm-24khz-16bit-mono-opus"，
    // 会让 Android/legado 播放器按 mp3 解码失败 (source error)；
    // 浏览器能放只是因为它会嗅探真实格式把 bug 盖住。
    opts.output_format = "audio-24khz-48kbitrate-mono-mp3".to_string();

    // 先抢首包（带重试），确认上游可用后再整段收取。
    // 关键点：legado 的 HTTP TTS 引擎需要“完整、带 Content-Length 的音频响应”，
    // 不支持分块流式（chunked）播放；因此改为整段缓冲后一次性返回，
    // 与参考 python 版及 enximi/edge-tts-for-legado 的已验证做法一致。
    let (first, stream) = match acquire(&state, text.clone(), opts).await {
        Ok(v) => v,
        Err(e) => {
            return Response::builder()
                .status(502)
                .body(Body::from(format!("tts upstream error: {e}")))
                .unwrap();
        }
    };

    let mut audio: Vec<u8> = first;
    let mut s = stream;
    while let Some(ev) = s.next().await {
        match ev {
            Ok(SynthesisEvent::Audio(b)) => audio.extend_from_slice(&b),
            Ok(_) => {} // 边界事件，忽略
            Err(e) => {
                return Response::builder()
                    .status(502)
                    .body(Body::from(format!("tts upstream error (mid-stream): {e}")))
                    .unwrap();
            }
        }
    }

    // 整段合成成功，写入缓存
    state.cache.lock().await.put(key, audio.clone());
    info!("synthesized {} bytes", audio.len());

    ([
        (header::CONTENT_TYPE, "audio/mpeg".to_string()),
        (header::CONTENT_LENGTH, audio.len().to_string()),
    ], Body::from(audio))
        .into_response()
}

// ----------------------------- 状态页 -----------------------------

fn index_html(
    voice_count: usize,
    token_ok: bool,
    given: Option<&str>,
    required: &str,
) -> impl IntoResponse {
    let status_line = if required.is_empty() || token_ok {
        r#"<span class="ok">✓ 服务运行中，一切正常</span>"#.to_string()
    } else {
        r#"<span class="bad">✗ Token 错误</span>——请核对服务地址里的 ?token=... 是否完整"#.to_string()
    };
    let token_line = if required.is_empty() {
        "未启用".to_string()
    } else if token_ok {
        r#"<span class="ok">校验通过</span>"#.to_string()
    } else {
        r#"<span class="bad">校验失败</span>"#.to_string()
    };
    let token_q = given.map(|t| format!("?token={t}")).unwrap_or_default();
    let token_a = given.map(|t| format!("&token={t}")).unwrap_or_default();
    let html = format!(
        r#"<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TTS-SERVER 状态</title><style>
 body{{font-family:system-ui,-apple-system,"Microsoft YaHei",sans-serif;background:#0f172a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}}
 .card{{background:#1e293b;border-radius:14px;padding:32px 40px;max-width:520px;width:92%;box-shadow:0 8px 30px rgba(0,0,0,.35)}}
 h1{{font-size:20px;margin:0 0 18px}} .ok{{color:#4ade80}} .warn{{color:#facc15}} .bad{{color:#f87171}}
 ul{{line-height:1.9;padding-left:20px;margin:14px 0}} a{{color:#60a5fa}} code{{background:#334155;padding:2px 6px;border-radius:4px;font-size:.9em}}
 .tip{{color:#94a3b8;font-size:13px;margin-top:16px}}
</style></head><body><div class="card">
<h1>🔊 TTS-SERVER (Rust)</h1>
<ul>
 <li>{status_line}</li>
 <li>音色数量：<b>{voice_count}</b> 个（legado_NG 默认全量）</li>
 <li>Token：{token_line}</li>
 <li>试听测试：<a href="/tts?text=你好，自托管语音服务已就绪{token_a}">点我播放一段测试语音</a></li>
 <li>音色清单：<a href="/voices{token_q}">/voices</a></li>
</ul>
<p class="tip">本服务为 legado_NG「自托管 Edge TTS」引擎专用 API，没有网页界面属正常现象。<br>
legado_NG 里『服务地址』填本页地址栏的完整 URL（含 ?token=...）。</p>
</div></body></html>"#,
        status_line = status_line,
        voice_count = voice_count,
        token_line = token_line,
        token_q = token_q,
    );
    ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], html).into_response()
}

// ----------------------------- 入口 -----------------------------

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().with_max_level(LevelFilter::INFO).init();

    // 39 音色目录：直接复用 server.py 的数据，编译期嵌入
    let voices_json: &'static str = include_str!("../voices.json");
    let voice_count = serde_json::from_str::<serde_json::Value>(voices_json)
        .ok()
        .and_then(|v| v.as_array().map(|a| a.len()))
        .unwrap_or(0);
    info!("loaded {voice_count} voices");

    let cache_size = env_or("CACHE_MAX_ITEMS", 600usize);
    let cache = Arc::new(Mutex::new(LruCache::new(
        NonZeroUsize::new(cache_size).unwrap_or(NonZeroUsize::new(600).unwrap()),
    )));

    let client = EdgeTtsClient::new()?;

    let state = AppState {
        client,
        token: env_or("TTS_TOKEN", String::new()),
        default_voice: env_or("DEFAULT_VOICE", "zh-CN-XiaoxiaoNeural".to_string()),
        cache,
        first_byte_timeout: Duration::from_millis(env_or("FIRST_BYTE_TIMEOUT_MS", 10_000u64)),
        total_timeout: Duration::from_millis(env_or("TOTAL_TIMEOUT_MS", 60_000u64)),
        retry_max_attempts: env_or("RETRY_MAX_ATTEMPTS", 3u32),
        retry_backoff: Duration::from_millis(env_or("RETRY_BACKOFF_MS", 1_000u64)),
        voices_json,
        voice_count,
    };

    let app = Router::new()
        .route("/", get(index_handler))
        .route("/voices", get(voices_handler))
        .route("/tts", get(tts_handler))
        .with_state(state);

    let host = env_or("HOST", "0.0.0.0".to_string());
    let port = env_or("PORT", 8080u16);
    let addr: std::net::SocketAddr = format!("{host}:{port}").parse()?;
    info!("TTS-SERVER (Rust) listening on http://{addr}");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

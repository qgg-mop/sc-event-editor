# -*- coding: utf-8 -*-
"""ShinyColors 風格 Agent API
把「角色語體規格 + 官方語料檢索 + 翻譯/改寫 + 語氣配音」包成一個 HTTP 介面。

啟動：
    D:\irodori\src\Irodori-TTS-main\.venv\Scripts\python.exe D:\事件編輯器\agent\style_agent_api.py --port 8090

端點：
    GET  /health
    GET  /style/card?speaker=月岡戀鐘
    POST /style/check        {"speaker":"月岡戀鐘","ja":"..."}
    GET  /corpus/search?speaker=月岡戀鐘&q=...&k=3
    GET  /models             (代理 8088 /models)
    GET  /voices             (代理 8088 /voices)
    POST /tts/line           {"speaker":"月岡戀鐘","text":"中文台詞","emotion":"欣喜","with_audio":true}
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import math
import os
import re
import struct
import time
import urllib.error
import urllib.request
from fastapi.responses import JSONResponse
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

ROOT = Path(r"D:\事件編輯器")
SPEC_PATH = ROOT / "資料" / "style" / "style-spec.json"
CORPUS_DIR = ROOT / "資料" / "style" / "corpus"
AI_CONFIG = Path(r"D:\語音模型\ai_config.json")
LLM_CONFIG = ROOT / "agent" / "llm-config.json"
TTS_BASE = "http://127.0.0.1:8088"
MAX_ROUNDS = 2

app = FastAPI(title="Style Agent API", version="1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)

_spec: dict | None = None
_manifest: dict | None = None
_corpus_cache: dict[str, list[dict]] = {}
_voices_cache: dict | None = None

# ---------- 基礎 ----------

def load_manifest() -> dict:
    global _manifest
    if _manifest is None:
        _manifest = json.loads((CORPUS_DIR / "_manifest.json").read_text(encoding="utf-8-sig"))
    return _manifest


def load_spec() -> dict:
    global _spec
    if _spec is None:
        _spec = json.loads(SPEC_PATH.read_text(encoding="utf-8-sig"))
        load_manifest()
    return _spec


def norm(s: str) -> str:
    return re.sub(r"[\s\u3000（）()・]", "", s or "")


def style_for(speaker: str) -> dict | None:
    spec = load_spec()
    n = norm(speaker)
    if not n:
        return None
    for c in spec.get("characters", []):
        for name in (c.get("tw"), c.get("jp"), c.get("zh")):
            nn = norm(name or "")
            if nn and (n == nn or nn in n or n in nn):
                return c
    return None


def official_speaker(card: dict) -> str | None:
    """角色 → 官方語料 speaker 短名（優先查 manifest，其次用日文名比對）。"""
    man = load_manifest()
    info = man.get(card.get("tw") or "")
    if info:
        return info.get("official")
    jp = norm(card.get("jp") or "")
    best = None
    for k, v in man.items():
        name = v.get("official") or ""
        if name and name in jp and (best is None or len(name) > len(best)):
            best = name
    return best


def load_corpus(short: str) -> list[dict]:
    if short in _corpus_cache:
        return _corpus_cache[short]
    rows = []
    entry = next((v for v in load_manifest().values() if v.get("official") == short), None)
    if entry:
        p = CORPUS_DIR / entry["file"]
        if p.exists():
            with p.open(encoding="utf-8") as f:
                for line in f:
                    try:
                        rows.append(json.loads(line))
                    except Exception:
                        pass
    _corpus_cache[short] = rows
    return rows


def llm_config() -> dict:
    """雲端 LLM 設定：優先 agent/llm-config.json，否則沿用 ai_config.json。"""
    cfg = None
    if LLM_CONFIG.exists():
        try:
            cfg = json.loads(LLM_CONFIG.read_text(encoding="utf-8-sig"))
        except Exception:
            cfg = None
    if not cfg:
        cfg = json.loads(AI_CONFIG.read_text(encoding="utf-8-sig"))
    if not cfg.get("api_key"):
        raise HTTPException(500, "沒有 API Key（agent/llm-config.json 或 ai_config.json）")
    return {"base_url": (cfg.get("base_url") or "https://api.deepseek.com").rstrip("/"),
            "model": cfg.get("model") or "deepseek-chat",
            "api_key": cfg.get("api_key")}


def ai_config() -> dict:
    return llm_config()


def http_json(url: str, payload: dict | None = None, timeout: int = 60, method: str = "POST") -> Any:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def http_bytes(url: str, payload: dict, timeout: int = 300) -> bytes:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ---------- 語體 ----------

def style_block(card: dict) -> str:
    L = [f"【角色語體：{card.get('tw')}（{card.get('jp')}）— 官方劇本統計】"]
    L.append(f"- 語体：{card.get('register','')}（整體敬語率 {card.get('keigo','?')}%）" +
             (f"；按場合：{card.get('scene')}" if card.get("scene") else ""))
    sp = card.get("special")
    if sp:
        L.append(f"- {sp.get('name')}（{sp.get('mode','')}）：角色形式 {'／'.join(sp.get('forms') or [])}" +
                 (f"；禁止使用 {'／'.join(sp.get('avoid') or [])}" if sp.get("avoid") else "") +
                 (f"；{sp.get('note')}" if sp.get("note") else ""))
    if card.get("first_person"):
        L.append(f"- 一人稱：{card['first_person']}")
    if card.get("len_min"):
        L.append(f"- 句長：{card['len_min']}–{card['len_max']} 字（中位 {card['len_med']}）")
    if card.get("endings"):
        L.append(f"- 常見句尾：{'、'.join(card['endings'])}")
    deg = card.get("degree") or {}
    if deg:
        L.append("- 頻率：" + "、".join(f"{k} {v}%" for k, v in deg.items()))
    if card.get("honorifics"):
        L.append(f"- 稱呼：{'、'.join(card['honorifics'])}")
    if card.get("examples"):
        L.append("- 官方範例：" + " ".join(f"「{e}」" for e in card["examples"]))
    L.append("以上統計必須遵守；禁止語尾絕對不要出現，角色語体有對應形式時要使用。")
    return "\n".join(L)


def speech_params(card: dict) -> dict:
    p = {"duration_scale": 1.0, "caption": ""}
    try:
        spd = float(card.get("speed") or 0)
    except Exception:
        spd = 0
    if spd > 0:
        p["duration_scale"] = round(max(0.82, min(1.30, 4.5 / spd)), 2)
    parts = []
    sp = card.get("special") or {}
    n = sp.get("name") or ""
    if "博多弁" in n: parts.append("明るく砕けた博多弁で")
    elif "武人腔" in n: parts.append("落ち着いた武人らしい口調で")
    elif "っす" in n: parts.append("元気で砕けた口調で")
    elif "古風" in n: parts.append("古風で丁寧な口調で")
    if not parts:
        reg = card.get("register") or ""
        parts.append("砕けた自然な口調で" if "平语" in reg else ("丁寧で落ち着いた口調で" if "场合驱动" in reg else "自然な口調で"))
    p["caption"] = "、".join(parts)
    return p


def metrics(card: dict, ja: str) -> dict:
    deg = card.get("degree") or {}
    m = {
        "length": len(ja),
        "len_min": card.get("len_min"),
        "len_max": card.get("len_max"),
        "len_med": card.get("len_med"),
        "keigo_per_100": round(len(re.findall(r"です|ます", ja)) * 100 / max(1, len(ja)), 1),
        "first_person": card.get("first_person"),
        "punct": {k: (k in ja) for k in ["！", "…", "？", "～"]},
        "degree_target": deg,
    }
    return m


def violations(card: dict, ja: str) -> list[str]:
    v: list[str] = []
    sp = card.get("special") or {}
    for w in sp.get("avoid") or []:
        if w and w in ja:
            v.append(f"使用了禁止語尾「{w}」")
    if sp.get("mode") == "全用" and sp.get("forms"):
        if not any(w and w in ja for w in sp["forms"]) and len(re.sub(r"[^\u3040-\u30ff\u4e00-\u9fff]", "", ja)) >= 14:
            v.append("沒有使用" + (sp.get("name") or "角色語体") + "（" + "／".join(sp["forms"]) + "）")
    fp = card.get("first_person")
    if fp:
        for w in ["わたくし", "わたし", "私", "僕", "ぼく", "あたし", "うち", "自分"]:
            if w != fp and w in ja and fp not in ja:
                v.append(f"一人稱要用「{fp}」，不要用「{w}」")
                break
    lmax = card.get("len_max")
    if lmax and len(ja) > lmax * 1.6:
        v.append(f"句子太長（{len(ja)} 字，官方中位 {card.get('len_med')}）")
    if "平语" in (card.get("register") or "") and len(re.findall(r"です|ます", ja)) >= 3:
        v.append("平语角色用了太多です／ます")
    return v


# ---------- 檢索 ----------

def bigrams(s: str) -> set:
    s = re.sub(r"[^\u3040-\u30ff\u4e00-\u9fff]", "", s)
    return {s[i:i+2] for i in range(len(s)-1)}


def search(short: str, q: str, k: int = 3) -> list[dict]:
    rows = load_corpus(short)
    if not rows:
        return []
    qb = bigrams(q)
    scored = []
    for r in rows:
        t = r.get("text") or ""
        if len(t) < 4 or len(t) > 60:
            continue
        tb = bigrams(t)
        if not tb:
            continue
        inter = len(qb & tb)
        score = inter / math.sqrt(len(tb) + 1)
        score -= abs(len(t) - len(q)) * 0.01
        if score > 0:
            scored.append((score, r))
    scored.sort(key=lambda x: -x[0])
    return [r for _, r in scored[:k]]


# ---------- LLM ----------

def chat(messages: list[dict], model: str | None = None, temperature: float = 0.3, max_tokens: int = 2000) -> str:
    cfg = llm_config()
    model = model or cfg["model"]
    body = {
        "model": model, "messages": messages,
        "temperature": temperature, "max_tokens": max_tokens,
    }
    req = urllib.request.Request(cfg["base_url"].rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + cfg["api_key"])
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise HTTPException(502, f"LLM 上游錯誤 {e.code}：{body}（模型 {model} 可能不存在）") from e
    except Exception as e:
        raise HTTPException(502, f"LLM 連線失敗：{e}") from e
    return (data["choices"][0]["message"].get("content") or "").strip()


def clean_line(s: str) -> str:
    s = s.strip().splitlines()[-1] if s.strip() else ""
    s = re.sub(r"^(日文|日本語|翻譯|Translation)\s*[:：]\s*", "", s.strip())
    return s.strip().strip('"「』').strip()


# ---------- API ----------

class CheckBody(BaseModel):
    speaker: str
    ja: str


class LineBody(BaseModel):
    speaker: str
    text: str = Field(min_length=1)
    emotion: str | None = None
    with_audio: bool = True
    model: str | None = None
    voice: str | None = None
    max_rounds: int = MAX_ROUNDS
    save: bool = False
    llm_model: str | None = None


@app.exception_handler(Exception)
async def _any_error(request, exc):
    return JSONResponse(status_code=500, content={"detail": str(exc)},
                        headers={"Access-Control-Allow-Origin": "*"})


@app.get("/health")
def health() -> dict:
    spec = load_spec()
    return {"ok": True, "characters": len(spec.get("characters", [])), "corpus_speakers": len(load_manifest())}


@app.get("/style/card")
def style_card(speaker: str = Query(...)) -> dict:
    card = style_for(speaker)
    if not card:
        raise HTTPException(404, "找不到角色：" + speaker)
    return {"ok": True, "speaker": card.get("tw"), "official": official_speaker(card),
            "speech": speech_params(card), "card": card}


@app.post("/style/check")
def style_check(body: CheckBody) -> dict:
    card = style_for(body.speaker)
    if not card:
        raise HTTPException(404, "找不到角色")
    return {"ok": True, "violations": violations(card, body.ja), "metrics": metrics(card, body.ja)}


@app.get("/corpus/search")
def corpus_search(speaker: str = Query(...), q: str = Query(...), k: int = 3) -> dict:
    card = style_for(speaker)
    if not card:
        raise HTTPException(404, "找不到角色")
    short = official_speaker(card)
    return {"ok": True, "official": short, "results": search(short, q, k) if short else []}


@app.get("/llm/config")
def get_llm_config() -> dict:
    cfg = llm_config()
    key = cfg["api_key"]
    return {"ok": True, "base_url": cfg["base_url"], "model": cfg["model"],
            "has_key": bool(key), "key_tail": key[-4:] if key else ""}


@app.post("/llm/config")
def set_llm_config(body: dict) -> dict:
    """{"base_url":"https://api.deepseek.com","model":"deepseek-chat","api_key":"sk-..."}"""
    cur = llm_config()
    cfg = {
        "base_url": (body.get("base_url") or cur["base_url"]).rstrip("/"),
        "model": body.get("model") or cur["model"],
        "api_key": body.get("api_key") or cur["api_key"],
    }
    LLM_CONFIG.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "base_url": cfg["base_url"], "model": cfg["model"]}


@app.get("/models")
def models() -> Any:
    return http_json(TTS_BASE + "/models", method="GET")


@app.get("/voices")
def voices() -> Any:
    return http_json(TTS_BASE + "/voices", method="GET")


def ensure_model(model: str) -> None:
    h = http_json(TTS_BASE + "/health", method="GET")
    if h.get("model") == model:
        return
    try:
        http_json(TTS_BASE + "/model/load", {"model": model}, timeout=300)
    except Exception as e:
        raise HTTPException(503, f"模型切換失敗：{e}")


def default_voice(card: dict) -> tuple[str, str] | None:
    """回傳 (model, voice)。"""
    global _voices_cache
    model = card.get("tw")
    if not model:
        return None
    if _voices_cache is None:
        _voices_cache = http_json(TTS_BASE + "/voices", method="GET")
    vs = [v for v in (_voices_cache.get("voices") or []) if v.get("character") == model]
    if not vs:
        return None
    return model, vs[0]["id"]


@app.post("/tts/line")
async def tts_line(body: LineBody) -> dict:
    t0 = time.time()
    card = style_for(body.speaker)
    if not card:
        raise HTTPException(404, "找不到角色：" + body.speaker)
    block = style_block(card)
    sys = ("你是《アイドルマスター シャイニーカラーズ》的日本語台詞翻譯。"
           "把下面中文台詞翻成角色本人的日文口吻，一人稱、句尾、稱呼要符合角色。"
           "只輸出日文台詞本身一行：不要引號、不要羅馬拼音、不要解釋、不要思考過程。\n\n" + block)
    msgs = [{"role": "system", "content": sys},
            {"role": "user", "content": f"說話者：{body.speaker}\n中文台詞：\n{body.text}"}]

    ja = ""
    rounds = 0
    viol: list[str] = []
    examples: list[dict] = []
    for attempt in range(body.max_rounds + 1):
        raw = await asyncio.to_thread(chat, msgs, body.llm_model or ("deepseek-flash" if attempt == 0 else "deepseek-chat"),
                                      0.3 if attempt == 0 else 0.2, 2000 if attempt == 0 else 900)
        ja = clean_line(raw)
        rounds = attempt + 1
        viol = violations(card, ja)
        if ja and not viol:
            break
        # 檢索官方相似句，帶進下一輪
        short = official_speaker(card)
        examples = await asyncio.to_thread(search, short, ja or body.text, 3) if short else []
        extra = "\n\n【官方相似台詞（僅供語感參考，不要照抄）】\n" + "\n".join(
            f"- 「{e['text']}」" for e in examples) if examples else ""
        fix = ("\n\n【上一輪的問題】\n- " + "\n- ".join(viol)) if viol else ""
        msgs = [{"role": "system", "content": sys + extra + fix},
                {"role": "user", "content": f"說話者：{body.speaker}\n中文台詞：\n{body.text}\n請重新輸出修正後的日文台詞。"}]

    if not ja:
        raise HTTPException(502, "翻譯失敗：模型沒有輸出")

    result = {
        "ok": not viol, "speaker": card.get("tw"), "ja": ja,
        "rounds": rounds, "violations": viol,
        "metrics": metrics(card, ja),
        "examples": [e.get("text") for e in examples],
        "speech": speech_params(card),
        "elapsed": round(time.time() - t0, 2),
    }

    if body.with_audio:
        mv = (body.model, body.voice) if body.model and body.voice else default_voice(card)
        if not mv:
            result["audio_error"] = "找不到對應模型／聲線"
            return result
        model, voice = mv
        await asyncio.to_thread(ensure_model, model)
        sp = result["speech"]
        payload = {"text": ja, "voice": voice, "response": "wav",
                   "duration_scale": sp["duration_scale"], "caption": sp["caption"]}
        if body.emotion:
            payload["emotion"] = body.emotion
        try:
            wav = await asyncio.to_thread(http_bytes, TTS_BASE + "/tts", payload, 300)
            result["model"] = model
            result["voice"] = voice
            result["audio_bytes"] = len(wav)
            if body.save:
                import hashlib
                key = f"{card.get('tw')}|{ja}|{voice}|{body.emotion or ''}|{sp['duration_scale']}"
                name = hashlib.sha1(key.encode("utf-8")).hexdigest()[:24] + ".wav"
                outdir = ROOT / "sc-editor" / "tts-cache"
                outdir.mkdir(parents=True, exist_ok=True)
                (outdir / name).write_bytes(wav)
                result["url"] = "/sc-editor/tts-cache/" + name
            else:
                result["audio_b64"] = base64.b64encode(wav).decode("ascii")
        except Exception as e:
            result["audio_error"] = str(e)
        result["elapsed"] = round(time.time() - t0, 2)
    return result


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
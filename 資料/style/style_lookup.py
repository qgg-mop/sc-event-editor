# -*- coding: utf-8 -*-
"""角色語體查詢工具（零依賴，任何 agent 都能呼叫）

用法：
    python style_lookup.py --list
    python style_lookup.py --speaker 月岡戀鐘
    python style_lookup.py --speaker 月岡戀鐘 --text "今天要不要一起去吃拉麵" --examples 3
    python style_lookup.py --speaker 月岡戀鐘 --check "わかったばい、うちが準備しとくけんね。"

輸出 JSON：
    {speaker, official, style_block, speech:{duration_scale,caption}, examples:[...], violations:[...], metrics:{...}}
"""
from __future__ import annotations
import argparse, json, math, os, re, sys

BASE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(BASE, "style-spec.json")
CORPUS = os.path.join(BASE, "corpus")
MANIFEST = os.path.join(CORPUS, "_manifest.json")

def norm(s): return re.sub(r"[\s\u3000（）()・]", "", s or "")

def load_spec(): return json.load(open(SPEC, encoding="utf-8"))

def find_card(speaker, spec=None):
    spec = spec or load_spec()
    n = norm(speaker)
    for c in spec["characters"]:
        for name in (c.get("tw"), c.get("jp"), c.get("zh")):
            nn = norm(name or "")
            if nn and (n == nn or nn in n or n in nn):
                return c
    return None

def style_block(c):
    L = [f"【角色語體：{c.get('tw')}（{c.get('jp')}）— 官方劇本統計】"]
    L.append(f"- 語体：{c.get('register','')}（整體敬語率 {c.get('keigo','?')}%）" + (f"；按場合：{c['scene']}" if c.get("scene") else ""))
    sp = c.get("special")
    if sp:
        L.append(f"- {sp.get('name')}（{sp.get('mode','')}）：角色形式 {'／'.join(sp.get('forms') or [])}" + (f"；禁止使用 {'／'.join(sp.get('avoid') or [])}" if sp.get("avoid") else "") + (f"；{sp.get('note')}" if sp.get("note") else ""))
    if c.get("first_person"): L.append(f"- 一人稱：{c['first_person']}")
    if c.get("len_min"): L.append(f"- 句長：{c['len_min']}–{c['len_max']} 字（中位 {c['len_med']}）")
    if c.get("endings"): L.append(f"- 常見句尾：{'、'.join(c['endings'])}")
    deg = c.get("degree") or {}
    if deg: L.append("- 頻率：" + "、".join(f"{k} {v}%" for k, v in deg.items()))
    if c.get("honorifics"): L.append(f"- 稱呼：{'、'.join(c['honorifics'])}")
    if c.get("examples"): L.append("- 官方範例：" + " ".join(f"「{e}」" for e in c["examples"]))
    L.append("以上統計必須遵守；禁止語尾絕對不要出現，角色語体有對應形式時要使用。")
    return "\n".join(L)

def speech_params(c):
    p = {"duration_scale": 1.0, "caption": ""}
    try: spd = float(c.get("speed") or 0)
    except Exception: spd = 0
    if spd > 0: p["duration_scale"] = round(max(0.82, min(1.30, 4.5 / spd)), 2)
    parts, sp = [], c.get("special") or {}
    n = sp.get("name") or ""
    if "博多弁" in n: parts.append("明るく砕けた博多弁で")
    elif "武人腔" in n: parts.append("落ち着いた武人らしい口調で")
    elif "っす" in n: parts.append("元気で砕けた口調で")
    elif "古風" in n: parts.append("古風で丁寧な口調で")
    if not parts:
        reg = c.get("register") or ""
        parts.append("砕けた自然な口調で" if "平语" in reg else ("丁寧で落ち着いた口調で" if "场合驱动" in reg else "自然な口調で"))
    if c.get("keigo") and float(c["keigo"]) < 3: parts.append("敬語はほとんど使わず")
    p["caption"] = "、".join(parts)
    return p

def bigrams(s):
    s = re.sub(r"[^\u3040-\u30ff\u4e00-\u9fff]", "", s or "")
    return {s[i:i+2] for i in range(len(s)-1)}

def examples_for(card, q, k=3):
    man = json.load(open(MANIFEST, encoding="utf-8"))
    info = man.get(card["tw"])
    if not info: return []
    rows = [json.loads(l) for l in open(os.path.join(CORPUS, info["file"]), encoding="utf-8")]
    if not q: return rows[:k]
    qb = bigrams(q); scored = []
    for r in rows:
        tb = bigrams(r["text"])
        if not tb: continue
        sc = len(qb & tb) / math.sqrt(len(tb) + 1) - abs(len(r["text"]) - len(q)) * 0.01
        if sc > 0: scored.append((sc, r))
    scored.sort(key=lambda x: -x[0])
    return [r for _, r in scored[:k]] or rows[:k]

def violations(c, ja):
    v, sp = [], c.get("special") or {}
    for w in sp.get("avoid") or []:
        if w and w in ja: v.append(f"使用了禁止語尾「{w}」")
    if sp.get("mode") == "全用" and sp.get("forms"):
        if not any(w and w in ja for w in sp["forms"]) and len(re.sub(r"[^\u3040-\u30ff\u4e00-\u9fff]", "", ja)) >= 14:
            v.append("沒有使用" + (sp.get("name") or "角色語体") + "（" + "／".join(sp["forms"]) + "）")
    fp = c.get("first_person")
    if fp:
        for w in ["わたくし","わたし","私","僕","ぼく","あたし","うち","自分"]:
            if w != fp and w in ja and fp not in ja:
                v.append(f"一人稱要用「{fp}」，不要用「{w}」"); break
    if c.get("len_max") and len(ja) > c["len_max"] * 1.6:
        v.append(f"句子太長（{len(ja)} 字，官方中位 {c.get('len_med')}）")
    if "平语" in (c.get("register") or "") and len(re.findall(r"です|ます", ja)) >= 3:
        v.append("平语角色用了太多です／ます")
    return v

def metrics(c, ja):
    return {"length": len(ja), "len_min": c.get("len_min"), "len_max": c.get("len_max"),
            "len_med": c.get("len_med"), "keigo_count": len(re.findall(r"です|ます", ja)),
            "first_person": c.get("first_person")}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--speaker")
    ap.add_argument("--text", default="")
    ap.add_argument("--check", default="")
    ap.add_argument("--examples", type=int, default=3)
    a = ap.parse_args()
    spec = load_spec()
    if a.list:
        print(json.dumps([{"tw": c["tw"], "jp": c["jp"], "register": c.get("register")} for c in spec["characters"]], ensure_ascii=False, indent=1)); return
    if not a.speaker:
        ap.print_help(); return
    c = find_card(a.speaker, spec)
    if not c:
        print(json.dumps({"error": "找不到角色：" + a.speaker}, ensure_ascii=False)); sys.exit(1)
    out = {"speaker": c["tw"], "official": (json.load(open(MANIFEST, encoding="utf-8")).get(c["tw"]) or {}).get("official"),
           "style_block": style_block(c), "speech": speech_params(c)}
    if a.text: out["examples"] = [e["text"] for e in examples_for(c, a.text, a.examples)]
    if a.check:
        out["violations"] = violations(c, a.check)
        out["metrics"] = metrics(c, a.check)
    print(json.dumps(out, ensure_ascii=False, indent=1))

if __name__ == "__main__":
    main()
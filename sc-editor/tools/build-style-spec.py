# -*- coding: utf-8 -*-
import re, json
src = r"D:\下載\翻译参数表.md"
out = r"D:\事件編輯器\sc-editor\style-spec.json"
txt = open(src, encoding="utf-8").read()
TW = {
 "櫻木真乃":"櫻木真乃","風野灯織":"風野燈織","八宮めぐる":"八宮巡","月岡恋鐘":"月岡戀鐘",
 "田中摩美々":"田中摩美美","白瀬咲耶":"白瀨咲耶","三峰結華":"三峰結華","幽谷霧子":"幽谷霧子",
 "小宮果穂":"小宮果穗","園田智代子":"園田智代子","西城樹里":"西城樹里","杜野凛世":"杜野凜世",
 "有栖川夏葉":"有栖川夏葉","大崎甘奈":"大崎甘奈","大崎甜花":"大崎甜花","桑山千雪":"桑山千雪",
 "芹沢あさひ":"芹澤朝日","黛冬優子":"黛冬優子","和泉愛依":"和泉愛依","浅倉透":"淺倉透",
 "樋口円香":"樋口圓香","福丸小糸":"福丸小糸","市川雛菜":"市川雛菜","七草にちか":"七草日花",
 "緋田美琴":"緋田美琴","斑鳩ルカ":"斑鳩路加","鈴木羽那":"鈴木羽那","郁田はるき":"郁田陽希",
 "七草はづき":"七草葉月",
}
secs=[]; cur=None
for ln in txt.splitlines():
    m = re.match(r"^## (.+?)（(.+?)）\s*$", ln)
    if m:
        cur={"jp":m.group(1).strip(),"zh":m.group(2).strip(),"raw":[]}; secs.append(cur)
    elif cur is not None:
        cur["raw"].append(ln)

def first(pat, text, default=""):
    m = re.search(pat, text, re.M)
    return m.group(1).strip() if m else default

chars=[]
for s in secs:
    raw="\n".join(s["raw"])
    c={"jp":s["jp"],"zh":s["zh"],"tw":TW.get(s["jp"],s["zh"]),
       "register":first(r"\*\*语体：(.+?)\*\*",raw),
       "keigo":first(r"整体敬语率 ([\d.]+)%",raw),
       "scene":first(r"按场合：(.+)",raw),
       "first_person":first(r"\| 一人称 \| \*\*(.+?)\*\*（([\d.]+)%",raw),
       "first_person_rate":first(r"\| 一人称 \| \*\*.+?\*\*（([\d.]+)%",raw),
       "speed":first(r"\| 语速 \| ([\d.]+) 字/秒",raw),
       "endings":[],"degree":{},"honorifics":[],"examples":[],"special":None}
    m=re.search(r"\| 句长 \| (\d+)[\-–](\d+) 字（中位 (\d+)）",raw)
    if m: c["len_min"],c["len_max"],c["len_med"]=int(m.group(1)),int(m.group(2)),int(m.group(3))
    ends=first(r"\| 句尾前六 \| (.+)",raw).replace("|","")
    c["endings"]=[x.strip() for x in re.split(r"[、,]",ends) if x.strip()]
    for dm in re.finditer(r"^- (.+?)：(\d+)% 的句子有",raw,re.M):
        c["degree"][dm.group(1).strip()]=int(dm.group(2))
    h=first(r"\*\*称呼\*\*：(.+)",raw)
    if h: c["honorifics"]=[x.strip() for x in h.split("、") if x.strip()]
    ex=first(r"例：(.+)",raw)
    if ex: c["examples"]=re.findall(r"「(.+?)」",ex)
    sm=re.search(r"\*\*(.+?)：(全用|部分用)\*\*",raw)
    if sm:
        block=raw[sm.start():]
        forms=first(r"角色形式：(.+)",block)
        avoid=first(r"\*\*不用\*\*：(.+)",block)
        note=first(r"判定：\*\*(.+?)\*\*",block)
        c["special"]={"name":sm.group(1).strip(),"mode":sm.group(2),
                      "forms":[x.strip() for x in re.split(r"[/／、]",forms) if x.strip()],
                      "avoid":[x.strip() for x in re.split(r"[/／、]",avoid) if x.strip()],
                      "note":note}
    if c["register"] or c["first_person"]: chars.append(c)

json.dump({"source":"翻译参数表.md","count":len(chars),"characters":chars},
          open(out,"w",encoding="utf-8"),ensure_ascii=False,indent=1)
print("角色",len(chars))
for c in chars:
    if c.get("special"): print(c["tw"], c["special"]["name"], c["special"]["mode"], c["special"]["forms"], "避:",c["special"]["avoid"])
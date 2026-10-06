#!/usr/bin/env python3
"""把官方 dlc.dat 合并成我们用的 dlc.dat（v2ray routercommon GeoSiteList 格式）。

规则：
  1. 官方 dat 的全部列表 / 域名 / 类型 / 属性原样保留 —— dlc 的历史一条不丢
  2. 已有的条目就地追加属性：@ads（filter_49）/ @cn（国内列表）/ @fake（!cn 走代理）
     优先级 ads > cn > fake，一个域名只打最高优先级那个
  3. dlc 里没有的域名写进对应列表：ADS / FAKE 新建，CN 追加进已有的 CN 列表
     目标条目一律用 Domain 型（后缀匹配），与 upstream.conf 的 [/domain/] 语义一致

输入是他生成的三个纯域名列表；--selfcheck 会在写盘前用官方 dat 验证编解码
往返是否字节一致，不一致就报错退出（防止格式漂移写出坏文件）。
"""

import argparse
import collections
import sys

# ---- proto: GeoSiteList { repeated GeoSite entry = 1 } ----
# GeoSite   { string country_code = 1; repeated Domain domain = 2 }
# Domain    { Type type = 1; string value = 2; repeated Attribute attribute = 3 }
# Attribute { string key = 1; oneof { bool bool_value = 2; int64 int_value = 3 } }
DOMAIN_TYPE = 2


def read_varint(buf, i):
    value = shift = 0
    while True:
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7


def write_varint(value):
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        out.append(b | (0x80 if value else 0))
        if not value:
            return bytes(out)


def field_bytes(num, payload):
    return write_varint((num << 3) | 2) + write_varint(len(payload)) + payload


def field_string(num, text):
    return field_bytes(num, text.encode())


def field_varint(num, value):
    return write_varint(num << 3) + write_varint(value)


def decode(data):
    """-> [(country_code, [{type, value, attrs:[[key, value, is_bool]]}])]"""
    sites = []
    i = 0
    while i < len(data):
        tag, i = read_varint(data, i)
        if tag != 0x0A:
            raise ValueError("GeoSiteList 里出现未知字段 tag=%#x" % tag)
        size, i = read_varint(data, i)
        sites.append(decode_site(data[i:i + size]))
        i += size
    return sites


def decode_site(buf):
    code = ""
    domains = []
    i = 0
    while i < len(buf):
        tag, i = read_varint(buf, i)
        if tag == 0x0A:
            size, i = read_varint(buf, i)
            code = buf[i:i + size].decode()
            i += size
        elif tag == 0x12:
            size, i = read_varint(buf, i)
            domains.append(decode_domain(buf[i:i + size]))
            i += size
        else:
            raise ValueError("GeoSite 里出现未知字段 tag=%#x" % tag)
    return code, domains


def decode_domain(buf):
    dom = {"type": 0, "value": "", "attrs": []}
    i = 0
    while i < len(buf):
        tag, i = read_varint(buf, i)
        if tag == 0x08:
            dom["type"], i = read_varint(buf, i)
        elif tag == 0x12:
            size, i = read_varint(buf, i)
            dom["value"] = buf[i:i + size].decode()
            i += size
        elif tag == 0x1A:
            size, i = read_varint(buf, i)
            dom["attrs"].append(decode_attr(buf[i:i + size]))
            i += size
        else:
            raise ValueError("Domain 里出现未知字段 tag=%#x" % tag)
    return dom


def decode_attr(buf):
    attr = {"key": "", "value": 0, "is_bool": True}
    i = 0
    while i < len(buf):
        tag, i = read_varint(buf, i)
        if tag == 0x0A:
            size, i = read_varint(buf, i)
            attr["key"] = buf[i:i + size].decode()
            i += size
        elif tag == 0x10:
            attr["value"], i = read_varint(buf, i)
            attr["is_bool"] = True
        elif tag == 0x18:
            attr["value"], i = read_varint(buf, i)
            attr["is_bool"] = False
        else:
            raise ValueError("Attribute 里出现未知字段 tag=%#x" % tag)
    return attr


def encode(sites):
    out = bytearray()
    for code, domains in sites:
        site = bytearray(field_string(1, code))
        for dom in domains:
            body = bytearray()
            if dom["type"]:
                body += field_varint(1, dom["type"])
            body += field_string(2, dom["value"])
            for attr in dom["attrs"]:
                one = bytearray(field_string(1, attr["key"]))
                one += field_varint(2 if attr["is_bool"] else 3, attr["value"])
                body += field_bytes(3, bytes(one))
            site += field_bytes(2, bytes(body))
        out += field_bytes(1, bytes(site))
    return bytes(out)


def load_domains(path):
    with open(path, encoding="utf-8") as fh:
        return {line.strip() for line in fh if line.strip()}


def has_attr(dom, key):
    return any(a["key"] == key for a in dom["attrs"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="官方 dlc.dat")
    ap.add_argument("--ads", required=True, help="filter_49 域名列表")
    ap.add_argument("--cn", required=True, help="国内域名列表")
    ap.add_argument("--fake", required=True, help="!cn 域名列表")
    ap.add_argument("--out", required=True, help="输出 dlc.dat")
    args = ap.parse_args()

    raw = open(args.base, "rb").read()
    sites = decode(raw)
    if encode(sites) != raw:
        sys.exit("dlc_dat: 官方 dlc.dat 编解码往返不是字节一致，疑似格式变化，中止")
    print("dlc_dat: 基准 %d 个列表 / %d 个域名，往返自检通过"
          % (len(sites), sum(len(d) for _, d in sites)))

    # 优先级 ads > cn > fake：一个域名只打一个标签
    tag_of = {}
    for tag, path in (("fake", args.fake), ("cn", args.cn), ("ads", args.ads)):
        for dom in load_domains(path):
            tag_of[dom] = tag
    counts = collections.Counter(tag_of.values())
    print("dlc_dat: 输入 ads %d / cn %d / fake %d（合并后 %d）"
          % (counts["ads"], counts["cn"], counts["fake"], len(tag_of)))

    # 域名 -> 它在哪些列表里出现过（只认 Domain 型，用于就地打标签）
    index = collections.defaultdict(list)
    for si, (_, domains) in enumerate(sites):
        for di, dom in enumerate(domains):
            if dom["type"] == DOMAIN_TYPE:
                index[dom["value"]].append((si, di))

    added = collections.Counter()
    pending = collections.defaultdict(list)
    for dom, tag in sorted(tag_of.items()):
        hits = [h for h in index.get(dom, []) if not has_attr(sites[h[0]][1][h[1]], tag)]
        if hits:
            for si, di in hits:
                sites[si][1][di]["attrs"].append({"key": tag, "value": 1, "is_bool": True})
                added["inplace " + tag] += 1
        else:
            pending[tag].append(dom)

    # dlc 里没有的（或只有 Full 型、覆盖不到子域的）域名，写进对应列表
    by_code = {code: i for i, (code, _) in enumerate(sites)}
    for tag, listname in (("ads", "ADS"), ("cn", "CN"), ("fake", "FAKE")):
        if not pending[tag]:
            continue
        entries = [{"type": DOMAIN_TYPE, "value": d,
                    "attrs": [{"key": tag, "value": 1, "is_bool": True}]}
                   for d in pending[tag]]
        if listname in by_code:
            sites[by_code[listname]][1].extend(entries)
        else:
            sites.append((listname, entries))
        added["new list " + listname] = len(entries)

    out = encode(sites)
    with open(args.out, "wb") as fh:
        fh.write(out)

    print("dlc_dat: 就地加属性 %d 条，新增条目 %d 条 -> %s（%d 字节，%d 个列表）"
          % (sum(v for k, v in added.items() if k.startswith("inplace")),
             sum(v for k, v in added.items() if k.startswith("new")),
             args.out, len(out), len(sites)))
    for key in sorted(added):
        print("           %-16s %d" % (key, added[key]))

    # 自检：解码回来，确认每个输入域名都能查到它的标签
    check = decode(out)
    tagged = collections.defaultdict(set)
    for code, domains in check:
        for dom in domains:
            for attr in dom["attrs"]:
                if attr["key"] in ("ads", "cn", "fake"):
                    tagged[dom["value"]].add(attr["key"])
    missing = [d for d in tag_of if tag_of[d] not in tagged.get(d, ())]
    if missing:
        sys.exit("dlc_dat: 自检失败，%d 个域名没打上标签，例：%s" % (len(missing), missing[:5]))
    print("dlc_dat: 自检通过，%d 个域名全部带上标签" % len(tag_of))


if __name__ == "__main__":
    main()

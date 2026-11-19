// 按来源 IP 限额时用的键:IPv4 用完整地址;IPv6 只取前 56 位(一个家庭 / 一个站点通常分到一整段 /56 或更大,
// 同一段里每换一个源地址就是一个新键的话,限额等于没有);IPv4 映射的 IPv6(::ffff:a.b.c.d)当 IPv4。
// 认不出的原样返回(只截长度),跟原来按完整字符串计一样。见 14 章决策 232。
export const IPV6_QUOTA_PREFIX_BITS = 56;

export function quotaIPKey(ip) {
  if (typeof ip !== "string" || !ip) return "unknown";
  const raw = ip.trim().toLowerCase();
  if (!raw.includes(":")) return raw.slice(0, 64);
  const groups = parseIPv6(raw);
  if (!groups) return raw.slice(0, 64);
  // ::ffff:0:0/96 是 IPv4 映射地址,按里面那个 IPv4 计。
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    return [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff].join(".");
  }
  const kept = [];
  for (let i = 0, bits = IPV6_QUOTA_PREFIX_BITS; i < 8; i++, bits -= 16) {
    const take = Math.max(0, Math.min(16, bits));
    kept.push(take === 0 ? 0 : groups[i] & ((0xffff << (16 - take)) & 0xffff));
  }
  return kept.map((g) => g.toString(16)).join(":") + "/" + IPV6_QUOTA_PREFIX_BITS;
}

// 解析成 8 个 16 位组;带区域号(%en0)的去掉区域号,末尾可以是点分 IPv4。不合法返回 null。
function parseIPv6(s) {
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  let tail = [];
  const lastColon = s.lastIndexOf(":");
  const v4 = s.slice(lastColon + 1);
  if (v4.includes(".")) {
    const b = v4.split(".");
    if (b.length !== 4 || !b.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)) return null;
    tail = [(Number(b[0]) << 8) | Number(b[1]), (Number(b[2]) << 8) | Number(b[3])];
    // 去掉 IPv4 那段:剩下的以 "::" 结尾就留着(压缩的零在这里),否则去掉末尾那个冒号。
    s = s.slice(0, lastColon + 1);
    if (!s.endsWith("::")) s = s.slice(0, -1);
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const part = (h) => (h === "" ? [] : h.split(":"));
  const head = part(halves[0]), rest = halves.length === 2 ? part(halves[1]) : [];
  const words = [...head, ...rest];
  if (!words.every((w) => /^[0-9a-f]{1,4}$/.test(w))) return null;
  const total = words.length + tail.length;
  if (halves.length === 1 ? total !== 8 : total > 7) return null;
  const fill = new Array(8 - total).fill(0);
  return [...head, ...fill, ...rest].map((w) => (typeof w === "number" ? w : parseInt(w, 16))).concat(tail);
}

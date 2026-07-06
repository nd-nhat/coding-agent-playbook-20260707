// 決定的 PRNG（mulberry32）。docs/design.md §7「決定的・seed 固定」。
// Math.random() を使わず、同じ seed なら毎回同じ列を返す（デモ再現性）。

/** seed から [0,1) の擬似乱数を返す関数を生成する */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

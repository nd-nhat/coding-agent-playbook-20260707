export type HeroVariant = 'good' | 'bad' | 'even';

// yen() が四捨五入で ￥0 表示になる差額は損益分岐として扱う
export function heroVariant(annualDiff: number): HeroVariant {
  if (Math.round(Math.abs(annualDiff)) === 0) return 'even';
  return annualDiff > 0 ? 'good' : 'bad';
}

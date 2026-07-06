const yenFmt = new Intl.NumberFormat('ja-JP', { style: 'currency', currency: 'JPY', maximumFractionDigits: 0 });

/** 12345 -> "￥12,345" */
export const yen = (n: number): string => yenFmt.format(Math.round(n));

/** "2025-06" -> "6月" */
export const monthLabel = (ym: string): string => `${Number(ym.slice(5, 7))}月`;

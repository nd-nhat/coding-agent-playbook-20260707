// 構造化ログ（JSON 1 行）。収集側で機械処理できるよう key を固定形に揃える。

export type LogLevel = 'info' | 'error';

export function log(level: LogLevel, event: string, fields: Record<string, unknown>): void {
  const line = JSON.stringify({ level, event, time: new Date().toISOString(), ...fields });
  if (level === 'error') console.error(line);
  else console.log(line);
}

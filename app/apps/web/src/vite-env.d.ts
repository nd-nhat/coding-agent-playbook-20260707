/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** デモモード（'false' で本番扱い、デモ用ヒントを隠す）。既定はデモ */
  readonly VITE_DEMO?: string;
}
interface ImportMeta {
  readonly env: ImportMetaEnv;
}

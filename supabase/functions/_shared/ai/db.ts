// supabase-js 클라이언트에서 AI 모듈이 쓰는 부분만. 테스트에서는 메모리 구현으로 바꿔 끼운다.
// deno-lint-ignore no-explicit-any
export type QueryBuilder = any;

export interface Db {
  from(table: string): QueryBuilder;
  rpc(fn: string, args?: Record<string, unknown>): QueryBuilder;
}

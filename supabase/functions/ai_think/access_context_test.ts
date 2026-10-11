import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  filterMemoriesForAi,
  memoryVisibleToRole,
  type ConversationAccessState,
} from './access_context.ts';
import { memory } from './test_support.ts';

function ctx(partial: Partial<ConversationAccessState>): ConversationAccessState {
  return {
    conversationId: 'c1',
    thinkRoleId: 'education',
    extraRefDepartments: [],
    linkedMemoryIds: new Set(),
    linkedDocumentNodeIds: new Set(),
    rolesFeatureReady: true,
    ...partial,
  };
}

Deno.test('부서 범위 기억은 해당 역할·명시 참조·연결·총괄만 AI에 보인다', () => {
  const deptMem = memory({
    id: 'd1',
    kind: 'note',
    title: '교육 메모',
    memory_scope: 'department',
    scope_department: 'education',
  });
  const productMem = memory({
    id: 'p1',
    kind: 'note',
    title: '제품 메모',
    memory_scope: 'department',
    scope_department: 'product',
  });
  assert(memoryVisibleToRole(deptMem, ctx({ thinkRoleId: 'education' })));
  assert(!memoryVisibleToRole(productMem, ctx({ thinkRoleId: 'education' })));
  assert(memoryVisibleToRole(productMem, ctx({ thinkRoleId: 'lead' })));
  assert(memoryVisibleToRole(productMem, ctx({ thinkRoleId: 'education', extraRefDepartments: ['product'] })));
  assert(memoryVisibleToRole(productMem, ctx({ thinkRoleId: 'education', linkedMemoryIds: new Set(['p1']) })));
});

Deno.test('구버전(역할 기능 미준비)은 레거시·공통 기억만 AI에 노출한다', () => {
  const legacy = memory({ id: 'l1', kind: 'note', title: '레거시', memory_scope: 'legacy_unscoped' });
  const dept = memory({
    id: 'd1',
    kind: 'note',
    title: '부서',
    memory_scope: 'department',
    scope_department: 'engineering',
  });
  const c = ctx({ rolesFeatureReady: false });
  assertEquals(filterMemoriesForAi([legacy, dept], c).map((m) => m.id), ['l1']);
});

Deno.test('identity는 역할·범위와 관계없이 항상 보인다', () => {
  const idMem = memory({ id: 'i1', kind: 'identity', title: '철학', memory_scope: 'common' });
  assert(memoryVisibleToRole(idMem, ctx({ thinkRoleId: 'engineering' })));
});

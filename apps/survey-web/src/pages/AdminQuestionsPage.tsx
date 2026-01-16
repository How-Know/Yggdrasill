import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { getSupabaseConfig, supabase } from '../lib/supabaseClient';
import * as XLSX from 'xlsx';

const tokens = {
  // ✅ 앱(학생 탭) 배경색과 통일 (Flutter: 0xFF0B1112)
  bg: '#0B1112',
  panel: '#18181A',
  border: '#2A2A2A',
  text: '#FFFFFF',
  textDim: 'rgba(255,255,255,0.7)',
  accent: '#1976D2',
};

type QuestionDraft = {
  id: string;
  trait: 'D'|'I'|'A'|'C'|'N'|'L'|'S'|'P';
  text: string;
  type: 'scale'|'text';
  min?: number;
  max?: number;
  reverse: 'Y'|'N';
  weight?: number;
  tags?: string;
  memo?: string;
  area?: string;
  group?: string;
  image?: string;
  pairId?: string;
  active?: boolean;
  version?: number;
};

type TraitRound = {
  id: string;
  name: string;
  description?: string | null;
  order_index?: number | null;
  is_active?: boolean | null;
};

type TraitRoundPart = {
  id: string;
  round_id: string;
  name: string;
  description?: string | null;
  image_url?: string | null;
  order_index?: number | null;
};

function ToolbarButton({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) {
  return (
    <button onClick={onClick} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}>{children}</button>
  );
}

function Modal({ title, onClose, children, actions, width }: { title: string; onClose: () => void; children: React.ReactNode; actions?: React.ReactNode; width?: number | string }) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 50 }}>
      <div style={{ width: (width ?? 'min(720px, 92vw)'), background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20, overflow: 'visible' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <div style={{ color: tokens.text, fontWeight: 900 }}>{title}</div>
          <button onClick={onClose} style={{ background: 'transparent', border: 'none', color: tokens.textDim, cursor: 'pointer' }}>✕</button>
        </div>
        <div>{children}</div>
        {actions && <div style={{ marginTop: 12, display: 'flex', gap: 8, justifyContent: 'flex-end' }}>{actions}</div>}
      </div>
    </div>
  );
}

function DragHandle() {
  return <span style={{ cursor: 'grab', color: tokens.textDim }}>≡</span>;
}

function ManageListDialog({ title, items, setItems, onClose }: { title: string; items: {id:string; name:string}[]; setItems: (v: {id:string; name:string}[]) => void; onClose: () => void }) {
  const [name, setName] = useState('');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [draftName, setDraftName] = useState('');
  const [dragIndex, setDragIndex] = useState<number | null>(null);

  async function add() {
    if (!name.trim()) return;
    const table = title.includes('영역') ? 'question_areas' : 'question_groups';
    const { data, error } = await supabase.from(table).insert({ name: name.trim(), order_index: items.length }).select('id,name').single();
    if (!error && data) {
      setItems([...items, { id: (data as any).id, name: (data as any).name }]);
    }
    setName('');
  }
  async function remove(id: string) {
    const table = title.includes('영역') ? 'question_areas' : 'question_groups';
    await supabase.from(table).delete().eq('id', id);
    setItems(items.filter((x) => x.id !== id));
  }
  function startEdit(id: string) {
    const it = items.find((x) => x.id === id);
    if (!it) return;
    setEditingId(id);
    setDraftName(it.name);
  }
  async function saveEdit() {
    if (!editingId) return;
    const table = title.includes('영역') ? 'question_areas' : 'question_groups';
    const nextName = draftName.trim();
    await supabase.from(table).update({ name: nextName }).eq('id', editingId);
    setItems(items.map((x) => x.id === editingId ? { ...x, name: nextName || x.name } : x));
    setEditingId(null);
    setDraftName('');
  }
  async function onDrag(startIdx: number, endIdx: number) {
    if (endIdx < 0 || endIdx >= items.length || startIdx === endIdx) return;
    const next = items.slice();
    const [moved] = next.splice(startIdx, 1);
    next.splice(endIdx, 0, moved);
    setItems(next);
    const table = title.includes('영역') ? 'question_areas' : 'question_groups';
    const payload = next.map((x, i) => ({ id: x.id, order_index: i }));
    await supabase.from(table).upsert(payload, { onConflict: 'id' });
  }

  return (
    <Modal title={title} onClose={onClose} actions={<>
      <button onClick={onClose} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}>닫기</button>
    </>}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
        <input value={name} onChange={(e)=>setName(e.target.value)} placeholder="이름 입력" style={{ flex: 1, minWidth: 0, height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px' }} />
        <button onClick={add} style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer' }}>추가</button>
      </div>

      <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12 }}>
        {items.length === 0 ? (
          <div style={{ padding: 14, color: tokens.textDim }}>아직 항목이 없습니다.</div>
        ) : (
          items.map((it, idx) => (
            <div key={it.id}
                 draggable
                 onDragStart={()=>setDragIndex(idx)}
                 onDragOver={(e)=>e.preventDefault()}
                 onDrop={()=>{ if (dragIndex !== null) onDrag(dragIndex, idx); setDragIndex(null); }}
                 style={{ display: 'grid', gridTemplateColumns: '32px 1fr 200px', alignItems: 'center', gap: 8, padding: 10, borderBottom: `1px solid ${tokens.border}` }}>
              <div><DragHandle /></div>
              <div>
                {editingId === it.id ? (
                  <input value={draftName} onChange={(e)=>setDraftName(e.target.value)} style={{ width: '100%', height: 36, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 10px' }} />
                ) : (
                  <div>{it.name}</div>
                )}
              </div>
              <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', minWidth: 200 }}>
                {editingId === it.id ? (
                  <>
                    <button onClick={saveEdit} style={{ padding: '8px 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer', whiteSpace: 'nowrap' }}>저장</button>
                    <button onClick={()=>{ setEditingId(null); setDraftName(''); }} style={{ padding: '8px 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: 'transparent', color: tokens.textDim, cursor: 'pointer', whiteSpace: 'nowrap' }}>취소</button>
                  </>
                ) : (
                  <>
                    <button onClick={()=>startEdit(it.id)} style={{ padding: '8px 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer', whiteSpace: 'nowrap' }}>수정</button>
                    <button onClick={()=>remove(it.id)} style={{ padding: '8px 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: 'transparent', color: '#ff8686', cursor: 'pointer', whiteSpace: 'nowrap' }}>삭제</button>
                  </>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </Modal>
  );
}
type OptionItem = { label: string; value: string };
function SelectPopup({ value, options, onChange, compact, dropUp }: { value: string; options: OptionItem[]; onChange: (v: string) => void; compact?: boolean; dropUp?: boolean }) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement | null>(null);
  const popupRef = useRef<HTMLDivElement | null>(null);
  const [rect, setRect] = useState<DOMRect | null>(null);

  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (!btnRef.current) return;
      if (!open) return;
      const target = e.target as Node;
      if (!btnRef.current.contains(target) && !(popupRef.current && popupRef.current.contains(target))) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);

  function toggle() {
    if (!btnRef.current) return;
    setRect(btnRef.current.getBoundingClientRect());
    setOpen((s) => !s);
  }

  const current = options.find(o => o.value === value);
  const label = current ? current.label : '선택';

  return (
    <>
      <button ref={btnRef} type="button" onClick={toggle}
        style={{ width: '100%', height: compact ? 36 : 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, textAlign: 'left', padding: '0 12px', cursor: 'pointer', marginTop: compact ? 0 : 6 }}>
        {label}
        <span style={{ float: 'right', opacity: 0.7 }}>▾</span>
      </button>
      {open && rect && createPortal(
        <div ref={popupRef}
             onWheel={(e)=>{ if (!popupRef.current) return; popupRef.current.scrollTop += e.deltaY; e.preventDefault(); }}
             style={{ position: 'fixed', left: rect.left, top: dropUp ? undefined : (rect.bottom + 4), bottom: dropUp ? (window.innerHeight - rect.top + 4) : undefined, width: rect.width, maxHeight: 320, overflowY: 'auto', background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 8, zIndex: 1000, overscrollBehavior: 'contain', touchAction: 'pan-y' }}>
          {options.map((opt) => (
            <div key={opt.value}
                 onMouseDown={(e) => { e.preventDefault(); e.stopPropagation(); onChange(opt.value); setOpen(false); }}
                 style={{ padding: '10px 12px', cursor: 'pointer', color: tokens.text, background: opt.value === value ? '#262A2E' : 'transparent' }}
                 onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = '#262A2E')}
                 onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = opt.value === value ? '#262A2E' : 'transparent')}
            >{opt.label}</div>
          ))}
        </div>, document.body)}
    </>
  );
}

export default function AdminQuestionsPage() {
  const QUESTIONS_TABLE = 'questions';
  const [areaDialog, setAreaDialog] = useState<null|'areas'|'groups'>(null);
  const [addQOpen, setAddQOpen] = useState(false);
  const [draft, setDraft] = useState<QuestionDraft>({
    id: Math.random().toString(36).slice(2),
    trait: 'D',
    text: '',
    type: 'scale',
    min: 1,
    max: 10,
    reverse: 'N',
    area: undefined,
    group: undefined,
    image: '',
    active: true,
  });
  const [items, setItems] = useState<QuestionDraft[]>([]);
  const [isNarrow, setIsNarrow] = useState(false);
  type AGItem = { id: string; name: string };
  const [areas, setAreas] = useState<AGItem[]>([]);
  const [groups, setGroups] = useState<AGItem[]>([]);
  const [typeEditId, setTypeEditId] = useState<string | null>(null);
  const [scaleEditId, setScaleEditId] = useState<string | null>(null);
  const [scaleDraftMin, setScaleDraftMin] = useState<number>(1);
  const [scaleDraftMax, setScaleDraftMax] = useState<number>(10);
  const [weightDrafts, setWeightDrafts] = useState<Record<string, string>>({});
  const [draftWeightText, setDraftWeightText] = useState<string>('');
  const [lastScaleRange, setLastScaleRange] = useState<{min:number; max:number}>(() => {
    try {
      const s = localStorage.getItem('last_scale_range');
      if (s) {
        const o = JSON.parse(s);
        if (typeof o?.min === 'number' && typeof o?.max === 'number') return { min: o.min, max: o.max };
      }
    } catch {}
    return { min: 1, max: 10 };
  });
  
  function generateNextPairId(existing: string[]): string {
    const prefix = 'PAIR-';
    const nums = existing
      .map((s) => {
        const m = /^PAIR-(\d{4,})$/.exec(s || '');
        return m ? Number(m[1]) : null;
      })
      .filter((n): n is number => n !== null);
    const next = (nums.length ? Math.max(...nums) + 1 : 1);
    return prefix + String(next).padStart(4, '0');
  }

  function toDbPatch(patch: Partial<QuestionDraft>) {
    const out: any = {};
    if (patch.area !== undefined) out.area_id = patch.area || null;
    if (patch.group !== undefined) out.group_id = patch.group || null;
    if (patch.trait !== undefined) out.trait = patch.trait;
    if (patch.text !== undefined) out.text = patch.text;
    if (patch.type !== undefined) out.type = patch.type;
    if (patch.min !== undefined) out.min_score = patch.min ?? null;
    if (patch.max !== undefined) out.max_score = patch.max ?? null;
    if (patch.weight !== undefined) out.weight = patch.weight ?? null;
    if (patch.reverse !== undefined) out.reverse = patch.reverse;
    if (patch.tags !== undefined) out.tags = patch.tags ?? null;
    if (patch.memo !== undefined) out.memo = patch.memo ?? null;
    if (patch.image !== undefined) out.image_url = patch.image ?? null;
    if (patch.pairId !== undefined) out.pair_id = patch.pairId ?? null;
    if (patch.active !== undefined) out.is_active = !!patch.active;
    if (patch.version !== undefined) out.version = patch.version ?? null;
    return out;
  }

  async function saveField(questionId: string, patch: Partial<QuestionDraft>) {
    const prev = items;
    setItems((arr)=>arr.map(it=>it.id===questionId?{...it, ...patch}:it));
    try {
      const isUuid = /[0-9a-fA-F-]{36}/.test(questionId);
      if (!isUuid) return;
      const dbPatch = toDbPatch(patch);
      if (Object.keys(dbPatch).length === 0) return;
      const { error } = await supabase.from(QUESTIONS_TABLE).update(dbPatch).eq('id', questionId);
      if (error) throw error;
    } catch (e:any) {
      console.error(e);
      alert('저장 실패: ' + (e?.message || '알 수 없는 오류'));
      // 되돌리기
      setItems(prev);
    }
  }

  useEffect(() => {
    (async () => {
      const { data: a } = await supabase.from('question_areas').select('id,name,order_index').order('order_index', { ascending: true });
      const { data: g } = await supabase.from('question_groups').select('id,name,order_index').order('order_index', { ascending: true });
      if (a) setAreas((a as any[]).map(x => ({ id: x.id, name: x.name })));
      if (g) setGroups((g as any[]).map(x => ({ id: x.id, name: x.name })));
    })();
  }, []);

  useEffect(() => {
    (async () => {
      const { data } = await supabase
        .from(QUESTIONS_TABLE)
        .select('id, area_id, group_id, trait, text, type, min_score, max_score, weight, reverse, tags, memo, image_url, pair_id, version, is_active')
        .order('created_at', { ascending: true });
      if (data) {
        setItems((data as any[]).map(row => ({
          id: row.id,
          area: row.area_id || undefined,
          group: row.group_id || undefined,
          trait: row.trait,
          text: row.text || '',
          type: row.type,
          min: row.min_score ?? undefined,
          max: row.max_score ?? undefined,
          weight: row.weight ?? undefined,
          reverse: (row.reverse || 'N'),
          tags: row.tags || undefined,
          memo: row.memo || undefined,
          image: row.image_url || undefined,
          pairId: row.pair_id || undefined,
          version: typeof row.version === 'number' ? row.version : undefined,
          active: !!row.is_active,
        })));
      }
    })();
  }, []);

  useEffect(() => {
    const onResize = () => setIsNarrow(window.innerWidth < 860);
    onResize();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  const isScale = draft.type === 'scale';

  function resetDraft() {
    setDraft({ id: Math.random().toString(36).slice(2), trait: 'D', text: '', type: 'scale', min: lastScaleRange.min, max: lastScaleRange.max, reverse: 'N', image: '', active: true });
    setDraftWeightText('');
  }

  const traitOptions = useMemo<OptionItem[]>(() => ['D','I','A','C','N','L','S','P'].map(v=>({label:v, value:v})), []);
  const [filterOpen, setFilterOpen] = useState(false);
  const [activeAreas, setActiveAreas] = useState<string[]>([]);
  const [activeGroups, setActiveGroups] = useState<string[]>([]);
  const [activeTraits, setActiveTraits] = useState<string[]>([]);
  const [pairPickForId, setPairPickForId] = useState<string | null>(null);

  // 회차/파트 설계
  const [roundOpen, setRoundOpen] = useState(false);
  const [rounds, setRounds] = useState<TraitRound[]>([]);
  const [roundParts, setRoundParts] = useState<TraitRoundPart[]>([]);
  const [selectedRoundId, setSelectedRoundId] = useState<string | null>(null);
  const [roundLoading, setRoundLoading] = useState(false);
  const [roundErr, setRoundErr] = useState<string | null>(null);

  const [newRoundName, setNewRoundName] = useState('');
  const [newRoundDesc, setNewRoundDesc] = useState('');
  const [editingRoundId, setEditingRoundId] = useState<string | null>(null);
  const [editingRoundName, setEditingRoundName] = useState('');
  const [editingRoundDesc, setEditingRoundDesc] = useState('');
  const [dragRoundIdx, setDragRoundIdx] = useState<number | null>(null);

  const [newPartName, setNewPartName] = useState('');
  const [newPartDesc, setNewPartDesc] = useState('');
  const [editingPartId, setEditingPartId] = useState<string | null>(null);
  const [editingPartName, setEditingPartName] = useState('');
  const [editingPartDesc, setEditingPartDesc] = useState('');
  const [dragPartIdx, setDragPartIdx] = useState<number | null>(null);

  async function loadRounds() {
    setRoundErr(null);
    setRoundLoading(true);
    try {
      const { data, error } = await supabase
        .from('trait_rounds')
        .select('id,name,description,order_index,is_active')
        .order('order_index', { ascending: true })
        .order('created_at', { ascending: true });
      if (error) throw error;
      const list = (data as any[] | null) ?? [];
      setRounds(list as any);
      const first = list[0]?.id ? String(list[0].id) : null;
      setSelectedRoundId((prev) => prev ?? first);
    } catch (e: any) {
      setRoundErr(e?.message || '회차를 불러오지 못했습니다.');
    } finally {
      setRoundLoading(false);
    }
  }

  async function loadParts(roundId: string) {
    setRoundErr(null);
    try {
      const { data, error } = await supabase
        .from('trait_round_parts')
        .select('id,round_id,name,description,image_url,order_index')
        .eq('round_id', roundId)
        .order('order_index', { ascending: true })
        .order('created_at', { ascending: true });
      if (error) throw error;
      setRoundParts(((data as any[]) ?? []) as any);
    } catch (e: any) {
      setRoundErr(e?.message || '파트를 불러오지 못했습니다.');
    }
  }

  useEffect(() => {
    if (!roundOpen) return;
    loadRounds();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roundOpen]);

  useEffect(() => {
    if (!roundOpen) return;
    if (!selectedRoundId) {
      setRoundParts([]);
      return;
    }
    loadParts(selectedRoundId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roundOpen, selectedRoundId]);

  useEffect(() => {
    if (!selectedRoundId) {
      setEditingRoundId(null);
      setEditingRoundName('');
      setEditingRoundDesc('');
      return;
    }
    const r = rounds.find((x) => x.id === selectedRoundId);
    if (!r) return;
    setEditingRoundId(r.id);
    setEditingRoundName(r.name || '');
    setEditingRoundDesc(r.description || '');
  }, [selectedRoundId, rounds]);

  async function addRound() {
    const name = newRoundName.trim();
    if (!name) return;
    try {
      const { data, error } = await supabase
        .from('trait_rounds')
        .insert({
          name,
          description: newRoundDesc.trim() || null,
          order_index: rounds.length,
          is_active: true,
        })
        .select('id,name,description,order_index,is_active')
        .single();
      if (error) throw error;
      const row = data as any;
      setRounds((arr) => [...arr, row]);
      setSelectedRoundId(String(row.id));
      setNewRoundName('');
      setNewRoundDesc('');
    } catch (e: any) {
      setRoundErr(e?.message || '회차 추가 실패');
    }
  }

  function startEditRound(r: TraitRound) {
    setSelectedRoundId(r.id);
    setEditingRoundId(r.id);
    setEditingRoundName(r.name || '');
    setEditingRoundDesc(r.description || '');
  }

  async function saveEditRound() {
    if (!editingRoundId) return;
    try {
      const nextName = editingRoundName.trim();
      if (!nextName) return;
      const nextDesc = editingRoundDesc.trim() || null;
      const { error } = await supabase
        .from('trait_rounds')
        .update({ name: nextName, description: nextDesc })
        .eq('id', editingRoundId);
      if (error) throw error;
      setRounds((arr) => arr.map((x) => (x.id === editingRoundId ? { ...x, name: nextName, description: nextDesc } : x)));
    } catch (e: any) {
      setRoundErr(e?.message || '회차 수정 실패');
    }
  }

  async function deleteRound(id: string) {
    const ok = window.confirm('회차를 삭제하시겠습니까? (하위 파트도 함께 삭제됩니다)');
    if (!ok) return;
    try {
      const { error } = await supabase.from('trait_rounds').delete().eq('id', id);
      if (error) throw error;
      setRounds((arr) => arr.filter((x) => x.id !== id));
      if (selectedRoundId === id) {
        setSelectedRoundId(null);
        setEditingRoundId(null);
        setEditingRoundName('');
        setEditingRoundDesc('');
      }
      setRoundParts([]);
    } catch (e: any) {
      setRoundErr(e?.message || '회차 삭제 실패');
    }
  }

  async function reorderRounds(startIdx: number, endIdx: number) {
    if (endIdx < 0 || endIdx >= rounds.length || startIdx === endIdx) return;
    const next = rounds.slice();
    const [moved] = next.splice(startIdx, 1);
    next.splice(endIdx, 0, moved);
    setRounds(next);
    const payload = next.map((r, i) => ({ id: r.id, order_index: i }));
    await supabase.from('trait_rounds').upsert(payload, { onConflict: 'id' });
  }

  async function addPart() {
    if (!selectedRoundId) return;
    const name = newPartName.trim();
    if (!name) return;
    try {
      const { data, error } = await supabase
        .from('trait_round_parts')
        .insert({
          round_id: selectedRoundId,
          name,
          description: newPartDesc.trim() || null,
          order_index: roundParts.length,
          image_url: null,
        })
        .select('id,round_id,name,description,image_url,order_index')
        .single();
      if (error) throw error;
      setRoundParts((arr) => [...arr, data as any]);
      setNewPartName('');
      setNewPartDesc('');
    } catch (e: any) {
      setRoundErr(e?.message || '파트 추가 실패');
    }
  }

  function startEditPart(p: TraitRoundPart) {
    setEditingPartId(p.id);
    setEditingPartName(p.name || '');
    setEditingPartDesc(p.description || '');
  }

  async function saveEditPart() {
    if (!editingPartId) return;
    try {
      const nextName = editingPartName.trim();
      if (!nextName) return;
      const nextDesc = editingPartDesc.trim() || null;
      const { error } = await supabase.from('trait_round_parts').update({ name: nextName, description: nextDesc }).eq('id', editingPartId);
      if (error) throw error;
      setRoundParts((arr) => arr.map((x) => (x.id === editingPartId ? { ...x, name: nextName, description: nextDesc } : x)));
      setEditingPartId(null);
      setEditingPartName('');
      setEditingPartDesc('');
    } catch (e: any) {
      setRoundErr(e?.message || '파트 수정 실패');
    }
  }

  async function deletePart(id: string) {
    const ok = window.confirm('파트를 삭제하시겠습니까?');
    if (!ok) return;
    try {
      const { error } = await supabase.from('trait_round_parts').delete().eq('id', id);
      if (error) throw error;
      setRoundParts((arr) => arr.filter((x) => x.id !== id));
    } catch (e: any) {
      setRoundErr(e?.message || '파트 삭제 실패');
    }
  }

  async function reorderParts(startIdx: number, endIdx: number) {
    if (endIdx < 0 || endIdx >= roundParts.length || startIdx === endIdx) return;
    const next = roundParts.slice();
    const [moved] = next.splice(startIdx, 1);
    next.splice(endIdx, 0, moved);
    setRoundParts(next);
    const payload = next.map((p, i) => ({ id: p.id, order_index: i }));
    await supabase.from('trait_round_parts').upsert(payload, { onConflict: 'id' });
  }

  async function uploadPartImage(partId: string, file: File) {
    try {
      setRoundErr(null);
      const ext = (file.name.split('.').pop() || 'bin').toLowerCase();
      const path = `round_parts/${selectedRoundId}/${partId}.${Date.now()}.${ext}`;
      const { error: upErr } = await supabase.storage.from('survey').upload(path, file, { upsert: true, cacheControl: '3600', contentType: (file as any).type || 'application/octet-stream' });
      if (upErr) throw upErr;
      const { data: pub } = supabase.storage.from('survey').getPublicUrl(path);
      const url = (pub as any)?.publicUrl as string;
      const { error } = await supabase.from('trait_round_parts').update({ image_url: url }).eq('id', partId);
      if (error) throw error;
      setRoundParts((arr) => arr.map((x) => (x.id === partId ? { ...x, image_url: url } : x)));
    } catch (e: any) {
      setRoundErr(e?.message || '이미지 업로드 실패');
    }
  }

  const [exportOpen, setExportOpen] = useState(false);
  const [exportCols, setExportCols] = useState<Record<string, boolean>>({});
  const [exportErr, setExportErr] = useState<string | null>(null);

  const [reportOpen, setReportOpen] = useState(false);
  const [reportModel, setReportModel] = useState('gpt-4.1-mini');
  const [reportPromptVersion, setReportPromptVersion] = useState('v1');
  const [reportForce, setReportForce] = useState(false);
  const [reportLoading, setReportLoading] = useState(false);
  const [reportErr, setReportErr] = useState<string | null>(null);
  const [reportFiltersHash, setReportFiltersHash] = useState<string | null>(null);
  const [reportRuns, setReportRuns] = useState<any[]>([]);

  const visibleItems = useMemo(() => {
    return items
      .filter((q)=> (activeAreas.length ? activeAreas.includes(q.area || '') : true))
      .filter((q)=> (activeGroups.length ? activeGroups.includes(q.group || '') : true))
      .filter((q)=> (activeTraits.length ? activeTraits.includes(q.trait) : true));
  }, [items, activeAreas, activeGroups, activeTraits]);

  const areaNameById = useMemo(() => {
    const m: Record<string, string> = {};
    for (const a of areas) m[a.id] = a.name;
    return m;
  }, [areas]);
  const groupNameById = useMemo(() => {
    const m: Record<string, string> = {};
    for (const g of groups) m[g.id] = g.name;
    return m;
  }, [groups]);

  const exportColumns = useMemo(() => {
    return [
      { key: 'row_no', label: '번호', get: (_q: QuestionDraft, i: number) => i + 1 },
      { key: 'id', label: '문항 ID', get: (q: QuestionDraft) => q.id },
      { key: 'area_id', label: '영역 ID', get: (q: QuestionDraft) => q.area || '' },
      { key: 'area_name', label: '영역', get: (q: QuestionDraft) => areaNameById[q.area || ''] || '' },
      { key: 'group_id', label: '그룹 ID', get: (q: QuestionDraft) => q.group || '' },
      { key: 'group_name', label: '그룹', get: (q: QuestionDraft) => groupNameById[q.group || ''] || '' },
      { key: 'trait', label: '성향', get: (q: QuestionDraft) => q.trait },
      { key: 'text', label: '내용', get: (q: QuestionDraft) => q.text || '' },
      { key: 'type', label: '평가 타입', get: (q: QuestionDraft) => q.type },
      { key: 'min', label: '최소', get: (q: QuestionDraft) => q.min ?? '' },
      { key: 'max', label: '최대', get: (q: QuestionDraft) => q.max ?? '' },
      { key: 'weight', label: '가중치', get: (q: QuestionDraft) => q.weight ?? '' },
      { key: 'reverse', label: '역문항', get: (q: QuestionDraft) => q.reverse || '' },
      { key: 'pair_id', label: '페어 ID', get: (q: QuestionDraft) => q.pairId || '' },
      { key: 'tags', label: '태그', get: (q: QuestionDraft) => q.tags || '' },
      { key: 'memo', label: '메모', get: (q: QuestionDraft) => q.memo || '' },
      { key: 'image_url', label: '이미지 URL', get: (q: QuestionDraft) => q.image || '' },
      { key: 'version', label: '버전', get: (q: QuestionDraft) => q.version ?? '' },
      { key: 'is_active', label: '활성화', get: (q: QuestionDraft) => (q.active ? 'Y' : 'N') },
    ] as const;
  }, [areaNameById, groupNameById]);

  useEffect(() => {
    // 초기 기본 선택 컬럼
    if (Object.keys(exportCols).length === 0) {
      const defaults = ['row_no','area_name','group_name','trait','text','type','min','max','weight','reverse','pair_id','tags','memo','image_url','version','is_active'];
      const m: Record<string, boolean> = {};
      for (const c of exportColumns) m[c.key] = defaults.includes(c.key);
      setExportCols(m);
    }
  }, [exportColumns]);

  useEffect(() => {
    // 모달 열릴 때 배경 스크롤 잠금(스크롤바 2개 방지)
    if (!exportOpen && !reportOpen && !roundOpen) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, [exportOpen, reportOpen, roundOpen]);

  function canonicalizeFilters() {
    const payload: any = {
      slug: 'trait_v1',
      is_active_only: true,
      traits: [...activeTraits].sort(),
      area_ids: [...activeAreas].sort(),
      group_ids: [...activeGroups].sort(),
    };
    // 키 정렬
    const keys = Object.keys(payload).sort();
    const out: any = {};
    for (const k of keys) out[k] = payload[k];
    return out;
  }

  async function sha256Hex(str: string): Promise<string> {
    const buf = new TextEncoder().encode(str);
    const hash = await crypto.subtle.digest('SHA-256', buf);
    return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  async function callFunction(name: string, opts: { method?: string; query?: Record<string,string>; body?: any }) {
    const cfg = getSupabaseConfig();
    if (!cfg.ok) throw new Error('Supabase 설정이 없습니다.');
    const session = (await supabase.auth.getSession()).data.session;
    const token = session?.access_token;
    if (!token) throw new Error('로그인이 필요합니다.');
    const q = new URLSearchParams(opts.query ?? {}).toString();
    const url = `${cfg.url.replace(/\/$/,'')}/functions/v1/${name}${q ? `?${q}` : ''}`;
    const res = await fetch(url, {
      method: opts.method ?? 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: cfg.anonKey,
        'Content-Type': 'application/json',
      },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    const text = await res.text();
    let data: any = null;
    try { data = text ? JSON.parse(text) : null; } catch { /* ignore */ }
    if (!res.ok) throw new Error((data?.error ?? text ?? `http_${res.status}`) as string);
    return data;
  }

  async function refreshRuns(hash?: string | null) {
    const h = hash ?? reportFiltersHash;
    if (!h) return;
    const data = await callFunction('trait_report_runs', { method: 'GET', query: { filters_hash: h, limit: '20' } });
    setReportRuns(Array.isArray(data?.runs) ? data.runs : []);
  }

  async function runReport() {
    setReportErr(null);
    setReportLoading(true);
    try {
      const filters = canonicalizeFilters();
      const filtersHash = await sha256Hex(JSON.stringify(filters));
      setReportFiltersHash(filtersHash);
      const res = await callFunction('trait_report_run', {
        method: 'POST',
        body: {
          filters_json: filters,
          model: reportModel,
          prompt_version: reportPromptVersion,
          force: reportForce,
          source: 'admin_ui',
        },
      });
      const run = res?.run;
      if (run?.filters_hash) setReportFiltersHash(String(run.filters_hash));
      await refreshRuns(String(run?.filters_hash ?? filtersHash));
    } catch (e:any) {
      setReportErr(e?.message || String(e));
    } finally {
      setReportLoading(false);
    }
  }

  async function downloadReport(runId: string, kind: 'json' | 'html') {
    try {
      setReportErr(null);
      const res = await callFunction('trait_report_run_get', { method: 'GET', query: { id: runId } });
      const signedUrl = res?.signed?.[kind];
      if (!signedUrl) throw new Error('다운로드 URL을 만들 수 없습니다.');

      const r = await fetch(String(signedUrl));
      if (!r.ok) throw new Error(`download_http_${r.status}`);
      const arr = await r.arrayBuffer();

      const filename = `trait_report_${runId}.${kind === 'json' ? 'json' : 'html'}`;
      const mime = kind === 'json' ? 'application/json' : 'text/html';
      const host = (window as any)?.chrome?.webview;
      if (host?.postMessage) {
        host.postMessage({
          type: 'download_file',
          filename,
          mime,
          base64: arrayToBase64(arr),
        });
        return;
      }
      const blob = new Blob([arr], { type: mime });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e:any) {
      setReportErr(e?.message || String(e));
    }
  }

  function arrayToBase64(arr: ArrayBuffer): string {
    const bytes = new Uint8Array(arr);
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  function downloadXlsx() {
    setExportErr(null);
    const selected = exportColumns.filter((c) => exportCols[c.key]);
    if (selected.length === 0) {
      setExportErr('내보낼 컬럼을 1개 이상 선택해 주세요.');
      return;
    }
    const aoa: any[][] = [];
    aoa.push(selected.map((c) => c.label));
    visibleItems.forEach((q, i) => {
      aoa.push(selected.map((c) => c.get(q, i)));
    });

    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.aoa_to_sheet(aoa);
    XLSX.utils.book_append_sheet(wb, ws, 'questions');

    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const filename = `questions_${ts}.xlsx`;
    const out = XLSX.write(wb, { bookType: 'xlsx', type: 'array' }) as ArrayBuffer;

    // ✅ WebView2(관리자앱)에서는 브라우저 다운로드가 막힐 수 있어 host로 전달
    const host = (window as any)?.chrome?.webview;
    if (host?.postMessage) {
      try {
        host.postMessage({
          type: 'download_file',
          filename,
          mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          base64: arrayToBase64(out),
        });
        setExportOpen(false);
        return;
      } catch (e: any) {
        // fallback below
        console.warn('[export] host postMessage failed', e);
      }
    }

    // 브라우저 환경: Blob 다운로드
    const blob = new Blob([out], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    setExportOpen(false);
  }
  async function logChange(questionId: string, action: string, fromValue: any, toValue: any) {
    try {
      await supabase.from('question_change_logs').insert({ question_id: questionId, action, from_value: JSON.stringify(fromValue), to_value: JSON.stringify(toValue) });
    } catch (e) {
      console.warn('[change_log] failed', e);
    }
  }
  const summary = useMemo(() => {
    const traitKeys = ['D','I','A','C','N','L','S','P'] as const;
    const perTrait: Record<typeof traitKeys[number], number> = { D:0,I:0,A:0,C:0,N:0,L:0,S:0,P:0 };
    const perTraitMax: Record<typeof traitKeys[number], number> = { D:0,I:0,A:0,C:0,N:0,L:0,S:0,P:0 };
    let total = 0;
    let totalMax = 0;
    for (const q of items) {
      total += 1;
      if ((perTrait as any)[q.trait] !== undefined) perTrait[q.trait as keyof typeof perTrait] += 1;
      if (q.type === 'scale') {
        const w = q.weight ?? 1;
        const mx = q.max ?? 0;
        const add = w * mx;
        totalMax += add;
        if ((perTraitMax as any)[q.trait] !== undefined) perTraitMax[q.trait as keyof typeof perTraitMax] += add;
      }
    }
    return { total, perTrait, totalMax, perTraitMax };
  }, [items]);

  const selectedRound = useMemo(() => {
    return rounds.find((r) => r.id === selectedRoundId) || null;
  }, [rounds, selectedRoundId]);

  return (
    <div style={{ color: tokens.text }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
        <ToolbarButton onClick={() => setAreaDialog('areas')}>영역</ToolbarButton>
        <ToolbarButton onClick={() => setAreaDialog('groups')}>그룹</ToolbarButton>
        <ToolbarButton onClick={() => { setRoundErr(null); setRoundOpen(true); }}>회차</ToolbarButton>
        <ToolbarButton onClick={() => setFilterOpen((s)=>!s)}>필터</ToolbarButton>
        <div style={{ flex: 1 }} />
        <ToolbarButton onClick={async () => { setReportErr(null); setReportOpen(true); try { const filters = canonicalizeFilters(); const h = await sha256Hex(JSON.stringify(filters)); setReportFiltersHash(h); await refreshRuns(h); } catch (e:any) { setReportErr(e?.message || String(e)); } }}>리포트</ToolbarButton>
        <ToolbarButton onClick={() => { setExportErr(null); setExportOpen(true); }}>엑셀로 내보내기</ToolbarButton>
        <ToolbarButton onClick={() => { resetDraft(); setAddQOpen(true); }}>추가</ToolbarButton>
      </div>

      {roundOpen && (
        <Modal
          title="회차 설계"
          width={920}
          onClose={() => setRoundOpen(false)}
          actions={<>
            <button onClick={() => setRoundOpen(false)} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}>닫기</button>
          </>}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
              <div>
                <div style={{ fontWeight: 900 }}>회차/파트 설계</div>
                <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 2 }}>1) 회차 편집 → 2) 회차 선택 후 파트 편집</div>
              </div>
              {roundErr && <div style={{ color: '#ff8686', fontSize: 12 }}>{roundErr}</div>}
            </div>

            <div style={{ maxHeight: '72vh', overflow: 'auto', paddingRight: 4 }}>
              <div style={{ display: 'grid', gridTemplateColumns: 'minmax(260px, 320px) 1fr', gap: 14 }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  <div style={{ background: '#141416', border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 12 }}>
                    <div style={{ fontWeight: 800, marginBottom: 8 }}>새 회차</div>
                    <input value={newRoundName} onChange={(e)=>setNewRoundName(e.target.value)} placeholder="회차 이름"
                           style={{ width: '100%', height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }} />
                    <textarea value={newRoundDesc} onChange={(e)=>setNewRoundDesc(e.target.value)} placeholder="회차 설명(선택)" rows={2}
                              style={{ width:'100%', marginTop: 8, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: 10, boxSizing:'border-box' }} />
                    <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 8 }}>
                      <button onClick={addRound} style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer' }}>회차 추가</button>
                    </div>
                  </div>

                  <div style={{ background: '#141416', border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 12 }}>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                      <div style={{ fontWeight: 800 }}>회차 목록</div>
                      <div style={{ color: tokens.textDim, fontSize: 12 }}>{rounds.length}개</div>
                    </div>
                    <div style={{ maxHeight: 420, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 8 }}>
                      {roundLoading ? (
                        <div style={{ padding: 10, color: tokens.textDim }}>불러오는 중...</div>
                      ) : rounds.length === 0 ? (
                        <div style={{ padding: 10, color: tokens.textDim }}>회차가 없습니다.</div>
                      ) : (
                        rounds.map((r, idx) => (
                          <div
                            key={r.id}
                            draggable
                            onDragStart={()=>setDragRoundIdx(idx)}
                            onDragOver={(e)=>e.preventDefault()}
                            onDrop={()=>{ if (dragRoundIdx !== null) reorderRounds(dragRoundIdx, idx); setDragRoundIdx(null); }}
                            onClick={()=>startEditRound(r)}
                            style={{
                              display: 'flex',
                              alignItems: 'center',
                              gap: 8,
                              padding: '8px 10px',
                              borderRadius: 10,
                              border: selectedRoundId === r.id ? `1px solid ${tokens.accent}` : `1px solid ${tokens.border}`,
                              background: selectedRoundId === r.id ? '#1C1F23' : '#121214',
                              cursor: 'pointer',
                            }}
                          >
                            <div style={{ opacity: 0.8 }}><DragHandle /></div>
                            <div style={{ flex: 1, minWidth: 0 }}>
                              <div style={{ fontWeight: 700 }}>{r.name}</div>
                              {r.description ? (
                                <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 2, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>{r.description}</div>
                              ) : null}
                            </div>
                          </div>
                        ))
                      )}
                    </div>
                  </div>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  {!selectedRoundId ? (
                    <div style={{ background: '#141416', border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 16, color: tokens.textDim }}>
                      회차를 선택하면 파트를 편집할 수 있어요.
                    </div>
                  ) : (
                    <>
                      <div style={{ background: '#141416', border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 12 }}>
                        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                          <div style={{ fontWeight: 800 }}>회차 편집</div>
                          {selectedRound?.id ? <div style={{ color: tokens.textDim, fontSize: 11 }}>ID {selectedRound.id}</div> : null}
                        </div>
                        <input value={editingRoundName} onChange={(e)=>setEditingRoundName(e.target.value)} placeholder="회차 이름"
                               style={{ width: '100%', height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }} />
                        <textarea value={editingRoundDesc} onChange={(e)=>setEditingRoundDesc(e.target.value)} placeholder="회차 설명(선택)" rows={2}
                                  style={{ width:'100%', marginTop: 8, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: 10, boxSizing:'border-box' }} />
                        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: 8 }}>
                          <button onClick={saveEditRound} style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer' }}>저장</button>
                          <button onClick={() => selectedRoundId && deleteRound(selectedRoundId)} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: 'transparent', color: '#ff8686', cursor: 'pointer' }}>삭제</button>
                        </div>
                      </div>

                      <div style={{ background: '#141416', border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 12 }}>
                        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                          <div style={{ fontWeight: 800 }}>파트 편집</div>
                          <div style={{ color: tokens.textDim, fontSize: 12 }}>{roundParts.length}개</div>
                        </div>
                        <div style={{ display: 'grid', gridTemplateColumns: '1fr auto', gap: 8 }}>
                          <input value={newPartName} onChange={(e)=>setNewPartName(e.target.value)} placeholder="파트 이름"
                                 style={{ width: '100%', height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }} />
                          <button onClick={addPart} style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer' }}>파트 추가</button>
                        </div>
                        <textarea value={newPartDesc} onChange={(e)=>setNewPartDesc(e.target.value)} placeholder="파트 설명(선택)" rows={2}
                                  style={{ width:'100%', marginTop: 8, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: 10, boxSizing:'border-box' }} />

                        <div style={{ border:`1px solid ${tokens.border}`, borderRadius: 10, marginTop: 10, padding: 8, display:'flex', flexDirection:'column', gap: 8, maxHeight: 360, overflowY: 'auto' }}>
                          {roundParts.length === 0 ? (
                            <div style={{ padding: 10, color: tokens.textDim }}>파트가 없습니다.</div>
                          ) : (
                            roundParts.map((p, idx) => (
                              <div
                                key={p.id}
                                draggable
                                onDragStart={()=>setDragPartIdx(idx)}
                                onDragOver={(e)=>e.preventDefault()}
                                onDrop={()=>{ if (dragPartIdx !== null) reorderParts(dragPartIdx, idx); setDragPartIdx(null); }}
                                style={{ background: '#121316', border: `1px solid ${tokens.border}`, borderRadius: 10, padding: 10 }}
                              >
                                <div style={{ display:'grid', gridTemplateColumns:'24px 1fr 220px', gap: 10, alignItems:'start' }}>
                                  <div style={{ opacity: 0.8 }}><DragHandle /></div>
                                  <div style={{ minWidth: 0 }}>
                                    {editingPartId === p.id ? (
                                      <>
                                        <input value={editingPartName} onChange={(e)=>setEditingPartName(e.target.value)}
                                               style={{ width:'100%', height: 36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.text, padding:'0 10px', boxSizing:'border-box' }} />
                                        <textarea value={editingPartDesc} onChange={(e)=>setEditingPartDesc(e.target.value)} rows={2}
                                                  style={{ width:'100%', marginTop: 6, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.text, padding:10, boxSizing:'border-box' }} />
                                      </>
                                    ) : (
                                      <>
                                        <div style={{ fontWeight: 800 }}>{p.name}</div>
                                        {p.description ? <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>{p.description}</div> : null}
                                        {p.image_url ? <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 6, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>{p.image_url}</div> : null}
                                      </>
                                    )}
                                  </div>
                                  <div style={{ display:'flex', flexDirection:'column', gap: 6 }}>
                                    <div
                                      onDrop={(e)=>{ e.preventDefault(); const file = e.dataTransfer.files?.[0]; if (file) uploadPartImage(p.id, file); }}
                                      onDragOver={(e)=>e.preventDefault()}
                                      onClick={async()=>{ if (p.image_url) { await supabase.from('trait_round_parts').update({ image_url: null }).eq('id', p.id); setRoundParts(arr=>arr.map(x=>x.id===p.id?{...x,image_url:null}:x)); } }}
                                      title={p.image_url ? '클릭하여 이미지 제거' : '이미지 드롭하여 등록'}
                                      style={{ width:'100%', height: 36, background:'#2A2A2A', border:`1px dashed ${tokens.border}`, borderRadius:8, color: tokens.textDim, display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer', fontSize: 12 }}
                                    >
                                      {p.image_url ? '이미지 ✔ (클릭=제거)' : '이미지 드롭'}
                                    </div>
                                    <div style={{ display:'flex', gap: 6, justifyContent:'flex-end' }}>
                                      {editingPartId === p.id ? (
                                        <>
                                          <button onClick={saveEditPart} style={{ padding:'8px 10px', borderRadius:10, border:`1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor:'pointer' }}>저장</button>
                                          <button onClick={()=>{ setEditingPartId(null); setEditingPartName(''); setEditingPartDesc(''); }} style={{ padding:'8px 10px', borderRadius:10, border:`1px solid ${tokens.border}`, background:'transparent', color: tokens.textDim, cursor:'pointer' }}>취소</button>
                                        </>
                                      ) : (
                                        <>
                                          <button onClick={()=>startEditPart(p)} style={{ padding:'8px 10px', borderRadius:10, border:`1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor:'pointer' }}>수정</button>
                                          <button onClick={()=>deletePart(p.id)} style={{ padding:'8px 10px', borderRadius:10, border:`1px solid ${tokens.border}`, background:'transparent', color:'#ff8686', cursor:'pointer' }}>삭제</button>
                                        </>
                                      )}
                                    </div>
                                  </div>
                                </div>
                              </div>
                            ))
                          )}
                        </div>
                      </div>
                    </>
                  )}
                </div>
              </div>
            </div>
          </div>
        </Modal>
      )}

      {reportOpen && (
        <Modal
          title="리포트 생성/조회"
          width={760}
          onClose={() => setReportOpen(false)}
          actions={
            <>
              <button
                onClick={() => refreshRuns()}
                style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: 'transparent', color: tokens.textDim, cursor: 'pointer' }}
              >
                새로고침
              </button>
              <button
                disabled={reportLoading}
                onClick={runReport}
                style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: reportLoading ? 'not-allowed' : 'pointer', fontWeight: 900, opacity: reportLoading ? 0.6 : 1 }}
              >
                {reportLoading ? '생성 중...' : '리포트 생성'}
              </button>
            </>
          }
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 13, marginBottom: 6 }}>모델</div>
              <input
                value={reportModel}
                onChange={(e) => setReportModel(e.target.value)}
                style={{ width: '100%', height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }}
              />
            </div>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 13, marginBottom: 6 }}>프롬프트 버전</div>
              <input
                value={reportPromptVersion}
                onChange={(e) => setReportPromptVersion(e.target.value)}
                style={{ width: '100%', height: 40, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }}
              />
            </div>
          </div>
          <label style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12, color: tokens.textDim, fontSize: 13 }}>
            <input type="checkbox" checked={reportForce} onChange={(e) => setReportForce(e.target.checked)} />
            캐시 무시하고 강제 재생성
          </label>
          <div style={{ marginTop: 10, color: tokens.textDim, fontSize: 12, lineHeight: 1.5 }}>
            현재 필터 기준으로 스냅샷을 만들고 리포트를 생성합니다. (현재 필터 적용 문항: <b style={{ color: tokens.text }}>{visibleItems.length}</b>개)
            <br />
            filters_hash: <span style={{ color: tokens.text }}>{reportFiltersHash ?? '-'}</span>
          </div>

          {reportErr && <div style={{ marginTop: 12, color: '#ff8686', fontSize: 13 }}>{reportErr}</div>}

          <div style={{ marginTop: 14, border: `1px solid ${tokens.border}`, borderRadius: 12, overflow: 'hidden' }}>
            <div style={{ padding: 12, background: '#141416', color: tokens.textDim, fontSize: 13, display: 'grid', gridTemplateColumns: '1.6fr 0.8fr 1fr 1fr', gap: 10 }}>
              <div>run_id</div>
              <div>상태</div>
              <div>다운로드</div>
              <div>생성일</div>
            </div>
            {reportRuns.length === 0 ? (
              <div style={{ padding: 12, color: tokens.textDim }}>아직 리포트가 없습니다.</div>
            ) : (
              reportRuns.map((r) => (
                <div key={r.id} style={{ padding: 12, borderTop: `1px solid ${tokens.border}`, display: 'grid', gridTemplateColumns: '1.6fr 0.8fr 1fr 1fr', gap: 10, alignItems: 'center' }}>
                  <div style={{ color: tokens.text, fontSize: 13, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.id}</div>
                  <div style={{ color: tokens.textDim, fontSize: 13 }}>{r.status}</div>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button onClick={() => downloadReport(String(r.id), 'json')} style={{ padding: '6px 10px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer', fontSize: 12 }}>JSON</button>
                    <button onClick={() => downloadReport(String(r.id), 'html')} style={{ padding: '6px 10px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer', fontSize: 12 }}>HTML</button>
                  </div>
                  <div style={{ color: tokens.textDim, fontSize: 12 }}>{String(r.created_at ?? '')}</div>
                </div>
              ))
            )}
          </div>
        </Modal>
      )}

      {exportOpen && (
        <Modal
          title="엑셀 내보내기"
          width={640}
          onClose={() => setExportOpen(false)}
          actions={
            <>
              <button
                onClick={() => {
                  const m: Record<string, boolean> = {};
                  for (const c of exportColumns) m[c.key] = false;
                  setExportCols(m);
                }}
                style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: 'transparent', color: tokens.textDim, cursor: 'pointer' }}
              >
                전체 해제
              </button>
              <button
                onClick={() => {
                  const m: Record<string, boolean> = {};
                  for (const c of exportColumns) m[c.key] = true;
                  setExportCols(m);
                }}
                style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}
              >
                전체 선택
              </button>
              <button
                onClick={downloadXlsx}
                style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer', fontWeight: 900 }}
              >
                내보내기 ({visibleItems.length}건)
              </button>
            </>
          }
        >
          <div style={{ color: tokens.textDim, fontSize: 13, lineHeight: 1.5 }}>
            내보낼 컬럼을 선택하세요. (현재 필터가 적용된 목록 기준)
          </div>
          <div style={{ marginTop: 12, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            {exportColumns.map((c) => {
              const checked = !!exportCols[c.key];
              return (
                <label key={c.key} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', border: `1px solid ${tokens.border}`, borderRadius: 10, background: tokens.panel }}>
                  <input
                    type="checkbox"
                    checked={checked}
                    onChange={(e) => setExportCols((m) => ({ ...m, [c.key]: e.target.checked }))}
                  />
                  <div style={{ color: tokens.text, fontWeight: 700 }}>{c.label}</div>
                </label>
              );
            })}
          </div>
          {exportErr && <div style={{ marginTop: 12, color: '#ff8686', fontSize: 13 }}>{exportErr}</div>}
        </Modal>
      )}

      {/* 요약 위젯 */}
      <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:12, marginBottom:12 }}>
        <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, padding:12, background: tokens.panel }}>
          <div style={{ display:'flex', alignItems:'baseline', justifyContent:'space-between', marginBottom:6 }}>
            <div style={{ color: tokens.textDim, fontSize:13 }}>총 문항수</div>
            <div style={{ fontWeight:900, fontSize:20 }}>{summary.total}</div>
          </div>
          <div style={{ display:'flex', alignItems:'baseline', justifyContent:'space-between' }}>
            <div style={{ color: tokens.textDim, fontSize:13 }}>총점(최대)</div>
            <div style={{ fontWeight:900, fontSize:18 }}>{summary.totalMax.toLocaleString()}</div>
          </div>
        </div>
        <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, padding:12, background: tokens.panel }}>
          <div style={{ display:'grid', gridTemplateColumns:'repeat(8, 1fr)', gap:8 }}>
            {(['D','I','A','C','N','L','S','P'] as const).map(k => (
              <div key={k} style={{ border:`1px solid ${tokens.border}`, borderRadius:10, padding:'8px 10px' }}>
                <div style={{ display:'flex', alignItems:'baseline', justifyContent:'space-between' }}>
                  <div style={{ color: tokens.textDim, fontSize:12 }}>{k}</div>
                  <div style={{ fontWeight:800 }}>{summary.perTrait[k]}</div>
                </div>
                <div style={{ color: tokens.textDim, fontSize:12, marginTop:6 }}>총점(최대) {summary.perTraitMax[k].toLocaleString()}</div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {filterOpen && (
        <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 10, marginBottom: 12 }}>
          <div style={{ color: tokens.textDim, fontSize: 13, marginBottom: 8 }}>영역</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 12 }}>
            {areas.map((a) => {
              const on = activeAreas.includes(a.id);
              return (
                <button key={a.id} onClick={()=> setActiveAreas(on ? activeAreas.filter(id=>id!==a.id) : [...activeAreas, a.id])}
                        style={{ padding: '6px 10px', borderRadius: 999, border: `1px solid ${tokens.border}`, background: on ? tokens.accent : 'transparent', color: on ? '#fff' : tokens.text, cursor: 'pointer' }}>{a.name}</button>
              );
            })}
          </div>
          <div style={{ color: tokens.textDim, fontSize: 13, marginBottom: 8 }}>그룹</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {groups.map((g) => {
              const on = activeGroups.includes(g.id);
              return (
                <button key={g.id} onClick={()=> setActiveGroups(on ? activeGroups.filter(id=>id!==g.id) : [...activeGroups, g.id])}
                        style={{ padding: '6px 10px', borderRadius: 999, border: `1px solid ${tokens.border}`, background: on ? tokens.accent : 'transparent', color: on ? '#fff' : tokens.text, cursor: 'pointer' }}>{g.name}</button>
              );
            })}
          </div>
          <div style={{ color: tokens.textDim, fontSize: 13, marginTop: 12, marginBottom: 8 }}>성향</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {(['D','I','A','C','N','L','S','P'] as const).map((t) => {
              const on = activeTraits.includes(t);
              return (
                <button key={t} onClick={()=> setActiveTraits(on ? activeTraits.filter(x=>x!==t) : [...activeTraits, t])}
                        style={{ padding: '6px 10px', borderRadius: 999, border: `1px solid ${tokens.border}`, background: on ? tokens.accent : 'transparent', color: on ? '#fff' : tokens.text, cursor: 'pointer' }}>{t}</button>
              );
            })}
          </div>
        </div>
      )}

      <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, overflowX: 'hidden', width: '100%', margin: '0 auto 48px' }}>
        <div style={{ width: '100%', display: 'grid', gridTemplateColumns: '48px minmax(0,1fr) minmax(0,1fr) minmax(0,0.8fr) minmax(0,5fr) minmax(0,0.8fr) 88px minmax(0,0.8fr) minmax(0,1fr) minmax(0,1fr) minmax(0,2fr) minmax(0,0.6fr) 72px 72px', gap: 16, padding: 12, borderBottom: `1px solid ${tokens.border}`, color: tokens.textDim, boxSizing: 'border-box' }}>
          <div style={{ textAlign:'right', paddingRight:4 }}>번호</div><div>영역</div><div>그룹</div><div>성향</div><div>내용</div><div>평가</div><div>가중치</div><div>역문항</div><div>페어 ID</div><div>태그</div><div>메모</div><div>그림</div><div style={{ textAlign:'center' }}>버전</div><div style={{ textAlign:'center', paddingRight: 4 }}>활성화</div>
        </div>
        {items.length === 0 ? (
          <div style={{ padding: 16, color: tokens.textDim }}>아직 문항이 없습니다. 우측 상단의 ‘추가’를 눌러 문항을 만들어 보세요.</div>
        ) : (
          visibleItems.map((q, idx, arr) => {
              const isLast5 = (arr.length - idx) <= 5;
              return (
            <div key={q.id} style={{ padding: 12, borderBottom: `1px solid ${tokens.border}`, width: '100%', display: 'grid', gridTemplateColumns: '48px minmax(0,1fr) minmax(0,1fr) minmax(0,0.8fr) minmax(0,5fr) minmax(0,0.8fr) 88px minmax(0,0.8fr) minmax(0,1fr) minmax(0,1fr) minmax(0,2fr) minmax(0,0.6fr) 72px 72px', gap: 16, boxSizing: 'border-box' }}>
              <div style={{ color: tokens.textDim, textAlign:'right', paddingRight:4 }}>{idx + 1}</div>
              <div>
                <SelectPopup compact dropUp={isLast5} value={q.area || ''} options={areas.map(a=>({label:a.name, value:a.id}))}
                  onChange={(v)=>saveField(q.id, { area: v })} />
              </div>
              <div>
                <SelectPopup compact dropUp={isLast5} value={q.group || ''} options={groups.map(g=>({label:g.name, value:g.id}))}
                  onChange={(v)=>saveField(q.id, { group: v })} />
              </div>
              <div>
                <SelectPopup compact dropUp={isLast5} value={q.trait} options={traitOptions}
                  onChange={(v)=>saveField(q.id, { trait: v as any })} />
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input value={q.text} onChange={(e)=>saveField(q.id, { text: e.target.value })}
                  placeholder="문항 내용" style={{ width:'100%', height: 36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 10px' }} />
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                {typeEditId === q.id ? (
                  <SelectPopup compact dropUp={isLast5}
                    value={q.type}
                    options={[{label:'scale', value:'scale'},{label:'text', value:'text'}]}
                    onChange={(v)=>{
                      if (v === 'scale') {
                        setScaleDraftMin(q.min ?? 1);
                        setScaleDraftMax(q.max ?? 10);
                        setScaleEditId(q.id);
                        setTypeEditId(null);
                      } else {
                        saveField(q.id, { type:'text', min:undefined, max:undefined });
                        setTypeEditId(null);
                      }
                    }}
                  />
                ) : (
                  <button onClick={()=>setTypeEditId(q.id)} style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 10px', textAlign:'left', cursor:'pointer' }}>
                    {q.type === 'scale' ? `${q.min ?? 1} ~ ${q.max ?? 10}` : 'text'}
                  </button>
                )}
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input inputMode="decimal" value={weightDrafts[q.id] ?? (q.weight?.toString() ?? '')}
                  onChange={(e)=>{
                    const text = e.target.value;
                    // 허용: 숫자, 하나의 점, 최대 두 자리 소수(실시간 입력 고려해 저장은 텍스트로)
                    if (!/^\d*(?:\.\d{0,2})?$/.test(text)) return;
                    setWeightDrafts(prev => ({ ...prev, [q.id]: text }));
                    const num = text === '' ? undefined : Number(text);
                    saveField(q.id, { weight: num });
                  }}
                  placeholder="예: 1.00" style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 6px' }} />
              </div>
              <div>
                <SelectPopup compact dropUp={isLast5} value={q.reverse} options={[{label:'N', value:'N'},{label:'Y', value:'Y'}]}
                  onChange={(v)=>saveField(q.id, { reverse: v as any })} />
              </div>
              <div>
                <button onClick={()=>{ setPairPickForId(q.id); }}
                        style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.textDim, padding:'0 10px', textAlign:'left', cursor:'pointer' }}>
                  {q.pairId ? q.pairId : '선택'}
                </button>
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input value={q.tags ?? ''} onChange={(e)=>saveField(q.id, { tags: e.target.value })} onBlur={(e)=>{ if (/[0-9a-fA-F-]{36}/.test(q.id)) saveField(q.id, { tags: e.target.value }); }}
                  placeholder="태그,쉼표" style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 10px' }} />
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input value={q.memo ?? ''} onChange={(e)=>saveField(q.id, { memo: e.target.value })}
                  placeholder="메모" style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 10px' }} />
              </div>
              <div onDrop={(e)=>{
                    e.preventDefault();
                    const file = e.dataTransfer.files?.[0];
                    if (!file) return;
                    (async ()=>{
                      try {
                        // 1) Supabase Storage 업로드
                        const ext = (file.name.split('.').pop() || 'bin').toLowerCase();
                        const path = `questions/${q.id}.${Date.now()}.${ext}`;
                        const { data: up, error: upErr } = await supabase.storage.from('survey').upload(path, file, { upsert: true, cacheControl: '3600', contentType: (file as any).type || 'application/octet-stream' });
                        if (upErr) throw upErr;
                        // 2) 퍼블릭 URL 가져오기
                        const { data: pub } = supabase.storage.from('survey').getPublicUrl(path);
                        const publicUrl = (pub as any)?.publicUrl as string;
                        // 3) DB 반영
                        saveField(q.id, { image: publicUrl });
                      } catch (e) {
                        alert('업로드 실패: ' + ((e as any)?.message || '알 수 없는 오류'));
                      }
                    })();
                  }}
                   onDragOver={(e)=>e.preventDefault()}
                   onClick={()=>{ if (q.image) { saveField(q.id, { image: '' }); } }}
                   title={q.image ? '클릭하여 이미지 삭제' : '이미지 드롭하여 등록'}
                   style={{ position:'relative', width:'100%', height:36, background:'#2A2A2A', border:`1px dashed ${tokens.border}`, borderRadius:8, color:tokens.text, display:'flex', alignItems:'center', justifyContent:'center', cursor: q.image ? 'pointer' : 'copy', fontSize:18, padding:'0 6px', boxSizing:'border-box' }}
                   onMouseEnter={(e)=>{
                     const t = e.currentTarget as HTMLDivElement & { __tipEl?: HTMLDivElement };
                     if (!q.image) return;
                     const rect = t.getBoundingClientRect();
                     const tip = document.createElement('div');
                     tip.className = 'img-preview-tip';
                     tip.style.position = 'fixed';
                     const maxW = 240; const maxH = 180; const margin = 8;
                     const left = Math.min(window.innerWidth - (maxW + margin), rect.left);
                     const top = Math.max(margin, rect.top - (maxH + 12));
                     tip.style.left = `${left}px`;
                     tip.style.top = `${top}px`;
                     tip.style.background = '#18181A';
                     tip.style.border = `1px solid ${tokens.border}`;
                     tip.style.borderRadius = '10px';
                     tip.style.padding = '6px';
                     tip.style.zIndex = '2000';
                     tip.style.boxShadow = '0 6px 18px rgba(0,0,0,0.45)';
                     const img = document.createElement('img');
                     img.src = q.image!;
                     img.style.maxWidth = `${maxW}px`;
                     img.style.maxHeight = `${maxH}px`;
                     img.style.borderRadius = '8px';
                     img.style.display = 'block';
                     tip.appendChild(img);
                     document.body.appendChild(tip);
                     t.__tipEl = tip;
                   }}
                   onMouseLeave={(e)=>{
                     const t = e.currentTarget as HTMLDivElement & { __tipEl?: HTMLDivElement };
                     if (t.__tipEl && t.__tipEl.parentElement) t.__tipEl.parentElement.removeChild(t.__tipEl);
                     t.__tipEl = undefined;
                   }}
              >
                {q.image ? '✔' : '+'}
              </div>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'center' }}>
                <button
                  onClick={()=>{
                    const current = (q.version ?? 1);
                    const next = current + 1;
                    saveField(q.id, { version: next });
                    logChange(q.id, 'version_bump', current, next);
                  }}
                  title="버전 올리기"
                  style={{ width:56, height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, cursor:'pointer', fontWeight:800 }}
                >{q.version ?? 1}</button>
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <button
                  onClick={()=>{
                    if (q.active) {
                      // o -> x
                      saveField(q.id, { active: false });
                      logChange(q.id, 'deactivate', q.version ?? 1, q.version ?? 1);
                    } else {
                      // x 상태에서 한 번 더 누르면 삭제 확인
                      const ok = window.confirm('삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.');
                      if (ok) {
                        (async ()=>{
                          try {
                            await supabase.from(QUESTIONS_TABLE).delete().eq('id', q.id);
                            setItems(arr => arr.filter(it => it.id !== q.id));
                            logChange(q.id, 'delete', q.version ?? 1, null);
                          } catch (e) {
                            alert('삭제 실패: ' + ((e as any)?.message || '알 수 없는 오류'));
                          }
                        })();
                      } else {
                        // 취소 시 다시 활성화로 복귀
                        saveField(q.id, { active: true });
                        logChange(q.id, 'activate', q.version ?? 1, q.version ?? 1);
                      }
                    }
                  }}
                  aria-pressed={!!q.active}
                  style={{ width:56, height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:q.active ? tokens.text : '#ff6b6b', textAlign:'center', cursor:'pointer', fontSize:17 }}
                >
                  {q.active ? 'o' : 'x'}
                </button>
              </div>
            </div>
          );
          })
        )}
      </div>

      {areaDialog && (
        <ManageListDialog
          title={areaDialog === 'areas' ? '영역 관리' : '그룹 관리'}
          items={areaDialog === 'areas' ? areas : groups}
          setItems={areaDialog === 'areas' ? setAreas : setGroups}
          onClose={() => setAreaDialog(null)}
        />
      )}

      {addQOpen && (
        <Modal title="문항 추가" onClose={() => setAddQOpen(false)} actions={<>
          <button onClick={() => setAddQOpen(false)} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}>취소</button>
          <button onClick={async () => {
            try {
              const payload = toDbPatch(draft);
              payload.trait = draft.trait;
              payload.text = draft.text;
              payload.type = draft.type;
              if (draft.type === 'scale') {
                payload.min_score = draft.min ?? 1;
                payload.max_score = draft.max ?? 10;
              } else {
                payload.min_score = null;
                payload.max_score = null;
              }
              payload.reverse = draft.reverse;
              payload.weight = draft.weight ?? 1;
              payload.is_active = true;
              const { data, error } = await supabase.from(QUESTIONS_TABLE).insert(payload).select('*').single();
              if (error) throw error;
              const row: any = data;
              setItems((arr)=>[
                ...arr,
                {
                  id: row.id,
                  area: row.area_id || undefined,
                  group: row.group_id || undefined,
                  trait: row.trait,
                  text: row.text || '',
                  type: row.type,
                  min: row.min_score ?? undefined,
                  max: row.max_score ?? undefined,
                  weight: row.weight ?? undefined,
                  reverse: (row.reverse || 'N'),
                  tags: row.tags || undefined,
                  memo: row.memo || undefined,
                  image: row.image_url || undefined,
                  pairId: row.pair_id || undefined,
                  active: !!row.is_active,
                }
              ]);
              setAddQOpen(false);
            } catch (e) {
              console.error(e);
              const msg = (e as any)?.message || '알 수 없는 오류';
              alert(`저장 실패: ${msg}`);
              // 다이얼로그를 닫지 않아 사용자가 수정 후 재시도할 수 있게 함
            }
          }} style={{ padding: '8px 12px', borderRadius: 10, border: 'none', background: tokens.accent, color: '#fff', cursor: 'pointer' }}>추가</button>
        </>}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 12 }}>
            {/* 1행: 영역, 그룹, 성향 */}
            <div style={{ display: 'grid', gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr 1fr', gap: 12, minWidth: 0 }}>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>영역</label>
                <SelectPopup value={draft.area || ''} options={areas.map(a=>({label:a.name, value:a.id}))} onChange={(v)=>setDraft({ ...draft, area: v })} />
              </div>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>그룹</label>
                <SelectPopup value={draft.group || ''} options={groups.map(g=>({label:g.name, value:g.id}))} onChange={(v)=>setDraft({ ...draft, group: v })} />
              </div>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>성향 코드</label>
                <SelectPopup value={draft.trait} options={traitOptions} onChange={(v)=>setDraft({ ...draft, trait: v as any })} />
              </div>
            </div>

            {/* 2행: 설문 문항 */}
            <div style={{ minWidth: 0 }}>
              <label style={{ color: tokens.textDim, fontSize: 13 }}>설문 문항</label>
              <input value={draft.text} onChange={(e)=>setDraft({ ...draft, text: e.target.value })} placeholder="문항 내용을 입력" style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }} />
            </div>

            {/* 3행: 역문항, 유형, (스케일이면 최소/최대) */}
            <div style={{ display: 'grid', gridTemplateColumns: isNarrow ? '1fr' : (isScale ? '1fr 1fr 1fr 1fr' : '1fr 1fr'), gap: 12, minWidth: 0 }}>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>역문항 여부</label>
                <SelectPopup value={draft.reverse} options={[{label:'N', value:'N'},{label:'Y', value:'Y'}]} onChange={(v)=>setDraft({ ...draft, reverse: v as any })} />
              </div>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>유형</label>
                <SelectPopup value={draft.type} options={[{label:'scale', value:'scale'},{label:'text', value:'text'}]} onChange={(v)=>setDraft({ ...draft, type: v as any })} />
              </div>
              {isScale && (
                <>
                  <div style={{ minWidth: 0 }}>
                    <label style={{ color: tokens.textDim, fontSize: 13 }}>최소 점수</label>
                    <input inputMode="numeric" pattern="[0-9]*" value={draft.min ?? 1} onChange={(e)=>setDraft({ ...draft, min: Number(e.target.value.replace(/[^0-9-]/g,'')) })} style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box', appearance: 'textfield' as any }} />
                  </div>
                  <div style={{ minWidth: 0 }}>
                    <label style={{ color: tokens.textDim, fontSize: 13 }}>최대 점수</label>
                    <input inputMode="numeric" pattern="[0-9]*" value={draft.max ?? 10} onChange={(e)=>setDraft({ ...draft, max: Number(e.target.value.replace(/[^0-9-]/g,'')) })} style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box', appearance: 'textfield' as any }} />
                  </div>
                </>
              )}
            </div>

            {/* 4행: 가중치, 태그 */}
            <div style={{ display: 'grid', gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr', gap: 12, minWidth: 0 }}>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>가중치</label>
                <input inputMode="decimal" value={draftWeightText !== '' ? draftWeightText : (draft.weight?.toString() ?? '')} onChange={(e)=>{
                  const text = e.target.value;
                  if (!/^\d*(?:\.\d{0,2})?$/.test(text)) return;
                  setDraftWeightText(text);
                  const num = text === '' ? undefined : Number(text);
                  setDraft({ ...draft, weight: num });
                }} placeholder="예: 1.00" style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box', appearance: 'textfield' as any }} />
              </div>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>태그</label>
                <input value={draft.tags ?? ''} onChange={(e)=>setDraft({ ...draft, tags: e.target.value })} placeholder="쉼표로 구분" style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box' }} />
              </div>
            </div>

            {/* 5행: 메모 */}
            <div style={{ minWidth: 0 }}>
              <label style={{ color: tokens.textDim, fontSize: 13 }}>메모</label>
              <textarea value={draft.memo ?? ''} onChange={(e)=>setDraft({ ...draft, memo: e.target.value })} rows={3}
                        style={{ width: '100%', marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: 12, resize: 'none', boxSizing: 'border-box' }} />
            </div>
          </div>
        </Modal>
      )}

      {scaleEditId && (
        <Modal title="척도 설정" width={420} onClose={()=>setScaleEditId(null)} actions={<>
          <button onClick={()=>setScaleEditId(null)} style={{ padding:'8px 12px', borderRadius:10, border:`1px solid ${tokens.border}`, background:tokens.panel, color:tokens.text, cursor:'pointer' }}>취소</button>
          <button onClick={()=>{
            if (scaleEditId) {
              setItems((arr)=>arr.map(it=>it.id===scaleEditId?{...it, type:'scale', min:scaleDraftMin, max:scaleDraftMax}:it));
              // persist to DB if row exists
              saveField(scaleEditId, { type: 'scale', min: scaleDraftMin, max: scaleDraftMax });
              try {
                setLastScaleRange({ min: scaleDraftMin, max: scaleDraftMax });
                localStorage.setItem('last_scale_range', JSON.stringify({ min: scaleDraftMin, max: scaleDraftMax }));
              } catch {}
            }
            setScaleEditId(null);
          }} style={{ padding:'8px 12px', borderRadius:10, border:'none', background:tokens.accent, color:'#fff', cursor:'pointer' }}>저장</button>
        </>}>
          <div style={{ display:'flex', alignItems:'center' }}>
            <label style={{ color: tokens.textDim, fontSize: 13, marginRight: 12 }}>최소 점수</label>
            <input inputMode="numeric" pattern="[0-9]*" value={scaleDraftMin}
                   onChange={(e)=>setScaleDraftMin(Number(e.target.value.replace(/[^0-9-]/g,'')))}
                   style={{ width:80, height:44, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 12px', marginRight: 40 }} />
            <label style={{ color: tokens.textDim, fontSize: 13, marginRight: 12 }}>최대 점수</label>
            <input inputMode="numeric" pattern="[0-9]*" value={scaleDraftMax}
                   onChange={(e)=>setScaleDraftMax(Number(e.target.value.replace(/[^0-9-]/g,'')))}
                   style={{ width:80, height:44, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 12px' }} />
          </div>
        </Modal>
      )}
      {pairPickForId && (
        <Modal title="페어 선택" onClose={()=>setPairPickForId(null)} actions={<> 
          <button onClick={()=>setPairPickForId(null)} style={{ padding:'8px 12px', borderRadius:10, border:`1px solid ${tokens.border}`, background:tokens.panel, color:tokens.text, cursor:'pointer' }}>닫기</button>
        </>}>
          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden' }}>
            <div style={{ display:'grid', gridTemplateColumns:'minmax(0,0.8fr) minmax(0,5fr)', gap:16, padding:12, borderBottom:`1px solid ${tokens.border}`, color:tokens.textDim }}>
              <div>성향</div>
              <div>내용</div>
            </div>
            <div style={{ maxHeight: 420, overflowY:'auto' }}>
              {items.map(it => (
                <div key={it.id}
                      onClick={async ()=>{
                        const targetId = pairPickForId;
                        if (!targetId) return;
                        const selectedId = it.id;
                        if (selectedId === targetId) { setPairPickForId(null); return; }
                        const existingIds = items.map(q=>q.pairId).filter(Boolean) as string[];
                        const newPair = generateNextPairId(existingIds);
                        const isUuid = (s:string)=>/[0-9a-fA-F-]{36}/.test(s);
                        const prev = items;
                        const target = prev.find(q=>q.id===targetId);
                        const selected = prev.find(q=>q.id===selectedId);
                        const nextPairId = target?.pairId || selected?.pairId || newPair;
                        // optimistic update
                        setItems(arr => arr.map(q =>
                          q.id===targetId ? { ...q, pairId: nextPairId } :
                          q.id===selectedId ? { ...q, pairId: nextPairId } : q
                        ));
                        try {
                          if (isUuid(targetId)) {
                            const { error } = await supabase.from(QUESTIONS_TABLE)
                              .update({ pair_id: nextPairId })
                              .eq('id', targetId);
                            if (error) throw error;
                          }
                          if (isUuid(selectedId)) {
                            const { error } = await supabase.from(QUESTIONS_TABLE)
                              .update({ pair_id: nextPairId })
                              .eq('id', selectedId);
                            if (error) throw error;
                          }
                        } catch (e:any) {
                          alert('페어 ID 저장 실패: ' + (e?.message || '알 수 없는 오류'));
                          // revert
                          setItems(prev);
                        }
                        setPairPickForId(null);
                      }}
                      style={{ display:'grid', gridTemplateColumns:'minmax(0,0.8fr) minmax(0,5fr)', gap:16, padding:'10px 12px', borderBottom:`1px solid ${tokens.border}`, cursor:'pointer' }}>
                  <div>{it.trait}</div>
                  <div style={{ color: tokens.textDim }}>{it.text || '(내용 없음)'}</div>
                </div>
               ))}
             </div>
           </div>
         </Modal>
       )}
    </div>
  );
}



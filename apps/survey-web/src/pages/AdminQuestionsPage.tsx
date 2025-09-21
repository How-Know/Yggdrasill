import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { supabase } from '../lib/supabaseClient';

const tokens = {
  bg: '#1F1F1F',
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
};

function ToolbarButton({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) {
  return (
    <button onClick={onClick} style={{ padding: '8px 12px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, cursor: 'pointer' }}>{children}</button>
  );
}

function Modal({ title, onClose, children, actions }: { title: string; onClose: () => void; children: React.ReactNode; actions?: React.ReactNode }) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 50 }}>
      <div style={{ width: 'min(720px, 92vw)', background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20, overflow: 'visible' }}>
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
function SelectPopup({ value, options, onChange, compact }: { value: string; options: OptionItem[]; onChange: (v: string) => void; compact?: boolean }) {
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
             style={{ position: 'fixed', left: rect.left, top: rect.bottom + 4, width: rect.width, maxHeight: 320, overflowY: 'auto', background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 8, zIndex: 1000, overscrollBehavior: 'contain', touchAction: 'pan-y' }}>
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
    max: 5,
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
  const [scaleDraftMax, setScaleDraftMax] = useState<number>(5);
  
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
    return out;
  }

  async function saveField(questionId: string, patch: Partial<QuestionDraft>) {
    setItems((arr)=>arr.map(it=>it.id===questionId?{...it, ...patch}:it));
    try {
      const isUuid = /[0-9a-fA-F-]{36}/.test(questionId);
      if (!isUuid) return;
      const dbPatch = toDbPatch(patch);
      if (Object.keys(dbPatch).length === 0) return;
      await supabase.from(QUESTIONS_TABLE).update(dbPatch).eq('id', questionId);
    } catch (e) {
      console.error(e);
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
    setDraft({ id: Math.random().toString(36).slice(2), trait: 'D', text: '', type: 'scale', min: 1, max: 5, reverse: 'N', image: '', active: true });
  }

  const traitOptions = useMemo<OptionItem[]>(() => ['D','I','A','C','N','L','S','P'].map(v=>({label:v, value:v})), []);
  const [filterOpen, setFilterOpen] = useState(false);
  const [activeAreas, setActiveAreas] = useState<string[]>([]);
  const [activeGroups, setActiveGroups] = useState<string[]>([]);
  const [pairPickForId, setPairPickForId] = useState<string | null>(null);

  return (
    <div style={{ color: tokens.text }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
        <ToolbarButton onClick={() => setAreaDialog('areas')}>영역</ToolbarButton>
        <ToolbarButton onClick={() => setAreaDialog('groups')}>그룹</ToolbarButton>
        <ToolbarButton onClick={() => setFilterOpen((s)=>!s)}>필터</ToolbarButton>
        <div style={{ flex: 1 }} />
        <ToolbarButton onClick={() => { resetDraft(); setAddQOpen(true); }}>추가</ToolbarButton>
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
        </div>
      )}

      <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, overflowX: 'hidden', width: '100%', margin: '0 auto' }}>
        <div style={{ width: '100%', display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) minmax(0,0.8fr) minmax(0,5fr) minmax(0,0.8fr) 88px minmax(0,0.8fr) minmax(0,1fr) minmax(0,1fr) minmax(0,2fr) minmax(0,0.6fr) 72px', gap: 16, padding: 12, borderBottom: `1px solid ${tokens.border}`, color: tokens.textDim, boxSizing: 'border-box' }}>
          <div>영역</div><div>그룹</div><div>성향</div><div>내용</div><div>평가</div><div>가중치</div><div>역문항</div><div>페어 ID</div><div>태그</div><div>메모</div><div>그림</div><div>활성화</div>
        </div>
        {items.length === 0 ? (
          <div style={{ padding: 16, color: tokens.textDim }}>아직 문항이 없습니다. 우측 상단의 ‘추가’를 눌러 문항을 만들어 보세요.</div>
        ) : (
          items
            .filter((q)=> (activeAreas.length ? activeAreas.includes(q.area || '') : true))
            .filter((q)=> (activeGroups.length ? activeGroups.includes(q.group || '') : true))
            .map((q) => (
            <div key={q.id} style={{ padding: 12, borderBottom: `1px solid ${tokens.border}`, width: '100%', display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr) minmax(0,0.8fr) minmax(0,5fr) minmax(0,0.8fr) 88px minmax(0,0.8fr) minmax(0,1fr) minmax(0,1fr) minmax(0,2fr) minmax(0,0.6fr) 72px', gap: 16, boxSizing: 'border-box' }}>
              <div>
                <SelectPopup compact value={q.area || ''} options={areas.map(a=>({label:a.name, value:a.id}))}
                  onChange={(v)=>saveField(q.id, { area: v })} />
              </div>
              <div>
                <SelectPopup compact value={q.group || ''} options={groups.map(g=>({label:g.name, value:g.id}))}
                  onChange={(v)=>saveField(q.id, { group: v })} />
              </div>
              <div>
                <SelectPopup compact value={q.trait} options={traitOptions}
                  onChange={(v)=>saveField(q.id, { trait: v as any })} />
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input value={q.text} onChange={(e)=>saveField(q.id, { text: e.target.value })}
                  placeholder="문항 내용" style={{ width:'100%', height: 36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 10px' }} />
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                {typeEditId === q.id ? (
                  <SelectPopup compact
                    value={q.type}
                    options={[{label:'scale', value:'scale'},{label:'text', value:'text'}]}
                    onChange={(v)=>{
                      if (v === 'scale') {
                        setScaleDraftMin(q.min ?? 1);
                        setScaleDraftMax(q.max ?? 5);
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
                    {q.type === 'scale' ? `${q.min ?? 1} ~ ${q.max ?? 5}` : 'text'}
                  </button>
                )}
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input inputMode="numeric" pattern="[0-9]*" value={q.weight ?? ''}
                  onChange={(e)=>{
                    const raw = e.target.value.replace(/[^0-9]/g,'');
                    const num = raw === '' ? undefined : Math.max(1, Number(raw));
                    saveField(q.id, { weight: num });
                  }}
                  placeholder="예:1" style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 6px' }} />
              </div>
              <div>
                <SelectPopup compact value={q.reverse} options={[{label:'N', value:'N'},{label:'Y', value:'Y'}]}
                  onChange={(v)=>saveField(q.id, { reverse: v as any })} />
              </div>
              <div>
                <button onClick={()=>{ setPairPickForId(q.id); }}
                        style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.textDim, padding:'0 10px', textAlign:'left', cursor:'pointer' }}>
                  {q.pairId ? q.pairId : '선택'}
                </button>
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <input value={q.tags ?? ''} onChange={(e)=>saveField(q.id, { tags: e.target.value })}
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
                    const reader = new FileReader();
                    reader.onload = () => {
                      const url = String(reader.result);
                      saveField(q.id, { image: url });
                    };
                    reader.readAsDataURL(file);
                  }}
                   onDragOver={(e)=>e.preventDefault()}
                   style={{ width:'100%', height:36, background:'#2A2A2A', border:`1px dashed ${tokens.border}`, borderRadius:8, color:tokens.text, display:'flex', alignItems:'center', justifyContent:'center', cursor:'copy', fontSize:18, padding:'0 6px', boxSizing:'border-box' }}>
                +
              </div>
              <div style={{ display:'flex', alignItems:'center' }}>
                <button
                  onClick={()=>saveField(q.id, { active: !q.active })}
                  aria-pressed={!!q.active}
                  style={{ width:56, height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:q.active ? tokens.text : '#ff6b6b', textAlign:'center', cursor:'pointer', fontSize:17 }}
                >
                  {q.active ? 'o' : 'x'}
                </button>
              </div>
            </div>
          ))
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
                payload.max_score = draft.max ?? 5;
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
              setItems((arr) => [...arr, draft]);
              setAddQOpen(false);
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
                    <input inputMode="numeric" pattern="[0-9]*" value={draft.max ?? 5} onChange={(e)=>setDraft({ ...draft, max: Number(e.target.value.replace(/[^0-9-]/g,'')) })} style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box', appearance: 'textfield' as any }} />
                  </div>
                </>
              )}
            </div>

            {/* 4행: 가중치, 태그 */}
            <div style={{ display: 'grid', gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr', gap: 12, minWidth: 0 }}>
              <div style={{ minWidth: 0 }}>
                <label style={{ color: tokens.textDim, fontSize: 13 }}>가중치</label>
                <input inputMode="numeric" pattern="[0-9]*" value={draft.weight ?? '' as any} onChange={(e)=>{
                  const raw = e.target.value.replace(/[^0-9]/g,'');
                  const num = raw === '' ? undefined : Math.max(1, Number(raw));
                  setDraft({ ...draft, weight: num });
                }} placeholder="예: 1" style={{ width: '100%', height: 44, marginTop: 6, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', boxSizing: 'border-box', appearance: 'textfield' as any }} />
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
        <Modal title="척도 설정" onClose={()=>setScaleEditId(null)} actions={<>
          <button onClick={()=>setScaleEditId(null)} style={{ padding:'8px 12px', borderRadius:10, border:`1px solid ${tokens.border}`, background:tokens.panel, color:tokens.text, cursor:'pointer' }}>취소</button>
          <button onClick={()=>{
            if (scaleEditId) {
              setItems((arr)=>arr.map(it=>it.id===scaleEditId?{...it, type:'scale', min:scaleDraftMin, max:scaleDraftMax}:it));
              // persist to DB if row exists
              saveField(scaleEditId, { type: 'scale', min: scaleDraftMin, max: scaleDraftMax });
            }
            setScaleEditId(null);
          }} style={{ padding:'8px 12px', borderRadius:10, border:'none', background:tokens.accent, color:'#fff', cursor:'pointer' }}>저장</button>
        </>}>
          <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:12 }}>
            <div>
              <label style={{ color: tokens.textDim, fontSize: 13 }}>최소 점수</label>
              <input inputMode="numeric" pattern="[0-9]*" value={scaleDraftMin}
                     onChange={(e)=>setScaleDraftMin(Number(e.target.value.replace(/[^0-9-]/g,'')))}
                     style={{ width:'100%', height:44, marginTop:6, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 12px' }} />
            </div>
            <div>
              <label style={{ color: tokens.textDim, fontSize: 13 }}>최대 점수</label>
              <input inputMode="numeric" pattern="[0-9]*" value={scaleDraftMax}
                     onChange={(e)=>setScaleDraftMax(Number(e.target.value.replace(/[^0-9-]/g,'')))}
                     style={{ width:'100%', height:44, marginTop:6, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:tokens.text, padding:'0 12px' }} />
            </div>
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
                      onClick={()=>{
                        const targetId = pairPickForId;
                        if (!targetId) return;
                        const selectedId = it.id;
                        if (selectedId === targetId) { setPairPickForId(null); return; }
                        const existingIds = items.map(q=>q.pairId).filter(Boolean) as string[];
                        const newPair = generateNextPairId(existingIds);
                        setItems(arr => {
                          const target = arr.find(q=>q.id===targetId);
                          const selected = arr.find(q=>q.id===selectedId);
                          const nextPairId = target?.pairId || selected?.pairId || newPair;
                          const nextArr = arr.map(q =>
                            q.id===targetId ? { ...q, pairId: nextPairId } :
                            q.id===selectedId ? { ...q, pairId: nextPairId } : q
                          );
                          const isUuid = (s:string)=>/[0-9a-fA-F-]{36}/.test(s);
                          if (isUuid(targetId)) supabase.from(QUESTIONS_TABLE).update({ pair_id: nextPairId }).eq('id', targetId);
                          if (isUuid(selectedId)) supabase.from(QUESTIONS_TABLE).update({ pair_id: nextPairId }).eq('id', selectedId);
                          return nextArr;
                        });
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



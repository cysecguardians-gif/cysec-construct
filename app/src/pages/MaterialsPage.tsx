import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Material = {
  id: string;
  name: string;
  description: string | null;
  hsn_sac_code: string | null;
  gst_rate: number;
  selling_price_paise: number;
  current_quantity: number;
  is_active: boolean;
  unit_id: string | null;
  category_id: string | null;
  units?: { name: string; short_code: string } | null;
  material_categories?: { name: string } | null;
};

type Unit = { id: string; name: string; short_code: string };
type Category = { id: string; name: string };

type Props = {
  supabase: SupabaseClient;
  organizationId: string;
  onBack: () => void;
};

const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });

export default function MaterialsPage({ supabase, organizationId, onBack }: Props) {
  const [materials, setMaterials] = useState<Material[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [categories, setCategories] = useState<Category[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing] = useState<Material | null>(null);
  const [adjusting, setAdjusting] = useState<Material | null>(null);

  async function load() {
    setBusy(true);
    setError('');
    const [materialsResult, unitsResult, categoriesResult] = await Promise.all([
      supabase.from('materials').select('id,name,description,hsn_sac_code,gst_rate,selling_price_paise,current_quantity,is_active,unit_id,category_id,units(name,short_code),material_categories(name)').eq('organization_id', organizationId).order('name'),
      supabase.from('units').select('id,name,short_code').eq('organization_id', organizationId).order('name'),
      supabase.from('material_categories').select('id,name').eq('organization_id', organizationId).order('name'),
    ]);
    setBusy(false);
    if (materialsResult.error || unitsResult.error || categoriesResult.error) {
      setError(materialsResult.error?.message || unitsResult.error?.message || categoriesResult.error?.message || 'Could not load materials.');
      return;
    }
    setMaterials((materialsResult.data ?? []) as unknown as Material[]);
    setUnits(unitsResult.data ?? []);
    setCategories(categoriesResult.data ?? []);
  }

  useEffect(() => { void load(); }, [organizationId]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return materials;
    return materials.filter((m) => `${m.name} ${m.hsn_sac_code ?? ''} ${m.material_categories?.name ?? ''}`.toLowerCase().includes(term));
  }, [materials, search]);

  async function saveMaterial(values: { name: string; description: string; hsn: string; gst: string; price: string; quantity: string; unitId: string; categoryId: string }) {
    setError('');
    const price = Math.round(Math.max(0, Number(values.price || 0)) * 100);
    const gst = Number(values.gst || 0);
    const quantity = Number(values.quantity || 0);
    if (!values.name.trim()) throw new Error('Material name is required.');
    if (!Number.isFinite(price) || !Number.isFinite(gst) || !Number.isFinite(quantity) || gst < 0 || gst > 100 || quantity < 0) throw new Error('Enter valid price, GST rate and quantity.');

    if (editing) {
      const { error: updateError } = await supabase.from('materials').update({ name: values.name.trim(), description: values.description.trim() || null, hsn_sac_code: values.hsn.trim() || null, gst_rate: gst, selling_price_paise: price, unit_id: values.unitId || null, category_id: values.categoryId || null }).eq('id', editing.id).eq('organization_id', organizationId);
      if (updateError) throw updateError;
    } else {
      const { data, error: insertError } = await supabase.from('materials').insert({ organization_id: organizationId, name: values.name.trim(), description: values.description.trim() || null, hsn_sac_code: values.hsn.trim() || null, gst_rate: gst, selling_price_paise: price, current_quantity: 0, unit_id: values.unitId || null, category_id: values.categoryId || null }).select('id').single();
      if (insertError) throw insertError;
      if (quantity > 0 && data) {
        const { error: stockError } = await supabase.rpc('adjust_stock', { p_organization_id: organizationId, p_material_id: data.id, p_quantity: quantity, p_notes: 'Opening stock' });
        if (stockError) throw stockError;
      }
    }
    setShowForm(false);
    setEditing(null);
    await load();
  }

  async function adjustStock(quantity: string, notes: string) {
    if (!adjusting) return;
    const value = Number(quantity);
    if (!Number.isFinite(value) || value === 0) throw new Error('Enter a non-zero stock adjustment.');
    const { error: rpcError } = await supabase.rpc('adjust_stock', { p_organization_id: organizationId, p_material_id: adjusting.id, p_quantity: value, p_notes: notes.trim() || null });
    if (rpcError) throw rpcError;
    setAdjusting(null);
    await load();
  }

  async function toggleActive(material: Material) {
    const { error: updateError } = await supabase.from('materials').update({ is_active: !material.is_active }).eq('id', material.id).eq('organization_id', organizationId);
    if (updateError) setError(updateError.message); else await load();
  }

  return (
    <main className="main-content">
      <header className="topbar">
        <div><button className="back-link" onClick={onBack}>← Overview</button><p className="eyebrow">Inventory</p><h1>Materials & stock</h1></div>
        <button className="primary compact" onClick={() => { setEditing(null); setShowForm(true); }}>Add material</button>
      </header>
      <section className="page-toolbar"><input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search materials, HSN/SAC or category…" /><span>{filtered.length} material{filtered.length === 1 ? '' : 's'}</span></section>
      {error && <div className="alert error page-alert">{error}</div>}
      <section className="table-card">
        {busy ? <div className="table-empty">Loading materials…</div> : filtered.length === 0 ? <div className="table-empty"><strong>No materials yet</strong><span>Add the first material to start tracking stock.</span></div> : (
          <table><thead><tr><th>Material</th><th>HSN/SAC</th><th>Unit</th><th>GST</th><th>Price</th><th>Stock</th><th>Status</th><th></th></tr></thead><tbody>
            {filtered.map((material) => <tr key={material.id}>
              <td><strong>{material.name}</strong>{material.material_categories?.name && <small>{material.material_categories.name}</small>}</td>
              <td>{material.hsn_sac_code || '—'}</td>
              <td>{material.units?.short_code || material.units?.name || '—'}</td>
              <td>{Number(material.gst_rate).toFixed(2)}%</td>
              <td>{money.format(Number(material.selling_price_paise) / 100)}</td>
              <td><strong>{Number(material.current_quantity).toLocaleString('en-IN')}</strong></td>
              <td><span className={material.is_active ? 'pill active' : 'pill'}>{material.is_active ? 'Active' : 'Inactive'}</span></td>
              <td><div className="row-actions"><button onClick={() => { setEditing(material); setShowForm(true); }}>Edit</button><button onClick={() => setAdjusting(material)}>Stock</button><button onClick={() => void toggleActive(material)}>{material.is_active ? 'Deactivate' : 'Activate'}</button></div></td>
            </tr>)}
          </tbody></table>
        )}
      </section>
      {showForm && <MaterialForm material={editing} units={units} categories={categories} onCancel={() => { setShowForm(false); setEditing(null); }} onSave={saveMaterial} />}
      {adjusting && <StockAdjustForm material={adjusting} onCancel={() => setAdjusting(null)} onSave={adjustStock} />}
    </main>
  );
}

function MaterialForm({ material, units, categories, onCancel, onSave }: { material: Material | null; units: Unit[]; categories: Category[]; onCancel: () => void; onSave: (values: { name: string; description: string; hsn: string; gst: string; price: string; quantity: string; unitId: string; categoryId: string }) => Promise<void> }) {
  const [form, setForm] = useState({ name: material?.name ?? '', description: material?.description ?? '', hsn: material?.hsn_sac_code ?? '', gst: String(material?.gst_rate ?? 0), price: material ? String(Number(material.selling_price_paise) / 100) : '', quantity: '', unitId: material?.unit_id ?? '', categoryId: material?.category_id ?? '' });
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  async function submit(e: React.FormEvent) { e.preventDefault(); setBusy(true); setError(''); try { await onSave(form); } catch (err) { setError(err instanceof Error ? err.message : 'Could not save material.'); } finally { setBusy(false); } }
  return <Modal title={material ? 'Edit material' : 'Add material'} onClose={onCancel}><form className="stack" onSubmit={submit}><div className="two-col wide"><label>Material name<input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required /></label><label>Unit<select value={form.unitId} onChange={(e) => setForm({ ...form, unitId: e.target.value })}><option value="">Select unit</option>{units.map((u) => <option key={u.id} value={u.id}>{u.name} ({u.short_code})</option>)}</select></label></div><div className="two-col wide"><label>Category <span className="muted">optional</span><select value={form.categoryId} onChange={(e) => setForm({ ...form, categoryId: e.target.value })}><option value="">No category</option>{categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>HSN/SAC <span className="muted">optional</span><input value={form.hsn} onChange={(e) => setForm({ ...form, hsn: e.target.value })} /></label></div><div className="two-col wide"><label>Selling price (₹)<input type="number" min="0" step="0.01" value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} /></label><label>GST rate (%)<input type="number" min="0" max="100" step="0.01" value={form.gst} onChange={(e) => setForm({ ...form, gst: e.target.value })} /></label></div>{!material && <label>Opening stock<input type="number" min="0" step="0.001" value={form.quantity} onChange={(e) => setForm({ ...form, quantity: e.target.value })} placeholder="0" /></label>}<label>Description <span className="muted">optional</span><input value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></label>{error && <div className="alert error">{error}</div>}<div className="modal-actions"><button type="button" onClick={onCancel}>Cancel</button><button className="primary compact" disabled={busy}>{busy ? 'Saving…' : 'Save material'}</button></div></form></Modal>;
}

function StockAdjustForm({ material, onCancel, onSave }: { material: Material; onCancel: () => void; onSave: (quantity: string, notes: string) => Promise<void> }) {
  const [quantity, setQuantity] = useState(''); const [notes, setNotes] = useState(''); const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  async function submit(e: React.FormEvent) { e.preventDefault(); setBusy(true); setError(''); try { await onSave(quantity, notes); } catch (err) { setError(err instanceof Error ? err.message : 'Could not adjust stock.'); } finally { setBusy(false); } }
  return <Modal title={`Adjust stock — ${material.name}`} onClose={onCancel}><form className="stack" onSubmit={submit}><p className="form-note">Current stock: <strong>{Number(material.current_quantity).toLocaleString('en-IN')}</strong>. Use a positive number to add stock and a negative number to remove stock.</p><label>Adjustment quantity<input type="number" step="0.001" value={quantity} onChange={(e) => setQuantity(e.target.value)} placeholder="e.g. 10 or -2" required /></label><label>Reason / notes<input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Purchase, correction, opening stock…" /></label>{error && <div className="alert error">{error}</div>}<div className="modal-actions"><button type="button" onClick={onCancel}>Cancel</button><button className="primary compact" disabled={busy}>{busy ? 'Updating…' : 'Update stock'}</button></div></form></Modal>;
}

function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return <div className="modal-backdrop"><div className="modal"><div className="modal-header"><h2>{title}</h2><button onClick={onClose}>×</button></div>{children}</div></div>;
}

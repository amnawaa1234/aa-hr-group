# AA HR Group — Sistem Permohonan Cuti

Sistem HR & Admin untuk **Ascend Advisory Group**. Fasa 1: Borang Permohonan Cuti (Leave Application Form).

- **Frontend:** HTML/CSS/JavaScript biasa (tiada PHP, tiada build) — upload terus ke Hostinger `public_html`.
- **Backend:** [Supabase](https://supabase.com) (login, database PostgreSQL, simpan fail MC). Pelan percuma sudah memadai.

## Jenis cuti (default — boleh ubah di Settings)

| Cuti | Hari/tahun | Kira | Lampiran | Boleh mohon lepas tarikh |
|---|---|---|---|---|
| Annual Leave | 14 | Hari bekerja | – | Tidak |
| Casual Leave | 3 | Hari bekerja | – | Tidak |
| Emergency Leave | 3 | Hari bekerja | – | Ya |
| Sick Leave | 14 | Hari bekerja | MC wajib | Ya |
| Maternity Leave | 98 | Hari kalendar | Wajib | Tidak |
| Unpaid Leave | Tiada had | Hari bekerja | – | Tidak |

Hari bekerja = Isnin–Jumaat, tolak cuti umum (tambah di Settings).

## Peranan (role)

| Role | Boleh buat |
|---|---|
| **Staff** | Mohon cuti, lihat baki, lihat/batal permohonan sendiri (yang masih pending) |
| **Director** | Semua di atas + **Approve / Reject** semua permohonan, lihat semua rekod |
| **HR & Admin** | Semua fungsi staff + urus staff, role, kelayakan cuti, jenis cuti, cuti umum, export CSV |

Semua peraturan (baki cuti, tarikh bertindih, MC wajib, hanya Director boleh approve, tak boleh approve cuti sendiri) dikuatkuasa di **database**, bukan sekadar di browser.

---

## Cara pasang (sekali sahaja)

### 1. Buat projek Supabase
1. Daftar di https://supabase.com → **New project** (pilih region *Southeast Asia (Singapore)*).
2. Pergi **SQL Editor → New query**, salin semua isi `supabase/schema.sql`, tekan **Run**.

### 2. Tetapan Auth di Supabase
1. **Authentication → Sign In / Providers → Email**: matikan **Allow new users to sign up** (supaya hanya staff yang dijemput boleh masuk).
2. **Authentication → URL Configuration**:
   - *Site URL*: `https://domain-anda.com/`
   - *Redirect URLs*: tambah `https://domain-anda.com/reset.html`

### 3. Masukkan kunci Supabase
Buka `assets/config.js` dan isi dari **Project Settings → API**:
```js
SUPABASE_URL: 'https://xxxx.supabase.co',
SUPABASE_ANON_KEY: 'eyJhbGciOi...',   // "anon public" key
```
(Kunci *anon* memang selamat diletak di browser. **Jangan** sekali-kali letak kunci *service_role*.)

### 4. Upload ke Hostinger
hPanel → **File Manager** → `public_html` → upload semua fail **kecuali** folder `supabase/` dan `README.md`:
```
index.html  reset.html  dashboard.html  apply.html  my-leaves.html
approvals.html  all-leaves.html  view.html  staff.html  settings.html
assets/ (style.css, app.js, config.js)
```
Pastikan SSL (HTTPS) aktif di hPanel.

### 5. Cipta akaun pertama (HR & Admin)
Supabase → **SQL Editor → New query**, tampal (tukar ID, nama dan password) dan tekan **Run**:
```sql
select public.admin_create_staff('AA001', 'Nama Penuh Awak', '1234', 'admin');  -- PIN 4 digit
```
Login di laman web dengan **Staff ID `AA001`** dan **PIN** tu.

### 6. Tambah staff lain (dalam sistem, tanpa emel)
Menu **Staff → + Add staff** → isi Staff ID, PIN 4 digit, nama, jabatan, jawatan dan role (pilih **Director** untuk Director) → **Create account**. Beri Staff ID + PIN kepada staff.

Staff lupa PIN → **Staff → Edit → New PIN**.

## Tema warna
HR & Admin boleh tukar tema di **Settings → Colour theme**: Emerald & Gold (default), Navy & Gold, Burgundy & Gold, Royal Plum, Charcoal & Amber. Tema terpakai untuk semua staff, termasuk halaman login.

## Nota
- Notifikasi emel kepada Director bila ada permohonan baru belum ada lagi — Director nampak bilangan di menu *Approvals* dan dashboard. Boleh ditambah kemudian (Supabase Edge Function + SMTP Hostinger).
- Tiada emel diperlukan. Sistem guna emel dalaman `<staffid>@aahr.local` di belakang tabir (tak dipaparkan).
- Borang permohonan boleh dicetak / simpan PDF dari halaman **View → Print / PDF**.

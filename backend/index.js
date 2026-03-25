const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const path = require('path');
const db = require('./database');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// ─── CLIENT APIS ──────────────────────────────────────────────────────────────

// 🔑 Validate/Activate License
app.post('/validate-license', (req, res) => {
  const { email, license_key, device_id } = req.body;
  if (!email || !license_key || !device_id) return res.status(400).json({ status: 'error', message: 'Missing parameters.' });

  try {
    const query = `SELECT * FROM licenses WHERE license_key = ?`;
    const license = db.prepare(query).get(license_key);

    if (!license) return res.status(401).json({ status: 'error', message: 'Invalid license key.' });
    if (license.is_active === 0) return res.status(403).json({ status: 'error', message: 'License deactivated.' });

    const today = new Date().toISOString().split('T')[0];
    if (license.expiry_date < today) return res.status(403).json({ status: 'error', message: 'License has expired.' });

    if (!license.email) {
      db.prepare(`UPDATE licenses SET email = ?, device_id = ? WHERE id = ?`).run(email, device_id, license.id);
      return res.json({ status: 'success', message: 'Activated', expiry_date: license.expiry_date });
    } else {
      if (license.email !== email || (license.device_id && license.device_id !== device_id)) {
        return res.status(403).json({ status: 'error', message: 'Email or device mismatch.' });
      }
      return res.json({ status: 'success', message: 'Valid', expiry_date: license.expiry_date });
    }
  } catch (err) {
    console.error('Database error:', err.message);
    return res.status(500).json({ status: 'error', message: 'Database error.' });
  }
});

// 🔁 Revalidate License
app.post('/check-license', (req, res) => {
  const { license_key, device_id } = req.body;
  if (!license_key || !device_id) return res.status(400).json({ status: 'error', message: 'Missing params.' });

  try {
    const license = db.prepare(`SELECT * FROM licenses WHERE license_key = ? AND device_id = ?`).get(license_key, device_id);
    if (!license) return res.json({ status: 'invalid' });
    if (license.is_active === 0) return res.json({ status: 'invalid' });
    const today = new Date().toISOString().split('T')[0];
    return res.json({ status: (license.expiry_date < today) ? 'expired' : 'valid' });
  } catch (err) {
    return res.json({ status: 'invalid' });
  }
});

// ─── AUTHENTICATION ───────────────────────────────────────────────────────────
const authenticate = (req, res, next) => {
  const username = req.headers['x-admin-username'];
  const password = req.headers['x-admin-password'];
  
  if (!username || !password) {
    return res.status(401).json({ error: 'Unauthorized: Credentials required.' });
  }

  try {
    const admin = db.prepare(`SELECT * FROM admins WHERE username = ? AND password = ?`).get(username, password);
    if (!admin) return res.status(401).json({ error: 'Unauthorized: Invalid credentials.' });
    next();
  } catch (err) {
    return res.status(500).json({ error: 'Authentication error.' });
  }
};

// 🔐 Admin Login (Verification only)
app.post('/admin/login', (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ status: 'error', message: 'Username and password required.' });
  }

  try {
    const admin = db.prepare(`SELECT * FROM admins WHERE username = ? AND password = ?`).get(username, password);
    if (admin) {
      res.json({ status: 'success', message: 'Logged in.' });
    } else {
      res.status(401).json({ status: 'error', message: 'Invalid credentials.' });
    }
  } catch (err) {
    res.status(500).json({ status: 'error', message: 'Database error.' });
  }
});

// ─── ADMIN APIS (Protected) ───────────────────────────────────────────────────

// 📊 GET All Licenses
app.get('/admin/licenses', authenticate, (req, res) => {
  try {
    const rows = db.prepare(`SELECT * FROM licenses`).all();
    res.json(rows);
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// ➕ ADD Key
app.post('/admin/add-license', authenticate, (req, res) => {
  const { license_key, expiry_date, email } = req.body;
  if (!license_key || !expiry_date) return res.status(400).json({ error: 'Missing data.' });
  try {
    db.prepare(`INSERT INTO licenses (license_key, expiry_date, email) VALUES (?, ?, ?)`).run(license_key, expiry_date, email || null);
    res.status(201).json({ message: 'License added.' });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// ✏️ UPDATE Key (Expiry or Status)
app.put('/admin/license/:id', authenticate, (req, res) => {
  const { expiry_date, is_active } = req.body;
  const { id } = req.params;
  try {
    db.prepare(`UPDATE licenses SET expiry_date = ?, is_active = ? WHERE id = ?`).run(expiry_date, is_active, id);
    res.json({ message: 'Updated.' });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// 🗑️ DELETE Key
app.delete('/admin/license/:id', authenticate, (req, res) => {
  try {
    db.prepare(`DELETE FROM licenses WHERE id = ?`).run(req.params.id);
    res.json({ message: 'Deleted.' });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`\x1b[32m✔ License Server (better-sqlite3) running at ${PORT}\x1b[0m`);
  console.log(`\x1b[34mℹ Live URL: https://markify-backend-3ylb.onrender.com/\x1b[0m`);
});

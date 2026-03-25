const Database = require('better-sqlite3');
const path = require('path');

const dbPath = path.resolve(__dirname, 'licenses.db');
const db = new Database(dbPath);

console.log('Connected to the SQLite database (better-sqlite3).');

db.exec(`CREATE TABLE IF NOT EXISTS licenses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT, 
  license_key TEXT UNIQUE NOT NULL,
  expiry_date TEXT NOT NULL,
  device_id TEXT,
  is_active INTEGER DEFAULT 1
)`);

db.exec(`CREATE TABLE IF NOT EXISTS admins (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password TEXT NOT NULL
)`);

console.log('Licenses table ready (Email is optional for unassigned keys).');

module.exports = db;

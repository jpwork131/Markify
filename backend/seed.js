const db = require('./database');

const sampleKeys = [
  'KEY-001-ALPHA',
  'KEY-002-BRAVO',
  'KEY-003-CHARLIE',
  'KEY-004-DELTA',
  'KEY-005-ECHO',
  'KEY-006-FOXTROT',
  'KEY-007-GOLF',
  'KEY-008-HOTEL',
  'KEY-009-INDIA',
  'KEY-010-JULIET'
];

const expiry = '2027-12-31';

try {
  // Seed Admins
  const adminUser = 'admin';
  const adminPass = 'admin123';
  db.prepare(`INSERT OR IGNORE INTO admins (username, password) VALUES (?, ?)`).run(adminUser, adminPass);
  console.log('✅ Admin account seeded: admin / admin123');

  // Seed Licenses
  const insert = db.prepare(`INSERT OR IGNORE INTO licenses (email, license_key, expiry_date, device_id, is_active) VALUES (?, ?, ?, ?, ?)`);
  
  const transaction = db.transaction((keys) => {
    for (const key of keys) {
      insert.run(null, key, expiry, null, 1);
    }
  });

  transaction(sampleKeys);

  console.log('✅ 10 Sample keys seeded successfully!');
  console.log('Available keys:', sampleKeys.join(', '));
} catch (err) {
  console.error('❌ Error seeding database:', err.message);
} finally {
  db.close();
}

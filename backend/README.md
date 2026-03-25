# 🔑 Markify License Backend

A lightweight, secure licensing server built with **Node.js, Express, and SQLite**. This system manages license key validation, device-binding, and expiration for the Markify application.

## 🚀 Getting Started

### 1. Install Dependencies
Make sure you have [Node.js](https://nodejs.org/) installed, then run:
```bash
npm install
```

### 2. Seed the Database
Run the seed script to create a fresh SQLite database (`licenses.db`) and inject **10 unassigned sample keys**:
```bash
node seed.js
```
*Current Keys: `KEY-001-ALPHA` through `KEY-010-JULIET`*

### 3. Start the Server
Start the Express server on `http://localhost:3000`:
```bash
node index.js
```

### 4. Admin Dashboard 🎨
You can now manage your licenses via the web browser:
📍 **http://localhost:3000/index.html** (or just `http://localhost:3000`)
- **Add / Delete Keys**: Instant creation of license serials.
- **Track Usage**: See how many keys are bound to user emails.
- **Deactivate Users**: Block access to specific keys instantly.
- **Live Edit Expiry**: Change expiration dates without touching the database files.

---

## 📡 API Endpoints

### 1. 🔑 Activation (`/validate-license`)
**POST** | Used when a user first enters their email and key.

**Request Body:**
```json
{
  "email": "user@example.com",
  "license_key": "KEY-001-ALPHA",
  "device_id": "UNIQUE_HARDWARE_ID"
}
```
**Logic:**
- If the key is **unassigned** (new), it binds the provided `email` and `device_id` to the key.
- If the key is **already assigned**, it verifies the `email` and `device_id` match the record.
- Checks if the license is **active** and **not expired**.

---

### 2. 🔁 Re-validation (`/check-license`)
**POST** | Used on every app startup to verify the license status.

**Request Body:**
```json
{
  "license_key": "KEY-001-ALPHA",
  "device_id": "UNIQUE_HARDWARE_ID"
}
```
**Returns:**
- `{ "status": "valid" }`
- `{ "status": "expired" }`
- `{ "status": "invalid" }`

---

### 3. 🧑‍💻 Admin Admin (`/admin/add-license`)
**POST** | Manually create a new license.

**Request Body:**
```json
{
  "license_key": "CUSTOM-KEY-555",
  "expiry_date": "2028-01-01",
  "email": "optional@email.com"
}
```

---

## 🗄️ Database Schema (SQLite)

| Column | Type | Description |
| :--- | :--- | :--- |
| `id` | INTEGER | Primary Key (Auto-increment) |
| `email` | TEXT | Encapsulates the user's email address (optional until assigned) |
| `license_key` | TEXT | The unique serial key (Unique constraint) |
| `expiry_date` | TEXT | ISO Format Date (e.g., `2026-12-31`) |
| `device_id` | TEXT | Bound hardware UUID |
| `is_active` | INTEGER | `1` for active, `0` to block access |

---

## 🔐 Security Features
- **Device Locking**: Prevents sharing keys by binding them to the specific motherboard/hardware UUID on Windows or Android ID.
- **Expiry Guard**: Built-in server-side and client-side checks to automatically logout users once their time is up.
- **Offline Grace Period**: The Flutter client is configured to allow offline usage for up to **3 days** before forcing an online re-check.
- **Concurrency**: SQLite handles multiple requests efficiently for small-to-medium scale deployments.

## 🛠️ Deployment Tips
When moving to production:
1. Change the `baseUrl` in your Flutter app's `license_service.dart`.
2. Add a secure API Token header to your requests.
3. Use HTTPS (SSL) to encrypt traffic between the app and the server.
